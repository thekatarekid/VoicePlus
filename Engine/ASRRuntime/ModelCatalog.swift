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
    /// H3 (V4.50) — the speaker-embedding weights: FluidAudio's diarizer repo, whose WeSpeaker v2
    /// model is the only backend that can tell voices apart (`FluidSpeakerEmbedder`). It needs the
    /// pyannote segmentation model beside it (the embedder sizes its mask from that model's output
    /// shape). ~14 MB. Declared last so `RealEngine.revision()`'s bit positions for the speech
    /// models do not move.
    case speakerEmbedding = "speaker-diarization-coreml"
}

/// Which fetcher `ModelManager` downloads a model with, and which loader it would load it with.
///
/// There is no speaker-embedding kind yet: adding one means a case in `ModelManager`'s exhaustive
/// loader switch and its default fetcher table, which H3 left to the owner of that file. Until then
/// `ModelID.speakerEmbedding` rides `.streamingEOU` — see its catalog entry for why that is safe.
public enum ModelKind: String, Codable, Sendable {
    case finalTDT, streamingEOU, whisper
}

/// Why a model is in the catalog at all — and therefore whether a user ever sees it.
///
/// R6.1 removed the `fast / balanced / best` picker. There is one stack now, so the catalog is no
/// longer a menu: it is one stack plus the things that stand in for it when the stack cannot run.
/// A model the user cannot choose must not be listed as though they could, which is what the three
/// "Local · …" rows in Settings › Models had become.
public enum ModelRole: String, Codable, Sendable, Equatable {
    /// Part of `ModelStack.models` — installed on first run, listed in Settings › Models.
    case stack
    /// Reachable only as a fallback: the recognizer walks down to it when the stack is missing
    /// (TDT-CTC 110M) or the architecture rules the stack out (Whisper). Never offered in the UI,
    /// never fetched on purpose, and never deleted from disk if it is already there.
    case fallback
    /// Second-pass refinement. Listed (and fetched) only while refinement is switched on — see
    /// `ModelStack.refinementFlagID`.
    case refinement
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
    /// Whether a user ever sees this model. Defaults to `.stack`, so an entry has to say out loud
    /// that it is a fallback before it can be hidden — the safer direction for a new entry.
    public var role: ModelRole

    public init(id: ModelID, kind: ModelKind, folderName: String? = nil, legacyFolderNames: [String] = [],
                hfRepo: String, hfSubdirectory: String = "", requiredPaths: [String],
                remoteFiles: [RemoteFile] = [], approxBytes: Int64, displayName: String, license: String,
                role: ModelRole = .stack) {
        self.role = role
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
            approxBytes: 110_000_000, displayName: "Parakeet TDT-CTC 110M (tiny)", license: "CC-BY-4.0",
            // Fallback only since R6.1. It stays in the catalog because `RecognizerFactory` and
            // `BundledModel` walk down to it when the stack is not on disk yet, and because a user
            // who already has it keeps it — but it is no longer something anybody is asked to pick.
            role: .fallback),
        .whisperSmall: ModelDescriptor(
            id: .whisperSmall, kind: .whisper, hfRepo: "ggerganov/whisper.cpp",
            requiredPaths: ["ggml-small.bin"],
            remoteFiles: [RemoteFile(path: "ggml-small.bin", size: 487_601_967)],
            approxBytes: 488_000_000, displayName: "Whisper small (Intel fallback, placeholder)", license: "MIT",
            role: .fallback),
        // H3 (V4.50) — the speaker-embedding weights, a required part of the stack so the MFCC
        // fallback ("Voice filtering unavailable") is never what a real user gets.
        //
        // Verified against the repo (HF tree, main @ 1ed7a66, 2026-03-14) and against what FluidAudio
        // itself fetched on this machine, byte for byte: FluidAudio's `Repo.diarizer`
        // ("FluidInference/speaker-diarization-coreml"), which `ModelHub` fetches as exactly
        // `ModelNames.Diarizer.requiredModels` — pyannote_segmentation.mlmodelc (5,766,532 bytes) and
        // wespeaker_v2.mlmodelc (7,954,144 bytes). Card license CC-BY-4.0.
        //
        // `folderName` = `Repo.diarizer.folderName`, like the Parakeet entries, so the folder we fill
        // is the one FluidAudio's own tooling would resolve to.
        //
        // `kind: .streamingEOU` is a borrowed kind (see `ModelKind`). What it buys is the right
        // fetcher: `FluidAudioFetcher`, which resolves `hfRepo` to `Repo.diarizer`, stages, verifies
        // with `ModelIntegrity` and publishes atomically. What it would cost, were anything to ask
        // `ModelManager.load` for this id, is a clean failure: the EOU loader opens
        // `streaming_encoder.mlmodelc` in this folder, finds none, and throws — no network, no
        // wrong model. (`.finalTDT`'s loader re-resolves through `ModelHub` and could fetch Parakeet.)
        // Nothing does ask: `FluidSpeakerEmbedder.load(from:)` is this model's loader.
        .speakerEmbedding: ModelDescriptor(
            id: .speakerEmbedding, kind: .streamingEOU,
            folderName: "speaker-diarization",
            hfRepo: "FluidInference/speaker-diarization-coreml",
            requiredPaths: ["pyannote_segmentation.mlmodelc", "wespeaker_v2.mlmodelc"],
            approxBytes: 13_720_676, displayName: "WeSpeaker v2 speaker embedding", license: "CC-BY-4.0"),
    ]

    /// Models Settings › Models may list, in catalog order.
    ///
    /// Fallbacks are excluded: offering "Whisper small (Intel fallback, placeholder)" as a choice on
    /// an arm64-only build is an offer that cannot be honoured. Refinement models appear only while
    /// refinement is on, because that is the only state in which they are downloaded at all.
    public static func userVisible(qwenRefinementEnabled: Bool) -> [ModelID] {
        ModelID.allCases.filter { id in
            switch descriptor(id).role {
            case .stack: return true
            case .refinement: return qwenRefinementEnabled
            case .fallback: return false
            }
        }
    }

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

/// The one speech stack VoicePlus installs (R6.1).
///
/// There used to be three: `fast` (TDT-CTC 110M), `balanced` (TDT v3) and `best` (TDT v3 + EOU),
/// picked on a screen during onboarding. The choice was not one a user could make — the only
/// honest answer was always "best", the sizes shown were wrong, and two of the three options
/// existed to describe *fallbacks* as products. So there is one stack, it installs on first run,
/// and the fallbacks stay in the catalog as fallbacks (`ModelRole.fallback`).
public enum ModelStack {
    /// Install order: the final model first, because it is what makes dictation work at all; the
    /// streaming preview second; the speaker-embedding weights last (H3, V4.50). They are small
    /// (~14 MB) and required, but nothing about dictating waits on them, so a failed fetch of them
    /// can never hold up either speech model.
    public static let models: [ModelID] = [.parakeetTDTv3, .parakeetEOU160, .speakerEmbedding]

    /// The flag that turns Qwen refinement on. Read by *id* on purpose: the flag itself is declared
    /// in `Shared/Types/FeatureFlag.swift` by the refinement work (V3 R5), and `isEnabled(id:)`
    /// answers `false` for a flag that does not exist yet — so a refinement model stays hidden
    /// until the flag lands, and needs no change here when it does. **Integration point:** an
    /// entry added for Qwen must carry `role: .refinement`.
    public static let refinementFlagID = "qwenRefinement"

    public static var descriptors: [ModelDescriptor] { models.map(ModelCatalog.descriptor) }
    public static var displayNames: [String] { descriptors.map(\.displayName) }
    public static var approximateBytes: Int64 { descriptors.reduce(0) { $0 + $1.approxBytes } }

    /// The stack's models that are not on disk, in install order. Empty means "already installed".
    public static func missing(in manager: ModelManager) async -> [ModelID] {
        var out: [ModelID] = []
        for id in models where await !manager.isPresent(id) { out.append(id) }
        return out
    }

    public static func isInstalled(in manager: ModelManager) async -> Bool {
        await missing(in: manager).isEmpty
    }

    /// Install whatever is missing, and nothing else.
    ///
    /// Existing installs are kept as they are: a model that is already on disk is not fetched, not
    /// re-verified against the network, and its `voiceplus-manifest.json` is not rewritten — the
    /// manifest is written by the fetcher at the end of a download, and no download is started for
    /// a model that `ModelManager.locate` already finds. Returns the models it actually fetched.
    @discardableResult
    public static func install(manager: ModelManager, progress: ModelProgressHandler? = nil) async throws -> [ModelID] {
        var fetched: [ModelID] = []
        for id in await missing(in: manager) {
            try await manager.ensureAvailable(id, progress: progress)
            fetched.append(id)
        }
        return fetched
    }
}
