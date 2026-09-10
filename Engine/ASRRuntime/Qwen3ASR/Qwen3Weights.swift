// VoicePlus original (task R5.1). Where the 1.2 GB of Qwen3-ASR int8 weights come from.
//
// Two sources, in this order:
//   1. A directory already on disk — VoicePlus's own models root first, then FluidAudio's cache
//      (`~/Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b/int8`), which is where the
//      owner's copy already lives. Borrowed read-only; we never write into somebody else's cache.
//   2. Download-on-enable, delegated to `Qwen3WeightsProvisioning`.
//
// Nothing here is gated on macOS 15: path resolution has to work on macOS 14 so the UI can say
// "installed, but refinement needs macOS 15" rather than "missing".
import Foundation
import Shared

// MARK: - On-disk layout

public enum Qwen3WeightsLayout: Sendable {
    /// Folder, relative to a models root. Matches FluidAudio's own cache layout, which is the
    /// whole reason the owner's existing 1.2 GB download is reusable without a byte of network.
    public static let folderName = "qwen3-asr-0.6b/int8"

    /// What `Qwen3AsrModels.load(from:)` opens. Missing any one of these = not installed.
    public static let requiredPaths = [
        "qwen3_asr_audio_encoder_v2.mlmodelc",
        "qwen3_asr_decoder_stateful.mlmodelc",
        "qwen3_asr_embeddings.bin",
        "vocab.json",
    ]

    /// Every file the publisher's manifest records, with the byte count it records.
    ///
    /// Taken from the marker the managed downloader leaves in the cache
    /// (`.muesli-managed-model-complete.json`, revision `main`). The publisher gives byte counts
    /// and no SHA256, so `Qwen3WeightsStore.verify` asserts sizes; a `voiceplus-manifest.json`
    /// with digests only appears for weights *we* download (see `catalogEntry` below).
    public static let files: [(path: String, bytes: Int64)] = [
        ("qwen3_asr_audio_encoder_v2.mlmodelc/analytics/coremldata.bin", 243),
        ("qwen3_asr_audio_encoder_v2.mlmodelc/coremldata.bin", 385),
        ("qwen3_asr_audio_encoder_v2.mlmodelc/metadata.json", 2_088),
        ("qwen3_asr_audio_encoder_v2.mlmodelc/model.mil", 726_626),
        ("qwen3_asr_audio_encoder_v2.mlmodelc/weights/weight.bin", 372_798_784),
        ("qwen3_asr_decoder_stateful.mlmodelc/analytics/coremldata.bin", 243),
        ("qwen3_asr_decoder_stateful.mlmodelc/coremldata.bin", 2_347),
        ("qwen3_asr_decoder_stateful.mlmodelc/metadata.json", 18_844),
        ("qwen3_asr_decoder_stateful.mlmodelc/model.mil", 939_591),
        ("qwen3_asr_decoder_stateful.mlmodelc/weights/weight.bin", 597_456_384),
        ("qwen3_asr_embeddings.bin", 311_164_936),
        ("vocab.json", 2_776_833),
    ]

    public static var approxBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Download scratch, same set `ModelIntegrity` treats as debris.
    public static let scratchExtensions: Set<String> = ["partial", "part", "etag"]
}

// MARK: - Provisioning (download-on-enable)

/// How a *missing* weights directory gets filled in. Deliberately a protocol living in this
/// directory: `ModelManager`/`ModelCatalog` are owned elsewhere in this wave, and the catalog's
/// `ModelID` is a closed enum, so Qwen cannot be registered from here without editing their
/// files. `Qwen3WeightsCatalogEntry` below carries exactly the data that registration needs.
public protocol Qwen3WeightsProvisioning: Sendable {
    /// Download (resumably, atomically, integrity-checked) and return the model folder.
    func provisionQwen3Weights(progress: (@Sendable (Double) -> Void)?) async throws -> URL
}

/// The default: refuse, in words a user can act on. Nothing downloads 1.2 GB by accident, and
/// tests get this for free — no network, ever.
public struct UnavailableQwen3WeightsProvisioner: Qwen3WeightsProvisioning {
    public init() {}
    public func provisionQwen3Weights(progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        throw RefinementError.weightsMissing(searched: Qwen3WeightsStore.defaultSearchPaths().map(\.path))
    }
}

/// A provisioner backed by a closure, so the app can hand in `ModelManager.ensureAvailable(_:)`
/// once the catalog entry exists without this file having to know about `ModelID`.
public struct ClosureQwen3WeightsProvisioner: Qwen3WeightsProvisioning {
    private let body: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL
    public init(_ body: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL) {
        self.body = body
    }
    public func provisionQwen3Weights(progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        try await body({ fraction in progress?(fraction) })
    }
}

/// Everything `ModelCatalog`/`ModelManager` need to own the Qwen download the way they own every
/// other model (manifest + integrity + resume). **This is the R5.1 integration point**: adding a
/// `ModelID` case and this descriptor is a change in files another agent owns, so it is described
/// here rather than made here.
public enum Qwen3WeightsCatalogEntry: Sendable {
    /// Proposed `ModelID` raw value — stable identity, written into `voiceplus-manifest.json`.
    public static let modelIDRawValue = "qwen3-asr-0.6b-coreml-int8"
    public static let hfRepo = "FluidInference/qwen3-asr-0.6b-coreml"
    /// Repo revision the on-disk copy came from.
    public static let hfRevision = "main"
    public static let hfSubdirectory = ""
    public static let folderName = Qwen3WeightsLayout.folderName
    public static let displayName = "Qwen3-ASR 0.6B (int8, refinement)"
    /// Weights licence, and the reason `LICENSE-Apache-2.0` sits next to this file.
    public static let license = "Apache-2.0"
    public static var requiredPaths: [String] { Qwen3WeightsLayout.requiredPaths }
    public static var approxBytes: Int64 { Qwen3WeightsLayout.approxBytes }
    /// `RemoteFile(path:size:)` rows, ready to paste: path + recorded byte count, no SHA256
    /// (the publisher does not publish digests; `ModelManifest.build` records ours on download).
    public static var remoteFiles: [(path: String, size: Int64)] {
        Qwen3WeightsLayout.files.map { (path: $0.path, size: $0.bytes) }
    }
}

// MARK: - Store

/// Resolve a weights directory: look on disk, then (only if asked) download.
public struct Qwen3WeightsStore: Sendable {
    public let searchPaths: [URL]
    public let provisioner: any Qwen3WeightsProvisioning
    /// `FileManager` is not `Sendable`; `.default` is the only value any caller passes and it is
    /// thread-safe for the read-only `stat`/enumerate this type does.
    private nonisolated(unsafe) let fileManager: FileManager

    public init(
        searchPaths: [URL] = Qwen3WeightsStore.defaultSearchPaths(),
        provisioner: any Qwen3WeightsProvisioning = UnavailableQwen3WeightsProvisioner(),
        fileManager: FileManager = .default
    ) {
        self.searchPaths = searchPaths
        self.provisioner = provisioner
        self.fileManager = fileManager
    }

    /// VoicePlus's own models root first, then FluidAudio's cache.
    ///
    /// Both are spelled out from `AppPaths`/`FileManager` rather than reused from
    /// `ModelCatalog`/`ModelManager`: those files belong to another task in this wave, and one
    /// less coupling is one less merge conflict. The two roots must stay in step with
    /// `ModelCatalog.modelsRoot()` and `ModelManager.defaultExternalCaches()`.
    public static func defaultSearchPaths(fileManager: FileManager = .default) -> [URL] {
        [voicePlusModelsRoot(fileManager: fileManager), fluidAudioModelsRoot(fileManager: fileManager)]
            .map { $0.appendingPathComponent(Qwen3WeightsLayout.folderName, isDirectory: true) }
    }

    /// `~/Library/Application Support/VoicePlus/Models` — the same directory `ModelCatalog` uses.
    public static func voicePlusModelsRoot(fileManager: FileManager = .default) -> URL {
        AppPaths.supportDirectory(fileManager: fileManager)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// `~/Library/Application Support/FluidAudio/Models` — FluidAudio's own cache. Read-only.
    public static func fluidAudioModelsRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// First search path that holds a complete model, or nil.
    public func locate() -> URL? {
        searchPaths.first { problems(at: $0).isEmpty }
    }

    public var isPresent: Bool { locate() != nil }

    /// Why `folder` is not a loadable model. Empty = nothing wrong that a cheap check can see.
    ///
    /// Same shape of check as `ModelIntegrity.problems(for:at:)`: a `.mlmodelc` is a *directory*
    /// and exists from the first byte a download writes into it, so "the path exists" proves
    /// nothing. Every recorded file must be there, be a regular file, and be non-empty; any
    /// leftover `.part`/`.partial` marks the folder as an interrupted download.
    public func problems(at folder: URL) -> [String] {
        var problems: [String] = []
        guard fileManager.fileExists(atPath: folder.path) else { return ["\(folder.lastPathComponent) is not installed"] }
        for file in Qwen3WeightsLayout.files {
            let url = folder.appendingPathComponent(file.path)
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else {
                problems.append("\(file.path) is missing")
                continue
            }
            if (attrs[.size] as? Int64 ?? 0) == 0 { problems.append("\(file.path) is empty") }
        }
        problems.append(contentsOf: scratchFiles(in: folder).map { "\($0) is an unfinished download" })
        return problems
    }

    /// Byte counts against the publisher's recorded manifest. Cheap (a `stat` per file) and the
    /// only integrity assertion available for a borrowed cache — the publisher ships no digests.
    /// An empty result from a folder that `problems` already rejected means nothing; ask both.
    public func verify(at folder: URL) -> [String] {
        Qwen3WeightsLayout.files.compactMap { file in
            let url = folder.appendingPathComponent(file.path)
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            guard let size, size == file.bytes else { return file.path }
            return nil
        }
    }

    public func scratchFiles(in folder: URL) -> [String] {
        guard let walker = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let url as URL in walker where Qwen3WeightsLayout.scratchExtensions.contains(url.pathExtension) {
            found.append(url.lastPathComponent)
        }
        return found.sorted()
    }

    /// The one call the session makes. `downloadIfMissing == false` never touches the network.
    public func resolve(
        downloadIfMissing: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let url = locate() { return url }
        guard downloadIfMissing else {
            throw RefinementError.weightsMissing(searched: searchPaths.map(\.path))
        }
        let url = try await provisioner.provisionQwen3Weights(progress: progress)
        let problems = problems(at: url)
        guard problems.isEmpty else {
            throw RefinementError.weightsIncomplete(path: url.path, problems: problems)
        }
        return url
    }
}
