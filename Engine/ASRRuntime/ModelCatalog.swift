import Foundation
import Shared

/// Models the ASR runtime knows about.
///
/// Raw values are the *stable identity* of a model — they are `Codable`, and every
/// `voiceplus-manifest.json` already on a user's disk has one written into it. They are deliberately
/// **not** the on-disk folder name any more: see `ModelDescriptor.folderName`.
public enum ModelID: String, Codable, CaseIterable, Sendable {
    /// Primary final-pass model (Apple Silicon). ~500 MB.
    case parakeetTDTv3 = "parakeet-tdt-0.6b-v3-coreml"
    /// Streaming preview + end-of-utterance model, 160 ms chunks. ~400 MB.
    case parakeetEOU160 = "parakeet-realtime-eou-120m-coreml-160ms"
    /// Smallest TDT-capable model (hybrid TDT-CTC 110M, ~110 MB): the "bundled tiny" model
    /// fetched first at onboarding so dictation works before the 500 MB download lands.
    case parakeetTDTCTC110m = "parakeet-tdt-ctc-110m-coreml"
    /// Intel fallback. Placeholder entry: no runtime in Phase 1 (documented deviation).
    case whisperSmall = "whisper-small"
}

public enum ModelKind: String, Codable, Sendable {
    case finalTDT, streamingEOU, whisper
}

/// A file the manifest-driven fetcher downloads. `sha256` nil = record-on-download.
public struct RemoteFile: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String?
    public var size: Int64?
    public init(path: String, sha256: String? = nil, size: Int64? = nil) {
        self.path = path; self.sha256 = sha256; self.size = size
    }
}

public struct ModelDescriptor: Equatable, Sendable {
    public var id: ModelID
    public var kind: ModelKind
    /// The folder this model lives in, under `ModelCatalog.modelsRoot()`.
    ///
    /// **This must equal FluidAudio's `Repo.folderName` for any model FluidAudio loads**, and that is
    /// the whole point of the property existing. `AsrModels.load(from:)` does not load from the
    /// directory you hand it: it takes `directory.deletingLastPathComponent()` as a *models root* and
    /// asks `ModelHub.loadModels(directory:)` for the repo, which resolves back down to
    /// `<parent>/<Repo.folderName>` — and `Repo.folderName` strips `-coreml`
    /// (`ModelNames.swift`: `name.replacingOccurrences(of: "-coreml", with: "")`).
    ///
    /// Until 1.7.13 the folder was the `ModelID` raw value, `…-v3-coreml`, so the round trip landed on
    /// `…/Models/parakeet-tdt-0.6b-v3`, found it empty, and re-downloaded all 468 MB from HuggingFace
    /// *every model, every tier* — a second copy on disk and ~81 s of "Warming up…" on top of the
    /// genuine one-time ANE compile. Only `parakeet_vocab.json` was ever read from our own copy.
    /// Naming the folder what FluidAudio resolves to makes the two the same directory.
    public var folderName: String
    /// Folder names this model used to be stored under, newest first. Migrated on `ModelManager` init.
    public var legacyFolderNames: [String]
    /// HuggingFace repo id, e.g. `FluidInference/parakeet-tdt-0.6b-v3-coreml`.
    public var hfRepo: String
    /// Sub-path inside the repo (EOU variants live in `160ms/`). Empty for root.
    public var hfSubdirectory: String
    /// Files that must exist (relative to the model folder) for the model to count as present.
    public var requiredPaths: [String]
    /// Flat files fetched by `ManifestFetcher` (only for models without a FluidAudio loader).
    public var remoteFiles: [RemoteFile]
    public var approxBytes: Int64
    public var displayName: String
    public var license: String

    public init(id: ModelID, kind: ModelKind, folderName: String? = nil, legacyFolderNames: [String] = [],
                hfRepo: String, hfSubdirectory: String = "", requiredPaths: [String],
                remoteFiles: [RemoteFile] = [], approxBytes: Int64, displayName: String, license: String) {
        self.id = id; self.kind = kind
        self.folderName = folderName ?? id.rawValue
        self.legacyFolderNames = legacyFolderNames.filter { $0 != (folderName ?? id.rawValue) }
        self.hfRepo = hfRepo; self.hfSubdirectory = hfSubdirectory
        self.requiredPaths = requiredPaths; self.remoteFiles = remoteFiles; self.approxBytes = approxBytes
        self.displayName = displayName; self.license = license
    }
}

public enum ModelCatalog {
    public static let all: [ModelID: ModelDescriptor] = [
        .parakeetTDTv3: ModelDescriptor(
            id: .parakeetTDTv3, kind: .finalTDT,
            // = `Repo.parakeetV3.folderName` (default branch: "parakeet-tdt-0.6b-v3-coreml" minus "-coreml").
            folderName: "parakeet-tdt-0.6b-v3", legacyFolderNames: ["parakeet-tdt-0.6b-v3-coreml"],
            hfRepo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            requiredPaths: ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"],
            approxBytes: 500_000_000, displayName: "Parakeet TDT 0.6B v3", license: "CC-BY-4.0"),
        // No `folderName` override, and deliberately so: `StreamingEouAsrManager.loadModels(from:)`
        // opens `<directory>/streaming_encoder.mlmodelc` and friends *directly* — it never goes
        // through `ModelHub`, never re-derives a parent, and so never re-downloads. The EOU model is
        // the one FluidAudio-loaded model the `-coreml` bug does not reach (confirmed on disk: no
        // duplicate EOU folder next to the duplicated TDT ones), and renaming it would cost a
        // migration for nothing.
        .parakeetEOU160: ModelDescriptor(
            id: .parakeetEOU160, kind: .streamingEOU, hfRepo: "FluidInference/parakeet-realtime-eou-120m-coreml", hfSubdirectory: "160ms",
            requiredPaths: ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"],
            approxBytes: 400_000_000, displayName: "Parakeet Realtime EOU 120M (160 ms)", license: "other"),
        .parakeetTDTCTC110m: ModelDescriptor(
            id: .parakeetTDTCTC110m, kind: .finalTDT,
            // = `Repo.parakeetTdtCtc110m.folderName` (an explicit case in `ModelNames.folderName`).
            folderName: "parakeet-tdt-ctc-110m", legacyFolderNames: ["parakeet-tdt-ctc-110m-coreml"],
            hfRepo: "FluidInference/parakeet-tdt-ctc-110m-coreml",
            requiredPaths: ["Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"],
            approxBytes: 110_000_000, displayName: "Parakeet TDT-CTC 110M (tiny)", license: "CC-BY-4.0"),
        .whisperSmall: ModelDescriptor(
            id: .whisperSmall, kind: .whisper, hfRepo: "ggerganov/whisper.cpp",
            requiredPaths: ["ggml-small.bin"],
            remoteFiles: [RemoteFile(path: "ggml-small.bin", size: 487_601_967)],
            approxBytes: 488_000_000, displayName: "Whisper small (Intel fallback, placeholder)", license: "MIT"),
    ]

    public static func descriptor(_ id: ModelID) -> ModelDescriptor { all[id]! }

    /// The single place a `ModelID` becomes a directory name. See `ModelDescriptor.folderName`.
    public static func folderName(for id: ModelID) -> String { descriptor(id).folderName }

    /// Where `id` lives under `root`.
    public static func folder(for id: ModelID, in root: URL) -> URL {
        root.appendingPathComponent(folderName(for: id), isDirectory: true)
    }

    /// Root for all VoicePlus-managed models: `~/Library/Application Support/VoicePlus/Models`.
    public static func modelsRoot(fileManager: FileManager = .default) -> URL {
        AppPaths.supportDirectory(fileManager: fileManager).appendingPathComponent("Models", isDirectory: true)
    }
}
