import Engine
import Foundation
import Lab
import Shared

/// V5 B1 — builds the app's `BoostingController`: the user's Dictionary, their confirmed
/// corrections and the learned lexicon (the `.authored` tier — never screen text) become a
/// per-utterance CTC boost list, applied to the final pass by `CTCVocabularyBooster`.
///
/// Context Writer (plan §1 "what the booster becomes") — the booster is scoped down: **no Contacts
/// and no screen terms** reach it from the App side either (the Engine's `BoostVocabulary` enforces
/// the same). The boost rubric gets the authored candidates without Contacts rows and none of the
/// turn's screen / near-caret / shell candidates, and `rubricConfig` admits no screen term to a
/// boost layer. Screen text reaches the writer's packet (and the legacy cleanup prompt) as data.
enum BoostingWiring {
    /// - Parameters:
    ///   - surface: N11 — the turn's resolved surface. When it returns a resolution, the boost list
    ///     is the rubric's stable + per-turn layers over the authored candidates only (no Contacts,
    ///     no screen); nil keeps the legacy authored-only list.
    ///   - weights: learned per-surface source weights (N28); starting weights when nil.
    static func controller(database: AppDatabase?, adaptation: AdaptationService?,
                           modelManager: ModelManager?,
                           surface: (@Sendable () -> SurfaceResolution?)? = nil,
                           weights: (@Sendable () -> RubricWeights)? = nil,
                           learning: ContextLearningTap? = nil) -> BoostingController? {
        guard let modelManager else { return nil }   // mock / unavailable engine: nothing to boost
        let source = ManagedCTCBoostingSource(manager: modelManager)
        return controller(database: database, adaptation: adaptation, surface: surface, weights: weights, learning: learning,
                          makeBooster: { terms in CTCVocabularyBooster(terms: terms, source: source) })
    }

    /// The same over any booster (tests pass a scripted one; the app the CTC model above).
    static func controller(database: AppDatabase?, adaptation: AdaptationService?,
                           surface: (@Sendable () -> SurfaceResolution?)?,
                           weights: (@Sendable () -> RubricWeights)?,
                           learning: ContextLearningTap?,
                           makeBooster: @escaping @Sendable ([String]) -> VocabularyBooster) -> BoostingController {
        // Authored-only harvester: corrections + Dictionary (as harvested) + learned lexicon. No AX,
        // no contacts, no recent words — building the list must never walk the screen.
        let authored = ContextHarvester()
        if let database { authored.add(CorrectionSource(store: DatabaseCorrectionStore(database: database, limit: 500))) }
        let learned = adaptation.map { LearnedLexiconSource(loop: $0.loop) }
        if let learned { authored.add(learned) }
        let ranker = ContextRanker()
        // Context Writer scope-down: no turn candidates (screen, near-caret, shell, participants)
        // and no Contacts rows in the boost rubric.
        let rubric = surface.map { rubricRanking(database: database, learned: learned, surface: $0,
                                                 turnCandidates: nil, weights: weights, learning: learning,
                                                 contacts: false) }
        return BoostingController(
            context: { now in ranker.rank(harvesting: authored, now: now) },
            corrections: {
                guard let database else { return [] }
                return (try? DatabaseCorrectionStore(database: database, limit: 500).correctedTerms().map(\.term)) ?? []
            },
            // N1 + Context Writer §2.4: the Dictionary rows with their origin and typed spoken forms
            // (Contacts imports dropped here and again by `BoostVocabulary`), so a term the
            // verbalizer cannot voice still reaches the boost list through the form the user typed —
            // on both the legacy and the rubric build.
            entries: { Self.boostEntries(database: database) },
            rubric: rubric,
            makeBooster: makeBooster)
    }

    /// The Dictionary rows the booster may use: every row with its origin and typed spoken forms,
    /// Contacts rows dropped (N1). Read fresh per utterance (the user may have just added a word).
    static func boostEntries(database: AppDatabase?) -> [DictionaryEntry] {
        guard let database, let entries = try? DictionaryOrigins.entries(database) else { return [] }
        return entries.filter { ContactsChannelPolicy.admits($0.origin, channel: .boost) }
    }

    /// N28 — learned per-surface source weights (JSON under the support dir). Pass as `weights:`;
    /// the app records each landed turn through `ContextLearningTap.shared.land(...)`.
    static let learnedWeights: @Sendable () -> RubricWeights = { SourceWeightLearner.shared.weights() }

    /// N11/N14 — the turn's rubric ranking. The boost list reads its layers; the cleanup prompt
    /// reads its spell list and screen terms when the app sets it as `ContextPromptSession.rubric`
    /// (`promptSession.rubric = BoostingWiring.rubricRanking(...)`). nil when no surface resolved.
    static func rubricRanking(database: AppDatabase?, adaptation: AdaptationService?,
                              surface: @escaping @Sendable () -> SurfaceResolution?,
                              turnCandidates: (@Sendable () -> [ContextCandidate])? = nil,
                              weights: (@Sendable () -> RubricWeights)? = nil,
                              learning: ContextLearningTap? = nil) -> @Sendable (Date) -> RankedContext? {
        rubricRanking(database: database, learned: adaptation.map { LearnedLexiconSource(loop: $0.loop) },
                      surface: surface, turnCandidates: turnCandidates, weights: weights, learning: learning)
    }

    /// - Parameter contacts: false drops the Dictionary's Contacts rows (the boost rubric).
    static func rubricRanking(database: AppDatabase?, learned: LearnedLexiconSource?,
                              surface: @escaping @Sendable () -> SurfaceResolution?,
                              turnCandidates: (@Sendable () -> [ContextCandidate])?,
                              weights: (@Sendable () -> RubricWeights)?,
                              learning: ContextLearningTap? = nil,
                              contacts: Bool = true) -> @Sendable (Date) -> RankedContext? {
        { now in
            guard let resolved = surface() else { return nil }
            var candidates = authoredCandidates(database: database)
            if !contacts { candidates.removeAll { $0.source == .contact } }
            candidates += ContextCandidates.entries(learned?.harvest(now: now) ?? [])
            candidates += turnCandidates?() ?? []
            let ranked = ContextRubric(config: rubricConfig, weights: weights?() ?? RubricWeights())
                .ranked(candidates: candidates, surface: resolved, now: now)
            learning?.remember(ranked, surface: resolved.kind, at: now)
            return ranked
        }
    }

    /// Context Writer scope-down: no screen term — far window or near the caret — is admitted to a
    /// boost layer, whatever the N11-lab report (`ScreenTermsDefault`) says. The ranking itself
    /// (prompt terms, spell list) is unchanged.
    static let rubricConfig: ContextRubric.Config = {
        var c = ContextRubric.Config()
        c.screenTermsInBoost = false
        c.nearCaretInBoost = false
        return c
    }()

    /// N11-lab — the Engine experiment's metrics as the counts-only Lab report.
    static func screenTermsReport(_ metrics: [ScreenTermsExperiment.Arm: BiasingMetrics],
                                  corpus: String, recognizer: String, measuredAt: Date = Date()) -> ScreenTermsReport {
        func counts(_ arm: ScreenTermsExperiment.Arm) -> ContextRecallCounts {
            let m = metrics[arm] ?? BiasingMetrics()
            return ContextRecallCounts(utterances: m.utterances, entitiesExpected: m.entitiesExpected,
                                       entitiesRecalled: m.entitiesRecalled, falseInsertions: m.falseInsertions,
                                       hypothesisWords: m.hypothesisWords)
        }
        return ScreenTermsReport(corpus: corpus, recognizer: recognizer, measuredAt: measuredAt,
                                 noScreen: counts(.noScreen), matchingScreen: counts(.matchingScreen),
                                 distractorScreen: counts(.distractorScreen))
    }

    /// N11 — the user's own candidates: Dictionary rows with their origin (Contacts rows become
    /// `.contact`, admitted by the rubric only on conversational surfaces) and corrections.
    static func authoredCandidates(database: AppDatabase?) -> [ContextCandidate] {
        guard let database else { return [] }
        var out = ContextCandidates.dictionary((try? DictionaryOrigins.entries(database)) ?? [])
        let corrected = (try? DatabaseCorrectionStore(database: database, limit: 500).correctedTerms()) ?? []
        out += ContextCandidates.corrections(corrected)
        return out
    }
}

/// N28 — the live learning loop's tap. The rubric closure remembers the turn's latest ranking
/// (boost list and cleanup prompt both run it); the lander hands over the final text, and the
/// offered terms + final text are recorded as one `TurnContextOutcome`. One record per ranking;
/// a ranking older than `maxAge` (or from a secure surface) is never recorded. Persisting runs off
/// the landing path.
final class ContextLearningTap: @unchecked Sendable {
    static let shared = ContextLearningTap(learner: .shared)

    let learner: SourceWeightLearner
    let maxAge: TimeInterval
    private let queue: DispatchQueue?
    private let lock = NSLock()
    private var pending: (ranked: RankedContext, surface: SurfaceKind, at: Date)?

    /// - Parameter queue: where `record` runs; nil records synchronously (tests).
    init(learner: SourceWeightLearner, maxAge: TimeInterval = 120,
         queue: DispatchQueue? = DispatchQueue(label: "voiceplus.context-learning", qos: .utility)) {
        self.learner = learner
        self.maxAge = maxAge
        self.queue = queue
    }

    func remember(_ ranked: RankedContext, surface: SurfaceKind, at: Date) {
        lock.withLock { pending = surface == .secure ? nil : (ranked, surface, at) }
    }

    /// Records the turn when a fresh, non-secure ranking with offered terms is pending. Returns
    /// whether a record was scheduled.
    @discardableResult
    func land(finalText: String, rawText: String? = nil, app: String? = nil, now: Date = Date()) -> Bool {
        guard let turn = lock.withLock({ () -> (ranked: RankedContext, surface: SurfaceKind, at: Date)? in
            defer { pending = nil }
            return pending
        }) else { return false }
        guard turn.surface != .secure, now.timeIntervalSince(turn.at) <= maxAge,
              !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let outcome = TurnContextOutcome(surface: turn.surface, app: app, ranked: turn.ranked,
                                         rawText: rawText, finalText: finalText)
        guard !outcome.offered.isEmpty else { return false }
        if let queue { queue.async { [learner] in learner.record(outcome) } } else { learner.record(outcome) }
        return true
    }
}
