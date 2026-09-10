import Foundation
import Shared

/// R2.2 — the engine's *segment* surface.
///
/// `EngineEvent` (in `Shared`) is the frozen utterance-shaped contract: one `.final` per
/// `stop()`. A segment is finer than that — V3 §4.2/§4.3 close a segment on **key release**
/// (hold) *and* on **endpoint** (latch, where capture continues afterwards), so one dictation
/// session can produce several committed pieces of text that must land in spoken order.
///
/// This stream carries that. `RealEngine.segmentEvents()` hands it out; it runs alongside
/// `events()`, which keeps behaving exactly as it did (see `RealEngine.segmentEvents()` for why
/// no case was added to `EngineEvent`).
///
/// Every event names its `SegmentID`, and every span carries its `Stability`:
/// `.preview` spans are `.provisional` and may be rewritten freely; `.closed` spans are
/// `.committed` (a segment closed mid-session by an endpoint) or `.final` (the segment that
/// closed the session), and are never retracted.
public enum SegmentEvent: Equatable, Sendable {
    /// A new segment is accumulating audio. Emitted on session start and after every closure
    /// that leaves capture open.
    case opened(SegmentID)

    /// Preview text for the open segment. Spans are `.provisional`; the pill owns them.
    case preview(segment: SegmentID, spans: [TranscriptSpan])

    /// The segment closed and its text is committed. Released in ascending `SegmentID` order,
    /// once per segment. `stability` is `.committed` while the session continues, `.final` for
    /// the segment that ended it.
    case closed(segment: SegmentID, spans: [TranscriptSpan], stability: Stability, reason: SegmentCloseReason)

    /// A result was dropped because its identity says it cannot be delivered.
    case rejected(segment: SegmentID, reason: SegmentRejection)
}

/// Why a segment stopped taking audio.
public enum SegmentCloseReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// Hold mode: the user released the key. This also ends the session (V3 §4.2).
    case keyRelease
    /// Latch mode: the endpointer decided speech ended. Capture continues (V3 §4.3).
    case endpoint
    /// The pending-segment backlog was full, so this segment committed its pass-1 text
    /// instead of waiting for refinement (V3 §5.3, "bounded backlog").
    case backlogBound
    /// Capture was abandoned; nothing is committed for this segment.
    case cancelled
}

/// Why a result carrying a `SegmentID` was refused.
public enum SegmentRejection: String, Codable, Sendable, Equatable, CaseIterable {
    /// No session is open, so no segment can belong to one.
    case noSession
    /// The result belongs to a different dictation session (`isSameSession(as:)` is false).
    case foreignSession
    /// The result is for a segment at or before the last committed one — a late second pass,
    /// or a duplicate. Committed text is never retracted or rewritten (V3 §5.3).
    case alreadyCommitted
    /// The segment index was never opened in this session.
    case unknownSegment
}

/// Fan-out for `SegmentEvent`, same shape as `Shared.EngineEventBroadcaster`: subscribers
/// register eagerly so events sent between `subscribe()` and the first `for await` are buffered
/// rather than lost.
public final class SegmentEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SegmentEvent>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<SegmentEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SegmentEvent>.makeStream()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func send(_ event: SegmentEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(event) }
    }

    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }
}
