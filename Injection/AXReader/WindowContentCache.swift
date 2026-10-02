import Foundation

/// Per-window content cache. Entries are invalidated by AX notifications (`AXValueChanged`,
/// focus changes) when an observer is available, and always fall back to a TTL.
public final class WindowContentCache {
    private struct Key: Hashable {
        let window: AXWindowID
        let scrollback: Bool
    }
    private struct Entry {
        let content: WindowContent
        let storedAt: Date
    }

    public let ttl: TimeInterval
    private let now: () -> Date
    private var entries: [Key: Entry] = [:]
    private var observers: [AXWindowID: AXObservationToken] = [:]
    private let lock = NSLock()
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(ttl: TimeInterval = 2.0, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.now = now
    }

    deinit { observers.values.forEach { $0.cancel() } }

    public func get(_ window: AXWindowID, scrollback: Bool) -> WindowContent? {
        lock.lock(); defer { lock.unlock() }
        let key = Key(window: window, scrollback: scrollback)
        guard let entry = entries[key] else { misses += 1; return nil }
        guard now().timeIntervalSince(entry.storedAt) < ttl else {
            entries[key] = nil
            misses += 1
            return nil
        }
        hits += 1
        return entry.content
    }

    public func put(_ content: WindowContent, scrollback: Bool) {
        lock.lock(); defer { lock.unlock() }
        entries[Key(window: content.window, scrollback: scrollback)] = Entry(content: content, storedAt: now())
    }

    public func invalidate(_ window: AXWindowID) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.key.window != window }
    }

    public func invalidateAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    public var isObserving: Bool {
        lock.lock(); defer { lock.unlock() }
        return !observers.isEmpty
    }

    public func isObserving(_ window: AXWindowID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return observers[window] != nil
    }

    /// Hooks AX notifications for `window`. Idempotent; no-op when the access layer offers no observer (TTL only).
    public func observe(_ window: AXWindowID, via access: AXNodeAccess) {
        lock.lock()
        if observers[window] != nil { lock.unlock(); return }
        lock.unlock()
        let token = access.observe(window: window) { [weak self] event in self?.handle(event) }
        guard let token else { return }
        lock.lock()
        if observers[window] == nil { observers[window] = token } else { token.cancel() }
        lock.unlock()
    }

    public func stopObserving(_ window: AXWindowID) {
        lock.lock()
        let token = observers.removeValue(forKey: window)
        lock.unlock()
        token?.cancel()
    }

    private func handle(_ event: AXChangeEvent) {
        switch event {
        case .valueChanged(let w), .focusChanged(let w):
            invalidate(w)
        case .windowDestroyed(let w):
            invalidate(w)
            stopObserving(w)
        }
    }
}

/// `AXReading` that serves repeated reads of the same window from `WindowContentCache`.
public final class CachedAXReader: AXReading {
    public let reader: AXReading
    public let cache: WindowContentCache
    private let access: AXNodeAccess

    public init(reader: AXReading, access: AXNodeAccess, cache: WindowContentCache = WindowContentCache()) {
        self.reader = reader
        self.access = access
        self.cache = cache
    }

    public convenience init(access: AXNodeAccess, cache: WindowContentCache = WindowContentCache()) {
        self.init(reader: AXWindowReader(access: access), access: access, cache: cache)
    }

    public func windows(pid: Int32) -> [AXWindowID] { reader.windows(pid: pid) }

    /// N7 — one walk at a time per window: a second reader of a window already being walked waits
    /// for that walk (until its own deadline, or `joinTimeout` without one) and reuses the result.
    /// If the walk is still running then, it gets an empty `interrupted` content instead of a
    /// second concurrent walk.
    public var joinTimeout: TimeInterval = 1.0
    private struct FlightKey: Hashable { let window: AXWindowID; let scrollback: Bool }
    private let flight = NSCondition()
    private var inFlight: Set<FlightKey> = []
    /// Walks that started (cache misses that reached the underlying reader). Test/diagnostic hook.
    public private(set) var walksStarted = 0

    public func readWindow(_ id: AXWindowID, options: AXReadOptions) throws -> WindowContent {
        if let cached = cache.get(id, scrollback: options.includeScrollback), fits(cached, options) { return cached }
        let key = FlightKey(window: id, scrollback: options.includeScrollback)
        flight.lock()
        if inFlight.contains(key) {
            let until = options.limits.deadline ?? Date().addingTimeInterval(joinTimeout)
            while inFlight.contains(key) {
                if !flight.wait(until: until) && inFlight.contains(key) {
                    flight.unlock()
                    return WindowContent(window: id, title: nil, blocks: [], truncated: true, nodesVisited: 0,
                                         readAt: Date(), interrupted: true)
                }
            }
            if let cached = cache.get(id, scrollback: options.includeScrollback), fits(cached, options) {
                flight.unlock()
                return cached
            }
        }
        inFlight.insert(key)
        walksStarted += 1
        flight.unlock()
        defer {
            flight.lock()
            inFlight.remove(key)
            flight.broadcast()
            flight.unlock()
        }
        let content = try reader.readWindow(id, options: options)
        // N7 — a walk cut short by its deadline or a cancel is partial: never served to the next reader.
        if !content.interrupted { cache.put(content, scrollback: options.includeScrollback) }
        cache.observe(id, via: access)
        return content
    }

    public func readFocusedWindow(pid: Int32, options: AXReadOptions) throws -> WindowContent {
        guard let node = access.focusedWindow(pid: pid), let id = access.windowID(of: node) else {
            throw AXReadError.noFocusedWindow(pid: pid)
        }
        return try readWindow(id, options: options)
    }

    /// A cached read made under a larger cap can be reused; one under a smaller cap cannot be trusted.
    private func fits(_ content: WindowContent, _ options: AXReadOptions) -> Bool {
        !content.truncated || content.characterCount >= options.limits.maxCharacters
    }
}
