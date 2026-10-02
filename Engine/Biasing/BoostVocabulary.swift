import Foundation
import Shared

/// V5 B1 — the per-utterance CTC boost list.
///
/// Sources, in priority order: the user's Dictionary, their confirmed corrections, then the
/// `.authored` tier of the ranked context (`ContextRanker`: corrections + dictionary as harvested).
/// **Never raw screen text**: boosting rewrites words against acoustic evidence, and a word that
/// is merely visible on screen is not something the user asked us to prefer. Screen text reaches the
/// cleanup prompt through B2 instead, where it is data, not a decode bias.
public enum BoostVocabulary {
    /// The cap V5 B1 fixes (matches `RankedContext.defaultCap`).
    public static let cap = 400
    /// Shortest term kept: the CTC rescorer skips shorter terms anyway (NeMo CTC-WS min length) and
    /// 1–2 letter terms are false-insertion magnets ("or" → "VR").
    public static let minCharacters = 3
    /// Longest term kept: anything longer is a sentence, not a name.
    public static let maxCharacters = 64

    /// Build the capped, deduplicated (case-insensitive, first spelling wins) list.
    /// - Parameters:
    ///   - dictionary: the user's Dictionary terms, kept whole (multi-word terms included).
    ///   - corrections: confirmed corrected text (`CorrectionRecord.corrected`), mined for entities.
    ///   - context: ranked context; **only** `.authored` is read — screen and recent tiers never.
    public static func build(dictionary: [String], corrections: [String], context: RankedContext = .empty,
                             cap: Int = BoostVocabulary.cap) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        // Corrections are whole corrected phrases ("send it to Kothari tomorrow"): only the
        // entity-like words in them are worth boosting — "tomorrow" would only spend the cap.
        let correctionTerms = corrections.flatMap { EntityExtractor.extract(from: $0) }
        // The ranked context's authored tier: Dictionary entries as-is; correction-derived words
        // only when entity-like (the harvester splits corrections into every word).
        let authored = context.terms(in: .authored).filter {
            $0.sources.contains { ContactsChannelPolicy.admits($0, channel: .boost) }
                && ($0.sources.contains(.dictionary) || EntityExtractor.isEntityLike($0.text))
        }.map(\.text)
        for raw in dictionary + correctionTerms + authored {
            guard out.count < cap else { break }
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = term.filter { $0.isLetter || $0.isNumber }.count
            guard letters >= minCharacters, term.count <= maxCharacters else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            out.append(term)
        }
        return out
    }

    /// N11 — the rubric's two layers (stable first, then per-turn), already typed, scored, quota'd
    /// and collision-gated by `ContextRubric`. Length rules and the cap still apply here.
    public static func build(rubric: RankedContext, cap: Int = BoostVocabulary.cap) -> [String] {
        var out: [String] = []
        for term in rubric.boostTerms where out.count < cap {
            let letters = term.filter { $0.isLetter || $0.isNumber }.count
            guard letters >= minCharacters, term.count <= maxCharacters else { continue }
            out.append(term)
        }
        return out
    }
}

/// Builds the boost list at hotkey-down and turns it into a booster for the final pass.
/// Replaces the old `BiasingController` (decode-time shallow fusion, flag `contextBiasing`; V5 A1).
///
/// There is no feature flag: an empty vocabulary installs nothing, and a missing CTC model makes
/// the booster a no-op, so boosting only ever acts for users who have told us words to prefer.
public final class BoostingController: @unchecked Sendable {
    private let context: @Sendable (Date) -> RankedContext
    private let dictionary: @Sendable () -> [String]
    private let corrections: @Sendable () -> [String]
    private let makeBooster: @Sendable ([String]) -> VocabularyBooster
    private let rubric: (@Sendable (Date) -> RankedContext?)?
    private let lock = NSLock()
    private var _lastTerms: [String] = []
    private var _lastBuildMs: Double = 0

    /// - Parameters:
    ///   - context: ranked context for this utterance; only its `.authored` tier is read. The app
    ///     ranks a harvester holding only the authored sources (corrections, dictionary, learned
    ///     lexicon), so building the boost list never walks the screen.
    ///   - dictionary / corrections: read fresh per utterance (the user may have just added a word).
    ///   - rubric: N11 — the rubric-ranked context for this utterance (nil = not wired / no surface).
    ///   - makeBooster: builds the per-utterance booster (the app passes `CTCVocabularyBooster` over a
    ///     shared model source; tests pass a scripted one).
    public init(context: @escaping @Sendable (Date) -> RankedContext = { _ in .empty },
                dictionary: @escaping @Sendable () -> [String] = { [] },
                corrections: @escaping @Sendable () -> [String] = { [] },
                rubric: (@Sendable (Date) -> RankedContext?)? = nil,
                makeBooster: @escaping @Sendable ([String]) -> VocabularyBooster) {
        self.rubric = rubric
        self.context = context
        self.dictionary = dictionary
        self.corrections = corrections
        self.makeBooster = makeBooster
    }

    public var lastTerms: [String] { lock.withLock { _lastTerms } }
    public var lastBuildMs: Double { lock.withLock { _lastBuildMs } }

    /// Rebuild the list for this utterance. Nil (= clear the booster) when there is nothing to boost.
    public func makeBoosterForUtterance(now: Date = Date()) -> VocabularyBooster? {
        let t0 = DispatchTime.now().uptimeNanoseconds
        // N11: when the rubric is wired (surface known), its layers are the whole list — including
        // "nothing" on a secure field. Otherwise the legacy authored-only build.
        let terms: [String]
        if let ranked = rubric?(now) {
            terms = BoostVocabulary.build(rubric: ranked)
        } else {
            terms = BoostVocabulary.build(dictionary: dictionary(), corrections: corrections(), context: context(now))
        }
        lock.withLock {
            _lastTerms = terms
            _lastBuildMs = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
        }
        return terms.isEmpty ? nil : makeBooster(terms)
    }
}
