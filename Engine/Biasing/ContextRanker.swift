import Foundation

// R4.1b — one ranked context list (V3 §7, §7.1–§7.3).
//
// `Ranker` (P1.5) already scores harvested entries for the *decode-time* trie, where every entry
// competes on one continuous score. The refinement prompt needs something different: a **band
// order** the score cannot cross. The user's own corrections and Dictionary entries must survive
// the cap even when a text editor is showing four hundred capitalised words, because a screen full
// of prose is data we happened to read, and a Dictionary entry is a thing the user asked for.
// So this file ranks in tiers first, score second — and nothing here is ever written down
// (`RankedContext` is deliberately not `Codable`; see `ContextSession.discard`).

/// Priority band. A lower `rawValue` wins outright: no amount of screen text can push an explicit
/// correction or a Dictionary entry out of the capped list.
public enum ContextTier: Int, Comparable, CaseIterable, Sendable {
    /// Explicit corrections + the user's Dictionary. Highest: the user typed or confirmed these.
    case authored = 0
    /// Focused-window text (and the open documents' names). Untrusted **data**, never instructions.
    case screen = 1
    /// Recent confirmed vocabulary — what was dictated or typed in the last ten minutes, plus the
    /// permissioned name sources the app may install. Lowest.
    case recent = 2

    public static func < (a: ContextTier, b: ContextTier) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .authored: return "corrections+dictionary"
        case .screen: return "focused window"
        case .recent: return "recent vocabulary"
        }
    }
}

/// One term in the ranked list. `score` orders terms *inside* a tier only.
public struct RankedContextTerm: Hashable, Sendable {
    public var text: String
    public var tier: ContextTier
    public var score: Double
    /// Every harvest source that produced this term (a term seen on screen *and* in the Dictionary
    /// keeps both, and is ranked in the higher tier).
    public var sources: Set<ContextSourceKind>

    public init(text: String, tier: ContextTier, score: Double, sources: Set<ContextSourceKind>) {
        self.text = text
        self.tier = tier
        self.score = score
        self.sources = sources
    }

    /// True when the only reason this term is here is something we read off the screen.
    public var isScreenOnly: Bool { tier == .screen }
}

/// The single ranked, deduped, capped list. In-memory only: **not** `Codable`, not `Encodable`,
/// no `description` that spells the terms out. `PromptBuilder` is the only thing that turns it
/// into a string, and `ContextSession` is what owns its lifetime (V3 §7.3).
public struct RankedContext: Sendable, Equatable {
    /// The cap V3 §7 fixes: 400 terms.
    public static let defaultCap = 400

    public let terms: [RankedContextTerm]
    public let cap: Int
    /// Distinct terms the ranker saw before the cap was applied.
    public let considered: Int
    /// How many distinct terms the cap dropped (`considered - terms.count`).
    public let dropped: Int

    // N11 — the rubric's outputs (`ContextRubric.rank`). Empty for a tier-ranked list.
    /// Stable boost layer (~200: corrections, dictionary, surface lexicon), cached per surface class.
    public internal(set) var stableLayer: [RubricTerm] = []
    /// Per-turn boost layer (~50: screen, folder, participant terms).
    public internal(set) var perTurnLayer: [RubricTerm] = []
    /// The cleanup prompt's "spell exactly" list, chosen by score (not dictionary-first).
    public internal(set) var spellList: [String] = []
    /// Top screen / per-turn terms for the cleanup prompt (data, never instructions).
    public internal(set) var promptTerms: [String] = []

    public init(terms: [RankedContextTerm], cap: Int, considered: Int) {
        self.terms = terms
        self.cap = cap
        self.considered = considered
        self.dropped = max(0, considered - terms.count)
    }

    /// Both boost layers, stable first, deduplicated (case-insensitive).
    public var boostTerms: [String] {
        var seen = Set<String>()
        return (stableLayer + perTurnLayer).map(\.text).filter { seen.insert($0.lowercased()).inserted }
    }

    public static let empty = RankedContext(terms: [], cap: RankedContext.defaultCap, considered: 0)

    public var count: Int { terms.count }
    public var isEmpty: Bool { terms.isEmpty }
    public var texts: [String] { terms.map(\.text) }

    public func terms(in tier: ContextTier) -> [RankedContextTerm] { terms.filter { $0.tier == tier } }
    public func count(in tier: ContextTier) -> Int { terms.reduce(0) { $0 + ($1.tier == tier ? 1 : 0) } }

    /// Case-insensitive membership.
    public func contains(_ text: String) -> Bool {
        let key = text.lowercased()
        return terms.contains { $0.text.lowercased() == key }
    }

    /// Counts only — safe to log. Never includes a term.
    public var shape: String {
        "\(count)/\(cap) terms (authored \(count(in: .authored)), screen \(count(in: .screen)), "
            + "recent \(count(in: .recent)), dropped \(dropped))"
    }
}

/// Merges the four sources into one ranked list: dedupe, tier order, hard cap.
///
/// Scoring inside a tier is `Ranker`'s (source weight × recency decay × salience), so there is one
/// place where "how much does a source count" lives.
public struct ContextRanker: Sendable {
    public static let defaultCap = RankedContext.defaultCap

    public var cap: Int
    /// Longest term kept. Anything longer is a sentence, not a name.
    public var maxTermCharacters: Int
    /// Scorer used inside a tier.
    public var scorer: Ranker

    public init(cap: Int = ContextRanker.defaultCap,
                maxTermCharacters: Int = 64,
                scorer: Ranker = Ranker(cap: ContextRanker.defaultCap)) {
        self.cap = max(1, cap)
        self.maxTermCharacters = max(2, maxTermCharacters)
        self.scorer = scorer
    }

    /// Which band a harvest source lands in. The three bands V3 §7 names, plus the permissioned
    /// name sources (`contacts`, `participants`), which sit in the lowest band so installing them
    /// can never displace the user's own words.
    public static func tier(for kind: ContextSourceKind) -> ContextTier {
        switch kind {
        case .corrections, .dictionary: return .authored
        case .axTree, .codeSymbols: return .screen
        case .recentWords, .contacts, .participants: return .recent
        }
    }

    /// Rank one harvest. Deterministic: equal tier and score break on the term text.
    public func rank(_ entries: [ContextEntry], now: Date = Date()) -> RankedContext {
        struct Accumulator {
            var text: String
            var tier: ContextTier
            var score: Double
            var sources: Set<ContextSourceKind>
        }
        var merged: [String: Accumulator] = [:]
        for entry in entries {
            // N1: Contacts never reach the boost list or the cleanup context (until N11).
            guard ContactsChannelPolicy.admits(entry.source, channel: .cleanupContext) else { continue }
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= maxTermCharacters else { continue }
            let key = text.lowercased()
            let tier = Self.tier(for: entry.source)
            let score = scorer.score(entry, now: now)
            if var existing = merged[key] {
                // Multi-source agreement: keep the best band, the best score, a small bonus for
                // being seen twice, and the capitalised spelling if one of them had it.
                existing.tier = min(existing.tier, tier)
                existing.score = max(existing.score, score) + 0.25 * min(existing.score, score)
                existing.sources.insert(entry.source)
                if text.first?.isUppercase == true { existing.text = text }
                merged[key] = existing
            } else {
                merged[key] = Accumulator(text: text, tier: tier, score: score, sources: [entry.source])
            }
        }
        let ordered = merged.values.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.score != b.score { return a.score > b.score }
            return a.text < b.text
        }
        let kept = ordered.prefix(cap).map {
            RankedContextTerm(text: $0.text, tier: $0.tier, score: $0.score, sources: $0.sources)
        }
        return RankedContext(terms: Array(kept), cap: cap, considered: merged.count)
    }

    /// Harvest and rank in one call — the per-utterance shape.
    public func rank(harvesting harvester: ContextHarvester, now: Date = Date()) -> RankedContext {
        rank(harvester.harvest(now: now), now: now)
    }
}

/// Owns the ranked list's lifetime: rebuilt per utterance, discarded with the session.
///
/// V3 §7.3, enforced here rather than described: the list lives in this object's memory, is thrown
/// away by `discard()` (which also drops the harvester's cached entries), and is never handed to
/// anything that writes — history, diagnostics and sync do not see it because nothing here can
/// serialise it.
public final class ContextSession: @unchecked Sendable {
    public let harvester: ContextHarvester
    public var ranker: ContextRanker

    private let lock = NSLock()
    private var list: RankedContext = .empty
    private var rebuildCount = 0

    public init(harvester: ContextHarvester, ranker: ContextRanker = ContextRanker()) {
        self.harvester = harvester
        self.ranker = ranker
    }

    /// The list built for the current utterance. `.empty` before the first `rebuild` and after
    /// `discard()`.
    public var current: RankedContext { lock.withLock { list } }
    public var rebuilds: Int { lock.withLock { rebuildCount } }

    /// Re-read every source and re-rank. Call at the start of each utterance: screen text one
    /// utterance old is stale context, not context.
    @discardableResult
    public func rebuild(now: Date = Date()) -> RankedContext {
        let ranked = ranker.rank(harvesting: harvester, now: now)
        return lock.withLock {
            list = ranked
            rebuildCount += 1
            return ranked
        }
    }

    /// End of session: forget the list *and* the harvest behind it.
    public func discard() {
        harvester.forgetLastHarvest()
        lock.withLock { list = .empty }
    }
}
