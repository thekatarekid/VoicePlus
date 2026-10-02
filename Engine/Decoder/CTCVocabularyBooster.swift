import FluidAudio
import Foundation
import Shared

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

    /// N6 — build (and cache) the rescorer for `terms` ahead of the turn, in the background, so the
    /// final pass only pays for spotting + rescoring.
    public func prepareRescorer(terms: [String]) async {
        guard !terms.isEmpty else { return }
        _ = try? await rescorer(for: terms)
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

/// N6 — what a final pass needs from the loaded booster model. `CTCBoostingRuntime` is the real one;
/// tests substitute slow or failing fakes.
public protocol CTCRescoring: Sendable {
    func rescore(tokens: [DecodedToken], samples: [Float], terms: [String]) async -> BoostOutcome?
    func prepareRescorer(terms: [String]) async
}

extension CTCBoostingRuntime: CTCRescoring {}

/// Where the CTC boosting model comes from. Every load goes through `ModelResidency` (§10).
///
/// N6 — two ways in, and only one of them may load:
/// - `prepare()` / `runtime()` load (and compile) the model. They run at launch, after a download,
///   and in the background after an eviction — **never inside a turn**.
/// - `readyRescorer()` is what the final pass calls. It never loads: when the model is not resident
///   it returns nil (that turn lands unboosted) and starts a background `prepare()`.
public protocol CTCBoostingModelSource: Sendable {
    /// Loads if needed. Not for the final pass.
    func runtime() async -> CTCBoostingRuntime?
    /// The resident model, or nil without loading anything (a background prepare is started).
    func readyRescorer() async -> (any CTCRescoring)?
    /// Start loading in the background (launch, after a download, after an eviction). Idempotent.
    func prepare() async
}

/// Loads once from a folder and caches; a failed load is retried by the next `prepare()`.
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

    public func readyRescorer() async -> (any CTCRescoring)? {
        if let loaded { return loaded }
        await prepare()
        return nil
    }

    public func prepare() async {
        guard loaded == nil, loading == nil else { return }
        Task { _ = await self.runtime() }
    }

    /// Drop the loaded model (memory pressure / residency eviction).
    public func unload() { loaded = nil }
}

/// N6 — how one final pass's boosting went. Carried into `FinalPassTiming` and `turn_records`.
public struct BoostReport: Sendable, Equatable {
    public enum Status: String, Sendable, Codable {
        /// The booster changed at least one word.
        case boosted
        /// It ran and changed nothing.
        case unchanged
        /// The model was not resident: landed unboosted, a background load was started.
        case modelNotReady
        /// The rescoring outlived the deadline: landed unboosted.
        case timedOut
        /// No booster installed, or an empty term list.
        case notApplied
    }
    public var outcome: BoostOutcome?
    public var status: Status
    /// Time spent getting the resident model (no load ever happens here, so this stays ~0).
    public var modelWaitMs: Double
    /// Time spent spotting + rescoring.
    public var rescoreMs: Double

    public init(outcome: BoostOutcome?, status: Status, modelWaitMs: Double = 0, rescoreMs: Double = 0) {
        self.outcome = outcome
        self.status = status
        self.modelWaitMs = modelWaitMs
        self.rescoreMs = rescoreMs
    }
}

/// A booster that reports its own stage timings (N6). `FluidAudioTDTDecoder` prefers this over
/// `boost(tokens:samples:)` when the installed booster offers it.
public protocol BoostReporting: VocabularyBooster {
    func boostReport(tokens: [DecodedToken], samples: [Float]) async -> BoostReport
    /// Build this booster's rescorer in the background (hotkey-down), never in the turn.
    func prepare()
}

/// The real B1 booster: one per utterance, carrying that utterance's terms; the heavy model is
/// shared through `source`. N6: it never loads the model — `source.readyRescorer()` — and the
/// decoder holds the rescoring to `FluidAudioTDTDecoder.boostDeadline`.
public struct CTCVocabularyBooster: VocabularyBooster, BoostReporting {
    public let terms: [String]
    private let source: CTCBoostingModelSource

    public init(terms: [String], source: CTCBoostingModelSource) {
        self.terms = terms
        self.source = source
    }

    public func boost(tokens: [DecodedToken], samples: [Float]) async -> BoostOutcome? {
        await boostReport(tokens: tokens, samples: samples).outcome
    }

    public func boostReport(tokens: [DecodedToken], samples: [Float]) async -> BoostReport {
        guard !terms.isEmpty else { return BoostReport(outcome: nil, status: .notApplied) }
        let t0 = DispatchTime.now()
        guard let rescorer = await source.readyRescorer() else {
            return BoostReport(outcome: nil, status: .modelNotReady, modelWaitMs: Self.ms(since: t0))
        }
        let wait = Self.ms(since: t0)
        let t1 = DispatchTime.now()
        let outcome = await rescorer.rescore(tokens: tokens, samples: samples, terms: terms)
        return BoostReport(outcome: outcome, status: (outcome?.wasModified ?? false) ? .boosted : .unchanged,
                           modelWaitMs: wait, rescoreMs: Self.ms(since: t1))
    }

    /// Hotkey-down: build the stable rescorer for these terms while the user speaks.
    public func prepare() {
        let source = self.source, terms = self.terms
        guard !terms.isEmpty else { return }
        Task.detached(priority: .utility) {
            guard let r = await source.readyRescorer() else { return }
            await r.prepareRescorer(terms: terms)
        }
    }

    static func ms(since t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
    }
}

/// "Preparing speech models" (N6): the booster's launch / post-download load, for Settings and
/// onboarding. Posted on `didChange` (object: the shared instance) from any thread.
public final class SpeechModelPreparation: @unchecked Sendable {
    public enum State: String, Sendable, Equatable {
        case idle, downloading, preparing, ready, unavailable
    }
    public static let shared = SpeechModelPreparation()
    public static let didChange = Notification.Name("VoicePlus.SpeechModelPreparation.didChange")
    private let lock = NSLock()
    private var _state: State = .idle
    public init() {}
    public var state: State { lock.withLock { _state } }
    /// What the UI shows while it is not `.ready`/`.idle` (nil = nothing to show).
    public var message: String? {
        switch state {
        case .downloading: return "Downloading the vocabulary model…"
        case .preparing: return "Preparing speech models…"
        case .unavailable: return "Vocabulary boosting is unavailable. Dictation still works."
        case .idle, .ready: return nil
        }
    }
    public func set(_ s: State) {
        let changed: Bool = lock.withLock { defer { _state = s }; return _state != s }
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}

/// The app's source: the model where `ModelManager` finds it (bundled read-only copy in a full
/// installer, or our install).
///
/// N6 (§D model residency): the model is loaded and compiled **at launch** (`prepareAtLaunch`) and
/// again right after a download, behind "Preparing speech models". It is registered `.resident`
/// under a **stable key** (`boost.parakeet-ctc-110m-coreml#app`), so it never idles out and is not
/// dropped on a memory warning — only under critical pressure, before the recogniser. A final pass
/// never loads it (`readyRescorer`): if it is somehow cold, that turn lands unboosted and a
/// background prepare reloads it. `residency: nil` keeps a bare load (tests).
public actor ManagedCTCBoostingSource: CTCBoostingModelSource {
    public static let modelID: ModelID = .parakeetCTC110m
    public static let residencyTier: ResidencyTier = .resident
    private let manager: ModelManager
    private let fetchWhenMissing: Bool
    private let residency: ModelResidency?
    private let status: SpeechModelPreparation
    public nonisolated let residencyKey: String
    private let box: RuntimeBox
    private var registered = false
    private var preparing: Task<Void, Never>?

    /// The stable residency key for `scope` (the app uses "app"; tests pass their own).
    public static func residencyKey(scope: String) -> String { "boost.\(modelID.rawValue)#\(scope)" }

    public init(manager: ModelManager, fetchWhenMissing: Bool = true, residency: ModelResidency? = .shared,
                scope: String = "app", prepareAtLaunch: Bool = true,
                status: SpeechModelPreparation = .shared) {
        self.manager = manager
        self.fetchWhenMissing = fetchWhenMissing
        self.residency = residency
        self.status = status
        let key = Self.residencyKey(scope: scope)
        self.residencyKey = key
        self.box = RuntimeBox.shared(for: key)
        if prepareAtLaunch { Task { await self.prepare() } }
    }

    /// Whether a load is running right now (tests, Settings).
    public var isPreparing: Bool { preparing != nil }

    public func prepare() async {
        guard preparing == nil else { return }
        if residency == nil, box.runtime != nil { return }
        if let residency, registered, await residency.isResident(residencyKey), box.runtime != nil { return }
        preparing = Task { await self.performPrepare() }
    }

    /// Wait for the current prepare (if any). Tests and onboarding.
    public func waitUntilPrepared() async {
        if let preparing { await preparing.value }
    }

    private func performPrepare() async {
        defer { preparing = nil }
        if await manager.locate(Self.modelID) == nil {
            guard fetchWhenMissing else { status.set(.unavailable); return }
            status.set(.downloading)
            guard (try? await manager.ensureAvailable(Self.modelID)) != nil else { status.set(.unavailable); return }
        }
        status.set(.preparing)
        let t0 = DispatchTime.now()
        let r = await runtime()
        status.set(r == nil ? .unavailable : .ready)
        if r != nil {
            Log.engine.info("boost: \(self.residencyKey) prepared in \(String(format: "%.0f", CTCVocabularyBooster.ms(since: t0))) ms")
        }
    }

    public func runtime() async -> CTCBoostingRuntime? {
        guard let url = await manager.locate(Self.modelID) else { return nil }
        guard let residency else {
            if box.runtime == nil { box.runtime = try? await CTCBoostingRuntime.load(from: url) }
            return box.runtime
        }
        if !registered {
            let box = self.box
            await residency.register(residencyKey, tier: Self.residencyTier,
                                     estimatedBytes: ModelCatalog.descriptor(Self.modelID).approxBytes * 2,
                                     owner: "boost.ctc",
                                     load: { if box.runtime == nil { box.runtime = try await CTCBoostingRuntime.load(from: url) } },
                                     unload: { box.runtime = nil })
            registered = true
        }
        do { try await residency.acquire(residencyKey) } catch { return nil }
        return box.runtime
    }

    public func readyRescorer() async -> (any CTCRescoring)? {
        if let residency {
            if registered, await residency.isResident(residencyKey), let r = box.runtime {
                await residency.touch(residencyKey)
                return r
            }
        } else if let r = box.runtime {
            return r
        }
        await prepare()   // background: this turn lands unboosted
        return nil
    }

    public func unload() async {
        if let residency, registered { await residency.unload(residencyKey, reason: .explicit) }
        box.runtime = nil
    }
}

/// Holds the runtime a residency `load` closure produced (the closures are `@Sendable`). One per
/// stable key, so a rebuilt source (engine refresh) finds the model already loaded.
final class RuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _runtime: CTCBoostingRuntime?
    var runtime: CTCBoostingRuntime? {
        get { lock.withLock { _runtime } }
        set { lock.withLock { _runtime = newValue } }
    }

    private static let registryLock = NSLock()
    private static var registry: [String: RuntimeBox] = [:]
    static func shared(for key: String) -> RuntimeBox {
        registryLock.withLock {
            if let b = registry[key] { return b }
            let b = RuntimeBox(); registry[key] = b; return b
        }
    }
}
