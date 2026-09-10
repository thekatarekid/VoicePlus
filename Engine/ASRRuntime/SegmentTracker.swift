import Foundation
import Shared

/// R2.2 — segment identity, ordering, and the bounds (V3 §4.5).
///
/// One instance per engine. It owns the answers to four questions the engine must not guess at:
///
///  1. **Which segment is open?** A session is a fresh `UUID`; segments count from 0 inside it.
///  2. **Is this result still wanted?** Anything from another session, or at/behind the last
///     committed index, is refused — a second pass that lands after its segment was already
///     delivered must never rewrite delivered text (V3 §5.3).
///  3. **In what order does text land?** Commits are *released* in ascending index order. A
///     segment that finishes early waits for its predecessor instead of jumping the queue; a
///     slow predecessor is not mistaken for a stale result.
///  4. **How much may be in flight?** `bounds.maxPendingSegments` (2). Past it, the caller must
///     commit pass-1 rather than queue more work.
///
/// Cross-session comparison is done with `isSameSession(as:)` / `precedes(_:)`, never with raw
/// `<` — `SegmentID`'s `Comparable` tiebreaks across sessions on the UUID, which carries no
/// meaning and would silently accept a foreign result as "newer".
public final class SegmentTracker: @unchecked Sendable {
    /// The bounds from the build doc: at most two segments in flight at once.
    public struct Bounds: Sendable {
        public var maxPendingSegments: Int
        /// Ring capacity, in seconds of 16 kHz audio, for one segment's samples. Generous — it
        /// exists so a wedged session cannot grow without limit, not to trim real speech
        /// (`Endpointer.maxUtterance` is 120 s).
        public var maxBufferedSeconds: TimeInterval

        public init(maxPendingSegments: Int = 2, maxBufferedSeconds: TimeInterval = 180) {
            self.maxPendingSegments = max(1, maxPendingSegments)
            self.maxBufferedSeconds = max(1, maxBufferedSeconds)
        }
    }

    /// What `commit(_:spans:)` decided.
    public enum CommitOutcome: Equatable {
        /// Refused by identity; nothing was released.
        case rejected(SegmentRejection)
        /// Accepted. These segments are now deliverable, in ascending index order — the one just
        /// committed plus any successors that had been waiting behind it. Empty is impossible.
        case released([(segment: SegmentID, spans: [TranscriptSpan])])

        public static func == (lhs: CommitOutcome, rhs: CommitOutcome) -> Bool {
            switch (lhs, rhs) {
            case (.rejected(let a), .rejected(let b)): return a == b
            case (.released(let a), .released(let b)):
                return a.count == b.count && zip(a, b).allSatisfy { $0.segment == $1.segment && $0.spans == $1.spans }
            default: return false
            }
        }
    }

    public private(set) var bounds: Bounds
    private let lock = NSLock()

    private var sessionID: UUID?
    /// The segment currently taking audio. `nil` between sessions.
    private var open: SegmentID?
    /// Highest index ever opened in this session, so a made-up index can be spotted.
    private var highestOpened = -1
    private var lastCommitted: SegmentID?
    /// Closed, not yet committed. Bounded by `bounds.maxPendingSegments`.
    private var pending: [SegmentID] = []
    /// Committed out of order; held until their predecessor lands.
    private var holding: [SegmentID: [TranscriptSpan]] = [:]

    public init(bounds: Bounds = Bounds()) { self.bounds = bounds }

    // MARK: session lifecycle

    /// Starts a fresh session and opens segment 0. Any prior state is dropped.
    @discardableResult
    public func beginSession(id: UUID = UUID()) -> SegmentID {
        lock.withLock {
            sessionID = id
            let first = SegmentID.first(in: id)
            open = first
            highestOpened = 0
            lastCommitted = nil
            pending.removeAll()
            holding.removeAll()
            return first
        }
    }

    /// Ends the session. Later results for it are refused with `.noSession`.
    public func endSession() {
        lock.withLock {
            sessionID = nil
            open = nil
            highestOpened = -1
            lastCommitted = nil
            pending.removeAll()
            holding.removeAll()
        }
    }

    public var currentSessionID: UUID? { lock.withLock { sessionID } }
    /// The segment taking audio right now.
    public var openSegment: SegmentID? { lock.withLock { open } }
    public var lastCommittedSegment: SegmentID? { lock.withLock { lastCommitted } }
    public var pendingCount: Int { lock.withLock { pending.count } }
    /// True when the backlog is full: the caller must commit pass-1 instead of queueing.
    public var isBacklogFull: Bool { lock.withLock { pending.count >= bounds.maxPendingSegments } }

    // MARK: closing

    /// Closes the open segment. When `openNext` is true (an endpoint in latch mode) the next
    /// segment is opened immediately and returned; on key release the session's last segment
    /// closes and nothing is opened.
    ///
    /// Returns `nil` when no segment is open.
    public func closeOpenSegment(openNext: Bool) -> (closed: SegmentID, opened: SegmentID?)? {
        lock.withLock {
            guard let closed = open else { return nil }
            if openNext {
                let next = closed.next
                open = next
                highestOpened = max(highestOpened, next.index)
                return (closed, next)
            }
            open = nil
            return (closed, nil)
        }
    }

    // MARK: admission and the backlog

    /// Why `id` cannot be committed, or `nil` if it can. Pure — no state changes.
    public func rejection(for id: SegmentID) -> SegmentRejection? {
        lock.withLock { rejectionLocked(for: id) }
    }

    private func rejectionLocked(for id: SegmentID) -> SegmentRejection? {
        guard let sessionID else { return .noSession }
        // Session first: ordering between sessions is meaningless, so it must never be consulted.
        guard id.isSameSession(as: SegmentID.first(in: sessionID)) else { return .foreignSession }
        guard id.index >= 0, id.index <= highestOpened else { return .unknownSegment }
        if let last = lastCommitted {
            // `precedes` cannot be nil here — same session was just established.
            if id == last || id.precedes(last) == true { return .alreadyCommitted }
        }
        return nil
    }

    /// Claims a slot in the pending backlog for a closed segment whose result is not ready yet
    /// (a second pass in flight). `false` means the backlog is full — the caller must commit
    /// pass-1 now, with `SegmentCloseReason.backlogBound`.
    public func enqueuePending(_ id: SegmentID) -> Bool {
        lock.withLock {
            guard rejectionLocked(for: id) == nil else { return false }
            guard !pending.contains(id) else { return true }
            guard pending.count < bounds.maxPendingSegments else { return false }
            pending.append(id)
            return true
        }
    }

    /// Drops a pending slot without committing (cancellation).
    public func dropPending(_ id: SegmentID) {
        lock.withLock { pending.removeAll { $0 == id } }
    }

    // MARK: committing

    /// Commits `spans` for `id`, releasing everything that is now in order.
    public func commit(_ id: SegmentID, spans: [TranscriptSpan]) -> CommitOutcome {
        lock.withLock {
            if let reason = rejectionLocked(for: id) { return .rejected(reason) }
            pending.removeAll { $0 == id }
            holding[id] = spans

            // Release in index order, starting at the successor of the last committed one.
            var released: [(segment: SegmentID, spans: [TranscriptSpan])] = []
            var expected = lastCommitted.map(\.next) ?? SegmentID.first(in: id.sessionID)
            while let ready = holding.removeValue(forKey: expected) {
                released.append((expected, ready))
                lastCommitted = expected
                expected = expected.next
            }
            // `id` itself finished early and is waiting behind a predecessor: nothing to deliver
            // yet, but it is accepted, not stale.
            return .released(released)
        }
    }
}
