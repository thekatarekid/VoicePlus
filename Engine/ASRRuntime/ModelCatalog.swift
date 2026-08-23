import Foundation
import Shared

/// Models the ASR runtime knows about. Raw values are stable on-disk folder names.
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

    public init(id: ModelID, kind: ModelKind, hfRepo: String, hfSubdirectory: String = "", requiredPaths: [String],
                remoteFiles: [RemoteFile] = [], approxBytes: Int64, displayName: String, license: String) {
        self.id = id; self.kind = kind; self.hfRepo = hfRepo; self.hfSubdirectory = hfSubdirectory
        self.requiredPaths = requiredPaths; self.remoteFiles = remoteFiles; self.approxBytes = approxBytes
        self.displayName = displayName; self.license = license
    }
}

public enum ModelCatalog {
    public static let all: [ModelID: ModelDescriptor] = [
        .parakeetTDTv3: ModelDescriptor(
            id: .parakeetTDTv3, kind: .finalTDT, hfRepo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
            requiredPaths: ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"],
            approxBytes: 500_000_000, displayName: "Parakeet TDT 0.6B v3", license: "CC-BY-4.0"),
        .parakeetEOU160: ModelDescriptor(
            id: .parakeetEOU160, kind: .streamingEOU, hfRepo: "FluidInference/parakeet-realtime-eou-120m-coreml", hfSubdirectory: "160ms",
            requiredPaths: ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"],
            approxBytes: 400_000_000, displayName: "Parakeet Realtime EOU 120M (160 ms)", license: "other"),
        .parakeetTDTCTC110m: ModelDescriptor(
            id: .parakeetTDTCTC110m, kind: .finalTDT, hfRepo: "FluidInference/parakeet-tdt-ctc-110m-coreml",
            requiredPaths: ["Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"],
            approxBytes: 110_000_000, displayName: "Parakeet TDT-CTC 110M (tiny)", license: "CC-BY-4.0"),
        .whisperSmall: ModelDescriptor(
            id: .whisperSmall, kind: .whisper, hfRepo: "ggerganov/whisper.cpp",
            requiredPaths: ["ggml-small.bin"],
            remoteFiles: [RemoteFile(path: "ggml-small.bin", size: 487_601_967)],
            approxBytes: 488_000_000, displayName: "Whisper small (Intel fallback, placeholder)", license: "MIT"),
    ]

    public static func descriptor(_ id: ModelID) -> ModelDescriptor { all[id]! }

    /// Root for all VoicePlus-managed models: `~/Library/Application Support/VoicePlus/Models`.
    public static func modelsRoot(fileManager: FileManager = .default) -> URL {
        AppPaths.supportDirectory(fileManager: fileManager).appendingPathComponent("Models", isDirectory: true)
    }
}
