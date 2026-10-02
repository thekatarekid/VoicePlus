import Foundation
import Shared

// N11 — the context rubric (Investigation R3 §E2–§E4).
//
// One scoring formula over typed candidates replaces the strict "corrections > dictionary >
// Contacts" tiers and the one-list-for-every-app boost list:
//
//     score = source weight × surface fit × closeness × freshness × evidence − collision penalty
//
// then per-source quotas (no source takes more than about half of a budget; corrections get a
// guaranteed share) and four outputs: a stable boost layer (~200), a per-turn boost layer (~50),
// the cleanup "spell exactly" list and the cleanup prompt's screen terms. Screen text is data,
// never instructions; nothing here is persisted (the learned weights live in `SourceWeightLearner`).

/// What a candidate is (§E2).
public enum CandidateType: String, CaseIterable, Sendable, Codable {
    case person, path, command, techTerm, link, formulaFunction, word

    /// Best-effort type of a bare term (screen text, harvested entries). Providers that know the
    /// type (shell commands, folder entries, formula names) set it directly.
    public static func infer(_ text: String) -> CandidateType {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return .word }
        let lower = t.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return .link }
        if !t.contains(" "), let dot = t.lastIndex(of: "."), dot != t.startIndex {
            let ext = t[t.index(after: dot)...]
            let tlds: Set<String> = ["com", "org", "net", "io", "ai", "dev", "app", "co", "in", "edu", "gov", "me", "so"]
            if tlds.contains(ext.lowercased()) { return .link }
            if (1...5).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return .path }
        }
        if t.contains("/") || t.hasPrefix("~") { return .path }
        if t.dropFirst().contains(where: \.isUppercase) && t.contains(where: \.isLowercase) && !t.contains(" ") { return .techTerm }
        if t.contains(where: { $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) { return .techTerm }
        if first.isUppercase { return .person }
        return .word
    }
}

/// Where a candidate came from (§E3 weights table).
public enum CandidateSource: String, CaseIterable, Sendable, Codable {
    /// The user's corrections. Everywhere; guaranteed share.
    case correction
    /// The user's Dictionary (personal / imported / earlier rows).
    case dictionary
    /// Terms visible near the caret or in the active thread.
    case screenNear
    /// What this kind of surface accepts: commands, folder entries, formula names, code symbols.
    case surfaceLexicon
    /// Other visible terms in the window.
    case screenWindow
    /// Recent dictations in this app.
    case recentDictation
    /// Thread participants. Chat and email only.
    case participant
    /// Contacts (Dictionary rows imported from Contacts). Chat, email and name fields only.
    case contact

    /// Starting weights (§E3). Tuned in the Lab, adjusted per surface by N28.
    public var startingWeight: Double {
        switch self {
        case .correction: return 1.0
        case .dictionary: return 0.9
        case .screenNear: return 0.8
        case .surfaceLexicon: return 0.85
        case .screenWindow: return 0.5
        case .recentDictation: return 0.6
        case .participant: return 0.9
        case .contact: return 0.6
        }
    }

    /// Read off the screen (gated by F27's Lab measurement for the boost layer).
    public var isScreen: Bool { self == .screenNear || self == .screenWindow }

    /// Timeless sources do not decay with age.
    var isTimeless: Bool {
        switch self {
        case .correction, .dictionary, .surfaceLexicon, .contact, .participant: return true
        default: return false
        }
    }

    /// The legacy harvest kind (for `RankedContext.terms` consumers such as `PromptBuilder`).
    public var contextSourceKind: ContextSourceKind {
        switch self {
        case .correction: return .corrections
        case .dictionary: return .dictionary
        case .screenNear, .screenWindow: return .axTree
        case .surfaceLexicon: return .codeSymbols
        case .recentDictation: return .recentWords
        case .participant: return .participants
        case .contact: return .contacts
        }
    }
}

/// One typed candidate (§E2): text, type, source, distance from the caret and freshness.
public struct ContextCandidate: Hashable, Sendable {
    public var text: String
    public var type: CandidateType
    public var source: CandidateSource
    /// Characters between the term and the caret; nil when not on screen / unknown.
    public var caretDistance: Int?
    public var observedAt: Date
    /// Provider-local evidence in 0…1 (salience: window title > body; dictionary weight).
    public var evidence: Double
    /// Visible on screen right now — strong evidence for a common-word term.
    public var onScreenNow: Bool
    /// A Dictionary term never used in a dictation (weight 0.6 instead of 0.9).
    public var neverUsed: Bool
    /// For `.surfaceLexicon`: the surface whose lexicon produced it (nil → inferred from type).
    public var lexiconSurface: SurfaceKind?
    /// For `.recentDictation`: the app it was dictated in.
    public var app: String?
    /// Spoken forms heard for this term (N28 aliases). Not ranked; carried for the learner.
    public var heardAliases: [String]

    public init(text: String, type: CandidateType? = nil, source: CandidateSource, caretDistance: Int? = nil,
                observedAt: Date = Date(), evidence: Double = 1, onScreenNow: Bool = false, neverUsed: Bool = false,
                lexiconSurface: SurfaceKind? = nil, app: String? = nil, heardAliases: [String] = []) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.type = type ?? CandidateType.infer(text)
        self.source = source
        self.caretDistance = caretDistance.map { max(0, $0) }
        self.observedAt = observedAt
        self.evidence = min(max(evidence, 0), 1)
        self.onScreenNow = onScreenNow || source.isScreen
        self.neverUsed = neverUsed
        self.lexiconSurface = lexiconSurface
        self.app = app
        self.heardAliases = heardAliases
    }
}

/// One ranked term in a rubric output.
public struct RubricTerm: Hashable, Sendable {
    public var text: String
    public var type: CandidateType
    /// The source whose candidate scored best (quotas count against it).
    public var source: CandidateSource
    public var sources: Set<CandidateSource>
    public var score: Double
    /// Also a common word (§E3 collision rule).
    public var isCollision: Bool
    /// Strong evidence: on screen now, corrected to, or in the matching surface's lexicon.
    public var hasStrongEvidence: Bool
}

/// Source weights, per surface class, within bounds (N28 adjusts them).
public struct RubricWeights: Sendable, Equatable, Codable {
    /// Multipliers per surface id (`SurfaceKind.id`) and source; 1 when absent.
    public var surfaceMultipliers: [String: [String: Double]]
    public static let bounds: ClosedRange<Double> = 0.5...1.5

    public init(surfaceMultipliers: [String: [String: Double]] = [:]) { self.surfaceMultipliers = surfaceMultipliers }

    public func multiplier(_ source: CandidateSource, surface: String) -> Double {
        let m = surfaceMultipliers[surface]?[source.rawValue] ?? 1
        return min(max(m, Self.bounds.lowerBound), Self.bounds.upperBound)
    }
}

/// The rubric. `ContextRubric.rank(candidates:surface:)` is the public contract.
public struct ContextRubric: Sendable {
    public struct Config: Sendable, Equatable {
        public var stableBudget = 200
        public var perTurnBudget = 50
        public var spellBudget = 60
        public var promptTermBudget = 40
        /// No single source takes more than this share of a budget while others have candidates.
        public var sourceQuota = 0.5
        /// Corrections' guaranteed share of the stable layer.
        public var correctionShare = 0.25
        public var collisionPenalty = 0.5
        public var halfLife: TimeInterval = 15 * 60
        public var neverUsedDictionaryWeight = 0.6
        /// F27: screen terms reach the per-turn boost layer only after the Lab measures a gain.
        public var screenTermsInBoost = false
        public var minBoostCharacters = BoostVocabulary.minCharacters
        public var maxTermCharacters = BoostVocabulary.maxCharacters
        public init() {}
        public static let `default` = Config()
    }

    public var config: Config
    public var weights: RubricWeights

    public init(config: Config = .default, weights: RubricWeights = RubricWeights()) {
        self.config = config
        self.weights = weights
    }

    /// The public contract (default config and starting weights).
    public static func rank(candidates: [ContextCandidate], surface: SurfaceResolution,
                            now: Date = Date(), app: String? = nil) -> RankedContext {
        ContextRubric().ranked(candidates: candidates, surface: surface, now: now, app: app)
    }

    // MARK: scoring

    static func isConversational(_ kind: SurfaceKind) -> Bool {
        switch kind {
        case .chatComposer, .emailBody: return true
        case .formField(let label): return ["recipient", "email", "name"].contains(label)
        default: return false
        }
    }

    static func lexiconMatches(_ c: ContextCandidate, _ kind: SurfaceKind) -> Bool {
        if let target = c.lexiconSurface {
            if target == kind { return true }
            // Folder entries and commands serve terminals and code editors alike.
            return c.type == .path && (kind == .terminal || kind == .codeEditor) && (target == .terminal || target == .codeEditor)
        }
        switch c.type {
        case .command: return kind == .terminal
        case .path: return kind == .terminal || kind == .codeEditor
        case .formulaFunction: return kind == .spreadsheetCell
        case .link: return kind == .urlBar
        case .techTerm: return kind == .codeEditor || kind == .terminal
        default: return false
        }
    }

    /// How well a type suits the surface, independent of source.
    static func typeFit(_ type: CandidateType, _ kind: SurfaceKind) -> Double {
        switch type {
        case .formulaFunction: return kind == .spreadsheetCell ? 1 : 0
        case .command: return kind == .terminal ? 1 : (kind == .codeEditor ? 0.5 : 0.2)
        case .link: return kind == .urlBar ? 1 : 0.8
        case .person: return [.terminal, .codeEditor, .spreadsheetCell, .urlBar].contains(kind) ? 0.3 : 1
        default: return 1
        }
    }

    /// Surface fit (§E3 "fit rule" column) × type fit. 0 = not admitted here.
    func surfaceFit(_ c: ContextCandidate, _ surface: SurfaceResolution, app: String?) -> Double {
        let kind = surface.kind
        if kind == .secure { return 0 }
        let sourceFit: Double
        switch c.source {
        case .correction, .dictionary, .screenNear, .screenWindow: sourceFit = 1
        case .surfaceLexicon: sourceFit = Self.lexiconMatches(c, kind) ? min(max(surface.confidence, 0.1), 1) : 0
        case .recentDictation: sourceFit = (app == nil || c.app == nil || c.app == app) ? 1 : 0
        case .participant: sourceFit = (kind == .chatComposer || kind == .emailBody) ? 1 : 0
        case .contact: sourceFit = ContactsChannelPolicy.admits(.contacts, channel: .boost, surface: kind) ? 1 : 0
        }
        guard sourceFit > 0 else { return 0 }
        // Lexicon terms are already matched to the surface; don't double-penalise their type.
        return c.source == .surfaceLexicon ? sourceFit : sourceFit * Self.typeFit(c.type, kind)
    }

    func closeness(_ c: ContextCandidate) -> Double {
        guard let d = c.caretDistance else { return 1 }
        return max(0.3, 1 - Double(min(d, 4_000)) / 4_000 * 0.7)
    }

    func freshness(_ c: ContextCandidate, now: Date) -> Double {
        if c.source.isTimeless { return 1 }
        let age = max(0, now.timeIntervalSince(c.observedAt))
        return max(0.05, pow(0.5, age / config.halfLife))
    }

    func weight(_ c: ContextCandidate, surface: SurfaceResolution) -> Double {
        let base = (c.source == .dictionary && c.neverUsed) ? config.neverUsedDictionaryWeight : c.source.startingWeight
        return base * weights.multiplier(c.source, surface: surface.kind.id)
    }

    /// The rubric's score for one candidate, before merging; `nil` = not admitted on this surface.
    public func score(_ c: ContextCandidate, surface: SurfaceResolution, now: Date = Date(), app: String? = nil)
        -> (score: Double, collision: Bool, strong: Bool)? {
        let fit = surfaceFit(c, surface, app: app)
        guard fit > 0, !c.text.isEmpty, c.text.count <= config.maxTermCharacters else { return nil }
        let raw = weight(c, surface: surface) * fit * closeness(c) * freshness(c, now: now) * max(0.05, c.evidence)
        let collision = c.type != .formulaFunction && CollisionLexicon.isCommonWord(c.text)
        let strong = c.onScreenNow || c.source == .correction || c.source == .surfaceLexicon
        let s = raw - ((collision && !strong) ? config.collisionPenalty : 0)
        return (s, collision, strong)
    }

    // MARK: ranking

    public func ranked(candidates: [ContextCandidate], surface: SurfaceResolution,
                       now: Date = Date(), app: String? = nil) -> RankedContext {
        guard surface.kind != .secure else { return .empty }
        var merged: [String: RubricTerm] = [:]
        var order: [String] = []
        for c in candidates {
            guard let (s, collision, strong) = score(c, surface: surface, now: now, app: app) else { continue }
            let key = c.text.lowercased()
            if var t = merged[key] {
                let best = max(t.score, s)
                if s > t.score { t.source = c.source; t.type = c.type }
                t.score = best + 0.25 * max(0, min(t.score, s))   // multi-source agreement
                t.sources.insert(c.source)
                t.hasStrongEvidence = t.hasStrongEvidence || strong
                if t.isCollision && t.hasStrongEvidence && t.score < s { t.score = s }
                if c.text.first?.isUppercase == true, t.text.first?.isUppercase != true { t.text = c.text }
                merged[key] = t
            } else {
                merged[key] = RubricTerm(text: c.text, type: c.type, source: c.source, sources: [c.source],
                                         score: s, isCollision: collision, hasStrongEvidence: strong)
                order.append(key)
            }
        }
        // A collision term with strong evidence from any source is not penalised.
        for (k, t) in merged where t.isCollision && t.hasStrongEvidence && t.score < 0 { merged[k]?.score = 0.01 }
        let all = merged.values.filter { $0.score > 0 }.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text
        }

        let boostable = all.filter { t in
            let letters = t.text.filter { $0.isLetter || $0.isNumber }.count
            return letters >= config.minBoostCharacters && (!t.isCollision || t.hasStrongEvidence)
        }
        let stableSources: Set<CandidateSource> = [.correction, .dictionary, .surfaceLexicon]
        let stablePool = boostable.filter { t in
            t.sources.contains { stableSources.contains($0) } && !(t.type == .path && t.sources == [.surfaceLexicon])
        }
        let stable = select(stablePool, budget: config.stableBudget,
                            guaranteed: Int((Double(config.stableBudget) * config.correctionShare).rounded()))
        let stableKeys = Set(stable.map { $0.text.lowercased() })
        let perTurnPool = boostable.filter { t in
            !stableKeys.contains(t.text.lowercased())
                && (config.screenTermsInBoost || !t.sources.allSatisfy(\.isScreen))
                && !t.sources.contains(where: { stableSources.contains($0) && $0 != .surfaceLexicon })
        }
        let perTurn = select(perTurnPool, budget: config.perTurnBudget, guaranteed: 0)

        let spellPool = all.filter { t in
            !t.sources.allSatisfy { $0.isScreen || $0 == .recentDictation }
                && (!t.isCollision || t.hasStrongEvidence)
        }
        let spell = select(spellPool, budget: config.spellBudget,
                           guaranteed: Int((Double(config.spellBudget) * config.correctionShare).rounded()))
        let promptPool = all.filter { $0.sources.contains { $0.isScreen || $0 == .participant } }
        let prompt = select(promptPool, budget: config.promptTermBudget, guaranteed: 0)

        // Legacy view for `PromptBuilder` / `BoostVocabulary` callers: everything admitted, by score.
        let legacy = all.prefix(RankedContext.defaultCap).map { t in
            RankedContextTerm(text: t.text, tier: Self.tier(t.source), score: t.score,
                              sources: Set(t.sources.map(\.contextSourceKind)))
        }
        var out = RankedContext(terms: Array(legacy), cap: RankedContext.defaultCap, considered: merged.count)
        out.stableLayer = stable
        out.perTurnLayer = perTurn
        out.spellList = spell.map(\.text)
        out.promptTerms = prompt.map(\.text)
        return out
    }

    static func tier(_ s: CandidateSource) -> ContextTier {
        switch s {
        case .correction, .dictionary: return .authored
        case .screenNear, .screenWindow, .surfaceLexicon: return .screen
        default: return .recent
        }
    }

    /// Quota-aware selection from a score-ordered pool: corrections first up to `guaranteed`, then
    /// score order with each source capped at `sourceQuota` of the budget, then leftover room
    /// back-filled in score order (the quota protects other sources' room; it never wastes it).
    func select(_ pool: [RubricTerm], budget: Int, guaranteed: Int) -> [RubricTerm] {
        guard budget > 0, !pool.isEmpty else { return [] }
        let quota = max(1, Int((Double(budget) * config.sourceQuota).rounded(.down)))
        var picked: [RubricTerm] = []
        var taken = Set<String>()
        var perSource: [CandidateSource: Int] = [:]
        func take(_ t: RubricTerm) {
            picked.append(t); taken.insert(t.text.lowercased()); perSource[t.source, default: 0] += 1
        }
        for t in pool where t.sources.contains(.correction) && picked.count < min(guaranteed, budget) { take(t) }
        for t in pool where picked.count < budget && !taken.contains(t.text.lowercased()) {
            if perSource[t.source, default: 0] < quota || t.source == .correction && perSource[.correction, default: 0] < max(quota, guaranteed) {
                take(t)
            }
        }
        for t in pool where picked.count < budget && !taken.contains(t.text.lowercased()) { take(t) }
        // Keep score order in the output (guaranteed corrections were taken first).
        return picked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }
    }
}
