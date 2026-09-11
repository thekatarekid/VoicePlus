import Foundation

/// Pulls every registered `ContextSource`, dedups by (text, source) keeping the newest.
/// Cheap enough to run before every utterance; sources do their own caching.
public final class ContextHarvester: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [ContextSource]
    /// Last harvest, for Lab inspection.
    public private(set) var lastEntries: [ContextEntry] = []

    public init(sources: [ContextSource] = []) { self.sources = sources }

    public func add(_ source: ContextSource) { lock.withLock { sources.append(source) } }
    public func removeAll(ofKind kind: ContextSourceKind) { lock.withLock { sources.removeAll { $0.kind == kind } } }
    public var kinds: [ContextSourceKind] { lock.withLock { sources.map(\.kind) } }

    /// Drop the cached harvest (R4.1b: `ContextSession.discard()` at the end of a session — screen
    /// text must not outlive the session that read it, even in memory).
    public func forgetLastHarvest() { lock.withLock { lastEntries = [] } }

    public func harvest(now: Date = Date()) -> [ContextEntry] {
        let srcs = lock.withLock { sources }
        var best: [String: ContextEntry] = [:]
        for s in srcs {
            for e in s.harvest(now: now) {
                let t = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.count <= 64 else { continue }
                var entry = e; entry.text = t
                let key = t.lowercased() + "|" + e.source.rawValue
                if let cur = best[key], cur.observedAt >= entry.observedAt, cur.salience >= entry.salience { continue }
                best[key] = entry
            }
        }
        let result = Array(best.values)
        lock.withLock { lastEntries = result }
        return result
    }
}
