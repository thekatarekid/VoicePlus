import Foundation

/// Latched-mode end-of-utterance detection driven by VAD events.
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

/// V4.21 — how much speech the VAD heard, and where, on one capture stream's clock.
///
/// Fed with the pipeline's VAD events (stream seconds since capture opened) and asked for the
/// speech inside a window — one segment's audio. `Endpointer.speechHeard` only says *whether*;
/// the no-speech gate needs *how much*, per segment, because a latched session closes several
/// segments on the same stream.
///
/// Three properties the engine relies on:
/// * An interval still open when a window closes counts up to the window's end. The VAD emits
///   `speechEnd` after its hangover, so at key release the last word is usually still "in speech".
/// * Overlapping intervals merge. The VAD pads both ends of a speech run, so a quick second run
///   can start before the padded end of the first; it is the same speech, counted once.
/// * A repeated event is ignored. Feeding the same VAD twice (the pipeline subscription and an
///   `onVAD` forward) must not double the count; a real VAD never emits the same edge twice.
public struct SpeechLedger: Sendable, Equatable {
    /// Closed speech runs, in the order they ended, merged where they overlap.
    public private(set) var intervals: [ClosedRange<TimeInterval>] = []
    /// Start of the run still in progress, if any.
    public private(set) var openStart: TimeInterval?
    private var seen: Set<Edge> = []

    private struct Edge: Hashable, Sendable {
        let isStart: Bool
        let bits: UInt64
    }

    public init() {}

    /// Records one VAD edge. Returns false when it changed nothing (a duplicate, a start while
    /// already in speech, an end while not in speech).
    @discardableResult
    public mutating func note(_ event: VADEvent) -> Bool {
        let t = max(0, event.time)
        let edge: Edge
        switch event {
        case .speechStart: edge = Edge(isStart: true, bits: t.bitPattern)
        case .speechEnd: edge = Edge(isStart: false, bits: t.bitPattern)
        }
        guard seen.insert(edge).inserted else { return false }
        switch event {
        case .speechStart:
            guard openStart == nil else { return false }
            if let last = intervals.last, t <= last.upperBound {
                // Padding overlap with the previous run: reopen it rather than count twice.
                intervals.removeLast()
                openStart = last.lowerBound
            } else {
                openStart = t
            }
        case .speechEnd:
            guard let start = openStart else { return false }
            openStart = nil
            intervals.append(start...max(start, t))
        }
        return true
    }

    /// Seconds of speech inside `[start, end]`. An open run counts up to `end`.
    public func speechSeconds(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        guard end > start else { return 0 }
        var total: TimeInterval = 0
        for run in intervals { total += Self.overlap(run.lowerBound, run.upperBound, start, end) }
        if let open = openStart { total += Self.overlap(open, end, start, end) }
        return total
    }

    /// True once any speech edge has been recorded.
    public var heardSpeech: Bool { openStart != nil || !intervals.isEmpty }

    public mutating func reset() { intervals.removeAll(); openStart = nil; seen.removeAll() }

    private static func overlap(_ a0: TimeInterval, _ a1: TimeInterval, _ b0: TimeInterval, _ b1: TimeInterval) -> TimeInterval {
        max(0, min(a1, b1) - max(a0, b0))
    }
}
