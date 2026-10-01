import FluidAudio
import Foundation

/// V5 B1 — the loaded CTC boosting model (`parakeet-ctc-110m-coreml`): keyword spotter + tokenizer,
/// plus a rescorer cached for the last vocabulary (consecutive utterances usually share one).
///
/// Why not `VocabularyBoostingSession`: upstream's session reads the CTC tokenizer from
/// FluidAudio's *own* cache directory (`CtcModels.defaultCacheDirectory`), while ours lives under
/// `~/Library/Application Support/VoicePlus/Models`. Composing the same public parts here with our
/// directory avoids a second 100 MB copy. The rescore call itself is the session's, line for line.
public actor CTCBoostingRuntime {
    public let directory: URL
    private let models: CtcModels
    private let tokenizer: CtcTokenizer
    private let spotter: CtcKeywordSpotter
    private var cached: (key: [String], vocabulary: CustomVocabularyContext, rescorer: VocabularyRescorer)?
    private let config: VocabularyRescorer.Config

    /// Rescorer thresholds. Upstream's `itnDefaultConfig` (string-similarity floors on the
    /// spotter-anchored rescue: 0.30 single-word, 0.50 multi-word): TDT v3 writes digits and
    /// punctuation, and with `.default` the acoustic-only rescue swapped an ordinary word for an
    /// unspoken list term on the entity fixtures ("stores" → "Postgres"). Raising these floors did
    /// not stop it (they gate the rescorer's own candidate span, not the words it finally swaps), so
    /// every swap is vetted again by `BoostGuard` (spelling/sound closeness, stricter for common
    /// words). Measured in `CTCBoostingLiveTests`.
    public static let defaultConfig = VocabularyBoostingSession.itnDefaultConfig

    /// Files `CtcModels.loadDirect` + `CtcTokenizer.load` read. The catalog's `requiredPaths`
    /// for `.parakeetCTC110m` must contain these.
    public static let requiredFiles = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "vocab.json", "tokenizer.json"]

    /// Load from our model folder. Callers go through `CTCBoostingModelSource`, which caches.
    public static func load(from directory: URL,
                            config: VocabularyRescorer.Config = CTCBoostingRuntime.defaultConfig) async throws -> CTCBoostingRuntime {
        let models = try await CtcModels.loadDirect(from: directory, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        return CTCBoostingRuntime(directory: directory, models: models, tokenizer: tokenizer, config: config)
    }

    private init(directory: URL, models: CtcModels, tokenizer: CtcTokenizer, config: VocabularyRescorer.Config) {
        self.config = config
        self.directory = directory
        self.models = models
        self.tokenizer = tokenizer
        self.spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
    }

    private func rescorer(for terms: [String]) async throws -> (CustomVocabularyContext, VocabularyRescorer) {
        if let c = cached, c.key == terms { return (c.vocabulary, c.rescorer) }
        let vocabTerms = terms.compactMap { text -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(text)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: text, ctcTokenIds: ids)
        }
        let vocabulary = CustomVocabularyContext(terms: vocabTerms)
        let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: vocabulary,
                                                           config: config, ctcModelDirectory: directory)
        cached = (terms, vocabulary, rescorer)
        return (vocabulary, rescorer)
    }

    /// Rescore `tokens` (TDT final pass) against CTC evidence from `samples`. Nil when nothing
    /// changed and nothing was spotted, or on any failure (boosting never breaks transcription).
    public func rescore(tokens: [DecodedToken], samples: [Float], terms: [String]) async -> BoostOutcome? {
        guard !terms.isEmpty, !tokens.isEmpty, !samples.isEmpty else { return nil }
        do {
            let (vocabulary, rescorer) = try await rescorer(for: terms)
            guard !vocabulary.terms.isEmpty else { return nil }
            let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: vocabulary, minScore: nil)
            guard !spot.logProbs.isEmpty else { return nil }
            let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            let timings = tokens.map {
                TokenTiming(token: $0.text, tokenId: $0.tokenId, startTime: $0.startTime, endTime: $0.endTime,
                            confidence: $0.probability)
            }
            let text = tokens.renderedText
            let out = rescorer.ctcTokenRescore(transcript: text, tokenTimings: timings, logProbs: spot.logProbs,
                                               frameDuration: spot.frameDuration, cbw: sizeConfig.cbw,
                                               marginSeconds: 0.5,
                                               minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity))
            let detected = Self.detectedTerms(spot.detections.map { ($0.term.text, $0.startTime) })
            let replacements = out.replacements.filter(\.shouldReplace).compactMap { r in
                r.replacementWord.map { BoostOutcome.Replacement(original: r.originalWord, replacement: $0) }
            }.filter { BoostGuard.accepts(original: $0.original, replacement: $0.replacement) }
            guard out.wasModified || !detected.isEmpty else { return nil }
            let boosted = out.wasModified
                ? BoostAlignment.apply(rescoredText: out.text, to: tokens, accept: BoostGuard.accepts(original:replacement:))
                : tokens
            let changed = boosted != tokens
            return BoostOutcome(tokens: boosted, replacements: changed ? replacements : [], detectedTerms: detected)
        } catch {
            return nil
        }
    }

    static func detectedTerms(_ hits: [(String, TimeInterval)]) -> [String] {
        var seen = Set<String>()
        return hits.sorted { $0.1 < $1.1 }.map(\.0).filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Where the CTC boosting model comes from. HW1 (`ModelResidency`) is meant to own every model load
/// (§10); until that lands this protocol is the seam — the app's implementation can register with
/// the residency without the decoder changing.
public protocol CTCBoostingModelSource: Sendable {
    /// The loaded runtime, or nil when the model is not on disk / failed to load.
    func runtime() async -> CTCBoostingRuntime?
}

/// Loads once from a folder and caches; a failed load is retried on the next call (the model may
/// still be downloading).
public actor CTCBoostingFolderSource: CTCBoostingModelSource {
    private let folder: URL
    private let isPresent: @Sendable () async -> Bool
    private var loaded: CTCBoostingRuntime?
    private var loading: Task<CTCBoostingRuntime?, Never>?

    public init(folder: URL, isPresent: @escaping @Sendable () async -> Bool) {
        self.folder = folder
        self.isPresent = isPresent
    }

    public func runtime() async -> CTCBoostingRuntime? {
        if let loaded { return loaded }
        if let loading { return await loading.value }
        guard await isPresent() else { return nil }
        let folder = self.folder
        let task = Task { try? await CTCBoostingRuntime.load(from: folder) }
        loading = task
        let r = await task.value
        loading = nil
        loaded = r
        return r
    }

    /// Drop the loaded model (memory pressure / residency eviction).
    public func unload() { loaded = nil }
}

/// The real B1 booster: one per utterance, carrying that utterance's terms; the heavy model is
/// shared through `source`.
public struct CTCVocabularyBooster: VocabularyBooster {
    public let terms: [String]
    private let source: CTCBoostingModelSource

    public init(terms: [String], source: CTCBoostingModelSource) {
        self.terms = terms
        self.source = source
    }

    public func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome? {
        guard !terms.isEmpty, let runtime = await source.runtime() else { return nil }
        return await runtime.rescore(tokens: tokens, samples: samples, terms: terms)
    }
}

/// The app's source: the model where `ModelManager` finds it (our install, or a read-only bundled
/// copy), fetched **on demand** the first time a non-empty vocabulary asks for it. That utterance
/// stays unboosted (the ~103 MB download runs in the background); the next one is boosted.
public actor ManagedCTCBoostingSource: CTCBoostingModelSource {
    public static let modelID: ModelID = .parakeetCTC110m
    private let manager: ModelManager
    private let fetchWhenMissing: Bool
    private var loaded: CTCBoostingRuntime?
    private var fetching: Task<Void, Never>?

    public init(manager: ModelManager, fetchWhenMissing: Bool = true) {
        self.manager = manager
        self.fetchWhenMissing = fetchWhenMissing
    }

    public func runtime() async -> CTCBoostingRuntime? {
        if let loaded { return loaded }
        guard let url = await manager.locate(Self.modelID) else {
            if fetchWhenMissing, fetching == nil {
                let manager = self.manager
                fetching = Task.detached(priority: .utility) {
                    _ = try? await manager.ensureAvailable(Self.modelID)
                }
            }
            return nil
        }
        loaded = try? await CTCBoostingRuntime.load(from: url)
        return loaded
    }

    public func unload() { loaded = nil }
}
