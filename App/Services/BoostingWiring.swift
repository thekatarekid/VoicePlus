import Engine
import Foundation
import Lab
import Shared

/// V5 B1 — builds the app's `BoostingController`: the user's Dictionary, their confirmed
/// corrections and the learned lexicon (the `.authored` tier — never screen text) become a
/// per-utterance CTC boost list, applied to the final pass by `CTCVocabularyBooster`.
enum BoostingWiring {
    /// - Parameters:
    ///   - surface: N11 — the turn's resolved surface. When it returns a resolution, the boost list
    ///     is the rubric's stable + per-turn layers (Contacts only on chat/email/name fields, common
    ///     words only with strong evidence); nil keeps the legacy authored-only list.
    ///   - turnCandidates: per-turn candidates the app gathered (screen, shell, lexicon, participants).
    ///   - weights: learned per-surface source weights (N28); starting weights when nil.
    static func controller(database: AppDatabase?, adaptation: AdaptationService?,
                           modelManager: ModelManager?,
                           surface: (@Sendable () -> SurfaceResolution?)? = nil,
                           turnCandidates: (@Sendable () -> [ContextCandidate])? = nil,
                           weights: (@Sendable () -> RubricWeights)? = nil) -> BoostingController? {
        guard let modelManager else { return nil }   // mock / unavailable engine: nothing to boost
        let source = ManagedCTCBoostingSource(manager: modelManager)
        // Authored-only harvester: corrections + Dictionary (as harvested) + learned lexicon. No AX,
        // no contacts, no recent words — building the list must never walk the screen.
        let authored = ContextHarvester()
        if let database { authored.add(CorrectionSource(store: DatabaseCorrectionStore(database: database, limit: 500))) }
        let learned = adaptation.map { LearnedLexiconSource(loop: $0.loop) }
        if let learned { authored.add(learned) }
        let ranker = ContextRanker()
        let rubric = surface.map { rubricRanking(database: database, learned: learned, surface: $0,
                                                 turnCandidates: turnCandidates, weights: weights) }
        return BoostingController(
            context: { now in ranker.rank(harvesting: authored, now: now) },
            // N1: Dictionary rows keep their origin; Contacts imports never enter the boost list.
            dictionary: {
                guard let database, let entries = try? DictionaryOrigins.entries(database) else { return [] }
                return ContactsChannelPolicy.terms(entries, channel: .boost)
            },
            corrections: {
                guard let database else { return [] }
                return (try? DatabaseCorrectionStore(database: database, limit: 500).correctedTerms().map(\.term)) ?? []
            },
            rubric: rubric,
            makeBooster: { terms in CTCVocabularyBooster(terms: terms, source: source) })
    }

    /// N11/N14 — the turn's rubric ranking. The boost list reads its layers; the cleanup prompt
    /// reads its spell list and screen terms when the app sets it as `ContextPromptSession.rubric`
    /// (`promptSession.rubric = BoostingWiring.rubricRanking(...)`). nil when no surface resolved.
    static func rubricRanking(database: AppDatabase?, adaptation: AdaptationService?,
                              surface: @escaping @Sendable () -> SurfaceResolution?,
                              turnCandidates: (@Sendable () -> [ContextCandidate])? = nil,
                              weights: (@Sendable () -> RubricWeights)? = nil) -> @Sendable (Date) -> RankedContext? {
        rubricRanking(database: database, learned: adaptation.map { LearnedLexiconSource(loop: $0.loop) },
                      surface: surface, turnCandidates: turnCandidates, weights: weights)
    }

    static func rubricRanking(database: AppDatabase?, learned: LearnedLexiconSource?,
                              surface: @escaping @Sendable () -> SurfaceResolution?,
                              turnCandidates: (@Sendable () -> [ContextCandidate])?,
                              weights: (@Sendable () -> RubricWeights)?) -> @Sendable (Date) -> RankedContext? {
        { now in
            guard let resolved = surface() else { return nil }
            var candidates = authoredCandidates(database: database)
            candidates += ContextCandidates.entries(learned?.harvest(now: now) ?? [])
            candidates += turnCandidates?() ?? []
            return ContextRubric(config: rubricConfig, weights: weights?() ?? RubricWeights())
                .ranked(candidates: candidates, surface: resolved, now: now)
        }
    }

    /// N11-lab (F27) — screen terms join the per-turn boost layer only when a measured Lab report
    /// (`screen-terms-lab.json` in the support folder) passes; off by default. Read once per launch.
    static let rubricConfig: ContextRubric.Config = {
        var c = ContextRubric.Config()
        c.screenTermsInBoost = ScreenTermsDefault.enabled()
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
