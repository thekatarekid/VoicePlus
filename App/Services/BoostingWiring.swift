import Engine
import Foundation
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
        let rubric: (@Sendable (Date) -> RankedContext?)? = surface.map { surface in
            { now in
                guard let resolved = surface() else { return nil }
                var candidates = authoredCandidates(database: database)
                candidates += ContextCandidates.entries(learned?.harvest(now: now) ?? [])
                candidates += turnCandidates?() ?? []
                return ContextRubric(weights: weights?() ?? RubricWeights())
                    .ranked(candidates: candidates, surface: resolved, now: now)
            }
        }
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
