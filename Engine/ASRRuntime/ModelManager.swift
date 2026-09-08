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
/// offers no way out. `EngineMessage.describe` prefers `errorDescription`, so this is what shows.
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

    /// Whether this manager may rearrange the models root it is pointed at.
    ///
    /// `.skip` exists for tests. Ten of them construct `ModelManager()` — no arguments, so the *real*
    /// `~/Library/Application Support/VoicePlus/Models` — to run WER and golden-transcript checks
    /// against whatever the developer actually has downloaded. Those are read-only intentions, but
    /// maintenance runs from `init`, so `swift test` was silently entitled to migrate and delete
    /// directories in a real user's 468 MB model store. A test suite that can do that is a hazard
    /// regardless of how careful the migration is.
    public enum Maintenance: Sendable {
        /// Migrate the layout and sweep parked directories. What the app does.
        case run
        /// Touch nothing. For reading a real models root without being entitled to change it.
        case skip
    }

    public init(root: URL = ModelCatalog.modelsRoot(),
                fetchers: [ModelKind: ModelFetcher]? = nil,
                externalCaches: [ModelID: [URL]]? = nil,
                loader: ModelLoader? = nil,
                maintenance: Maintenance = .run) {
        self.root = root
        self.fetchers = fetchers ?? [.finalTDT: FluidAudioFetcher(), .streamingEOU: FluidAudioFetcher(), .whisper: ManifestFetcher()]
        self.externalCaches = externalCaches ?? Self.defaultExternalCaches()
        self.loader = loader ?? Self.coreMLLoader
        if case .run = maintenance { Self.runMaintenance(root: root) }
    }

    /// Layout migration + parked-directory sweep, under a cross-process lock.
    ///
    /// Deliberately here in `init` and not lazily behind `locate`: a migration that ran halfway
    /// through a load would move the directory out from under CoreML. It has to be finished before
    /// anything can ask where a model is.
    ///
    /// The lock is what keeps two VoicePlus processes launching together from interleaving each
    /// other's park/rename/delete over the same two paths. `init` is synchronous and non-isolated,
    /// so it is already a place that can block; `ModelRootLock` bounds how long it will.
    ///
    /// Cost on an already-migrated install: one `open`, a `stat` per model, one directory listing.
    private static func runMaintenance(root: URL) {
        ModelRootLock.withLock(root: root) {
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
        return [
            .parakeetTDTv3: [fa.appendingPathComponent("parakeet-tdt-0.6b-v3"), fa.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml")],
            .parakeetTDTCTC110m: [fa.appendingPathComponent("parakeet-tdt-ctc-110m"), fa.appendingPathComponent("parakeet-tdt-ctc-110m-coreml")],
            .parakeetEOU160: [fa.appendingPathComponent("parakeet-eou-streaming/160ms"),
                              fa.appendingPathComponent("parakeet-realtime-eou-120m-coreml/160ms")],
        ]
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
        let d = ModelCatalog.descriptor(id)
        let own = folder(for: id)
        if hasRequiredFiles(d, at: own) { return own }
        return (externalCaches[id] ?? []).first { hasRequiredFiles(d, at: $0) }
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
