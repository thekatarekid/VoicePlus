@preconcurrency import CoreML
import FluidAudio
import Foundation
import Shared

// V5 G2 — Nemotron 3.5 ASR Streaming Multilingual (NVIDIA, CoreML by FluidInference) as the final
// recognizer *and* the streaming preview when the user chose a language Parakeet v3 does not speak
// (LANG1). One variant only: `multilingual/1120ms` (~0.66 GB, full 13k vocab, every language incl.
// Hindi / CJK). The repo ships 9 languages × 4 chunk tiers; fetching the repo would pull all of them,
// so the catalog lists this variant's 22 files (`ManifestFetcher`, flat files from the subdirectory).
//
// Loading goes through `ModelResidency` only (§10): one shared set of MLModels, two decoding streams
// (final + preview) built from it with `loadFromShared`, so the weights are resident once.

/// Catalog facts for the one Nemotron variant VoicePlus installs.
public enum NemotronMultilingualFiles {
    public static let repo = "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML"
    public static let subdirectory = "multilingual/1120ms"
    /// Our folder under `ModelCatalog.modelsRoot()` (loaded file by file, so no upstream name to match).
    public static let folderName = "nemotron-3.5-multilingual-1120ms"
    public static let chunkMs = 1120
    public static let residencyKey = "asr.nemotron-multilingual"
    public static let license = "OpenMDW-1.1"

    /// What `StreamingNemotronMultilingualAsrManager.loadModels(from:)` needs (decoder + joint is one
    /// valid decode path; metadata carries the prompt dictionary).
    public static let requiredPaths = ["encoder.mlmodelc", "decoder.mlmodelc", "joint.mlmodelc", "metadata.json", "tokenizer.json"]

    /// HF tree of `multilingual/1120ms` (main, 2026-10-02): sizes + LFS sha256; `model.mil` / JSON are
    /// not LFS, so size-checked only. 664,144,423 bytes.
    public static let remote: [RemoteFile] = [
        RemoteFile(path: "decoder.mlmodelc/analytics/coremldata.bin", sha256: "fdb14a08e42b4806a2d1505501586be71e4f04ca9256c719544fd7ed6937e509", size: 243),
        RemoteFile(path: "decoder.mlmodelc/coremldata.bin", sha256: "6d13f9f434a2485bf9bac16e353f0c2ea850ec5a98e44effc33bfe17da8559d5", size: 433),
        RemoteFile(path: "decoder.mlmodelc/model.mil", size: 11_743),
        RemoteFile(path: "decoder.mlmodelc/weights/weight.bin", sha256: "dcdeccd4ccf46e2675224f9f030d46c1a89e2bda4abb316e901e1a21f1597f8f", size: 29_870_592),
        RemoteFile(path: "decoder_joint.mlmodelc/analytics/coremldata.bin", sha256: "8a8e98a54ed1f16c3d5125816a002b991e167d620beb8fcc557f26d9a1c092f8", size: 243),
        RemoteFile(path: "decoder_joint.mlmodelc/coremldata.bin", sha256: "0cf3b4fe7bc448f822058c9de3e9fdc72f6277fb72f77836535c829ae3058d0a", size: 454),
        RemoteFile(path: "decoder_joint.mlmodelc/model.mil", size: 15_801),
        RemoteFile(path: "decoder_joint.mlmodelc/weights/weight.bin", sha256: "01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b", size: 48_782_272),
        RemoteFile(path: "encoder.mlmodelc/analytics/coremldata.bin", sha256: "5488ed81fa1e370dd5411218d9b0e0562d01ca33c45b9ea1935bab6c8e8dc943", size: 243),
        RemoteFile(path: "encoder.mlmodelc/coremldata.bin", sha256: "93d7f1b6412b965b379f3359e38f9c4330099b5b41f9d30b85bf7286b098a78d", size: 572),
        RemoteFile(path: "encoder.mlmodelc/model.mil", size: 998_158),
        RemoteFile(path: "encoder.mlmodelc/weights/weight.bin", sha256: "e3dbd37659c7ef51d2dc691afac42fbdd1f04998fa62816ff0f2eebec5cc3d01", size: 564_646_848),
        RemoteFile(path: "joint.mlmodelc/analytics/coremldata.bin", sha256: "a1a90a7d5f8b86f564a42ab45b42a43eb0bbce6682176916bd94591b28cca447", size: 243),
        RemoteFile(path: "joint.mlmodelc/coremldata.bin", sha256: "15415f76583ac18c78be1a4192aad2023432acd9095baf4862b86e5122cf0958", size: 341),
        RemoteFile(path: "joint.mlmodelc/model.mil", size: 5_072),
        RemoteFile(path: "joint.mlmodelc/weights/weight.bin", sha256: "c0ef0a3a6598f962d2aad598dc6850e4428874033419817121e11f1fff4a9cfe", size: 18_911_744),
        RemoteFile(path: "metadata.json", size: 3_005),
        RemoteFile(path: "preprocessor.mlmodelc/analytics/coremldata.bin", sha256: "265c27d899f10ef55d65912885b59e3420ba752d15009a925a1167db666792da", size: 243),
        RemoteFile(path: "preprocessor.mlmodelc/coremldata.bin", sha256: "3d1aa8c8e7e283e4944af4b0b701db760ed99ef14919d3f989c599b9f63335a2", size: 371),
        RemoteFile(path: "preprocessor.mlmodelc/model.mil", size: 18_449),
        RemoteFile(path: "preprocessor.mlmodelc/weights/weight.bin", sha256: "297514e2b211d14b0e53cb97193d679bb89ead98d28e578f3f1d049ddbcc36b3", size: 592_384),
        RemoteFile(path: "tokenizer.json", size: 284_969),
    ]

    public static var approxBytes: Int64 { remote.compactMap(\.size).reduce(0, +) }

    /// Whether a folder holds a loadable variant (also used for the converted Nemotron-Hinglish, G1).
    public static func isInstalled(at folder: URL, fileManager: FileManager = .default) -> Bool {
        requiredPaths.allSatisfy { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// LANG1 base code → a key the model's `prompt_dictionary` knows. Bare codes the dictionary
    /// lacks get their region spelled out; nil (several languages / unknown) = "auto".
    public static func promptLanguage(for code: String?) -> String? {
        guard let c = code?.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init),
              !c.isEmpty else { return nil }
        let regional: [String: String] = [
            "ja": "ja-JP", "zh": "zh-CN", "th": "th-TH", "vi": "vi-VN", "id": "id-ID", "ms": "ms-MY",
            "bn": "bn-IN", "ur": "ur-PK", "fa": "fa-IR", "ta": "ta-IN", "te": "te-IN", "mr": "mr-IN",
            "gu": "gu-IN", "kn": "kn-IN", "ml": "ml-IN", "he": "he-IL", "si": "si-LK", "ne": "ne-NP",
            "sw": "sw-KE", "af": "af-ZA", "az": "az-AZ", "ka": "ka-GE", "hy": "hy-AM", "uz": "uz-UZ",
        ]
        return regional[c] ?? c
    }
}

// MARK: - Session seam (FluidAudio in the app, scripted in tests)

/// One SentencePiece piece with its time and confidence (lang tags already stripped).
public struct NemotronToken: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float
    public init(text: String, start: Double, end: Double, confidence: Float) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

/// One decoding stream over the (shared) Nemotron weights.
public protocol NemotronStreamingSession: AnyObject, Sendable {
    /// Fresh stream state, language prompt set (nil = automatic).
    func begin(language: String?) async
    /// 16 kHz mono samples.
    func feed(_ samples: [Float]) async throws
    func partialText() async -> String
    /// Flushes the tail and returns the stream's pieces.
    func finish() async throws -> [NemotronToken]
}

/// `StreamingNemotronMultilingualAsrManager` behind the seam.
public final class FluidNemotronSession: NemotronStreamingSession, @unchecked Sendable {
    let manager: StreamingNemotronMultilingualAsrManager
    public init(manager: StreamingNemotronMultilingualAsrManager) { self.manager = manager }

    public func begin(language: String?) async {
        await manager.reset()
        await manager.setLanguage(language ?? "auto")
    }

    public func feed(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        _ = try await manager.process(samples: samples)
    }

    public func partialText() async -> String { await manager.getPartialTranscript() }

    public func finish() async throws -> [NemotronToken] {
        let (_, timings) = try await manager.finishWithTokenTimings()
        return timings.map { NemotronToken(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence) }
    }
}

// MARK: - Residency-managed runtime

/// The two streams (final, preview) over one resident copy of the weights. Registered with
/// `ModelResidency` as `.always` while it is the dictation recognizer (dictation ASR stays resident,
/// like Parakeet); every use is inside `withModel`, so an eviction can never pull it mid-utterance.
public final class NemotronRuntime: @unchecked Sendable {
    public typealias Streams = (final: NemotronStreamingSession, preview: NemotronStreamingSession)
    public typealias Loader = @Sendable () async throws -> Streams

    public let key: String
    private let residency: ModelResidency
    private let estimatedBytes: Int64
    private let tier: ResidencyTier
    private let loader: Loader
    private let lock = NSLock()
    private var streams: Streams?
    private var registered = false

    public init(key: String = NemotronMultilingualFiles.residencyKey, estimatedBytes: Int64 = NemotronMultilingualFiles.approxBytes * 2,
                tier: ResidencyTier = .always, residency: ModelResidency = .shared, loader: @escaping Loader) {
        self.key = key; self.estimatedBytes = estimatedBytes; self.tier = tier
        self.residency = residency; self.loader = loader
    }

    /// FluidAudio over an installed variant folder.
    public static func fluid(folder: URL, key: String = NemotronMultilingualFiles.residencyKey,
                             residency: ModelResidency = .shared) -> NemotronRuntime {
        NemotronRuntime(key: key, residency: residency) {
            let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: folder)
            let final = StreamingNemotronMultilingualAsrManager()
            let preview = StreamingNemotronMultilingualAsrManager()
            try await final.loadFromShared(shared)
            try await preview.loadFromShared(shared)
            return (FluidNemotronSession(manager: final), FluidNemotronSession(manager: preview))
        }
    }

    private func registerIfNeeded() async {
        guard lock.withLock({ () -> Bool in defer { registered = true }; return !registered }) else { return }
        await residency.register(key, tier: tier, estimatedBytes: estimatedBytes, owner: "asr.nemotron",
                                 load: { [weak self] in
                                     guard let self else { return }
                                     let s = try await self.loader()
                                     self.lock.withLock { self.streams = s }
                                 },
                                 unload: { [weak self] in self?.lock.withLock { self?.streams = nil } })
    }

    public func withFinal<T>(_ body: (NemotronStreamingSession) async throws -> T) async throws -> T {
        try await with { try await body($0.final) }
    }

    public func withPreview<T>(_ body: (NemotronStreamingSession) async throws -> T) async throws -> T {
        try await with { try await body($0.preview) }
    }

    private func with<T>(_ body: (Streams) async throws -> T) async throws -> T {
        await registerIfNeeded()
        return try await residency.withModel(key) {
            guard let s = lock.withLock({ streams }) else { throw NemotronError.notLoaded }
            return try await body(s)
        }
    }

    public var isResident: Bool { lock.withLock { streams != nil } }
}

public enum NemotronError: Error, Equatable { case notLoaded }

// MARK: - Recognizers

/// G2 — the final pass. Spans: one per word (SentencePiece `▁` starts a word), confidence the
/// geometric mean of the word's piece confidences, `audioRange` from the piece timings, provenance
/// `[.asr, asr.nemotron]`.
public final class NemotronRecognizer: FinalRecognizer, @unchecked Sendable {
    public static let stage: StageID = "asr.nemotron"
    public let name: String
    public let runtime: NemotronRuntime
    /// Prompt language (`NemotronMultilingualFiles.promptLanguage`); nil = automatic.
    public let language: String?
    private let stage: StageID

    public init(runtime: NemotronRuntime, language: String?, name: String = "nemotron-3.5-multilingual",
                stage: StageID = NemotronRecognizer.stage) {
        self.runtime = runtime; self.language = language; self.name = name; self.stage = stage
    }

    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        let tokens = try await runtime.withFinal { s -> [NemotronToken] in
            await s.begin(language: language)
            try await s.feed(samples)
            return try await s.finish()
        }
        return Self.spans(from: tokens, stage: stage)
    }

    public static let wordMarker: Character = "\u{2581}"

    public static func spans(from tokens: [NemotronToken], stage: StageID = NemotronRecognizer.stage) -> [TranscriptSpan] {
        var words: [[NemotronToken]] = []
        for tok in tokens {
            guard !tok.text.isEmpty, tok.text != "<blank>", tok.text != "<unk>" else { continue }
            if tok.text.first == wordMarker || words.isEmpty { words.append([tok]) } else { words[words.count - 1].append(tok) }
        }
        return words.compactMap { pieces in
            let text = pieces.map(\.text).joined().replacingOccurrences(of: String(wordMarker), with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let first = pieces.first, let last = pieces.last else { return nil }
            let logMean = pieces.map { log(max(1e-6, Double($0.confidence))) }.reduce(0, +) / Double(pieces.count)
            return TranscriptSpan(text: text, confidence: Float(exp(logMean)),
                                  audioRange: first.start...max(first.start, last.end), provenance: [.asr, stage])
        }
    }
}

/// G2 — streaming preview on the second stream. `reset()` arms a fresh stream for the next feed.
public final class NemotronPreviewRecognizer: PreviewRecognizer, @unchecked Sendable {
    public let runtime: NemotronRuntime
    public let language: String?
    private let lock = NSLock()
    private var started = false

    public init(runtime: NemotronRuntime, language: String?) { self.runtime = runtime; self.language = language }

    public func feed(_ samples: [Float]) async throws -> String {
        let begin = lock.withLock { () -> Bool in defer { started = true }; return !started }
        return try await runtime.withPreview { s in
            if begin { await s.begin(language: language) }
            try await s.feed(samples)
            return await s.partialText()
        }
    }

    public func reset() async { lock.withLock { started = false } }
}
