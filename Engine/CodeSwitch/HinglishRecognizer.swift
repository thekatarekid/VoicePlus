@preconcurrency import CoreML
import Foundation
import Shared

// V5 G1 — Hinglish ASR from a third party, replacing Parakeet as the final pass when Hindi is one of
// the user's languages (LANG1). Two candidates, one shipped:
//
// * **Srota** — `moorlee/qwen3-asr-0.6b-hinglish` (Apache-2.0), a fine-tune of Qwen3-ASR-0.6B. Same
//   architecture, tokenizer (identical `vocab.json`, 2,776,833 bytes) and CoreML contract as the base
//   model our Qwen3 port already runs, so it converts with the existing Qwen3-ASR recipe
//   (`tools/qwen3-asr-hinglish/`) and loads with `Qwen3AsrManager` unchanged. Publisher-reported WER:
//   HiACC 15.8 % (base 24.7 %), MUCS-2021 35.1 % (base 50.7 %).
// * **Nemotron-Hinglish** — `smajji/nemotron-hinglish-v1` (Apache-2.0), a fine-tune of the G2 model,
//   converted with the G2 recipe (`tools/nemotron-hinglish/`) and run through G2's runtime.
//
// The V1 harness (`lab eval --model hinglish-srota|hinglish-nemotron --set mucs2021|hiacc`) picks
// the winner; `HinglishASRCandidate.shipped` records it. Output script is left to G3
// (`ScriptOutputStage`): Srota writes Hindi in Devanagari and English in Latin.

public enum HinglishASRCandidate: String, CaseIterable, Sendable {
    case srota = "qwen3-asr-0.6b-hinglish"
    case nemotronHinglish = "nemotron-hinglish-v1"

    /// The candidate the app uses. Srota until a V1 run on MUCS-2021 + HiACC says otherwise
    /// (`Lab/results/*-mucs2021-*.json`, `*-hiacc-*.json`).
    public static let shipped: HinglishASRCandidate = .srota

    /// Eval-backend id (`lab eval --model …`).
    public var evalModelID: String { self == .srota ? "hinglish-srota" : "hinglish-nemotron" }
    public var sourceRepo: String { self == .srota ? HinglishASRFiles.sourceRepo : "smajji/nemotron-hinglish-v1" }
    /// Folder under `ModelCatalog.modelsRoot()` the conversion recipe writes.
    public var folderName: String { self == .srota ? HinglishASRFiles.folderName : "nemotron-hinglish-v1-1120ms" }
}

/// Catalog facts for the converted Srota (`ModelID.qwen3AsrHinglish`).
public enum HinglishASRFiles {
    public static let sourceRepo = "moorlee/qwen3-asr-0.6b-hinglish"
    public static let folderName = "qwen3-asr-0.6b-hinglish"
    public static let license = "Apache-2.0"
    public static let residencyKey = "asr.qwen3-asr-hinglish"
    /// Same file set as the base int8 export (`Qwen3WeightsLayout`).
    public static var requiredPaths: [String] { Qwen3WeightsLayout.requiredPaths }
    /// The base int8 export's bytes: same architecture, same quantisation (~1.29 GB). The V5 table's
    /// ~1.9 GB is the fp16 export; the recipe produces int8 like the base we already ship.
    public static var approxBytes: Int64 { Qwen3WeightsLayout.approxBytes }
    /// Where the converted CoreML is published for download. Nil until the owner uploads the recipe's
    /// output (no CoreML Srota exists upstream); until then it is installed by the recipe only and the
    /// catalog entry has no remote files (`ModelCatalog` can never fetch something that is not there).
    public static let publishedCoreMLRepo: String? = nil

    public static func isInstalled(at folder: URL, fileManager: FileManager = .default) -> Bool {
        requiredPaths.allSatisfy { fileManager.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }
}

/// Audio → text, the part of a Hinglish model the recognizer needs (Qwen3 in the app, scripted in tests).
public protocol SpeechTranscribing: AnyObject, Sendable {
    /// Longest window one call accepts, seconds.
    var maxWindowSeconds: Double { get }
    func transcribe(_ samples: [Float]) async throws -> String
}

/// Srota through the Qwen3-ASR port, loaded only through `ModelResidency` (§10).
public final class Qwen3HinglishTranscriber: SpeechTranscribing, @unchecked Sendable {
    public let folder: URL
    public let key: String
    /// Qwen3-ASR language prompt; nil = the model's own detection (Srota is trained on code-switched
    /// speech, so naming one language would bias it).
    public let language: String?
    public var maxWindowSeconds: Double { Qwen3AsrConfig.maxAudioSeconds }
    private let residency: ModelResidency
    private let tier: ResidencyTier
    private let lock = NSLock()
    private var manager: Qwen3AsrManager?
    private var registered = false

    public init(folder: URL, language: String? = nil, key: String = HinglishASRFiles.residencyKey,
                tier: ResidencyTier = .always, residency: ModelResidency = .shared) {
        self.folder = folder; self.language = language; self.key = key; self.tier = tier; self.residency = residency
    }

    private func registerIfNeeded() async {
        guard lock.withLock({ () -> Bool in defer { registered = true }; return !registered }) else { return }
        let folder = self.folder
        // Resident footprint ≈ 2× the int8 files (compiled models + embedding table + KV state).
        await residency.register(key, tier: tier, estimatedBytes: HinglishASRFiles.approxBytes * 2, owner: "asr.hinglish",
                                 load: { [weak self] in
                                     let m = Qwen3AsrManager()
                                     try await m.loadModels(from: folder, computeUnits: .cpuAndNeuralEngine)
                                     self?.lock.withLock { self?.manager = m }
                                 },
                                 unload: { [weak self] in self?.lock.withLock { self?.manager = nil } })
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        await registerIfNeeded()
        return try await residency.withModel(key) {
            guard let m = lock.withLock({ manager }) else { throw Qwen3AsrError.modelNotFound(folder.path) }
            return try await m.transcribe(audioSamples: samples, language: language)
        }
    }
}

/// G1 — the Hinglish final pass. Conforms to `IndicASRBackend`, so it also fills P6.3's
/// `CodeSwitchRouter` slot (X7: that slot had only the unavailable and mock backends).
///
/// Qwen3-ASR is a text decoder: it gives no per-word times or scores. Spans therefore carry an
/// `audioRange` spread over their window by character share and a fixed `unscoredConfidence`
/// (above the repair threshold, so nothing is flagged on a guess), provenance `[.asr, asr.hinglish]`.
/// Utterances longer than the model's window are cut into back-to-back windows.
public final class HinglishRecognizer: IndicASRBackend, @unchecked Sendable {
    public static let stage: StageID = "asr.hinglish"
    public static let unscoredConfidence: Float = 0.85
    public let name: String
    public let languages = ["hi", "en"]
    public let isAvailable: Bool
    private let transcriber: SpeechTranscribing
    private let sampleRate = 16_000.0

    public init(transcriber: SpeechTranscribing, name: String = HinglishASRCandidate.srota.rawValue, isAvailable: Bool = true) {
        self.transcriber = transcriber; self.name = name; self.isAvailable = isAvailable
    }

    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        let window = max(1, Int(transcriber.maxWindowSeconds * sampleRate) - Int(sampleRate / 2))
        var spans: [TranscriptSpan] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            // A tail under 0.3 s is not worth a decode (and Qwen3 cannot extract mel from it).
            if end - start >= Int(0.3 * sampleRate) || start == 0 {
                let text = try await transcriber.transcribe(Array(samples[start..<end]))
                spans += Self.spans(text: text, from: Double(start) / sampleRate, to: Double(end) / sampleRate)
            }
            start = end
        }
        return spans
    }

    /// One span per whitespace word, time split by character share.
    public static func spans(text: String, from t0: Double, to t1: Double, stage: StageID = HinglishRecognizer.stage) -> [TranscriptSpan] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let total = Double(max(1, words.reduce(0) { $0 + $1.count }))
        var cursor = t0
        return words.map { w in
            let dur = (t1 - t0) * Double(w.count) / total
            defer { cursor += dur }
            return TranscriptSpan(text: w, confidence: unscoredConfidence, audioRange: cursor...(cursor + dur),
                                  provenance: [.asr, stage])
        }
    }
}

/// G1 — Nemotron-Hinglish through G2's runtime, as an `IndicASRBackend`.
public final class NemotronHinglishBackend: IndicASRBackend, @unchecked Sendable {
    public let name = HinglishASRCandidate.nemotronHinglish.rawValue
    public let languages = ["hi", "en"]
    public let isAvailable: Bool
    private let recognizer: NemotronRecognizer

    public init(runtime: NemotronRuntime, isAvailable: Bool = true) {
        self.isAvailable = isAvailable
        self.recognizer = NemotronRecognizer(runtime: runtime, language: "hi", name: HinglishASRCandidate.nemotronHinglish.rawValue,
                                             stage: HinglishRecognizer.stage)
    }

    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] { try await recognizer.recognize(samples) }
}

public enum HinglishASRFactory {
    /// The shipped candidate over its installed folder under `root`, or nil when not installed.
    public static func make(candidate: HinglishASRCandidate = .shipped, root: URL,
                            residency: ModelResidency = .shared) -> IndicASRBackend? {
        let folder = root.appendingPathComponent(candidate.folderName, isDirectory: true)
        switch candidate {
        case .srota:
            guard HinglishASRFiles.isInstalled(at: folder) else { return nil }
            return HinglishRecognizer(transcriber: Qwen3HinglishTranscriber(folder: folder, residency: residency))
        case .nemotronHinglish:
            guard NemotronMultilingualFiles.isInstalled(at: folder) else { return nil }
            return NemotronHinglishBackend(runtime: .fluid(folder: folder, key: "asr.nemotron-hinglish", residency: residency))
        }
    }
}
