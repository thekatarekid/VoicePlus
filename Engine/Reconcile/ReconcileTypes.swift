import Foundation
import Shared

public extension StageID {
    /// Bet 4 dual-path reconciler (Phase 1.5).
    static let dualPath: StageID = "dualPath"
}

/// Wall-clock stats for one dual-path run. `overlap` is the time both passes were in flight —
/// the window in which ANE contention can occur. `contentionRatio` = final wall time while the
/// preview was also running ÷ final wall time (1.0 = fully contended).
public struct DualPathTiming: Equatable, Sendable {
    public var previewWall: TimeInterval
    public var finalWall: TimeInterval
    public var overlap: TimeInterval
    public var totalWall: TimeInterval
    public var previewFeeds: Int
    public var audioSeconds: TimeInterval

    public init(previewWall: TimeInterval, finalWall: TimeInterval, overlap: TimeInterval, totalWall: TimeInterval, previewFeeds: Int, audioSeconds: TimeInterval) {
        self.previewWall = previewWall; self.finalWall = finalWall; self.overlap = overlap
        self.totalWall = totalWall; self.previewFeeds = previewFeeds; self.audioSeconds = audioSeconds
    }

    public var contentionRatio: Double { finalWall > 0 ? min(1, overlap / finalWall) : 0 }
    public var finalRealTimeFactor: Double { audioSeconds > 0 ? finalWall / audioSeconds : 0 }
}

/// Output of `DualPathRunner`: the fast hypothesis (what we injected) and the accurate one.
public struct DualPathResult: Equatable, Sendable {
    public var preview: [TranscriptSpan]
    public var final: [TranscriptSpan]
    public var timing: DualPathTiming
    public init(preview: [TranscriptSpan], final: [TranscriptSpan], timing: DualPathTiming) {
        self.preview = preview; self.final = final; self.timing = timing
    }
}

/// One region where preview and final disagree, produced by `WordAligner.disagreements`.
public struct Disagreement: Equatable, Sendable {
    /// Index range into the preview spans (may be empty for a pure insertion).
    public var previewRange: Range<Int>
    /// Index range into the final spans (may be empty for a pure deletion).
    public var finalRange: Range<Int>
    public var previewText: String
    public var finalText: String
    public var previewConfidence: Float
    public var finalConfidence: Float
    public var audioRange: ClosedRange<TimeInterval>

    public init(previewRange: Range<Int>, finalRange: Range<Int>, previewText: String, finalText: String,
                previewConfidence: Float, finalConfidence: Float, audioRange: ClosedRange<TimeInterval>) {
        self.previewRange = previewRange; self.finalRange = finalRange
        self.previewText = previewText; self.finalText = finalText
        self.previewConfidence = previewConfidence; self.finalConfidence = finalConfidence
        self.audioRange = audioRange
    }
}

/// What the planner decided for one disagreement.
public enum CorrectionDecision: Equatable, Sendable {
    /// Silently replace `range` (UTF-16, in the focused element) — all three rules passed.
    case correct
    /// Show as a suggestion; never touch the document.
    case suggest(reason: SuggestReason)
    /// Not worth surfacing at all (e.g. case/punctuation-only difference, tiny confidence delta).
    case drop(reason: DropReason)

    public enum SuggestReason: String, Sendable { case safetyMismatch, readbackUnavailable, lowFinalConfidence }
    public enum DropReason: String, Sendable { case semanticallyEqual, confidenceDeltaBelowThreshold, emptyReplacement }
}

/// One planned edit. `range`/`expected` are what the applier hands to the `ReplaceRangeSink`,
/// which re-checks `expected` at write time (second line of defence).
public struct CorrectionItem: Equatable, Sendable {
    public var utteranceID: UUID
    public var range: Range<Int>
    public var expected: String
    public var replacement: String
    public var confidenceDelta: Float
    public var audioRange: ClosedRange<TimeInterval>
    public var decision: CorrectionDecision
    public init(utteranceID: UUID, range: Range<Int>, expected: String, replacement: String, confidenceDelta: Float,
                audioRange: ClosedRange<TimeInterval>, decision: CorrectionDecision) {
        self.utteranceID = utteranceID; self.range = range; self.expected = expected; self.replacement = replacement
        self.confidenceDelta = confidenceDelta; self.audioRange = audioRange; self.decision = decision
    }
}

public struct CorrectionPlan: Equatable, Sendable {
    public var utteranceID: UUID
    public var items: [CorrectionItem]
    public init(utteranceID: UUID, items: [CorrectionItem]) { self.utteranceID = utteranceID; self.items = items }
    public var corrections: [CorrectionItem] { items.filter { $0.decision == .correct } }
    public var suggestions: [CorrectionItem] { items.filter { if case .suggest = $0.decision { return true }; return false } }
    public var isEmpty: Bool { items.isEmpty }
}

/// What actually happened to a plan item, for the UX layer (P1.5.2: shimmer/underline, "was: …",
/// revert, "show what changed") and for Lab precision counting.
public struct CorrectionEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Document was changed; `range` now holds `replacement`.
        case applied
        /// Surfaced as a suggestion only.
        case suggested(CorrectionDecision.SuggestReason)
        /// Planned as a correction but the sink refused at write time (document changed in between).
        case refused
    }
    public var utteranceID: UUID
    public var kind: Kind
    /// UTF-16 range in the field after the edit (for `.applied`) or the original target (otherwise).
    public var range: Range<Int>
    public var was: String
    public var now: String
    public var audioRange: ClosedRange<TimeInterval>
    public init(utteranceID: UUID, kind: Kind, range: Range<Int>, was: String, now: String, audioRange: ClosedRange<TimeInterval>) {
        self.utteranceID = utteranceID; self.kind = kind; self.range = range; self.was = was; self.now = now; self.audioRange = audioRange
    }
}

/// Consumed by the correction UX (P1.5.2). Named `CorrectionEventSink` because `CorrectionSink`
/// is already taken by the P1.6 provenance logger in `Engine/Repair`.
public protocol CorrectionEventSink: AnyObject, Sendable {
    func correction(_ event: CorrectionEvent)
}

/// Readback entry point (Bet 4 safety rule). Production: Injection's AX `focusedElement().value`.
public protocol DocumentReadback: AnyObject, Sendable {
    /// The focused element's full value, or nil when AX cannot read it.
    func currentText() -> String?
}

// MARK: - In-memory implementations

public final class InMemoryCorrectionEventSink: CorrectionEventSink, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var events: [CorrectionEvent] = []
    public init() {}
    public func correction(_ event: CorrectionEvent) { lock.withLock { events.append(event) } }
}

/// Readback over an in-memory document. Pair with `InMemoryReplaceRangeSink` by handing it the
/// same sink, so readback tracks applied corrections.
public final class SinkReadback: DocumentReadback, @unchecked Sendable {
    private let sink: InMemoryReplaceRangeSink
    public var unavailable = false
    public init(_ sink: InMemoryReplaceRangeSink) { self.sink = sink }
    public func currentText() -> String? { unavailable ? nil : sink.document }
}
