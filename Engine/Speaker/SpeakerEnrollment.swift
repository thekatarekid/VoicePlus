import Foundation

/// Onboarding-2 enrollment: the user reads three prompts; their embeddings are averaged into a
/// centroid profile. Pure model — the UI drives `record(_:)` with captured samples.
public struct SpeakerEnrollment: Equatable, Sendable {
    public static let prompts = [
        "Hey VoicePlus, this is how I normally talk.",
        "Type a quick reply and send it to the team.",
        "Remind me to call the dentist on Thursday afternoon."
    ]
    public static let requiredUtterances = 3
    /// Enrollment utterances must be roughly consistent (guards against a TV in the background).
    /// Deliberately loose: single-utterance Gaussians are noisier than the final centroid.
    public static let minConsistency: Float = 0.15

    public enum Step: Equatable, Sendable { case prompt(Int), done }
    public private(set) var embeddings: [SpeakerEmbedding] = []
    public private(set) var profile: SpeakerProfile?

    public init() {}
    public var step: Step { embeddings.count >= Self.requiredUtterances ? .done : .prompt(embeddings.count) }
    public var currentPrompt: String? { if case .prompt(let i) = step { return Self.prompts[i] } ; return nil }

    public enum Outcome: Equatable, Sendable { case accepted(Int), inconsistent(similarity: Float), complete }

    /// Adds one utterance. Rejects an utterance whose cosine to the running centroid is below
    /// `minConsistency` (someone else spoke). Returns `.complete` when the profile is built.
    @discardableResult
    public mutating func record(_ e: SpeakerEmbedding) -> Outcome {
        guard step != .done else { return .complete }
        if let c = SpeakerEmbedding.centroid(embeddings) {
            let s = c.similarity(e)
            if s < Self.minConsistency { return .inconsistent(similarity: s) }
        }
        embeddings.append(e)
        if step == .done, let c = SpeakerEmbedding.centroid(embeddings) {
            profile = SpeakerProfile(centroid: c, utteranceCount: embeddings.count, enrolledAt: Date())
            return .complete
        }
        return .accepted(embeddings.count)
    }

    public mutating func reset() { embeddings = []; profile = nil }
}

/// The enrolled user. Persisted as JSON (no raw audio is ever stored).
public struct SpeakerProfile: Codable, Equatable, Sendable {
    public var centroid: SpeakerEmbedding
    public var utteranceCount: Int
    public var enrolledAt: Date
    /// "Not you" corrections: embeddings of speech the user said was not theirs.
    public var negatives: [SpeakerEmbedding] = []

    public init(centroid: SpeakerEmbedding, utteranceCount: Int, enrolledAt: Date) {
        self.centroid = centroid; self.utteranceCount = utteranceCount; self.enrolledAt = enrolledAt
    }

    /// Fold a confirmed-user utterance into the centroid (slow adaptation).
    public mutating func reinforce(_ e: SpeakerEmbedding, weight: Float = 0.1) {
        centroid = centroid.blended(with: e, weight: weight)
        utteranceCount += 1
    }

    public mutating func addNegative(_ e: SpeakerEmbedding, keep: Int = 32) {
        negatives.append(e)
        if negatives.count > keep { negatives.removeFirst(negatives.count - keep) }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    public static func load(from url: URL) throws -> SpeakerProfile {
        try JSONDecoder().decode(SpeakerProfile.self, from: Data(contentsOf: url))
    }
}
