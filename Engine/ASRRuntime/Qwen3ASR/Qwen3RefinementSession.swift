// VoicePlus original (task R5.1). The real `RefinementSession`: the ported Qwen3-ASR CoreML
// pipeline behind the deadline/cancellation contract the pipeline needs.
//
// Everything Qwen touches is macOS 15+ (the stateful CoreML decoder) and arm64 (Float16 embedding
// lookup). macOS 15 is the package floor (V5 J7), so
// `RefinementAvailability` only checks the architecture: an Intel Mac gets a clear "unavailable".
@preconcurrency import CoreML
import Foundation
import OSLog
import Shared

// MARK: - Availability

public enum RefinementAvailability: Sendable {
    /// Why refinement cannot run here, or nil if it can.
    public static var unavailableReason: String? {
        #if !arch(arm64)
        return "it needs an Apple Silicon Mac"
        #else
        return nil  // macOS 15 is the deployment floor (V5 J7).
        #endif
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    /// Build the real session, or throw `RefinementError.unavailableOnThisSystem`.
    ///
    /// This is what app code calls: it keeps the hardware check (Apple Silicon) in one place.
    public static func makeQwen3Session(
        store: Qwen3WeightsStore = Qwen3WeightsStore(),
        language: Qwen3AsrLanguageHint = .automatic,
        downloadIfMissing: Bool = false
    ) throws -> any RefinementSession {
        if let reason = unavailableReason { throw RefinementError.unavailableOnThisSystem(reason) }
        return Qwen3RefinementSession(store: store, language: language, downloadIfMissing: downloadIfMissing)
    }
}

/// A language hint that app code can name without importing `Qwen3AsrConfig.Language`.
public enum Qwen3AsrLanguageHint: Sendable, Equatable {
    case automatic
    /// ISO code ("en") or English name ("English"); unknown values fall back to automatic.
    case named(String)

    public static let english = Qwen3AsrLanguageHint.named("en")

    var resolved: Qwen3AsrConfig.Language? {
        switch self {
        case .automatic: return nil
        case .named(let value): return Qwen3AsrConfig.Language(from: value)
        }
    }
}

// MARK: - Session

public final class Qwen3RefinementSession: RefinementSession {
    private let backend: Backend

    public init(
        store: Qwen3WeightsStore = Qwen3WeightsStore(),
        language: Qwen3AsrLanguageHint = .automatic,
        computeUnits: MLComputeUnits = .all,
        downloadIfMissing: Bool = false
    ) {
        self.backend = Backend(
            store: store,
            language: language.resolved,
            computeUnits: computeUnits,
            downloadIfMissing: downloadIfMissing
        )
    }

    /// Resolve the weights and load the models. Optional: `refine` does it on first use, but
    /// paying ~10 s of CoreML compile inside a 300 ms deadline is not a plan, so the app should
    /// call this when refinement is enabled.
    ///
    /// V5 Q15: loading (re-specialising) a model while a timed-out prediction from an earlier
    /// session is still running is what crashed CoreML, so this waits for in-flight refinement
    /// work first. A released session's models stay alive until its in-flight body finishes,
    /// because that body holds the backend.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        await RefinementInFlight.shared.drain()
        let backend = self.backend
        try await Qwen3CoreMLGate.shared.run { try await backend.prepare(progress: progress) }
    }

    /// Where the weights are, if they are anywhere. No network, no load.
    public var weightsLocation: URL? { backend.weightsLocation }

    public func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        guard !samples.isEmpty else { throw RefinementError.emptyAudio }
        let count = samples.count
        let backend = self.backend
        let text = try await Refinement.withDeadline(deadline) {
            try await Qwen3CoreMLGate.shared.run {
                try await backend.transcribe(samples: samples, context: context)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [Refinement.span(text: trimmed, sampleCount: count)]
    }
}

// MARK: - Backend

/// Serializes load and inference. Separate from `Qwen3RefinementSession` on purpose: the deadline
/// race in `refine` has to live *outside* the actor, or the timeout task would queue behind the
/// inference it is supposed to interrupt.
private actor Backend {
    private let store: Qwen3WeightsStore
    private let language: Qwen3AsrConfig.Language?
    private let computeUnits: MLComputeUnits
    private let downloadIfMissing: Bool
    private let manager = Qwen3AsrManager()
    private let logger = Logger(subsystem: "in.adityakatare.voiceplus", category: "Qwen3Refinement")

    private var tokenizer: Qwen3ContextTokenizer?
    private var loadedFrom: URL?

    init(store: Qwen3WeightsStore, language: Qwen3AsrConfig.Language?, computeUnits: MLComputeUnits, downloadIfMissing: Bool) {
        self.store = store
        self.language = language
        self.computeUnits = computeUnits
        self.downloadIfMissing = downloadIfMissing
    }

    nonisolated var weightsLocation: URL? { store.locate() }

    func prepare(progress: (@Sendable (Double) -> Void)?) async throws {
        guard loadedFrom == nil else { return }
        let folder = try await store.resolve(downloadIfMissing: downloadIfMissing, progress: progress)
        let incomplete = store.problems(at: folder)
        guard incomplete.isEmpty else {
            throw RefinementError.weightsIncomplete(path: folder.path, problems: incomplete)
        }
        // V5 K21 — byte counts against the publisher's manifest before any load, so the Settings
        // row's "Ready" / "Not verified" means exactly what the backend accepted.
        let unverified = store.verify(at: folder)
        guard unverified.isEmpty else {
            throw RefinementError.weightsIncomplete(path: folder.path,
                                                    problems: unverified.map { "\($0) does not match the published size" })
        }
        do {
            tokenizer = try Qwen3ContextTokenizer(
                vocabularyFile: folder.appendingPathComponent("vocab.json")
            )
            try await manager.loadModels(from: folder, computeUnits: computeUnits)
        } catch let error as RefinementError {
            throw error
        } catch {
            throw RefinementError.backendFailure(Self.describe(error))
        }
        loadedFrom = folder
        logger.info("Qwen3 refinement ready from \(folder.path, privacy: .public)")
    }

    func transcribe(samples: [Float], context: String) async throws -> String {
        try await prepare(progress: nil)
        try Task.checkCancellation()
        // Two things go to the model, and the split matters — it was measured, not guessed
        // (`Qwen3PromptProbe`, 2026-09-11, qwen3-asr-0.6b int8, first real-room utterance):
        //
        //  * The **system message** carries the biasing context and nothing else. A task
        //    instruction there changes nothing: "Transcribe the audio to English text." in the
        //    system message, the port's hard-coded task table, and an empty system message all
        //    produced byte-identical Devanagari for clean English speech.
        //  * The **assistant turn** is where the output language is decided. Left to itself the
        //    model writes its own header first — `language ĠHindi <|asr_text|>` on that utterance,
        //    hence Devanagari, WER 1.000 — and then transcribes in the language it just named.
        //    Writing that header ourselves (forced decoder ids) is the only lever: with
        //    `language English<|asr_text|>` prefilled, the same audio came back as "The quick
        //    brown fox jumps over the lazy dog.", WER 0.000.
        //
        // So `language:` is passed to the port as nil — its task table is inert either way — and
        // the language arrives as `assistantPrefixTokens`.
        let contextTokens = tokenizer?.encode(
            context, limit: Qwen3RefinementBudget.contextTokenBudget(sampleCount: samples.count)
        ) ?? []
        let prefix = Qwen3RefinementPrompt.assistantHeaderTokens(
            language: language, tokenizer: tokenizer
        )
        do {
            return try await manager.transcribe(
                audioSamples: samples,
                language: nil as Qwen3AsrConfig.Language?,
                contextTokens: contextTokens,
                assistantPrefixTokens: prefix,
                maxNewTokens: Qwen3RefinementBudget.maxNewTokens
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RefinementError.backendFailure(Self.describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}

// MARK: - Prompt budget

/// How the fixed KV cache is divided between audio, prompt scaffolding, context and output.
///
/// The stateful decoder's cache is `Qwen3AsrConfig.maxCacheSeqLen` long and audio tokens are not
/// negotiable, so the context prompt is what gets cut when a segment is long.
enum Qwen3RefinementBudget {
    static let maxNewTokens = 256
    /// Chat-template scaffolding plus the forced assistant header, in tokens.
    static let promptOverheadTokens = 24
    /// Output tokens kept free no matter how much context is offered.
    static let reservedOutputTokens = 64

    /// Audio tokens `sampleCount` will occupy: mel frames = samples / 160, the encoder consumes
    /// them in `melWindowSize` windows and emits `outputFramesPerWindow` per whole window.
    static func audioTokenCount(sampleCount: Int) -> Int {
        let melFrames = sampleCount / 160
        guard melFrames > 0 else { return 0 }
        let window = Qwen3AsrConfig.melWindowSize
        let whole = melFrames / window
        let remainder = melFrames % window
        let tail = remainder == 0
            ? 0
            : (remainder + Qwen3AsrConfig.convDownsampleFactor - 1) / Qwen3AsrConfig.convDownsampleFactor
        return whole * Qwen3AsrConfig.outputFramesPerWindow + tail
    }

    /// Context tokens that still leave room to answer.
    static func contextTokenBudget(sampleCount: Int) -> Int {
        let used = audioTokenCount(sampleCount: sampleCount) + promptOverheadTokens + reservedOutputTokens
        return max(0, Qwen3AsrConfig.maxCacheSeqLen - used)
    }
}

// MARK: - Prompt text

/// The two prompt pieces Qwen3-ASR actually reads. Its own type so both can be tested without
/// weights: getting the assistant header wrong is invisible until a transcription comes back in
/// the wrong script, which is exactly how this was found.
enum Qwen3RefinementPrompt {
    /// The header the model writes for itself at the start of the assistant turn, as plain text:
    /// the literal word `language`, then the language's English name. Prefilling it is what forces
    /// the output language; `nil` means "let the model detect the language", which is the port's
    /// own behaviour.
    static func assistantHeader(language: Qwen3AsrConfig.Language?) -> String? {
        guard let language else { return nil }
        return "language \(language.englishName)"
    }

    /// `assistantHeader` encoded, terminated by `<|asr_text|>` — the special token the model emits
    /// between its header and the transcription. Forcing the terminator too leaves the model
    /// nothing to decide before the first word of text.
    static func assistantHeaderTokens(
        language: Qwen3AsrConfig.Language?, tokenizer: Qwen3ContextTokenizer?
    ) -> [Int32] {
        guard let tokenizer, let header = assistantHeader(language: language) else { return [] }
        let tokens = tokenizer.encode(header, limit: headerTokenBudget)
        guard !tokens.isEmpty else { return [] }
        return tokens + [Int32(Qwen3AsrConfig.asrTextTokenId)]
    }

    /// Room for `language ` plus the longest language name in the vocabulary.
    static let headerTokenBudget = 6
}
