import Foundation

/// Hands-free end-of-utterance detection driven by VAD events.
/// Fires `.endpoint` once speech has been heard and `trailingSilence` has elapsed since it ended,
/// `.noSpeech` if nothing was heard within `noSpeechTimeout`, and `.maxDuration` as a hard stop.
public struct Endpointer: Sendable {
    public enum Decision: Equatable, Sendable { case endpoint(at: TimeInterval), noSpeech, maxDuration }

    public var trailingSilence: TimeInterval
    public var noSpeechTimeout: TimeInterval
    public var maxUtterance: TimeInterval
    private(set) public var speechHeard = false
    private(set) public var inSpeech = false
    private var lastSpeechEnd: TimeInterval = 0
    private var decided = false

    public init(trailingSilence: TimeInterval = 1.2, noSpeechTimeout: TimeInterval = 8.0, maxUtterance: TimeInterval = 120) {
        self.trailingSilence = trailingSilence
        self.noSpeechTimeout = noSpeechTimeout
        self.maxUtterance = maxUtterance
    }

    public mutating func speechStarted(at _: TimeInterval) { speechHeard = true; inSpeech = true }
    public mutating func speechEnded(at t: TimeInterval) { inSpeech = false; lastSpeechEnd = t }

    /// Call on every audio tick with the current stream position. Returns at most one decision, once.
    public mutating func tick(now: TimeInterval) -> Decision? {
        guard !decided else { return nil }
        if now >= maxUtterance { decided = true; return .maxDuration }
        if !speechHeard {
            if now >= noSpeechTimeout { decided = true; return .noSpeech }
            return nil
        }
        if !inSpeech, now - lastSpeechEnd >= trailingSilence { decided = true; return .endpoint(at: lastSpeechEnd) }
        return nil
    }

    public mutating func reset() { speechHeard = false; inSpeech = false; lastSpeechEnd = 0; decided = false }
}
