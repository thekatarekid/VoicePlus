import Foundation
import os

/// Bounded, in-memory ring of timeline events. Holds at most `horizon` seconds of history
/// (relative to the newest event) and at most `capacity` events. Never persisted anywhere.
public final class InputTimeline: @unchecked Sendable {
    public let horizon: TimeInterval
    public let capacity: Int
    private var ring: [TimelineEvent?]
    private var head = 0   // index of oldest
    private var count = 0
    private var lock = os_unfair_lock()

    public init(horizon: TimeInterval = 30, capacity: Int = 16_384) {
        self.horizon = horizon
        self.capacity = max(1, capacity)
        ring = Array(repeating: nil, count: self.capacity)
    }

    public var eventCount: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    public func append(_ event: TimelineEvent) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if count == capacity { head = (head + 1) % capacity; count -= 1 }
        ring[(head + count) % capacity] = event
        count += 1
        evictLocked(before: event.timestamp - horizon)
    }

    public func record(_ kind: TimelineEventKind, at t: TimelineInstant = TimelineClock.shared.now()) {
        append(TimelineEvent(timestamp: t, kind: kind))
    }

    /// Drops everything older than `instant - horizon` (use with a live clock to age out history
    /// even when no new events arrive).
    public func expire(now instant: TimelineInstant) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        evictLocked(before: instant - horizon)
    }

    public func clear() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        head = 0; count = 0
        for i in ring.indices { ring[i] = nil }
    }

    /// Oldest → newest.
    public var events: [TimelineEvent] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (0..<count).compactMap { ring[(head + $0) % capacity] }
    }

    public func events(in range: ClosedRange<TimelineInstant>) -> [TimelineEvent] {
        events.filter { range.contains($0.timestamp) }
    }

    /// Pointer position at `instant`: the latest positional event at or before it, else the first after
    /// it within `tolerance`.
    public func pointer(at instant: TimelineInstant, tolerance: TimeInterval = 0.25) -> GlobalPoint? {
        let all = events
        if let e = all.last(where: { $0.timestamp <= instant && $0.kind.point != nil }),
           instant - e.timestamp <= horizon { return e.kind.point }
        return all.first(where: { $0.timestamp > instant && $0.timestamp - instant <= tolerance })?.kind.point
    }

    /// Stroke points grouped by stroke id, in time order, for strokes that have any point in `range`.
    public func strokes(in range: ClosedRange<TimelineInstant>) -> [UUID: [TimelineEvent]] {
        var ids = Set<UUID>()
        let all = events
        for e in all where range.contains(e.timestamp) {
            if case .strokePoint(let id, _, _) = e.kind { ids.insert(id) }
        }
        var out: [UUID: [TimelineEvent]] = [:]
        for e in all {
            if case .strokePoint(let id, _, _) = e.kind, ids.contains(id) { out[id, default: []].append(e) }
        }
        return out
    }

    public func selection(at instant: TimelineInstant) -> SelectionSnapshot? {
        for e in events.reversed() where e.timestamp <= instant {
            if case .selectionChange(let s) = e.kind { return s }
        }
        return nil
    }

    private func evictLocked(before cutoff: TimelineInstant) {
        while count > 0, let e = ring[head], e.timestamp < cutoff {
            ring[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
    }
}
