import Engine
import Foundation
import Shared

/// V5 B1 — builds the app's `BoostingController`: the user's Dictionary, their confirmed
/// corrections and the learned lexicon (the `.authored` tier — never screen text) become a
/// per-utterance CTC boost list, applied to the final pass by `CTCVocabularyBooster`.
enum BoostingWiring {
    static func controller(database: AppDatabase?, adaptation: AdaptationService?,
                           modelManager: ModelManager?) -> BoostingController? {
        guard let modelManager else { return nil }   // mock / unavailable engine: nothing to boost
        let source = ManagedCTCBoostingSource(manager: modelManager)
        // Authored-only harvester: corrections + Dictionary (as harvested) + learned lexicon. No AX,
        // no contacts, no recent words — building the list must never walk the screen.
        let authored = ContextHarvester()
        if let database { authored.add(CorrectionSource(store: DatabaseCorrectionStore(database: database, limit: 500))) }
        if let adaptation { authored.add(LearnedLexiconSource(loop: adaptation.loop)) }
        let ranker = ContextRanker()
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
            makeBooster: { terms in CTCVocabularyBooster(terms: terms, source: source) })
    }
}
