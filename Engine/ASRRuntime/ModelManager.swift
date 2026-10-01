import FluidAudio
import Foundation
import Shared

public enum ModelStatus: Equatable, Sendable {
    case missing
    case downloading(Double)
    case present(URL)
    case loaded(URL)
}

/// A model resident in memory. Whisper has no Phase-1 runtime (placeholder).
public enum LoadedModel: Sendable {
    case tdt(AsrModels)
    case eou(StreamingEouAsrManager)

    public var asrModels: AsrModels? { if case .tdt(let m) = self { return m }; return nil }
    public var eouManager: StreamingEouAsrManager? { if case .eou(let m) = self { return m }; return nil }
}

public enum ModelManagerError: Error, Equatable {
    case unsupported(ModelID)
    case notPresent(ModelID)
    case verificationFailed(ModelID, [String])
    /// On disk but not usable: an interrupted download left scratch files, a required file is
    /// missing, or a file is shorter than it was when it installed. Recoverable by re-downloading.
    case incomplete(ModelID, [String])
}

/// Plain language, because these reach the notch. Until 1.7.10 an incomplete model surfaced as
/// whatever Cocoa error the failing move threw — the user's screenshot read `The file
/// "weight.bin.partial" doesn't exist.`, which names an internal scratch file, explains nothing and
/// offers no way out. Since S9 `EngineMessage.describe` shows the recovery catalogue's headline and
/// this sentence goes to the log; it is still what any other `localizedDescription` reader gets.
extension ModelManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported(let id):
            return "VoicePlus can\u{2019}t run the \u{201C}\(ModelCatalog.descriptor(id).displayName)\u{201D} model on this Mac."
        case .notPresent(let id):
            return "The \(ModelCatalog.descriptor(id).displayName) speech model isn\u{2019}t installed yet. Download it from Settings \u{203A} Models."
        case .verificationFailed(let id, let paths), .incomplete(let id, let paths):
            // Deliberately no scratch filenames. "weight.bin.partial" is what the 1.7.9 screenshot
            // said, and naming an internal staging file tells the user nothing they can act on —
            // the count does, and the log carries the paths for whoever needs them.
            let name = ModelCatalog.descriptor(id).displayName
            let count = paths.count
            let detail = count == 1 ? "1 file" : "\(count) files"
            return "The \(name) speech model didn\u{2019}t finish downloading"
                + (count == 0 ? "" : " \u{2014} \(detail) are missing or incomplete")
                + ". The unfinished pieces have been cleared; download the model again from Settings \u{203A} Models."
        }
    }
}

/// Owns disk layout (`AppPaths` → `Models/<id>`), downloads (resume + SHA256 manifest),
/// load/unload and warm-start. One instance per app; actor-isolated.
public actor ModelManager {
    public let root: URL
    private let fetchers: [ModelKind: ModelFetcher]
    private var fileManager: FileManager { .default }
    private var loaded: [ModelID: LoadedModel] = [:]
    private var downloads: [ModelID: Task<URL, Error>] = [:]
    /// In-flight loads, keyed by model. See `load(_:)` — without this, actor reentrancy let two
    /// callers run two CoreML loads (and, underneath them, two HuggingFace downloads) over the same
    /// folder at once.
    private var loads: [ModelID: Task<LoadedModel, Error>] = [:]
    private var progress: [ModelID: Double] = [:]
    /// Extra read-only places to look for already-downloaded models (warm start without re-download).
    private let externalCaches: [ModelID: [URL]]

    /// How a located model becomes a resident one. Injectable so the dedupe contract in `load(_:)`
    /// can be exercised without CoreML (which no test machine here has models for).
    public typealias ModelLoader = @Sendable (ModelID, ModelDescriptor, URL) async throws -> LoadedModel
    private let loader: ModelLoader

    /// Whether this manager may rearrange the models root it is pointed at, and when.
    ///
    /// `.skip` exists for tests. Ten of them construct `ModelManager()` — no arguments, so the *real*
    /// `~/Library/Application Support/VoicePlus/Models` — to run WER and golden-transcript checks
    /// against whatever the developer actually has downloaded. Those are read-only intentions, but
    /// maintenance used to run from `init`, so `swift test` was silently entitled to migrate and
    /// delete directories in a real user's 468 MB model store. A test suite that can do that is a
    /// hazard regardless of how careful the migration is.
    ///
    /// V4.8: `init` never runs the pass any more. It used to, synchronously, under a cross-process
    /// file lock, on the path that builds the container — so the hotkey could not be armed until
    /// another process let go of the lock. Nothing that reads the layout ever sees it half-moved:
    /// a read while the pass runs waits for it, and a load or download awaits it first.
    public enum Maintenance: Sendable {
        /// Migrate the layout and sweep parked directories, on first use: the first layout read runs
        /// it inline, the first load or download starts it detached and awaits it.
        case run
        /// What the app does: the same pass, started detached by `startMaintenance()` once the app
        /// is wired (or by the first load/download, whichever comes first). Until then reads see the
        /// layout as it is on disk, which nothing is moving.
        case deferred
        /// Touch nothing. For reading a real models root without being entitled to change it.
        case skip
    }

    /// How the pass takes the cross-process lock. Injectable so a test can hold the lock and prove
    /// `init` does not wait for it.
    public typealias RootLock = @Sendable (_ root: URL, _ body: () -> Void) -> Void
    public static let crossProcessRootLock: RootLock = { root, body in ModelRootLock.withLock(root: root, body) }

    private let maintenanceMode: Maintenance
    private let maintenancePass: ModelMaintenancePass

    /// V5 HW1 — the shared memory budget this manager's models are loaded through (§10: the only
    /// way a model is loaded). `nil` bypasses it (only for tests that need a bare manager).
    public nonisolated let residency: ModelResidency?
    /// Separates this manager's residency keys from another manager's copies of the same model.
    public nonisolated let residencyScope: String = String(UUID().uuidString.prefix(8))
    private var registered: Set<ModelID> = []

    public init(root: URL = ModelCatalog.modelsRoot(),
                fetchers: [ModelKind: ModelFetcher]? = nil,
                externalCaches: [ModelID: [URL]]? = nil,
                loader: ModelLoader? = nil,
                maintenance: Maintenance = .run,
                rootLock: RootLock? = nil,
                residency: ModelResidency? = .shared) {
        self.root = root
        self.residency = residency
        if let residency, residency === ModelResidency.shared { MemoryPressureMonitor.startSharedServices() }
        self.fetchers = fetchers ?? [.finalTDT: FluidAudioFetcher(), .streamingEOU: FluidAudioFetcher(), .whisper: ManifestFetcher()]
        self.externalCaches = externalCaches ?? Self.defaultExternalCaches()
        self.loader = loader ?? Self.coreMLLoader
        self.maintenanceMode = maintenance
        let lock = rootLock ?? Self.crossProcessRootLock
        if case .skip = maintenance {
            self.maintenancePass = ModelMaintenancePass(skipped: true) {}
        } else {
            self.maintenancePass = ModelMaintenancePass(skipped: false) { Self.runMaintenance(root: root, lock: lock) }
        }
    }

    /// V4.8 — start the maintenance pass detached, if it has not started. Never blocks. The app calls
    /// this once it has wired itself, so the pass never sits on the launch path.
    public nonisolated func startMaintenance() { maintenancePass.startDetached() }

    /// Wait for the maintenance pass (starting it if it has not started). Returns at once for `.skip`.
    public nonisolated func maintenanceFinished() async { await maintenancePass.finished() }

    /// True once the pass has run (or will never run: `.skip`).
    public nonisolated var isMaintenanceComplete: Bool { maintenancePass.isComplete }

    /// Before a synchronous read of the layout: a pass that is moving directories is waited for, and
    /// under `.run` a pass that has not started runs here, first.
    private func settleLayoutForRead() {
        switch maintenanceMode {
        case .run: maintenancePass.runOrWait()
        case .deferred: maintenancePass.waitWhileRunning()
        case .skip: break
        }
    }

    /// Before anything that writes into the layout or hands a folder to CoreML: the pass has finished.
    private func settleLayout() async {
        guard !maintenancePass.isComplete else { return }
        await maintenancePass.finished()
    }

    /// Layout migration + parked-directory sweep, under a cross-process lock.
    ///
    /// A migration that ran halfway through a load would move the directory out from under CoreML,
    /// so every read of the layout waits while it runs and every load awaits it (see `Maintenance`).
    /// It no longer runs in `init` (V4.8): `ModelMaintenancePass` runs it once, on its own queue or
    /// inline on first use.
    ///
    /// The lock is what keeps two VoicePlus processes launching together from interleaving each
    /// other's park/rename/delete over the same two paths. `ModelRootLock` bounds how long it waits.
    ///
    /// Cost on an already-migrated install: one `open`, a `stat` per model, one directory listing.
    private static func runMaintenance(root: URL, lock: RootLock) {
        lock(root) {
            let migrated = ModelLayoutMigration.migrate(root: root)
            if !migrated.isEmpty {
                let reclaimed = migrated.reduce(0) { $0 + $1.reclaimedBytes }
                Log.engine.notice("model layout migrated: \(migrated.map { "\($0.id.rawValue)=\($0.outcome.rawValue)/manifest=\($0.manifest.rawValue)" }.joined(separator: ", ")); \(reclaimed) bytes reclaimed")
            }
            // The other half of "a swap, not a delete-then-move": the parked copies that a crash
            // between the swap and the cleanup would otherwise strand forever.
            ParkedModelDirectories.sweep(root: root)
        }
    }

    /// The real thing: CoreML compile + ANE warm through FluidAudio.
    static let coreMLLoader: ModelLoader = { id, descriptor, url in
        switch descriptor.kind {
        case .finalTDT:
            if id == .parakeetTDTv3 {
                return .tdt(try await LocalTDTModels.loadV3(from: url))
            }
            let version: AsrModelVersion = (id == .parakeetTDTCTC110m) ? .tdtCtc110m : .v3
            return .tdt(try await AsrModels.load(from: url, version: version))
        case .streamingEOU:
            let manager = StreamingEouAsrManager(chunkSize: .ms160)
            try await manager.loadModels(from: url)
            return .eou(manager)
        case .whisper:
            throw ModelManagerError.unsupported(id)
        }
    }

    /// FluidAudio's own cache (current + legacy folder names) so a model pulled by upstream tools is reused.
    public static func defaultExternalCaches() -> [ModelID: [URL]] {
        let fa = MLModelConfigurationUtils.defaultModelsDirectory()
        // FluidAudio's own `Repo.folderName` first in each list: that is the folder its loaders
        // resolve to, so borrowing *that* one costs no download either. The `-coreml` spellings stay
        // as a fallback for caches written by older upstream tools.
        var caches: [ModelID: [URL]] = [
            .parakeetTDTv3: [fa.appendingPathComponent("parakeet-tdt-0.6b-v3"), fa.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")],
            .parakeetTDTCTC110m: [fa.appendingPathComponent("parakeet-tdt-ctc-110m"), fa.appendingPathComponent("parakeet-tdt-ctc-110m-coreml")],
            .parakeetEOU160: [fa.appendingPathComponent("parakeet-eou-streaming/160ms"),
                              fa.appendingPathComponent("parakeet-realtime-eou-120m-coreml/160ms")],
        ]
        for (id, folder) in BundledModelResources.candidates() {
            caches[id, default: []].insert(folder, at: 0)
        }
        return caches
    }

    /// Where we store `id`. Not `<root>/<id.rawValue>`: the folder name has to be the one FluidAudio
    /// resolves back to from the parent directory, or every load re-downloads the model into a second
    /// folder. See `ModelDescriptor.folderName` and `ModelLayoutMigration`.
    public func folder(for id: ModelID) -> URL { ModelCatalog.folder(for: id, in: root) }

    /// Is this a complete, loadable model — not just a directory with the right name?
    ///
    /// This used to be `requiredPaths.allSatisfy(fileExists)`. Every required path is a `.mlmodelc`
    /// *directory*, and that directory exists from the first byte the downloader writes into it, so
    /// a download interrupted mid-weights reported as installed. See `ModelIntegrity`.
    private func hasRequiredFiles(_ d: ModelDescriptor, at url: URL) -> Bool {
        ModelIntegrity.isComplete(d, at: url, fileManager: fileManager)
    }

    /// Where the model lives on disk, if anywhere (our folder first, then external caches).
    public func locate(_ id: ModelID) -> URL? {
        settleLayoutForRead()
        let d = ModelCatalog.descriptor(id)
        let own = folder(for: id)
        if hasRequiredFiles(d, at: own) { return own }
        if let external = (externalCaches[id] ?? []).first(where: { hasRequiredFiles(d, at: $0) }) { return external }
        // V4.8 — while a deferred pass has not run yet, an install still on the pre-1.7.13 layout
        // is present, just not migrated. Say so, rather than building the launch engine as if the
        // model were missing. Nothing loads from here: `load` awaits the pass, which moves it first.
        guard case .deferred = maintenanceMode, !maintenancePass.isComplete else { return nil }
        return d.legacyFolderNames.map { root.appendingPathComponent($0, isDirectory: true) }
            .first { hasRequiredFiles(d, at: $0) }
    }

    public func status(_ id: ModelID) -> ModelStatus {
        if let p = progress[id], downloads[id] != nil { return .downloading(p) }
        guard let url = locate(id) else { return .missing }
        return loaded[id] != nil ? .loaded(url) : .present(url)
    }

    public func isPresent(_ id: ModelID) -> Bool { locate(id) != nil }
    public func isLoaded(_ id: ModelID) -> Bool { loaded[id] != nil }

    /// Re-hash every file the manifest records and return the paths that do not match.
    ///
    /// An empty result means "nothing disagreed", which is **not** the same as "verified": a model
    /// with no manifest has nothing to disagree with and also returns empty. Ask `assess(_:)` when
    /// the difference matters — it does whenever the answer is being reported as integrity rather
    /// than used as a go/no-go for loading.
    public func verify(_ id: ModelID) -> [String] {
        guard let url = locate(id) else { return [] }
        guard let manifest = ModelManifest.load(from: url) else {
            Log.engine.notice("verify \(id.rawValue): no \(ModelManifest.fileName) at \(url.path) — nothing to re-hash against, so this is 'not checked', not 'checked and fine'")
            return []
        }
        return manifest.verify(in: url)
    }

    /// What we are entitled to say about the model on disk: `.verified`, `.unverifiable` (usable, but
    /// with no manifest to catch a truncated file), or `.incomplete`. Cheap — no hashing.
    public func assess(_ id: ModelID) -> ModelIntegrity.Verification {
        guard let url = locate(id) else { return .incomplete(["\(id.rawValue) is not installed"]) }
        return ModelIntegrity.assess(ModelCatalog.descriptor(id), at: url, fileManager: fileManager)
    }

    /// Download if missing. Concurrent callers share one download task. Returns the model folder.
    @discardableResult
    public func ensureAvailable(_ id: ModelID, progress handler: ModelProgressHandler? = nil) async throws -> URL {
        await settleLayout()
        if let url = locate(id) { return url }
        if let task = downloads[id] { return try await task.value }
        let d = ModelCatalog.descriptor(id)
        guard let fetcher = fetchers[d.kind] else { throw ModelManagerError.unsupported(id) }
        let dest = folder(for: id)
        progress[id] = 0
        let task = Task<URL, Error> {
            try await fetcher.fetch(d, into: dest) { [weak self] info in
                handler?(info)
                Task { await self?.setProgress(id, info.fraction) }
            }
            return dest
        }
        downloads[id] = task
        defer { downloads[id] = nil; progress[id] = nil }
        let url = try await task.value
        // The install is only an install once every file is actually there. A fetcher that returned
        // without throwing but left the folder incomplete used to be indistinguishable from success:
        // `notPresent` here, and the debris stayed to poison the retry.
        let problems = ModelIntegrity.problems(for: d, at: url, fileManager: fileManager)
        guard problems.isEmpty else {
            Log.engine.error("model \(id.rawValue) downloaded but incomplete: \(problems.joined(separator: ", "))")
            repair(id)
            throw ModelManagerError.incomplete(id, problems)
        }
        return url
    }

    /// Clear the interrupted-download debris in our own folder for `id`, and return what went.
    ///
    /// The recovery half of the 1.7.9 `weight.bin.partial` report. A stale `.partial` is precisely
    /// what the next download trips over — FluidAudio streams into it and then moves it into place,
    /// so a leftover one from a killed run turns a retry into the same cryptic Cocoa error. Only the
    /// scratch files go; whole files that landed are kept, so a retry costs one file, not the model.
    /// External caches are somebody else's directory and are never touched.
    @discardableResult
    public func repair(_ id: ModelID) -> [String] {
        // Repair and the pass sweep the same directories; never both at once.
        if case .skip = maintenanceMode {} else { maintenancePass.runOrWait() }
        // Parked copies (`.superseded-`/`.replaced-`) are the other kind of debris a failed install
        // leaves, and they are the expensive kind — a whole 468 MB tree, not a scratch file. Nothing
        // used to look at them at all, so a crash mid-swap stranded them permanently.
        ParkedModelDirectories.sweep(root: root)
        let own = folder(for: id)
        guard fileManager.fileExists(atPath: own.path) else { return [] }
        let removed = ModelIntegrity.removeIncompleteParts(under: own, fileManager: fileManager)
        if !removed.isEmpty {
            Log.engine.info("cleared \(removed.count) unfinished part(s) of \(id.rawValue): \(removed.joined(separator: ", "))")
        }
        // Deliberately nothing else. What is left after the incomplete bundles go is either a
        // complete model or one that is now honestly missing a required path — and a model that
        // reports "not installed" is exactly what makes the UI offer a re-download. Deleting the
        // rest would only throw away bytes that the next download would otherwise skip.
        return removed
    }

    private func setProgress(_ id: ModelID, _ p: Double) { progress[id] = p }

    public func cancelDownload(_ id: ModelID) { downloads[id]?.cancel() }

    /// Load into memory (CoreML compile/ANE warm). Idempotent. Does not download.
    ///
    /// Concurrent callers share one load task, and that sharing is the fix for the 1.7.9 report.
    /// `load` is actor-isolated but it suspends on `AsrModels.load`, and an actor releases itself
    /// across a suspension: two callers — the launch preload (`AppContainer.warmUpEngine`) and the
    /// user's first hotkey press — both saw `loaded[id] == nil` and both went on to load. Underneath,
    /// `AsrModels.load` is not a pure read: it calls `ModelHub.loadModels`, which re-downloads
    /// anything the cache is missing. Two of those over one folder race on the same scratch file, one
    /// wins the move, and the loser reports `The file "weight.bin.partial" doesn't exist.` — the
    /// error in the screenshot. Eager preload (9f4b0c3) did not cause this; it supplied the second
    /// caller that made it reachable.
    @discardableResult
    public func load(_ id: ModelID) async throws -> LoadedModel {
        guard let residency else { return try await performLoad(id) }
        let key = id.residencyKey(scope: residencyScope)
        if let m = loaded[id] { await residency.touch(key); return m }
        await registerWithResidency(id, residency)
        // The residency evicts what the tier rules require, then calls back into `performLoad`.
        try await residency.acquire(key)
        if let m = loaded[id] { return m }
        return try await performLoad(id)
    }

    deinit {
        if let residency { let scope = residencyScope; Task { await residency.unregisterAll(owner: scope) } }
    }

    private func registerWithResidency(_ id: ModelID, _ residency: ModelResidency) async {
        guard !registered.contains(id) else { return }
        // Inserted only after the await: a concurrent caller re-registers (harmless) rather than
        // racing ahead to `acquire` an unregistered key.
        await residency.register(id.residencyKey(scope: residencyScope), tier: id.residencyTier,
                                 estimatedBytes: ModelCatalog.descriptor(id).approxBytes, owner: residencyScope,
                                 load: { [weak self] in _ = try await self?.performLoad(id) },
                                 unload: { [weak self] in await self?.performUnload(id) })
        registered.insert(id)
    }

    private func performLoad(_ id: ModelID) async throws -> LoadedModel {
        if let m = loaded[id] { return m }
        // V4.8 — the pass that used to finish inside `init` is awaited here instead, so a migration
        // can still never move a folder CoreML is reading.
        await settleLayout()
        if let m = loaded[id] { return m }
        if let inFlight = loads[id] { return try await inFlight.value }
        guard let url = locate(id) else { throw ModelManagerError.notPresent(id) }
        let d = ModelCatalog.descriptor(id)
        // `locate` already applies this, but an external cache can change under us and a load is the
        // last moment we can say something useful instead of letting CoreML throw about a temp file.
        let problems = ModelIntegrity.problems(for: d, at: url, fileManager: fileManager)
        guard problems.isEmpty else {
            Log.engine.error("refusing to load incomplete model \(id.rawValue): \(problems.joined(separator: ", "))")
            repair(id)
            throw ModelManagerError.incomplete(id, problems)
        }
        let load = loader
        let task = Task<LoadedModel, Error> { try await load(id, d, url) }
        loads[id] = task
        defer { loads[id] = nil }
        do {
            let model = try await task.value
            loaded[id] = model
            // Say out loud when what we just loaded is only *structurally* sound. Without a manifest
            // there are no recorded byte counts, so a file that is silently short would have passed
            // every check above. External caches are the normal reason: they are FluidAudio's
            // directory, we never write into it, so a model borrowed from there has no manifest.
            if ModelManifest.load(from: url) == nil {
                Log.engine.notice("ModelManager loaded \(d.displayName) from \(url.path) with no \(ModelManifest.fileName) — usable, but truncation cannot be detected for it")
            } else {
                Log.engine.info("ModelManager loaded \(d.displayName) from \(url.path)")
            }
            return model
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A load that failed on a folder that has since gone incomplete is the corruption case,
            // not a CoreML-can't-run-here case: say so in words the user can act on, and clear the
            // debris so pressing the key again is a real retry rather than the same crash.
            let after = ModelIntegrity.problems(for: d, at: url, fileManager: fileManager)
            let scratchNamed = "\(error)".contains(".partial") || "\(error)".contains(".part")
            guard !after.isEmpty || scratchNamed else { throw error }
            Log.engine.error("load of \(id.rawValue) failed on an incomplete model: \(error)")
            repair(id)
            throw ModelManagerError.incomplete(id, after.isEmpty ? ["an unfinished download was left behind"] : after)
        }
    }

    public func unload(_ id: ModelID) async {
        if let residency, registered.contains(id) {
            await residency.unload(id.residencyKey(scope: residencyScope), reason: .explicit)
        }
        await performUnload(id)
    }

    private func performUnload(_ id: ModelID) async {
        if case .eou(let m)? = loaded[id] { await m.cleanup() }
        loaded[id] = nil
    }

    public func unloadAll() async { for id in Array(loaded.keys) { await unload(id) } }

    /// Warm start: load whatever of `preferred` is already on disk, best-effort, no network.
    /// Returns the ids that are now resident.
    @discardableResult
    public func warmStart(preferred: [ModelID] = [.parakeetEOU160, .parakeetTDTv3, .parakeetTDTCTC110m]) async -> [ModelID] {
        var ok: [ModelID] = []
        for id in preferred where isPresent(id) {
            if (try? await load(id)) != nil { ok.append(id) }
        }
        return ok
    }

    /// The best final-pass model currently on disk: full TDT v3, else the tiny one.
    /// Shares `BundledModel.finalModelsByQuality` with `RecognizerFactory.chooseFinal`.
    public func bestFinalModelOnDisk() -> ModelID? {
        BundledModel.finalModelsByQuality.first { isPresent($0) }
    }
}

/// V4.8 — the model-store maintenance pass, run exactly once: detached on its own queue
/// (`startDetached`), inline on first use (`runOrWait`), or never (`skipped`). Its own dispatch queue
/// rather than a Swift task on purpose: a synchronous reader blocks in `waitWhileRunning` on a
/// cooperative-pool thread, and the pass must never need a pool thread to finish.
final class ModelMaintenancePass: @unchecked Sendable {
    enum Phase: Equatable, Sendable { case pending, running, finished, skipped }

    private let condition = NSCondition()
    private var phase: Phase
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let work: @Sendable () -> Void
    private let queue = DispatchQueue(label: "in.adityakatare.voiceplus.models.maintenance", qos: .utility)

    init(skipped: Bool, work: @escaping @Sendable () -> Void) {
        self.phase = skipped ? .skipped : .pending
        self.work = work
    }

    var current: Phase { condition.lock(); defer { condition.unlock() }; return phase }
    var isComplete: Bool { let p = current; return p == .finished || p == .skipped }

    /// Starts a pending pass on its own queue. Never blocks.
    func startDetached() {
        guard claim() else { return }
        queue.async { self.run() }
    }

    /// Runs a pending pass on the calling thread, or waits for one that is already running.
    func runOrWait() {
        if claim() { run() } else { waitWhileRunning() }
    }

    /// Blocks only while a pass is actually moving directories; a pending one is left alone.
    func waitWhileRunning() {
        condition.lock()
        while phase == .running { condition.wait() }
        condition.unlock()
    }

    /// Starts the pass if it is pending and suspends until it has finished.
    func finished() async {
        startDetached()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            condition.lock()
            if phase == .running {
                waiters.append(c)
                condition.unlock()
            } else {
                condition.unlock()
                c.resume()
            }
        }
    }

    private func claim() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard phase == .pending else { return false }
        phase = .running
        return true
    }

    private func run() {
        work()
        condition.lock()
        phase = .finished
        let resumed = waiters
        waiters.removeAll()
        condition.broadcast()
        condition.unlock()
        resumed.forEach { $0.resume() }
    }
}
