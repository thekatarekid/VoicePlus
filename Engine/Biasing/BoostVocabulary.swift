import Foundation
import Shared

/// V5 B1 — the per-utterance CTC boost list, scoped down for the Context Writer (plan §1 "what
/// the booster becomes"; investigation: 6 changed turns, 4 worse, 0 better, Contacts leaking in).
///
/// What remains: the user's Dictionary terms that have a **spoken form** — one they typed
/// ("queen" for Qwen) or one `SpokenFormVerbalizer` derives ("a sixteen z" for a16z, "team viewer"
/// for TeamViewer) — and their **confirmed corrections** (entity-like words, plus the learned
/// lexicon). The CTC spotter can only help where the written form differs from what is heard; a
/// plain name it would merely overwrite on acoustics alone is left to the writer's `VOCAB` evidence
/// (`VocabularyMatcher`). **Never Contacts, never screen terms, never the surface lexicon**: the
/// rubric's `screenTermsInBoost` / near-caret admissions are ignored here. Cap 100.
public enum BoostVocabulary {
    /// The cap (was 400 before the scope-down).
    public static let cap = 100
    /// Shortest term kept: the CTC rescorer skips shorter terms anyway (NeMo CTC-WS min length) and
    /// 1–2 letter terms are false-insertion magnets ("or" → "VR").
    public static let minCharacters = 3
    /// Longest term kept: anything longer is a sentence, not a name.
    public static let maxCharacters = 64

    /// Legacy strings-only build: every term counts as a personal Dictionary row with no typed
    /// spoken form, so only terms the verbalizer can voice survive. Prefer `build(entries:...)`.
    public static func build(dictionary: [String], corrections: [String], context: RankedContext = .empty,
                             cap: Int = BoostVocabulary.cap) -> [String] {
        build(entries: dictionary.map { DictionaryEntry(term: $0, origin: .personal) },
              corrections: corrections, context: context, cap: cap)
    }

    /// Build the capped, deduplicated (case-insensitive, first spelling wins) list.
    /// - Parameters:
    ///   - entries: the user's Dictionary rows with origin and typed spoken forms. Contacts rows are
    ///     dropped; the rest need at least one spoken form (typed or verbalized).
    ///   - corrections: confirmed corrected text (`CorrectionRecord.corrected`), mined for entities.
    ///   - context: ranked context; **only** `.authored` is read — screen and recent tiers never.
    public static func build(entries: [DictionaryEntry], corrections: [String], context: RankedContext = .empty,
                             cap: Int = BoostVocabulary.cap) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        /// Appends `raw` when the length rules allow; false once the list is full. Every source is
        /// walked lazily through this, so the spoken-form test stops at the cap (hotkey-down).
        func take(_ raw: String) -> Bool {
            guard out.count < cap else { return false }
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let letters = term.filter { $0.isLetter || $0.isNumber }.count
            if letters >= minCharacters, term.count <= maxCharacters, seen.insert(term.lowercased()).inserted {
                out.append(term)
            }
            return out.count < cap
        }
        for e in entries where e.origin != .contacts && SpokenFormVerbalizer.hasSpokenForm(e.term, typed: e.spokenForms) {
            guard take(e.term) else { return out }
        }
        // Corrections are whole corrected phrases ("send it to Kothari tomorrow"): only the
        // entity-like words in them are worth boosting — "tomorrow" would only spend the cap.
        for correction in corrections {
            for term in EntityExtractor.extract(from: correction) { guard take(term) else { return out } }
        }
        // The ranked context's authored tier: Dictionary entries with a spoken form; correction-
        // derived words only when entity-like (the harvester splits corrections into every word).
        let typed = typedForms(entries)
        for t in context.terms(in: .authored) {
            let admitted = (t.sources.contains(.corrections) && EntityExtractor.isEntityLike(t.text))
                || (t.sources.contains(.dictionary) && SpokenFormVerbalizer.hasSpokenForm(t.text, typed: typed[t.text.lowercased()] ?? []))
            if admitted { guard take(t.text) else { return out } }
        }
        return out
    }

    /// N11 — the rubric's two layers (stable first, then per-turn), already scored, quota'd and
    /// collision-gated by `ContextRubric`; this keeps only what the scope-down admits (see
    /// `admits`). `spokenForms` is the typed forms by lower-cased term. Length rules and the cap apply.
    public static func build(rubric: RankedContext, spokenForms: [String: [String]] = [:],
                             cap: Int = BoostVocabulary.cap) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for term in rubric.stableLayer + rubric.perTurnLayer where out.count < cap {
            guard admits(term, typed: spokenForms[term.text.lowercased()] ?? []) else { continue }
            let letters = term.text.filter { $0.isLetter || $0.isNumber }.count
            guard letters >= minCharacters, term.text.count <= maxCharacters else { continue }
            guard seen.insert(term.text.lowercased()).inserted else { continue }
            out.append(term.text)
        }
        return out
    }

    /// A confirmed correction when it is entity-like (the same rule as the legacy build: a plain
    /// word the user once corrected to, "tomorrow", is not vocabulary); a Dictionary term only with
    /// a spoken form; nothing else — not a Contact, not a participant, not a screen, surface-lexicon
    /// or recent-dictation term, whatever `ContextRubric.Config.screenTermsInBoost` /
    /// `nearCaretInBoost` admitted.
    public static func admits(_ term: RubricTerm, typed: [String] = []) -> Bool {
        if term.sources.contains(.correction), EntityExtractor.isEntityLike(term.text) { return true }
        if term.sources.contains(.dictionary) { return SpokenFormVerbalizer.hasSpokenForm(term.text, typed: typed) }
        return false
    }

    /// Typed spoken forms by lower-cased term (Contacts rows excluded).
    public static func typedForms(_ entries: [DictionaryEntry]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for e in entries where e.origin != .contacts && !e.spokenForms.isEmpty {
            out[e.term.lowercased(), default: []] += e.spokenForms
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
    private let entries: (@Sendable () -> [DictionaryEntry])?
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
    ///   - entries: the Dictionary rows with origin and typed spoken forms; when given, they replace
    ///     `dictionary` and their typed forms also reach the rubric build (Context Writer §2.4).
    ///   - rubric: N11 — the rubric-ranked context for this utterance (nil = not wired / no surface).
    ///   - makeBooster: builds the per-utterance booster (the app passes `CTCVocabularyBooster` over a
    ///     shared model source; tests pass a scripted one).
    public init(context: @escaping @Sendable (Date) -> RankedContext = { _ in .empty },
                dictionary: @escaping @Sendable () -> [String] = { [] },
                corrections: @escaping @Sendable () -> [String] = { [] },
                entries: (@Sendable () -> [DictionaryEntry])? = nil,
                rubric: (@Sendable (Date) -> RankedContext?)? = nil,
                makeBooster: @escaping @Sendable ([String]) -> VocabularyBooster) {
        self.rubric = rubric
        self.entries = entries
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
        let rows = entries?()
        if let ranked = rubric?(now) {
            terms = BoostVocabulary.build(rubric: ranked, spokenForms: BoostVocabulary.typedForms(rows ?? []))
        } else if let rows {
            terms = BoostVocabulary.build(entries: rows, corrections: corrections(), context: context(now))
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
