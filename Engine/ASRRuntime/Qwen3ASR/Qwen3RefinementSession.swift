// VoicePlus original (task R5.1). The real `RefinementSession`: the ported Qwen3-ASR CoreML
// pipeline behind the deadline/cancellation contract the pipeline needs.
//
// Everything Qwen touches is macOS 15+ (the stateful CoreML decoder) and arm64 (Float16 embedding
// lookup). `RefinementAvailability` is the non-gated door: callers on macOS 14 get a clear
// "unavailable" instead of a compile-time problem.
@preconcurrency import CoreML
import Foundation
import OSLog
import Shared

// MARK: - Availability (not gated — must answer on macOS 14)

public enum RefinementAvailability: Sendable {
    /// Why refinement cannot run here, or nil if it can.
    public static var unavailableReason: String? {
        #if !arch(arm64)
        return "it needs an Apple Silicon Mac"
        #else
        if #available(macOS 15, *) { return nil }
        return "it needs macOS 15 or later"
        #endif
    }

    public static var isAvailable: Bool { unavailableReason == nil }

    /// Build the real session, or throw `RefinementError.unavailableOnThisSystem`.
    ///
    /// This is what app code calls: it keeps every `@available(macOS 15, *)` type behind one
    /// runtime check instead of spreading `if #available` through the pipeline.
    public static func makeQwen3Session(
        store: Qwen3WeightsStore = Qwen3WeightsStore(),
        language: Qwen3AsrLanguageHint = .automatic,
        downloadIfMissing: Bool = false
    ) throws -> any RefinementSession {
        if let reason = unavailableReason { throw RefinementError.unavailableOnThisSystem(reason) }
        guard #available(macOS 15, *) else {
            throw RefinementError.unavailableOnThisSystem("it needs macOS 15 or later")
        }
        return Qwen3RefinementSession(store: store, language: language, downloadIfMissing: downloadIfMissing)
    }
}

/// A language hint that can be named on macOS 14, where `Qwen3AsrConfig.Language` is unavailable.
public enum Qwen3AsrLanguageHint: Sendable, Equatable {
    case automatic
    /// ISO code ("en") or English name ("English"); unknown values fall back to automatic.
    case named(String)

    public static let english = Qwen3AsrLanguageHint.named("en")

    @available(macOS 15, *)
    var resolved: Qwen3AsrConfig.Language? {
        switch self {
        case .automatic: return nil
        case .named(let value): return Qwen3AsrConfig.Language(from: value)
        }
    }
}

// MARK: - Session

@available(macOS 15, *)
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
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await backend.prepare(progress: progress)
    }

    /// Where the weights are, if they are anywhere. No network, no load.
    public var weightsLocation: URL? { backend.weightsLocation }

    public func refine(samples: [Float], context: String, deadline: Duration) async throws -> [TranscriptSpan] {
        guard !samples.isEmpty else { throw RefinementError.emptyAudio }
        let count = samples.count
        let backend = self.backend
        let text = try await Refinement.withDeadline(deadline) {
            try await backend.transcribe(samples: samples, context: context)
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
@available(macOS 15, *)
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
        // The system message is built here and handed over as `contextTokens`, and the port's own
        // `language:` path is deliberately bypassed (`nil`).
        //
        // Why: the ported `Qwen3AsrManager.taskTokens` table hard-codes token ids that do not
        // match the `vocab.json` shipped with these weights. Its English row is
        // `[3246, 56541, 279, 7461, 311, 6364, 1467, 13]`, which decodes against this vocabulary
        // as "agnıs the Oper to English text." — five of the eight ids are right and three are
        // not. Measured consequence, first real-room utterance, built-in mic: the model got no
        // usable instruction, auto-detected the language of accented English speech and answered
        // in Devanagari ("… ब्राउन फॉक्स … डॉग", WER 1.000 against a correct English reference).
        // Encoding the same sentence against `vocab.json` gives
        // `[3167, 3114, 279, 7699, 311, 6364, 1467, 13]` = "Transcribe the audio to English
        // text." — so the instruction is built from the vocabulary that is actually on disk.
        let prompt = Qwen3RefinementPrompt.systemPrompt(language: language, context: context)
        let contextTokens = tokenizer?.encode(
            prompt, limit: Qwen3RefinementBudget.contextTokenBudget(sampleCount: samples.count)
        ) ?? []
        do {
            return try await manager.transcribe(
                audioSamples: samples,
                language: nil as Qwen3AsrConfig.Language?,
                contextTokens: contextTokens,
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
@available(macOS 15, *)
enum Qwen3RefinementBudget {
    static let maxNewTokens = 256
    /// Chat-template scaffolding plus the task sentence, in tokens.
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

/// The system message the refinement pass sends. Its own type so it can be tested without
/// weights: getting this wrong is invisible until a transcription comes back in the wrong script.
@available(macOS 15, *)
enum Qwen3RefinementPrompt {
    /// Qwen3-ASR's task instruction plus the caller's context, as plain text. Empty context and
    /// automatic language give an empty system message, which is what "no instruction" means.
    static func systemPrompt(language: Qwen3AsrConfig.Language?, context: String) -> String {
        var parts: [String] = []
        if let language { parts.append("Transcribe the audio to \(language.englishName) text.") }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts.joined(separator: "\n")
    }

}
