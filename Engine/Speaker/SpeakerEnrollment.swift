import Foundation

/// Speaker enrollment: embeddings of the user's speech averaged into a centroid profile. Pure
/// model — the caller embeds the audio and hands the embedding in. No audio is ever kept.
///
/// Two ways in:
/// * **Prompted** (onboarding-2, Voice › Enrollment): the user reads three prompts; `record(_:)`.
/// * **Passive** (V4.49, H2): the fallback when the user skips the prompted step. A hold-to-talk
///   utterance is the user by definition — they pressed the key — so the first
///   `passiveUtterances` holds with at least `minimumHoldSpeechSeconds` of VAD speech build the
///   profile silently; `recordHold(_:speechSeconds:)`.
///
/// Codable so a passive enrollment in progress survives a relaunch (ten holds rarely happen in one
/// session). What is encoded is embeddings — never samples.
public struct SpeakerEnrollment: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable { case prompted, passive }

    public static let prompts = [
        "Hey VoicePlus, this is how I normally talk.",
        "Type a quick reply and send it to the team.",
        "Remind me to call the dentist on Thursday afternoon."
    ]
    /// Prompted enrollment: three read phrases.
    public static let requiredUtterances = 3
    /// V4.49 — passive enrollment: ten hold-to-talk utterances.
    public static let passiveUtterances = 10
    /// V4.49 — a hold counts toward passive enrollment only with this much VAD speech in it. Shorter
    /// ("yes", "send it") gives an embedding too noisy to average into an identity.
    public static let minimumHoldSpeechSeconds: TimeInterval = 1.5
    /// Enrollment utterances must be roughly consistent (guards against a TV in the background).
    /// Deliberately loose: single-utterance Gaussians are noisier than the final centroid.
    public static let minConsistency: Float = 0.15

    /// In passive mode `prompt(n)` means "n utterances learned so far"; there is nothing to read,
    /// so `currentPrompt` is nil.
    public enum Step: Equatable, Sendable { case prompt(Int), done }
    public private(set) var mode: Mode
    public private(set) var embeddings: [SpeakerEmbedding] = []
    public private(set) var profile: SpeakerProfile?

    public init(mode: Mode = .prompted) { self.mode = mode }

    /// How many accepted utterances build the profile in this mode.
    public var requiredCount: Int { mode == .passive ? Self.passiveUtterances : Self.requiredUtterances }
    /// Accepted utterances so far (the "learning N of 10" number).
    public var learnedCount: Int { min(embeddings.count, requiredCount) }
    /// 0…1, for a progress bar.
    public var progress: Double { Double(learnedCount) / Double(requiredCount) }
    public var step: Step { embeddings.count >= requiredCount ? .done : .prompt(embeddings.count) }
    public var currentPrompt: String? {
        guard mode == .prompted, case .prompt(let i) = step, Self.prompts.indices.contains(i) else { return nil }
        return Self.prompts[i]
    }

    public enum Outcome: Equatable, Sendable { case accepted(Int), inconsistent(similarity: Float), complete }

    /// Adds one utterance. Rejects an utterance whose similarity to the running centroid is below
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

    // MARK: Passive (V4.49)

    public enum HoldOutcome: Equatable, Sendable {
        /// Under `minimumHoldSpeechSeconds` of speech: ignored, nothing learned.
        case tooShort(speechSeconds: TimeInterval)
        /// Did not sound like the holds learned so far (someone else was louder): not averaged in.
        case inconsistent(similarity: Float)
        /// Learned; `n` of `passiveUtterances`.
        case learned(Int)
        /// The tenth hold: the profile is built.
        case complete(SpeakerProfile)
        /// Nothing left to learn.
        case alreadyComplete
    }

    /// Whether a hold with this much VAD speech counts. Lets a caller skip the embedder entirely for
    /// a short hold.
    public static func holdQualifies(speechSeconds: TimeInterval) -> Bool {
        speechSeconds >= minimumHoldSpeechSeconds
    }

    /// One hold-to-talk utterance, already embedded. Only meaningful in `.passive` mode; a prompted
    /// enrollment ignores holds (`.alreadyComplete` is never the answer there — the user is reading).
    @discardableResult
    public mutating func recordHold(_ e: SpeakerEmbedding, speechSeconds: TimeInterval) -> HoldOutcome {
        guard step != .done else { return .alreadyComplete }
        guard Self.holdQualifies(speechSeconds: speechSeconds) else { return .tooShort(speechSeconds: speechSeconds) }
        // A different backend (the embedding weights arrived part-way through) produces vectors that
        // cannot be averaged with the old ones. Start over rather than build a profile nobody can use.
        if let first = embeddings.first, !first.isComparable(with: e) { embeddings.removeAll() }
        switch record(e) {
        case .accepted(let n): return .learned(n)
        case .inconsistent(let s): return .inconsistent(similarity: s)
        case .complete: return profile.map(HoldOutcome.complete) ?? .alreadyComplete
        }
    }

    public mutating func reset() { embeddings = []; profile = nil }
}

extension SpeakerEmbedding {
    /// Same backend, same metric, same length: the only pairs whose similarity means anything.
    public func isComparable(with other: SpeakerEmbedding) -> Bool {
        embedder == other.embedder && metric == other.metric && vector.count == other.vector.count
    }
}

/// The enrolled user. Persisted as JSON (no raw audio is ever stored).
public struct SpeakerProfile: Codable, Equatable, Sendable {
    public var centroid: SpeakerEmbedding
    public var utteranceCount: Int
    public var enrolledAt: Date
    /// "Not you" corrections: embeddings of speech the user said was not theirs.
    public var negatives: [SpeakerEmbedding] = []
    /// H2 — the similarity a latch segment must reach after "Not you" corrections. Each correction
    /// lifts it just past the similarity of the voice the user rejected (`noteNotYou`); `SpeakerGate`
    /// applies it, bounded above so corrections can never lock the user out. nil = never corrected.
    public var thresholdFloor: Float?

    /// How far past a rejected voice's similarity the floor is set.
    public static let notYouStep: Float = 0.02

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

    /// H2 — "Not you": the voice was let through and it was not the user. Keep it as a negative, and
    /// raise the threshold to just above how similar it was, so the same voice is not let through
    /// again at that similarity. The floor only ever rises; `SpeakerGate` caps what it applies.
    public mutating func noteNotYou(_ e: SpeakerEmbedding) {
        addNegative(e)
        guard centroid.isComparable(with: e) else { return }
        let lifted = min(1, centroid.similarity(e) + Self.notYouStep)
        thresholdFloor = max(thresholdFloor ?? lifted, lifted)
    }

    enum CodingKeys: String, CodingKey { case centroid, utteranceCount, enrolledAt, negatives, thresholdFloor }

    /// Profiles written before a field existed still load: `negatives` and `thresholdFloor` are
    /// optional on disk.
    public init(from decoder: Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        centroid = try c.decode(SpeakerEmbedding.self, forKey: .centroid)
        utteranceCount = try c.decode(Int.self, forKey: .utteranceCount)
        enrolledAt = try c.decode(Date.self, forKey: .enrolledAt)
        negatives = try c.decodeIfPresent([SpeakerEmbedding].self, forKey: .negatives) ?? []
        thresholdFloor = try c.decodeIfPresent(Float.self, forKey: .thresholdFloor)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    public static func load(from url: URL) throws -> SpeakerProfile {
        try JSONDecoder().decode(SpeakerProfile.self, from: Data(contentsOf: url))
    }
}
