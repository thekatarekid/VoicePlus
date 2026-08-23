import Foundation

/// Decides whether an utterance was spoken by the enrolled user. In hands-free mode anything
/// that is not the user (TV, podcast, colleague) is dropped before it reaches the pipeline.
public struct SpeakerGate: Sendable {
    public enum Verdict: Equatable, Sendable {
        case user(similarity: Float)
        case other(similarity: Float)
        /// No profile enrolled, or the embedder failed: caller decides (default: allow).
        case unknown
        public var isUser: Bool { if case .user = self { return true } ; return false }
    }

    public var profile: SpeakerProfile?
    /// Similarity threshold on the profile centroid. MFCC fallback: 0.5 (= distance D₀, tuned on
    /// the fixture corpus, see SpeakerRejectionTests); WeSpeaker cosine: 0.6 like Engine/Meeting.
    public var threshold: Float
    /// Margin by which a "not you" negative must beat the centroid to veto a user verdict.
    public var negativeMargin: Float = 0.05

    public init(profile: SpeakerProfile?, threshold: Float = 0.6) {
        self.profile = profile; self.threshold = threshold
    }

    public static func defaultThreshold(for embedder: any SpeakerEmbedder) -> Float {
        embedder is MFCCEmbedder ? 0.5 : 0.6
    }

    public func verdict(for e: SpeakerEmbedding) -> Verdict {
        guard let p = profile, p.centroid.vector.count == e.vector.count else { return .unknown }
        let s = p.centroid.similarity(e)
        guard s >= threshold else { return .other(similarity: s) }
        let bestNeg = p.negatives.map { $0.similarity(e) }.max() ?? -1
        return bestNeg > s + negativeMargin ? .other(similarity: s) : .user(similarity: s)
    }

    public func verdict(for samples: [Float], embedder: any SpeakerEmbedder) -> Verdict {
        guard let e = try? embedder.embed(samples) else { return .unknown }
        return verdict(for: e)
    }

    /// Hands-free policy: pass the utterance only when it is the user (or when identity is unknown).
    public func shouldAccept(_ v: Verdict, handsFree: Bool) -> Bool {
        guard handsFree else { return true }
        switch v { case .user, .unknown: return true; case .other: return false }
    }
}
