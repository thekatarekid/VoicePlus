import Foundation
import Shared

// MARK: - X5 · the on-device edit models (Qwen3.5-2B / 4B): download, delete, which one is active
//
// Owner decisions (round 3): both models are offered; the user picks one in onboarding (or skips),
// Settings can delete one and download the other. Nothing downloads on its own and nothing is in the
// DMG. Consumers: onboarding's model step, the notch's one-time offer, Settings (L3/L2 surfaces) and
// the shared LLM provider (which model runs).

public enum LocalModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }
}

public protocol LocalModelManaging: AnyObject, Sendable {
    /// Qwen3.5-2B (1.28 GB) and Qwen3.5-4B (2.74 GB), in that order.
    var models: [LocalLLMModel] { get }
    func state(_ id: String) -> LocalModelState
    /// The user's click. Progress is reported through `state` / the change observer.
    func download(_ id: String) async
    /// Unloads (residency) and removes the GGUF. No-op when it is not on disk.
    func delete(_ id: String) async throws
    /// The model edits run on: the user's pick when it is ready, else any ready model (2B first).
    var activeModel: LocalLLMModel? { get }
    func setPreferred(_ id: String?)
}

public enum LocalModelError: Error, Equatable, Sendable {
    case unknownModel(String)
    case busy
}

public final class LocalModelManager: LocalModelManaging, @unchecked Sendable {
    public static let preferredKey = "llm.edit.preferredModel"

    public let models: [LocalLLMModel]
    public let root: URL
    private let downloader: any ModelDownloading
    private let residency: ModelResidency?
    private let freeDiskBytes: @Sendable () -> Int64?
    private let defaults: ModelOfferPolicy.Persistence
    private let lock = NSLock()
    private var inFlight: [String: LocalModelState] = [:]
    private var observers: [UUID: @Sendable () -> Void] = [:]

    /// Free space kept after a download (CLAUDE.md: keep ≥ 8 GB free is for builds; the app keeps 1 GB).
    public static let diskHeadroom: Int64 = 1 << 30

    public init(models: [LocalLLMModel] = LocalLLMCatalog.shared, root: URL = LocalLLMCatalog.directory,
                downloader: any ModelDownloading = URLSessionModelDownloader(), residency: ModelResidency? = .shared,
                persistence: ModelOfferPolicy.Persistence = .userDefaults(),
                freeDiskBytes: @escaping @Sendable () -> Int64? = LocalModelManager.volumeFreeBytes) {
        self.models = models
        self.root = root
        self.downloader = downloader
        self.residency = residency
        self.defaults = persistence
        self.freeDiskBytes = freeDiskBytes
    }

    public static let volumeFreeBytes: @Sendable () -> Int64? = {
        let url = AppPaths.supportDirectory()
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    public func model(_ id: String) -> LocalLLMModel? { models.first { $0.id == id } }

    public func isOnDisk(_ model: LocalLLMModel) -> Bool {
        FileManager.default.fileExists(atPath: model.localURL(root: root).path)
    }

    public func state(_ id: String) -> LocalModelState {
        if let s = lock.withLock({ inFlight[id] }) { return s }
        guard let m = model(id) else { return .notDownloaded }
        return isOnDisk(m) ? .ready : .notDownloaded
    }

    /// Called on every state change (any thread). Returns a token for `removeObserver`.
    @discardableResult
    public func addObserver(_ body: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = body }
        return id
    }

    public func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }

    private func set(_ id: String, _ s: LocalModelState?) {
        let obs: [@Sendable () -> Void] = lock.withLock { inFlight[id] = s; return Array(observers.values) }
        obs.forEach { $0() }
    }

    public func download(_ id: String) async {
        guard let m = model(id) else { return }
        if isOnDisk(m) { set(id, nil); return }
        let started: Bool = lock.withLock {
            if case .downloading? = inFlight[id] { return false }
            inFlight[id] = .downloading(0)
            return true
        }
        guard started else { return }
        set(id, .downloading(0))
        if let free = freeDiskBytes(), free < m.bytes + Self.diskHeadroom {
            set(id, .failed("Not enough disk space (\(m.sizeLabel) needed)"))
            return
        }
        do {
            _ = try await downloader.download(m, root: root) { [weak self] p in self?.set(id, .downloading(p)) }
            set(id, nil)
            if lock.withLock({ defaults.get(Self.preferredKey) }) == nil { setPreferred(id) }
            Log.providers.info("model manager: \(id) ready")
        } catch is CancellationError {
            set(id, nil)
        } catch let e as LocalLLMDownloadError {
            if case .checksumMismatch = e { set(id, .failed("The download was damaged. Try again.")) }
            else { set(id, .failed("Download failed. Check your connection and try again.")) }
        } catch {
            set(id, .failed("Download failed. Check your connection and try again."))
        }
    }

    public func delete(_ id: String) async throws {
        guard let m = model(id) else { throw LocalModelError.unknownModel(id) }
        if case .downloading? = lock.withLock({ inFlight[id] }) { throw LocalModelError.busy }
        if let residency {
            let key = LocalLLMCatalog.residencyKey(for: m)
            await residency.unload(key)
        }
        let url = m.localURL(root: root)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        if defaults.get(Self.preferredKey) == id { setPreferred(nil) }
        set(id, nil)
    }

    public var preferredID: String? { defaults.get(Self.preferredKey) }

    public func setPreferred(_ id: String?) {
        defaults.set(Self.preferredKey, id)
        let obs = lock.withLock { Array(observers.values) }
        obs.forEach { $0() }
    }

    public var activeModel: LocalLLMModel? {
        if let p = preferredID, let m = model(p), state(p).isReady { return m }
        return models.first { state($0.id).isReady }
    }

    /// The model to recommend for this Mac: 4B on 24 GB+, else 2B (H16).
    public func recommended(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> LocalLLMModel? {
        let want = physicalMemory >= LocalLLMCatalog.fourBRecommendedBytes ? LocalLLMCatalog.qwen35_4B.id
                                                                            : LocalLLMCatalog.qwen35_2B.id
        return model(want) ?? models.first
    }
}

// MARK: - When the download is offered

/// Owner decision (round 3): pick in onboarding → if skipped, offer once in the notch the first time
/// a rewrite command is used → if that is skipped too, Settings only. Persisted.
public final class ModelOfferPolicy: @unchecked Sendable {
    public enum Stage: String, Sendable, Equatable {
        /// Never asked (onboarding predates the step, or has not reached it).
        case undecided
        case chosenInOnboarding
        case skippedInOnboarding
        /// The notch offer was shown (accepted or not): from now on Settings only.
        case settingsOnly
    }

    /// Two closures over a string store (UserDefaults in the app, a dictionary in tests).
    public struct Persistence: @unchecked Sendable {
        public var get: (String) -> String?
        public var set: (String, String?) -> Void
        public init(get: @escaping (String) -> String?, set: @escaping (String, String?) -> Void) {
            self.get = get
            self.set = set
        }

        public static func userDefaults(_ d: UserDefaults = .standard) -> Persistence {
            Persistence(get: { d.string(forKey: $0) }, set: { k, v in
                if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            })
        }

        public static func inMemory() -> Persistence {
            let box = Box()
            return Persistence(get: { k in box.lock.withLock { box.values[k] } },
                               set: { k, v in box.lock.withLock { box.values[k] = v } })
        }

        final class Box: @unchecked Sendable { let lock = NSLock(); var values: [String: String] = [:] }
    }

    public static let key = "llm.edit.offerStage"
    private let store: Persistence
    public init(store: Persistence = .userDefaults()) { self.store = store }

    public var stage: Stage { store.get(Self.key).flatMap(Stage.init(rawValue:)) ?? .undecided }

    public func recordOnboardingChoice() { store.set(Self.key, Stage.chosenInOnboarding.rawValue) }
    public func recordOnboardingSkipped() { store.set(Self.key, Stage.skippedInOnboarding.rawValue) }

    /// True exactly once: on the first rewrite command when no model is ready and the user did not
    /// already choose (or decline the notch offer).
    public func shouldOfferInNotch(hasReadyModel: Bool) -> Bool {
        guard !hasReadyModel else { return false }
        switch stage {
        case .undecided, .skippedInOnboarding: return true
        case .chosenInOnboarding, .settingsOnly: return false
        }
    }

    /// The notch offer was shown; whatever the answer, it is never shown again.
    public func recordNotchOfferShown() { store.set(Self.key, Stage.settingsOnly.rawValue) }
}
