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
}

/// Owns disk layout (`AppPaths` → `Models/<id>`), downloads (resume + SHA256 manifest),
/// load/unload and warm-start. One instance per app; actor-isolated.
public actor ModelManager {
    public let root: URL
    private let fetchers: [ModelKind: ModelFetcher]
    private let fileManager: FileManager
    private var loaded: [ModelID: LoadedModel] = [:]
    private var downloads: [ModelID: Task<URL, Error>] = [:]
    private var progress: [ModelID: Double] = [:]
    /// Extra read-only places to look for already-downloaded models (warm start without re-download).
    private let externalCaches: [ModelID: [URL]]

    public init(root: URL = ModelCatalog.modelsRoot(),
                fetchers: [ModelKind: ModelFetcher]? = nil,
                externalCaches: [ModelID: [URL]]? = nil,
                fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        self.fetchers = fetchers ?? [.finalTDT: FluidAudioFetcher(), .streamingEOU: FluidAudioFetcher(), .whisper: ManifestFetcher()]
        self.externalCaches = externalCaches ?? Self.defaultExternalCaches()
    }

    /// FluidAudio's own cache (current + legacy folder names) so a model pulled by upstream tools is reused.
    public static func defaultExternalCaches() -> [ModelID: [URL]] {
        let fa = MLModelConfigurationUtils.defaultModelsDirectory()
        return [
            .parakeetTDTv3: [fa.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml"), fa.appendingPathComponent("parakeet-tdt-0.6b-v3")],
            .parakeetTDTCTC110m: [fa.appendingPathComponent("parakeet-tdt-ctc-110m-coreml")],
            .parakeetEOU160: [fa.appendingPathComponent("parakeet-eou-streaming/160ms"),
                              fa.appendingPathComponent("parakeet-realtime-eou-120m-coreml/160ms")],
        ]
    }

    public func folder(for id: ModelID) -> URL { root.appendingPathComponent(id.rawValue, isDirectory: true) }

    private func hasRequiredFiles(_ d: ModelDescriptor, at url: URL) -> Bool {
        d.requiredPaths.allSatisfy { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }
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

    /// Verify the manifest (if one exists). Returns mismatching paths; empty = OK / no manifest.
    public func verify(_ id: ModelID) -> [String] {
        guard let url = locate(id), let manifest = ModelManifest.load(from: url) else { return [] }
        return manifest.verify(in: url)
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
        guard hasRequiredFiles(d, at: url) else { throw ModelManagerError.notPresent(id) }
        return url
    }

    private func setProgress(_ id: ModelID, _ p: Double) { progress[id] = p }

    public func cancelDownload(_ id: ModelID) { downloads[id]?.cancel() }

    /// Load into memory (CoreML compile/ANE warm). Idempotent. Does not download.
    @discardableResult
    public func load(_ id: ModelID) async throws -> LoadedModel {
        if let m = loaded[id] { return m }
        guard let url = locate(id) else { throw ModelManagerError.notPresent(id) }
        let d = ModelCatalog.descriptor(id)
        let model: LoadedModel
        switch d.kind {
        case .finalTDT:
            let version: AsrModelVersion = (id == .parakeetTDTCTC110m) ? .tdtCtc110m : .v3
            model = .tdt(try await AsrModels.load(from: url, version: version))
        case .streamingEOU:
            let mgr = StreamingEouAsrManager(chunkSize: .ms160)
            try await mgr.loadModels(from: url)
            model = .eou(mgr)
        case .whisper:
            throw ModelManagerError.unsupported(id)
        }
        loaded[id] = model
        Log.engine.info("ModelManager loaded \(d.displayName) from \(url.path)")
        return model
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
    public func bestFinalModelOnDisk() -> ModelID? {
        [ModelID.parakeetTDTv3, .parakeetTDTCTC110m].first { isPresent($0) }
    }
}
