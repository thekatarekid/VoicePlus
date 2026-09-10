import Foundation
import Shared

/// R2.3 — the ordered commit queue: committed segments reach the field in `SegmentID` order, and
/// the same segment is never delivered twice.
///
/// Why it is needed: with a second recognition pass and a latch, segment 2 can finalize before
/// segment 1 (a short sentence overtaking a long one), and a retry or a duplicated engine event can
/// present the same segment again. Text is append-only (V3 §14.3) — there is no way to reorder or
/// retract what already landed — so ordering has to happen *before* delivery.
///
/// Both memories are bounded. `maxPending` caps how long an out-of-order segment may wait: past it,
/// the queue stops waiting for the missing index and releases what it has, in order, because
/// committed text arriving late is still better than committed text never arriving.
/// `deliveredMemory` caps duplicate suppression at the last N ids.
public final class CommitQueue {
    public struct Entry: Equatable, Sendable {
        public var segment: SegmentID
        public var request: InjectionRequest
        public init(segment: SegmentID, request: InjectionRequest) {
            self.segment = segment
            self.request = request
        }
    }

    /// How many out-of-order segments may wait for a gap to fill before the queue gives up waiting.
    /// Matches the engine's pending-segment backlog bound (R2.2, max 2) with one slot of slack.
    public var maxPending = 3
    /// How many delivered ids are remembered for duplicate suppression.
    public var deliveredMemory = 64

    /// Segments waiting for an earlier index, sorted.
    public private(set) var pending: [Entry] = []
    /// Ids already released, newest last, bounded by `deliveredMemory`.
    public private(set) var deliveredIDs: [SegmentID] = []
    /// The session the queue is currently tracking.
    public private(set) var session: UUID?
    /// The next index expected in `session`.
    public private(set) var nextIndex = 0

    public init() {}

    public func hasDelivered(_ id: SegmentID) -> Bool { deliveredIDs.contains(id) }

    /// Offers one committed segment. Returns what may be delivered **now**, in order — possibly
    /// empty (waiting for an earlier index, or a duplicate), possibly several (a gap just filled).
    public func submit(_ entry: Entry) -> [Entry] {
        if hasDelivered(entry.segment) {
            Log.injection.notice("duplicate segment \(entry.segment.description) suppressed")
            return []
        }
        if pending.contains(where: { $0.segment == entry.segment }) {
            Log.injection.notice("segment \(entry.segment.description) already pending; ignored")
            return []
        }

        // A new session supersedes the old one. Anything still waiting from the old session will
        // never complete, so release it first, in order, and start counting again.
        var released: [Entry] = []
        if session != entry.segment.sessionID {
            released += pending.sorted { $0.segment < $1.segment }
            pending.removeAll()
            session = entry.segment.sessionID
            nextIndex = 0
        }
        // Stale: an index we have already passed in this session.
        if entry.segment.index < nextIndex {
            Log.injection.notice("stale segment \(entry.segment.description) below \(nextIndex); dropped")
            return released.map { note($0) }
        }

        pending.append(entry)
        pending.sort { $0.segment < $1.segment }
        released += drain()
        return released.map { note($0) }
    }

    /// Releases everything still waiting, in order. For end-of-session flushes and the quit path.
    public func flush() -> [Entry] {
        let all = pending.sorted { $0.segment < $1.segment }
        pending.removeAll()
        if let last = all.last { nextIndex = max(nextIndex, last.segment.index + 1) }
        return all.map { note($0) }
    }

    public func reset() {
        pending.removeAll()
        session = nil
        nextIndex = 0
    }

    // MARK: Internals

    private func drain() -> [Entry] {
        var out: [Entry] = []
        while let first = pending.first {
            if first.segment.index == nextIndex {
                pending.removeFirst()
                nextIndex = first.segment.index + 1
                out.append(first)
            } else if pending.count > maxPending {
                // Bounded wait: the missing index is not coming. Skip to what we have.
                Log.injection.notice("commit backlog full; releasing \(first.segment.description) over the gap at \(nextIndex)")
                pending.removeFirst()
                nextIndex = first.segment.index + 1
                out.append(first)
            } else {
                break   // still waiting for an earlier segment
            }
        }
        return out
    }

    private func note(_ entry: Entry) -> Entry {
        deliveredIDs.append(entry.segment)
        if deliveredIDs.count > deliveredMemory { deliveredIDs.removeFirst(deliveredIDs.count - deliveredMemory) }
        return entry
    }
}
