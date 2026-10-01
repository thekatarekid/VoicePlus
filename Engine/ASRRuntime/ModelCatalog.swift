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
    /// V5 B1 — Parakeet CTC 110M (~103 MB), the keyword-spotting model behind final-pass vocabulary
    /// boosting (`CTCVocabularyBooster`). Not a transcriber. Fetched on demand: only once the user
    /// has words to boost (Dictionary / corrections), never as part of the stack.
    case parakeetCTC110m = "parakeet-ctc-110m-coreml"
    /// V5 C6 — Silero VAD (CoreML, 256 ms frames, ~1 MB). Part of the stack so users get Silero, not
    /// `EnergyVAD`. Appended so older `RealEngine.revision()` bit positions hold.
    case sileroVAD = "silero-vad-coreml"
    /// V5 C1b — LocalVQE speech enhancement (neural AEC + NS + dereverb, v1.3 4.8M, 256 ms chunk).
    /// Not part of the stack: fetched only when Settings › Voice selects it (`ModelRole.onDemand`).
    case localVQE = "localvqe-coreml"
    /// V5 C5 — Parakeet realtime EOU 120M at the 320 ms chunk size (upstream ~5.7 % vs ~8.3 % WER
    /// on test-clean). The preview prefers it when present (`PreviewEOUTier`); `.onDemand` until the
    /// V1 preview-WER gate moves the first-run stack to it.
    case parakeetEOU320 = "parakeet-realtime-eou-120m-coreml-320ms"
    /// V5 B5 — Parakeet Ultra (moondream's full-precision post-training of TDT v3; same tokenizer,
    /// window and joint contract; int8 encoder, ~0.63 GB). Optional final model, fetched only on
    /// request; ranked in `BundledModel.finalModelsByQuality` by the V1 result. Appended so older
    /// `RealEngine.revision()` bit positions hold.
    case parakeetUltra = "parakeet-ultra-coreml"
    /// V5 B5 — Parakeet Redux (moondream's ternary re-training of TDT v3; 2-bit palettised encoder,
    /// ~0.22 GB). Optional, for small-memory Macs. Needs macOS 15 (iOS 18 Core ML ops) — see
    /// `ModelCatalog.isSupportedOnThisOS`.
    case parakeetRedux = "parakeet-redux-coreml"
    /// V5 M7 — Sortformer streaming diarization (NVIDIA "high context" v2.1 weights, CoreML, ~0.26 GB)
    /// for live meeting speaker labels and the M8 re-diarization. On demand: fetched only when
    /// meetings want it, never part of the stack. Appended so older `RealEngine.revision()` bits hold.
    case sortformer = "diar-streaming-sortformer-coreml"
    /// V5 M9 — CAM++ speaker embedding (FunASR, 192-d, CoreML, ~17 MB): the alternative meeting
    /// embedding backend to WeSpeaker. On demand; the V1 `--stage diar` DER run picks the default
    /// (`MeetingEmbeddingChoice`). Appended so older `RealEngine.revision()` bits hold.
    case campPlus = "campplus-coreml"
    /// V5 G1 — Srota (`moorlee/qwen3-asr-0.6b-hinglish`, Apache-2.0), Qwen3-ASR-0.6B fine-tuned on
    /// Hinglish, converted with the Qwen3-ASR recipe (`tools/qwen3-asr-hinglish/`). The final pass
    /// when Hindi is one of the user's languages (LANG1). On demand. Appended (revision bits).
    case qwen3AsrHinglish = "qwen3-asr-0.6b-hinglish-coreml"
    /// V5 G2 — Nemotron 3.5 ASR Streaming Multilingual, `multilingual/1120ms` only (~0.66 GB): final
    /// pass + streaming preview when a language Parakeet v3 lacks is chosen. On demand. Appended.
    case nemotronMultilingual = "nemotron-3.5-asr-streaming-multilingual-0.6b-coreml-1120ms"
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
    /// V5 B1/B5 — an optional model fetched only when a feature needs it (CTC boosting) or the user
    /// opts in. Never part of the first-run stack, not listed as a choice, never deleted if present.
    case onDemand
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
            // FX3: the real size — the sum of the 23 files a verified 1.11.1 install recorded in its
            // manifest (483,257,242 bytes). It was 500 MB, and with EOU's 400 MB the first-run
            // screen quoted 914 MB for a ~721 MB download.
            approxBytes: 483_257_242, displayName: "Parakeet TDT 0.6B v3", license: "CC-BY-4.0"),
        // No `folderName` override, and deliberately so: `StreamingEouAsrManager.loadModels(from:)`
        // opens `<directory>/streaming_encoder.mlmodelc` and friends *directly* — it never goes
        // through `ModelHub`, never re-derives a parent, and so never re-downloads. The EOU model is
        // the one FluidAudio-loaded model the `-coreml` bug does not reach (confirmed on disk: no
        // duplicate EOU folder next to the duplicated TDT ones), and renaming it would cost a
        // migration for nothing.
        .parakeetEOU160: ModelDescriptor(
            id: .parakeetEOU160, kind: .streamingEOU, hfRepo: "FluidInference/parakeet-realtime-eou-120m-coreml", hfSubdirectory: "160ms",
            requiredPaths: ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"],
            // FX3: the real size of the 160 ms variant — 16 files, 224,047,838 bytes in a verified
            // 1.11.1 install's manifest (it was quoted as 400 MB).
            approxBytes: 224_047_838, displayName: "Parakeet Realtime EOU 120M (160 ms)", license: "other"),
        // V5 C5 — same file set in the repo's `320ms/` folder (`Repo.parakeetEou320`); loaded file by
        // file like the 160 ms one, at `StreamingChunkSize.ms320`. Size approximate until a verified
        // install records its manifest.
        .parakeetEOU320: ModelDescriptor(
            id: .parakeetEOU320, kind: .streamingEOU, hfRepo: "FluidInference/parakeet-realtime-eou-120m-coreml", hfSubdirectory: "320ms",
            requiredPaths: ["streaming_encoder.mlmodelc", "decoder.mlmodelc", "joint_decision.mlmodelc", "vocab.json"],
            approxBytes: 230_000_000, displayName: "Parakeet Realtime EOU 120M (320 ms)", license: "other",
            role: .onDemand),
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
        // V5 B1 — CTC keyword spotter for vocabulary boosting. `folderName` = upstream's
        // `Repo.parakeetCtc110m.folderName` (which keeps `-coreml`), like every `ModelHub` repo here.
        // Loaded by `CTCBoostingRuntime.load(from:)` (`CtcModels.loadDirect` + `CtcTokenizer`), never
        // `ModelManager.load`: `kind: .streamingEOU` is borrowed only for its fetcher
        // (`FluidAudioFetcher`), exactly as for the speaker model. Bytes: the two `.mlmodelc` trees the
        // hub fetches (101,843,432 + 582,831) plus the root JSON (tokenizer/vocab/config, 377,606);
        // the repo's `CtcHead` and conversion files are not fetched.
        .parakeetCTC110m: ModelDescriptor(
            id: .parakeetCTC110m, kind: .streamingEOU,
            folderName: "parakeet-ctc-110m-coreml",
            hfRepo: "FluidInference/parakeet-ctc-110m-coreml",
            requiredPaths: ["AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "vocab.json", "tokenizer.json"],
            approxBytes: 102_803_869, displayName: "Parakeet CTC 110M (vocabulary boosting)", license: "CC-BY-4.0",
            role: .onDemand),
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
        // V5 C6 — Silero VAD. `folderName` = `Repo.vad.folderName` ("silero-vad"), the folder
        // FluidAudio's `ModelHub` produces for this repo, so `FluidAudioFetcher` stages and publishes
        // it like the diarizer. The required file is the one the pinned FluidAudio asks for
        // (`ModelNames.VAD.sileroVadFile`, v6.2.1 since J6; a test pins the two together). The
        // byte count is the real sum of its five files. Loader: `SileroVAD.loadIfAvailable`, never
        // `ModelManager.load` (the borrowed `.streamingEOU` kind would fail cleanly there, as for
        // the speaker model). MIT (Silero) — the copy in `Packaging/vad/` ships in every app bundle.
        .sileroVAD: ModelDescriptor(
            id: .sileroVAD, kind: .streamingEOU,
            folderName: "silero-vad",
            hfRepo: "FluidInference/silero-vad-coreml",
            requiredPaths: ["silero-vad-unified-256ms-v6.2.1.mlmodelc"],
            approxBytes: 1_063_425, displayName: "Silero voice activity detection", license: "MIT"),
        // V5 C1b — LocalVQE (Apache-2.0). `folderName` = `Repo.localVqe.folderName`; fetched through
        // `FluidAudioFetcher` (Repo.localVqe) only when Settings › Voice selects it. Only the
        // v1.3/256 ms file is required; `ModelHub` fetches the repo's other three exports too, so
        // `approxBytes` quotes the whole download (50,290,308 bytes, HF tree 2026-10-01).
        // Loader: `LocalVQEStage.loadIfAvailable`, never `ModelManager.load`.
        .localVQE: ModelDescriptor(
            id: .localVQE, kind: .streamingEOU,
            folderName: "localvqe",
            hfRepo: "FluidInference/localvqe-coreml",
            requiredPaths: ["localvqe-v1.3-4.8M-256ms.mlmodelc"],
            approxBytes: 50_290_308, displayName: "LocalVQE noise and echo reduction", license: "Apache-2.0",
            role: .onDemand),
        // V5 B5 — drop-in final models with v3's contract (`AsrModelVersion.ultra` / `.redux`): same
        // file set as v3 (`ModelNames.ASR.requiredModelsV3()` + vocab), fetched by `FluidAudioFetcher`
        // (`Repo.parakeetUltra` / `.parakeetRedux`) into upstream's folder name ("-coreml" stripped),
        // so `AsrModels.load(from:version:)` resolves to the same directory. CC-BY-4.0; attribution in
        // `Packaging/model-notices/parakeet-ultra-redux-NOTICE.txt`. `.onDemand`: never part of the
        // stack; whichever loses the V1 comparison stays optional. Bytes: the HF repo trees
        // (2026-10-01).
        .parakeetUltra: ModelDescriptor(
            id: .parakeetUltra, kind: .finalTDT,
            folderName: "parakeet-ultra",
            hfRepo: "FluidInference/parakeet-ultra-coreml",
            requiredPaths: ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"],
            approxBytes: 632_318_254, displayName: "Parakeet Ultra", license: "CC-BY-4.0",
            role: .onDemand),
        .parakeetRedux: ModelDescriptor(
            id: .parakeetRedux, kind: .finalTDT,
            folderName: "parakeet-redux",
            hfRepo: "FluidInference/parakeet-redux-coreml",
            requiredPaths: ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "parakeet_vocab.json"],
            approxBytes: 220_462_264, displayName: "Parakeet Redux (compact)", license: "CC-BY-4.0",
            role: .onDemand),
        // V5 M7 — one Sortformer variant, not the repo: `ModelHub` (`Repo.sortformer`) would fetch every
        // variant at both precisions (`ModelNames.Sortformer.requiredModels`), so this entry borrows
        // `.whisper` for its fetcher (`ManifestFetcher`, flat files from `hfSubdirectory`) and lists the ten
        // files of `v3/fp16/SortformerNvidiaHigh_v2.1.mlmodelc` — the BNNS-fixed v3 rebuild (FluidAudio
        // issue #726). Sizes and LFS sha256 from the HF tree (main @ ae9a27a, 2026-10-01); the two
        // `model.mil` files are not LFS, so size-checked only. 255,245,283 bytes. CC-BY-4.0 (card).
        // Loader: `SortformerRuntime` through `ModelResidency`, never `ModelManager.load` (`.whisper` throws
        // `unsupported` there — a clean failure, no network).
        .sortformer: ModelDescriptor(
            id: .sortformer, kind: .whisper,
            folderName: "diar-streaming-sortformer",
            hfRepo: "FluidInference/diar-streaming-sortformer-coreml", hfSubdirectory: "v3/fp16",
            requiredPaths: [SortformerFiles.bundle,
                            SortformerFiles.bundle + "/model0/weights/0-weight.bin",
                            SortformerFiles.bundle + "/model1/weights/1-weight.bin"],
            remoteFiles: SortformerFiles.remote,
            approxBytes: SortformerFiles.remote.compactMap(\.size).reduce(0, +),
            displayName: "Sortformer live speaker labels", license: "CC-BY-4.0",
            role: .onDemand),
        // V5 M9 — CAM++ (FunASR `speech_campplus_sv_zh-cn_16k-common`, converted by FluidInference).
        // `folderName` = `Repo.campPlus.folderName` ("campplus"), fetched by `FluidAudioFetcher`
        // (`Repo.campPlus`, the whole repo: two bundles + README/config). Bytes: the HF tree
        // (main @ 321b18e, 2026-10-02) — 16,618,757. Licence: upstream FunASR model licence ("other"
        // on the card) — verify before shipping it as default. Loader: `ResidentCampPlusEmbedding`
        // through `ModelResidency`, never `ModelManager.load` (the borrowed `.streamingEOU` kind
        // fails cleanly there, no network).
        .campPlus: ModelDescriptor(
            id: .campPlus, kind: .streamingEOU,
            folderName: "campplus",
            hfRepo: "FluidInference/campplus-coreml",
            requiredPaths: ["CamPlusPreprocessor.mlmodelc", "CamPlusPlus.mlmodelc"],
            approxBytes: 16_618_757, displayName: "CAM++ speaker embedding", license: "FunASR model licence",
            role: .onDemand),
        // V5 G1 — the converted Srota. No CoreML Srota exists upstream: the recipe writes this folder
        // (`tools/qwen3-asr-hinglish/`), and `remoteFiles` stays empty until the owner publishes the
        // output (`HinglishASRFiles.publishedCoreMLRepo`) — `ManifestFetcher` then refuses cleanly
        // (`noRemoteFiles`) instead of fetching the 1.56 GB safetensors. `hfRepo` names the weights'
        // source for attribution. Borrows `.whisper` for that fetcher; loader: `Qwen3HinglishTranscriber`
        // through `ModelResidency`, never `ModelManager.load` (`.whisper` throws `unsupported` there).
        .qwen3AsrHinglish: ModelDescriptor(
            id: .qwen3AsrHinglish, kind: .whisper,
            folderName: HinglishASRFiles.folderName,
            hfRepo: HinglishASRFiles.publishedCoreMLRepo ?? HinglishASRFiles.sourceRepo,
            requiredPaths: HinglishASRFiles.requiredPaths,
            approxBytes: HinglishASRFiles.approxBytes, displayName: "Srota Hinglish speech recognition",
            license: HinglishASRFiles.license, role: .onDemand),
        // V5 G2 — one variant of the repo (9 languages × 4 chunk tiers upstream): `ManifestFetcher` takes
        // the 22 files of `multilingual/1120ms` (sizes + LFS sha256 from the HF tree, 2026-10-02). Loader:
        // `NemotronRuntime.fluid(folder:)` through `ModelResidency`, never `ModelManager.load`.
        .nemotronMultilingual: ModelDescriptor(
            id: .nemotronMultilingual, kind: .whisper,
            folderName: NemotronMultilingualFiles.folderName,
            hfRepo: NemotronMultilingualFiles.repo, hfSubdirectory: NemotronMultilingualFiles.subdirectory,
            requiredPaths: NemotronMultilingualFiles.requiredPaths,
            remoteFiles: NemotronMultilingualFiles.remote,
            approxBytes: NemotronMultilingualFiles.approxBytes, displayName: "Nemotron 3.5 multilingual speech recognition",
            license: NemotronMultilingualFiles.license, role: .onDemand),
    ]

    /// Whether `id` can load on the running OS. Parakeet Redux's 2-bit encoder uses iOS 18 / macOS 15
    /// Core ML ops (FluidAudio `AsrModels.checkPlatformSupport`); everything else runs on our macOS 14
    /// floor. Rankings skip a model that cannot load rather than fail at load time.
    public static func isSupportedOnThisOS(_ id: ModelID) -> Bool {
        guard id == .parakeetRedux else { return true }
        if #available(macOS 15, *) { return true }
        return false
    }

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
            case .onDemand: return false
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
    ///
    /// V5 C6: Silero VAD last, for the same reason — ~1 MB, and every app bundle already carries a
    /// copy (`Packaging/vad/`), so on a normal install this entry is satisfied without a fetch.
    public static let models: [ModelID] = [.parakeetTDTv3, .parakeetEOU160, .speakerEmbedding, .sileroVAD]

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

/// V5 M7 — the files of the one Sortformer variant the catalog installs (see `ModelCatalog.all[.sortformer]`).
public enum SortformerFiles {
    /// `ModelNames.Sortformer.Variant.highContextV2_1.name` + `.mlmodelc` (a test pins the two together).
    public static let bundle = "SortformerNvidiaHigh_v2.1.mlmodelc"
    public static let remote: [RemoteFile] = [
        RemoteFile(path: bundle + "/analytics/coremldata.bin", sha256: "28954e7ccf79680bee9cc6e3ced612c319c3c1c685cf321ed0f93a16971a21cc", size: 202),
        RemoteFile(path: bundle + "/coremldata.bin", sha256: "a7ff887a7abe071f1c2670b73b158fb0bfb590742c4fe9ea8f976e3558a4688c", size: 1_099),
        RemoteFile(path: bundle + "/model0/analytics/coremldata.bin", sha256: "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a", size: 108),
        RemoteFile(path: bundle + "/model0/coremldata.bin", sha256: "5a47708a470a5a440345dcc2a8c91c4defdaa4ba05c24b24c2d9f2dda643ad38", size: 634),
        RemoteFile(path: bundle + "/model0/model.mil", size: 63_578),
        RemoteFile(path: bundle + "/model0/weights/0-weight.bin", sha256: "88a98803e35186b1dfb41d7f748f7cee5093bb6efeb117f56953c17549792fa4", size: 8_948_544),
        RemoteFile(path: bundle + "/model1/analytics/coremldata.bin", sha256: "5a8281049b2a65a3be541cfd9f949e84b8fe1c5251ce90e46da1626fed54e58a", size: 108),
        RemoteFile(path: bundle + "/model1/coremldata.bin", sha256: "27f7962852ce92d8886fdfec8abb124b9357de9ceb5551811fcccd2ba1a89a12", size: 595),
        RemoteFile(path: bundle + "/model1/model.mil", size: 3_024_719),
        RemoteFile(path: bundle + "/model1/weights/1-weight.bin", sha256: "6efba8623ce70f92314d10edcdd205d4d0d3e72ca3adf8c2ef92b7c5c1a3506c", size: 243_205_696),
    ]
}
