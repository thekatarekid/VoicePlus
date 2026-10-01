import Dispatch
import Foundation
import Shared

// V5 HW1/HW3 — Engine side of the residency contract. The actor itself is `Shared.ModelResidency`
// (every model-loading module reaches it); this file maps the engine's catalog onto it and owns the
// kernel memory-pressure source.

extension ModelID {
    /// Dictation ASR stays resident; everything else the catalog loads is on demand.
    public var residencyTier: ResidencyTier {
        switch ModelCatalog.descriptor(self).kind {
        case .finalTDT, .streamingEOU: return .always
        case .whisper: return .onDemand
        }
    }

    /// Namespaced residency key. `scope` separates two `ModelManager`s holding their own copies.
    public func residencyKey(scope: String) -> String { "asr.\(rawValue)#\(scope)" }
}

/// HW3 — `DispatchSource.makeMemoryPressureSource` → `ModelResidency.handleMemoryPressure`.
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let residency: ModelResidency
    private let queue: DispatchQueue
    private var source: DispatchSourceMemoryPressure?
    private let lock = NSLock()

    public init(residency: ModelResidency = .shared,
                queue: DispatchQueue = DispatchQueue(label: "voiceplus.memory-pressure", qos: .utility)) {
        self.residency = residency
        self.queue = queue
    }

    deinit { source?.cancel() }

    /// Kernel event → residency level. The most severe flag present wins.
    public static func level(for event: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }

    /// Idempotent.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        let residency = self.residency
        s.setEventHandler { [weak s] in
            guard let s else { return }
            let level = Self.level(for: s.data)
            Task { await residency.handleMemoryPressure(level) }
        }
        s.resume()
        source = s
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        source?.cancel()
        source = nil
    }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return source != nil }

    /// The app-wide monitor feeding `ModelResidency.shared`.
    public static let shared = MemoryPressureMonitor()

    /// Start the shared pressure monitor and the shared idle sweeper (D5). Idempotent; called by the
    /// first `ModelManager` that uses `ModelResidency.shared`, so the app needs no extra wiring.
    public static func startSharedServices() {
        guard !sharedStarted.exchange() else { return }
        shared.start()
        Task { await ModelResidency.shared.startIdleSweeper() }
    }

    private static let sharedStarted = OnceFlag()
}

/// Thread-safe one-shot flag: `exchange()` returns whether it was already set, and sets it.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func exchange() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let was = set; set = true; return was
    }
}
