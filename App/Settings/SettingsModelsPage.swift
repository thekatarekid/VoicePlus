import Engine
import Foundation
import Shared

// S7g — Settings › Models (design §8.6, §9): the compatible model, its installed size, real byte
// progress → Verifying → Loading → Ready, retry / cancel, the last working model, and the H3
// speaker-embedding row. "Ready" is said only after the stack is verified *and* loaded — never on
// download completion (design §8.6). The phase and rows are plain values; the model runs the install
// through `ModelManaging` and the load through a loader, and reads presence from the disk itself.

// MARK: - What is on disk

/// One model's presence and size on disk.
public struct ModelInventoryEntry: Equatable, Sendable {
    public var installed: Bool
    /// Bytes the model's folder holds; nil when not installed or unreadable.
    public var bytesOnDisk: Int64?

    public init(installed: Bool, bytesOnDisk: Int64? = nil) {
        self.installed = installed
        self.bytesOnDisk = bytesOnDisk
    }
}

/// Reads per-model presence. The live reader asks `ModelManager` (with maintenance `.skip`: it
/// reads the real models root without being entitled to move anything) and sums the folder.
public protocol ModelInventoryReading: Sendable {
    func read() async -> [ModelID: ModelInventoryEntry]
}

public struct LiveModelInventory: ModelInventoryReading {
    public init() {}

    public func read() async -> [ModelID: ModelInventoryEntry] {
        let manager = ModelManager(maintenance: .skip)
        var out: [ModelID: ModelInventoryEntry] = [:]
        for id in ModelsPage.listed {
            let url = await manager.locate(id)
            out[id] = ModelInventoryEntry(installed: url != nil, bytesOnDisk: url.map(Self.size(of:)))
        }
        return out
    }

    static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

/// A fixed inventory, for tests and previews.
public struct StaticModelInventory: ModelInventoryReading {
    public var entries: [ModelID: ModelInventoryEntry]
    public init(_ entries: [ModelID: ModelInventoryEntry]) { self.entries = entries }
    public func read() async -> [ModelID: ModelInventoryEntry] { entries }
}

// MARK: - Phase

/// The Models page's one line of truth about the speech stack.
public enum ModelsPagePhase: Equatable, Sendable {
    /// The first disk read — "Verifying the speech model…" (never the empty copy).
    case checking
    /// Nothing of the stack on disk and nothing fetching: the empty state, "Install a speech model".
    case notInstalled
    /// Asked for; no byte reported yet.
    case starting
    /// Real byte progress.
    case downloading(ModelDownloadProgress)
    /// Every byte is in; the checksum and integrity checks run before the files count.
    case verifying
    /// On disk and verified; being loaded into memory.
    case loading
    /// Verified and loaded — the only phase that may say Ready.
    case ready(name: String)
    /// The download or its verification failed (M02–M06 from the error).
    case downloadFailed(RecoveryID)
    /// On disk, but loading it failed (M07).
    case loadFailed(RecoveryID)

    public var isReady: Bool { if case .ready = self { return true }; return false }

    /// A download or load is running: Cancel is offered for a download, nothing else starts.
    public var isBusy: Bool {
        switch self {
        case .starting, .downloading, .verifying, .loading, .checking: return true
        default: return false
        }
    }

    public var isDownloading: Bool {
        switch self {
        case .starting, .downloading, .verifying: return true
        default: return false
        }
    }

    /// The status line under the stack row.
    public var statusLine: String {
        switch self {
        case .checking: return SectionCopy.verifyingModel
        case .notInstalled: return RecoveryCatalog.entry(.M01).consequence
        case .starting: return ModelsPageCopy.starting
        case .downloading(let p):
            let bytes = p.bytesExpected > 0
                ? "\(ByteText.short(p.bytesReceived)) of \(ByteText.short(p.bytesExpected))"
                : ByteText.short(p.bytesReceived)
            return "Downloading \(p.modelName) · \(bytes) · \(p.percent)%"
        case .verifying: return ModelsPageCopy.verifying
        case .loading: return ModelsPageCopy.loading
        case .ready(let name):
            // N6: "Preparing speech models…" while the vocabulary booster loads/compiles at launch.
            return ModelsPageCopy.ready(name) + (SpeechModelPreparation.shared.message.map { " \($0)" } ?? "")
        case .downloadFailed(let id), .loadFailed(let id): return RecoveryCatalog.entry(id).headline
        }
    }

    /// The stack row's tag: good only when Ready.
    var tag: (text: String, kind: StatusTag.Kind) {
        switch self {
        case .ready: return ("Ready", .good)
        case .checking, .starting, .downloading, .verifying, .loading: return ("Not ready yet", .neutral)
        case .notInstalled: return ("Not installed", .warn)
        case .downloadFailed, .loadFailed: return ("Needs attention", .warn)
        }
    }
}

// MARK: - Rows

public enum ModelsPage {
    /// The models the page lists: the stack (speech, preview, speaker embedding). Fallbacks are
    /// never offered (R6.1); the optional refinement model has its own row.
    public static var listed: [ModelID] { ModelStack.models }

    public struct Row: Equatable, Identifiable, Sendable {
        public var id: ModelID
        public var name: String
        public var purpose: String
        public var installed: Bool
        public var sizeText: String

        public var detail: String { "\(purpose) · \(installed ? "Installed · \(sizeText)" : "Not installed · \(sizeText) to download")" }
    }

    /// One row per stack model: what it does, whether it is here, its size (on disk when installed,
    /// the catalog's advertised size when not).
    public static func rows(_ inventory: [ModelID: ModelInventoryEntry]) -> [Row] {
        listed.map { id in
            let d = ModelCatalog.descriptor(id)
            let entry = inventory[id] ?? ModelInventoryEntry(installed: false)
            let bytes = entry.installed ? (entry.bytesOnDisk ?? d.approxBytes) : d.approxBytes
            return Row(id: id, name: d.displayName, purpose: purpose(id), installed: entry.installed,
                       sizeText: ByteText.short(bytes))
        }
    }

    static func purpose(_ id: ModelID) -> String {
        switch id {
        case .parakeetTDTv3: return "Speech recognition · \(speechCompatibility)"
        case .parakeetEOU160: return "Live preview and end of speech"
        case .speakerEmbedding: return "Speaker embedding · lets Latch answer only to you"
        case .sileroVAD: return "Voice activity detection · hears when you start and stop"
        default: return "Fallback"
        }
    }

    /// The speech model is built for Apple silicon (`ModelID.parakeetTDTv3`); an Intel Mac is told so
    /// rather than shown a "compatible" it cannot keep.
    static var speechCompatibility: String {
        #if arch(arm64)
        return "compatible with this Mac"
        #else
        return "made for Apple silicon; this Mac may not run it"
        #endif
    }

    /// H3 — what the speaker-embedding row says when its weights are missing.
    public static func speakerNote(installed: Bool) -> String? {
        installed ? nil : "\(SpeakerFilter.unavailableLabel) until it is installed. Hold-to-talk is unaffected."
    }
}

public enum ModelsPageCopy {
    public static let stackTitle = "Local speech model"
    public static let starting = "Starting the download…"
    public static let verifying = "Verifying…"
    public static let loading = "Loading…"
    public static func ready(_ name: String) -> String { "Ready · \(name) is verified and loaded." }
    public static let install = "Install model"
    public static let cancel = "Cancel download"
    public static let lastWorkingTitle = "Last working model"
    public static func lastWorking(_ name: String) -> String { "\(name) keeps working until a replacement is verified and loaded." }
    public static let noLastWorking = "None yet. Dictation starts once a model is verified and loaded."
    public static let footnote = "Download completion is followed by verification and loading. An incomplete model is never marked ready."
    public static let refinementTitle = "Optional refinement model"
    public static let routingTitle = "Processing by stage"
    public static let routingDetail = "Auto keeps every stage on this Mac unless you pin a service. Transcription is always local."
}

// MARK: - The page model

@MainActor
public final class ModelsPageModel: ObservableObject {
    @Published public private(set) var phase: ModelsPagePhase = .checking
    @Published public private(set) var inventory: [ModelID: ModelInventoryEntry] = [:]
    /// The recogniser last verified and loaded on this Mac (persisted).
    @Published public private(set) var lastWorking: String?

    private let models: ModelManaging
    private let reader: ModelInventoryReading
    private let load: @MainActor () async -> OnboardingStateMachine.ModelLoadOutcome
    private let store: SettingsStore
    private var downloadTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var preparationObserver: NSObjectProtocol?

    public init(models: ModelManaging, inventory: ModelInventoryReading = LiveModelInventory(),
                store: SettingsStore,
                load: @escaping @MainActor () async -> OnboardingStateMachine.ModelLoadOutcome) {
        self.models = models
        self.reader = inventory
        self.store = store
        self.load = load
        self.lastWorking = store.string(SettingsKeys.lastWorkingModel)
        // N6: re-render the status line when the booster's preparation state changes.
        preparationObserver = NotificationCenter.default.addObserver(
            forName: SpeechModelPreparation.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    /// The window's loader: the composition root's `loadModel` when wired, else re-resolve the
    /// engine against what is on disk and prewarm it (idempotent; it loads the model and never
    /// opens the microphone).
    public static func loader(for deps: OnboardingDependencies) -> @MainActor () async -> OnboardingStateMachine.ModelLoadOutcome {
        if let load = deps.loadModel { return load }
        // The composition root hands its live wiring (the engine's own "is the model loaded?" and
        // preload) to onboarding through `configure`; the window's copy of the dependencies does
        // not carry it, so borrow it the same way onboarding does.
        var live = deps
        OnboardingWindowController.configure?(&live)
        if let load = live.loadModel { return load }
        let prepare = deps.prepareEngine
        let engine = deps.engine
        let models = deps.models
        return {
            await prepare?()
            do {
                try await engine.prewarm()
                if case .unavailable = engine.state { return .failed(RecoveryCatalog.entry(.M01).headline) }
                return .loaded(name: models.stackReadiness.recognizerName ?? ModelStack.displayNames.first ?? "the speech model")
            } catch {
                return .failed(RecoveryCatalog.report(error).headline)
            }
        }
    }

    public var rows: [ModelsPage.Row] { ModelsPage.rows(inventory) }

    public var speakerRow: ModelsPage.Row? { rows.first { $0.id == .speakerEmbedding } }

    /// Stack models not on disk, in install order (read from disk, not from a cache that may not
    /// have been filled yet).
    public var missing: [ModelID] { ModelsPage.listed.filter { inventory[$0]?.installed != true } }

    /// The final speech model is what makes dictation possible; without it the page is empty.
    public var speechInstalled: Bool { inventory[ModelStack.models[0]]?.installed == true }

    /// Whatever transcribes right now while the stack is incomplete or failing.
    public var inUseNow: String? { models.stackReadiness.recognizerName }

    /// The page's base rendering: loading while the first read runs, empty with nothing installed
    /// and nothing fetching, else content (failures are a scoped banner over readable rows).
    public func state(hotkey: String) -> SectionState {
        switch phase {
        case .checking: return .loading(.models)
        case .notInstalled: return .empty(.models, hotkey: hotkey)
        default: return .content
        }
    }

    /// The partial banner for a failed download or load; nil otherwise.
    public var banner: SectionBanner? {
        switch phase {
        case .downloadFailed(let id), .loadFailed(let id): return .partial(RecoveryCatalog.entry(id))
        default: return nil
        }
    }

    // MARK: Actions

    /// Reads the disk; loads the stack when it is all here, else reports it missing.
    public func refresh() async {
        inventory = await reader.read()
        guard downloadTask == nil else { return }
        if speechInstalled {
            if !phase.isReady { await loadStack() }
        } else if !phase.isDownloading, !isFailure {
            phase = .notInstalled
        }
    }

    /// The empty state's "Choose a model" and the row's "Install model": fetch what is missing.
    public func install() {
        guard downloadTask == nil else { return }
        guard !missing.isEmpty else {
            Task { await loadStack() }
            return
        }
        phase = .starting
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await models.downloadStack { progress in
                    Task { @MainActor [weak self] in self?.noteProgress(progress) }
                }
                // A cancelled task leaves the page to `cancel()`, which already reset it — so a new
                // install started since is never clobbered by this one finishing.
                guard !Task.isCancelled else { return }
                downloadTask = nil
                inventory = await reader.read()
                await loadStack()
            } catch {
                guard !Task.isCancelled else { return }
                downloadTask = nil
                phase = error is CancellationError ? .notInstalled : .downloadFailed(Self.downloadFailureID(error))
            }
        }
    }

    /// Cancel: the task is the download (the manager's contract); the page returns to not installed.
    public func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        phase = .notInstalled
        Task { await refresh() }
    }

    /// The banner's one action: retry what failed — the download, or the load.
    public func retry() {
        switch phase {
        case .loadFailed: Task { await loadStack() }
        default: install()
        }
    }

    // MARK: Internals

    private var isFailure: Bool {
        switch phase {
        case .downloadFailed, .loadFailed: return true
        default: return false
        }
    }

    func noteProgress(_ progress: ModelDownloadProgress) {
        guard downloadTask != nil else { return }
        phase = progress.fraction >= 1 ? .verifying : .downloading(progress)
    }

    private func loadStack() async {
        if let loadTask { await loadTask.value; return }
        phase = .loading
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            switch await load() {
            case .loaded(let name):
                phase = .ready(name: name)
                lastWorking = name
                store.set(name, for: SettingsKeys.lastWorkingModel)
            case .failed:
                phase = .loadFailed(.M07)
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// A download error as its Models entry: the catalogue's own mapping when it is a model entry,
    /// else "didn't finish downloading" (M02) — a model failure never reads as a generic X08.
    static func downloadFailureID(_ error: Error) -> RecoveryID {
        let id = RecoveryCatalog.report(error).id
        switch id {
        case .M02, .M03, .M04, .M05, .M06: return id
        case .N01, .N04: return .M04
        default: return .M02
        }
    }
}
