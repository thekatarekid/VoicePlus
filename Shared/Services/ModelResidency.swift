import Foundation

// MARK: - V5 HW1 · Model residency manager (§10 contract)
//
// `ModelResidency` is the ONLY way an on-device model is loaded. No module calls
// `MLModel(contentsOf:)`, `AsrModels.load` or a llama.cpp load directly: it registers the model here
// once, then asks for it with `acquire` / `withModel`. The residency decides what has to leave memory
// first so that everything the app holds fits one budget (16 GB Mac → 4.5 GiB for all models).
//
// It lives in `Shared` because every module that loads a model (Engine, Pipeline cleanup, Providers
// llama.cpp, Actions CUA) depends on `Shared` and nothing else in common.
//
// How to use it (every later model item — D2, O4, CU2/CU8, M7, LR — follows this):
//
//     let residency = ModelResidency.shared
//     await residency.register("cleanup.qwen3.5-2b", tier: .onDemand,
//                              estimatedBytes: 1_600_000_000,
//                              lighterAlternative: nil, owner: "cleanup",
//                              load:   { try await llm.load() },
//                              unload: { await llm.unload() })
//     let text = try await residency.withModel("cleanup.qwen3.5-2b") { try await llm.run(prompt) }
//
// - `withModel` loads if needed, pins the model for the duration of `body` (a pinned model is never
//   evicted, idled out or swapped), and marks it most-recently-used.
// - Before choosing a key, ask `preferredKey(for:)`: under critical memory pressure (HW3) it returns
//   the registered `lighterAlternative` (Kev → Laya e8, 4B → 2B).
// - The `load` / `unload` closures do the real work; the residency only does bookkeeping, ordering
//   and logging. `load` should be idempotent; `unload` must release every reference to the weights.

/// How a model may occupy memory.
public enum ResidencyTier: String, Sendable, Codable, CaseIterable {
    /// Always resident (dictation ASR). Never evicted for budget, idle or pressure; never refused.
    case always
    /// Loaded when used; first to leave — LRU under budget, after the idle timeout, on memory warning.
    case onDemand
    /// Loaded only for one job (CUA-S1-4B for an act turn). Loading it evicts every unpinned
    /// `.onDemand` model first, and it is refused while a *different* `.exclusive` model is resident.
    case exclusive
}

/// Why a model was loaded, unloaded or refused. Every event is logged with one.
public enum ResidencyReason: String, Sendable, Codable {
    case requested       // `acquire` / `withModel` loaded it
    case budget          // LRU eviction to make room under the budget
    case exclusive       // evicted because an `.exclusive` model is loading
    case idle            // unused past the idle timeout (D5)
    case memoryWarning   // HW3 `.warning`
    case memoryCritical  // HW3 `.critical`
    case lighterModel    // HW3 `.critical` swapped it for its lighter alternative
    case explicit        // the owner called `unload`
    case exclusiveConflict
    case overBudget
}

/// Kernel memory-pressure level, independent of `DispatchSource` so tests can drive it.
public enum MemoryPressureLevel: String, Sendable, Codable { case normal, warning, critical }

public enum ResidencyError: Error, Equatable, Sendable {
    case notRegistered(String)
    /// `requested` is `.exclusive` and `resident` (another `.exclusive`) is still in memory.
    case exclusiveConflict(requested: String, resident: String)
    /// Even after evicting every evictable model, `requested` would not fit.
    case overBudget(requested: String, neededBytes: Int64, budgetBytes: Int64)
}

public struct ResidencyEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case load, unload, refused }
    public let key: String
    public let kind: Kind
    public let reason: ResidencyReason
    public let bytes: Int64
    public let at: Date
}

public struct ResidencySnapshot: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let tier: ResidencyTier
        public let estimatedBytes: Int64
        public let resident: Bool
        public let pinned: Bool
        public let lastUsed: Date?
    }
    public let budgetBytes: Int64
    /// Bytes of models resident or loading.
    public let usedBytes: Int64
    public let runningLighter: Bool
    public let entries: [Entry]
    public var residentKeys: [String] { entries.filter(\.resident).map { $0.key } }
}

/// Budget = f(physical RAM). Pinned points from V5 §HW: 8 GB → 2 GiB, 16 GB → 4.5 GiB, 24 GB → 8 GiB;
/// above that, a third of RAM.
public enum ResidencyBudget {
    public static let gib: Int64 = 1 << 30

    public static func bytes(forPhysicalMemory physical: UInt64) -> Int64 {
        let ram = Double(physical) / Double(gib)
        switch ram {
        case ..<12: return 2 * gib
        case ..<20: return gib * 9 / 2
        case ..<28: return 8 * gib
        default: return Int64(physical / 3)
        }
    }

    public static var forThisMac: Int64 { bytes(forPhysicalMemory: ProcessInfo.processInfo.physicalMemory) }
}

public actor ModelResidency {
    public typealias Loader = @Sendable () async throws -> Void
    public typealias Unloader = @Sendable () async -> Void

    /// The app-wide instance. Tests construct their own.
    public static let shared = ModelResidency()

    /// HW3 pill chip copy while `isRunningLighter`.
    public static let lighterModelsMessage = "Running lighter models — memory is low"

    public static let defaultIdleTimeout: TimeInterval = 5 * 60

    private enum State { case unloaded, loading, resident }

    private struct Entry {
        var tier: ResidencyTier
        var estimatedBytes: Int64
        var lighterAlternative: String?
        var owner: String?
        var load: Loader
        var unload: Unloader
        var state: State = .unloaded
        var lastUsed: Date?
        var pins: Int = 0
        var order: Int = 0
    }

    public private(set) var budgetBytes: Int64
    public private(set) var idleTimeout: TimeInterval
    public private(set) var isRunningLighter = false

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var events: [ResidencyEvent] = []
    private var useCounter = 0
    private let now: @Sendable () -> Date
    private let maxEvents = 256
    private var eventObserver: (@Sendable (ResidencyEvent) -> Void)?
    private var lighterObserver: (@Sendable (Bool) -> Void)?
    private var sweeper: Task<Void, Never>?

    public init(budgetBytes: Int64 = ResidencyBudget.forThisMac,
                idleTimeout: TimeInterval = ModelResidency.defaultIdleTimeout,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.budgetBytes = budgetBytes
        self.idleTimeout = idleTimeout
        self.now = now
    }

    // MARK: Registration

    /// Register (or re-register) a loadable. Re-registering keeps residency state and only replaces
    /// the metadata and closures. `key` is a stable, namespaced id ("asr.parakeet-tdt-v3", "cleanup.…").
    public func register(_ key: String, tier: ResidencyTier, estimatedBytes: Int64,
                         lighterAlternative: String? = nil, owner: String? = nil,
                         load: @escaping Loader, unload: @escaping Unloader) {
        var e = entries[key] ?? Entry(tier: tier, estimatedBytes: estimatedBytes, load: load, unload: unload)
        e.tier = tier; e.estimatedBytes = max(0, estimatedBytes)
        e.lighterAlternative = lighterAlternative; e.owner = owner
        e.load = load; e.unload = unload
        entries[key] = e
    }

    public func isRegistered(_ key: String) -> Bool { entries[key] != nil }

    /// Forget a model without calling its unloader (its owner is gone). Frees its bytes in the budget.
    public func unregister(_ key: String) { entries[key] = nil }

    /// Forget every model registered with `owner` (e.g. a deallocated `ModelManager`).
    public func unregisterAll(owner: String) {
        for (k, e) in entries where e.owner == owner { entries[k] = nil }
    }

    // MARK: Use

    /// Make `key` resident, evicting what the tier rules require. Marks it most-recently-used.
    /// Throws `ResidencyError` (or whatever the loader throws). Concurrent calls share one load.
    public func acquire(_ key: String) async throws {
        try await acquire(key, pin: false)
    }

    /// Load (if needed), pin for the duration of `body`, then unpin. The body runs off the actor.
    public nonisolated func withModel<T>(_ key: String, _ body: () async throws -> T) async throws -> T {
        try await acquire(key, pin: true)
        do {
            let result = try await body()
            await unpin(key)
            return result
        } catch {
            await unpin(key)
            throw error
        }
    }

    /// Mark `key` used now (resets its idle clock, moves it to the MRU end).
    public func touch(_ key: String) {
        guard entries[key] != nil else { return }
        useCounter += 1
        entries[key]?.lastUsed = now()
        entries[key]?.order = useCounter
    }

    public func unload(_ key: String, reason: ResidencyReason = .explicit) async {
        guard let e = entries[key], e.state != .unloaded else { return }
        if let t = inFlight[key] { _ = try? await t.value }
        await evict(key, reason: reason)
    }

    /// Under critical pressure, the lighter alternative of `key` if one is registered; else `key`.
    public func preferredKey(for key: String) -> String {
        guard isRunningLighter, let alt = entries[key]?.lighterAlternative, entries[alt] != nil else { return key }
        return alt
    }

    public func isResident(_ key: String) -> Bool { entries[key]?.state == .resident }

    // MARK: Policy (D5 idle, HW3 pressure)

    public func setIdleTimeout(_ seconds: TimeInterval) { idleTimeout = max(0, seconds) }

    public func setBudget(_ bytes: Int64) async {
        budgetBytes = max(0, bytes)
        await enforceBudget(reserving: 0, for: nil)
    }

    /// Unload every unpinned non-`.always` model unused for `idleTimeout`. Returns what was unloaded.
    @discardableResult
    public func sweepIdle() async -> [String] {
        let t = now()
        let idle = entries.filter { _, e in
            e.state == .resident && e.tier != .always && e.pins == 0
                && t.timeIntervalSince(e.lastUsed ?? .distantPast) >= idleTimeout
        }.map { $0.key }.sorted()
        for k in idle { await evict(k, reason: .idle) }
        return idle
    }

    /// Start a background loop calling `sweepIdle` every `interval` seconds. Idempotent.
    public func startIdleSweeper(every interval: TimeInterval = 30) {
        guard sweeper == nil else { return }
        let ns = UInt64(max(1, interval) * 1_000_000_000)
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ns)
                guard let self else { return }
                await self.sweepIdle()
            }
        }
    }

    public func stopIdleSweeper() { sweeper?.cancel(); sweeper = nil }

    /// HW3. `.warning` → unload unpinned on-demand models. `.critical` → that, plus switch to lighter
    /// alternatives (`preferredKey(for:)`), unload unpinned models that have one, and raise
    /// `isRunningLighter` (the pill shows `lighterModelsMessage`). `.normal` → lighter mode off.
    public func handleMemoryPressure(_ level: MemoryPressureLevel) async {
        Log.engine.notice("residency: memory pressure \(level.rawValue)")
        switch level {
        case .normal:
            setLighter(false)
        case .warning:
            await evictUnpinned(where: { $0.tier == .onDemand }, reason: .memoryWarning)
        case .critical:
            setLighter(true)
            await evictUnpinned(where: { $0.tier == .onDemand }, reason: .memoryCritical)
            await evictUnpinned(where: { $0.tier != .always && $0.lighterAlternative != nil }, reason: .lighterModel)
        }
    }

    // MARK: Observation

    public func snapshot() -> ResidencySnapshot {
        ResidencySnapshot(
            budgetBytes: budgetBytes, usedBytes: usedBytes(excluding: nil), runningLighter: isRunningLighter,
            entries: entries.sorted { $0.key < $1.key }.map { k, e in
                .init(key: k, tier: e.tier, estimatedBytes: e.estimatedBytes, resident: e.state == .resident,
                      pinned: e.pins > 0, lastUsed: e.lastUsed)
            })
    }

    /// The most recent load/unload/refusal events, oldest first (ring of 256).
    public func recentEvents() -> [ResidencyEvent] { events }

    public func setEventObserver(_ observer: (@Sendable (ResidencyEvent) -> Void)?) { eventObserver = observer }

    /// Called with the new value whenever `isRunningLighter` changes (pill chip wiring).
    public func setLighterModeObserver(_ observer: (@Sendable (Bool) -> Void)?) { lighterObserver = observer }

    // MARK: Internals

    private func acquire(_ key: String, pin: Bool) async throws {
        guard entries[key] != nil else { throw ResidencyError.notRegistered(key) }
        if pin { entries[key]?.pins += 1 }
        do {
            if entries[key]?.state != .resident {
                if let t = inFlight[key] {
                    try await t.value
                } else {
                    let t = Task { try await self.performLoad(key) }
                    inFlight[key] = t
                    defer { inFlight[key] = nil }
                    try await t.value
                }
            }
            touch(key)
        } catch {
            if pin { entries[key]?.pins -= 1 }
            throw error
        }
    }

    private func unpin(_ key: String) {
        guard let p = entries[key]?.pins, p > 0 else { return }
        entries[key]?.pins = p - 1
        touch(key)
    }

    private func performLoad(_ key: String) async throws {
        guard let e = entries[key] else { throw ResidencyError.notRegistered(key) }
        if e.state == .resident { return }
        if e.tier == .exclusive,
           let other = entries.first(where: { $0.key != key && $0.value.tier == .exclusive && $0.value.state != .unloaded })?.key {
            record(key, .refused, .exclusiveConflict, e.estimatedBytes)
            throw ResidencyError.exclusiveConflict(requested: key, resident: other)
        }
        // Reserve before suspending so a concurrent load of another key sees these bytes.
        entries[key]?.state = .loading
        if e.tier == .exclusive {
            await evictUnpinned(where: { $0.tier == .onDemand }, reason: .exclusive, except: key)
        }
        await enforceBudget(reserving: e.estimatedBytes, for: key)
        let needed = usedBytes(excluding: key) + e.estimatedBytes
        if needed > budgetBytes {
            if e.tier == .always {
                Log.engine.notice("residency: \(key) is .always — loading over budget (\(needed) of \(budgetBytes) bytes)")
            } else {
                entries[key]?.state = .unloaded
                record(key, .refused, .overBudget, e.estimatedBytes)
                throw ResidencyError.overBudget(requested: key, neededBytes: needed, budgetBytes: budgetBytes)
            }
        }
        do {
            try await e.load()
        } catch {
            if entries[key]?.state == .loading { entries[key]?.state = .unloaded }
            Log.engine.error("residency: load \(key) failed: \(error)")
            throw error
        }
        guard entries[key] != nil else { return }   // unregistered while loading
        entries[key]?.state = .resident
        record(key, .load, .requested, e.estimatedBytes)
    }

    /// LRU-evict unpinned `.onDemand` models until `reserving` more bytes fit (or nothing is left).
    private func enforceBudget(reserving bytes: Int64, for key: String?) async {
        while usedBytes(excluding: key) + bytes > budgetBytes {
            let victim = entries
                .filter { $0.key != key && $0.value.tier == .onDemand && $0.value.state == .resident && $0.value.pins == 0 }
                .min { $0.value.order < $1.value.order }?.key
            guard let victim else { return }
            await evict(victim, reason: .budget)
        }
    }

    private func evictUnpinned(where match: (Entry) -> Bool, reason: ResidencyReason, except: String? = nil) async {
        let keys = entries
            .filter { $0.key != except && $0.value.state == .resident && $0.value.pins == 0 && match($0.value) }
            .sorted { $0.value.order < $1.value.order }.map { $0.key }
        for k in keys { await evict(k, reason: reason) }
    }

    private func evict(_ key: String, reason: ResidencyReason) async {
        guard let e = entries[key], e.state == .resident else { return }
        entries[key]?.state = .unloaded
        record(key, .unload, reason, e.estimatedBytes)
        await e.unload()
    }

    private func usedBytes(excluding key: String?) -> Int64 {
        entries.reduce(0) { sum, kv in
            (kv.key != key && kv.value.state != .unloaded) ? sum + kv.value.estimatedBytes : sum
        }
    }

    private func setLighter(_ on: Bool) {
        guard isRunningLighter != on else { return }
        isRunningLighter = on
        Log.engine.notice("residency: lighter models \(on ? "on" : "off")")
        lighterObserver?(on)
    }

    private func record(_ key: String, _ kind: ResidencyEvent.Kind, _ reason: ResidencyReason, _ bytes: Int64) {
        let event = ResidencyEvent(key: key, kind: kind, reason: reason, bytes: bytes, at: now())
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        let mb = bytes / 1_000_000
        let used = usedBytes(excluding: nil) / 1_000_000
        Log.engine.info("residency: \(kind.rawValue) \(key) (\(mb) MB) — \(reason.rawValue); \(used)/\(budgetBytes / 1_000_000) MB")
        eventObserver?(event)
    }
}
