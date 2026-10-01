import Foundation
import Shared

/// Where an act-domain utterance goes. Deterministic catalogue first; the agent only for the unmatched tail.
public enum ActRoute: Equatable, Sendable {
    case stop                                   // sacred: kills anything in flight
    case confirm                                // spoken confirmation of a pending card
    case cancel                                 // spoken cancel of a pending card
    case deterministic(CatalogMatch, ActionRequest)
    case agentic(goal: String)
    case empty
    public var isDeterministic: Bool { if case .deterministic = self { return true }; return false }
    public var isAgentic: Bool { if case .agentic = self { return true }; return false }
}

/// Act-domain intent parse. No model call: control grammar → fuzzy catalogue match → agentic fallback.
public struct ActIntentParser: ActPreRouting {
    public let catalog: ActionCatalog
    public let activation: any ActDomainActivation
    public let threshold: Double
    /// Bundle id → app kind, so the catalogue can be scoped ("close tab" in Safari vs Xcode).
    public var appKinds: [String: ActionCategory]
    public static let stopWords: Set<String> = ["stop", "stop stop", "halt", "abort", "cancel that", "never mind", "nevermind"]
    /// Spoken prefixes that force the agent even when something in the catalogue would fuzzily match.
    static let agentPrefixes = ["can you ", "could you ", "please ", "i want you to "]

    public init(catalog: ActionCatalog, activation: any ActDomainActivation, threshold: Double = FuzzyMatch.defaultThreshold,
                appKinds: [String: ActionCategory] = ActIntentParser.defaultAppKinds) {
        self.catalog = catalog; self.activation = activation; self.threshold = threshold; self.appKinds = appKinds
    }

    public static let defaultAppKinds: [String: ActionCategory] = [
        "com.apple.Safari": .browser, "com.google.Chrome": .browser, "company.thebrowser.Browser": .browser, "org.mozilla.firefox": .browser,
        "com.microsoft.VSCode": .editor, "com.apple.dt.Xcode": .editor, "com.todesktop.cursor": .editor,
        "com.tinyspeck.slackmacgap": .chat, "com.hnc.Discord": .chat, "com.apple.MobileSMS": .chat,
        "com.apple.mail": .mail, "com.microsoft.Outlook": .mail, "com.apple.finder": .files,
    ]

    /// A captured argument that is itself a clause ("the invoice from march and forward it") is a goal, not a parameter.
    static func argumentIsCompound(_ arg: String?) -> Bool {
        guard let a = arg else { return false }
        let n = " \(FuzzyMatch.normalize(a)) "
        return [" and ", " then "].contains { n.contains($0) }
    }

    /// Inert unless the second key holds the act domain open.
    public func preRoute(_ text: String, appBundleID: String?) -> ActRoute? {
        guard activation.isActDomainActive else { return nil }
        return parse(text, appBundleID: appBundleID)
    }

    /// Domain-independent parse (used directly by the router once the act key is down).
    public func parse(_ text: String, appBundleID: String? = nil) -> ActRoute {
        let norm = FuzzyMatch.normalize(text)
        guard !norm.isEmpty else { return .empty }
        if Self.stopWords.contains(norm) { return .stop }
        if ConfirmationCard.isSpokenConfirm(norm) { return .confirm }
        if ConfirmationCard.isSpokenCancel(norm) { return .cancel }
        let forcedAgent = Self.isForcedAgent(text)
        // Multi-step phrasing ("… and then …", "… then …") is the agent's job, not a fuzzy single match.
        let multiStep = Self.isMultiStep(text)
        if !forcedAgent, !multiStep, let m = match(text, appBundleID: appBundleID, threshold: threshold),
           !Self.argumentIsCompound(m.argument) {
            return .deterministic(m, ActionRequest(m.entry, argument: m.argument))
        }
        return .agentic(goal: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: V5 CU6 · matching hygiene (found by measuring the 200 actions)

    /// Spoken lead-ins and tails that carry no action ("ok launch Preview", "close tab please").
    /// Without this "okay launch Preview" fuzzily matched *click OK*.
    static let leadingFillers: Set<String> = ["ok", "okay", "um", "uh", "erm", "so", "now", "hey", "alright", "right", "and"]
    static let trailingFillers: [[String]] = [["please"], ["now"], ["for", "me"], ["thanks"], ["thank", "you"]]
    static let numberWords: [String: String] = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
                                                "six": "6", "seven": "7", "eight": "8", "nine": "9"]

    /// `text` without leading fillers, and without trailing ones too. Never strips to nothing.
    static func strippedForms(_ text: String) -> (lead: String, both: String) {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func norm(_ w: String) -> String { FuzzyMatch.normalize(w) }
        while words.count > 1, leadingFillers.contains(norm(words[0])) { words.removeFirst() }
        let lead = words.joined(separator: " ")
        var changed = true
        while changed {
            changed = false
            for tail in trailingFillers where words.count > tail.count
                && Array(words.suffix(tail.count)).map(norm) == tail {
                words.removeLast(tail.count); changed = true
            }
        }
        return (lead, words.joined(separator: " "))
    }

    /// The catalogue match for an utterance: as spoken first (an exact phrasing such as "okay" wins),
    /// then without fillers, then with spoken numbers as digits ("desktop two"). A template's argument
    /// is captured from the text with only the lead-in removed, so a trailing word stays in it.
    public func match(_ text: String, appBundleID: String?, threshold: Double, among ids: Set<String>? = nil) -> CatalogMatch? {
        let appKind = appBundleID.flatMap { appKinds[$0] }
        func run(_ t: String) -> CatalogMatch? { catalog.match(t, appKind: appKind, threshold: threshold, among: ids) }
        var best = run(text)
        func consider(_ m: CatalogMatch?) { if let m, m.score > (best?.score ?? -1) { best = m } }
        if (best?.score ?? 0) < 1 {
            let (lead, both) = Self.strippedForms(text)
            if both != text {
                let m = run(both)
                if let m, m.phrasing.hasSuffix("{arg}"), lead != both { consider(run(lead)) } else { consider(m) }
            }
            if lead != text, lead != both { consider(run(lead)) }
            let digits = both.split(separator: " ").map { Self.numberWords[$0.lowercased()] ?? String($0) }.joined(separator: " ")
            if digits != both, let m = run(digits), !m.phrasing.hasSuffix("{arg}") { consider(m) }
        }
        guard var m = best else { return nil }
        m.utterance = text
        return m
    }
}

// MARK: - V5 CU4 · retrieval confirm (Layer 2)

/// A retrieved candidate the fuzzy matcher agreed with.
public struct RetrievalConfirmation: Equatable, Sendable {
    public let match: CatalogMatch
    public let cosine: Double
    public let fuzzy: Double
    /// `ActIntentParser.confirmScore(cosine:fuzzy:)`; executes directly at ≥ `retrievalExecuteScore`.
    public let score: Double
}

extension ActIntentParser {
    /// Confirm score at or above which a retrieved catalogue action runs without CUA-S1 or the planner.
    public static let retrievalExecuteScore = 0.8
    /// The fuzzy confirm: the retrieved candidate's words must agree with the utterance at least this
    /// much before its cosine counts (CU6: below 0.5 the embedding alone misfired — "shut tab" →
    /// "the pull request tab").
    public static let confirmGate = 0.5
    /// Lowest fuzzy score still computed for a retrieved candidate (below it the words share nothing).
    static let confirmFloor = 0.3

    /// "can you …", "please …": the speaker asked for the agent; the catalogue stays out of it.
    public static func isForcedAgent(_ text: String) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        return agentPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// "… and then …", "… then …", "… after that …": a multi-step goal, the planner's job.
    public static func isMultiStep(_ text: String) -> Bool {
        let norm = FuzzyMatch.normalize(text)
        return [" and then ", " then ", " after that "].contains { " \(norm) ".contains($0) }
    }

    /// Words and meaning must agree. A candidate whose words pass the fuzzy confirm (≥ `confirmGate`)
    /// scores its cosine (or its fuzzy score when that is higher); one that fails it scores only its
    /// fuzzy score, so meaning alone never executes anything. Measured on the CU6 set with the M16
    /// encoder: blending the two instead lost a third of the paraphrase gain for no fewer misfires.
    public static func confirmScore(cosine: Double, fuzzy: Double) -> Double {
        guard fuzzy >= confirmGate else { return fuzzy }
        return max(fuzzy, max(0, min(1, cosine)))
    }

    /// The fuzzy confirm of the retrieved top-k: per candidate entry, the catalogue matcher restricted
    /// to that entry (template arguments captured as usual), scored with the cosine. Best first.
    public func confirm(_ text: String, candidates: [CatalogCandidate], appBundleID: String?) -> RetrievalConfirmation? {
        guard !Self.isForcedAgent(text), !Self.isMultiStep(text) else { return nil }
        var best: RetrievalConfirmation?
        for c in candidates {
            guard let m = match(text, appBundleID: appBundleID, threshold: Self.confirmFloor, among: [c.entry.id]),
                  !Self.argumentIsCompound(m.argument) else { continue }
            // A template with nothing after its head has no argument to act on.
            if m.phrasing.hasSuffix("{arg}"), (m.argument ?? "").isEmpty { continue }
            let score = Self.confirmScore(cosine: c.cosine, fuzzy: m.score)
            if score > (best?.score ?? -1) { best = RetrievalConfirmation(match: m, cosine: c.cosine, fuzzy: m.score, score: score) }
        }
        return best
    }

    /// Layer 2 over an `.agentic` route: retrieve the top 3, confirm, and return `.deterministic` when
    /// the confirm score reaches `retrievalExecuteScore`; any other route comes back unchanged.
    ///
    /// With retrieval present a fuzzy-only match below `retrievalExecuteScore` (the 0.72–0.8 band) is
    /// no longer executed on its own: it must be confirmed like any retrieved candidate (its own entry
    /// competes with the top 3), else the utterance goes on to CUA-S1 / the planner. Without
    /// retrieval the catalogue keeps its P4.1 threshold.
    public func refine(_ route: ActRoute, appBundleID: String?, retrieval: CatalogRetrievalIndex?) async -> ActRoute {
        guard let retrieval else { return route }
        let goal: String
        var extra: [CatalogCandidate] = []
        switch route {
        case .agentic(let g):
            goal = g
        case .deterministic(let m, _) where m.score < Self.retrievalExecuteScore:
            guard let utterance = m.utterance else { return route }
            goal = utterance
            let cos = await retrieval.cosine(utterance, entryID: m.entry.id) ?? 0
            extra = [CatalogCandidate(entry: m.entry, phrasing: m.phrasing, cosine: cos)]
        default:
            return route
        }
        guard !Self.isForcedAgent(goal), !Self.isMultiStep(goal) else { return route }
        let top = await retrieval.top(goal, appKind: appBundleID.flatMap { appKinds[$0] })
        let candidates = extra + top.filter { c in !extra.contains { $0.entry.id == c.entry.id } }
        guard let c = confirm(goal, candidates: candidates, appBundleID: appBundleID),
              c.score >= Self.retrievalExecuteScore else {
            return .agentic(goal: goal.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .deterministic(c.match, ActionRequest(c.match.entry, argument: c.match.argument))
    }
}

extension ConsentRequest {
    /// Catalogue bridge: the catalogue's reversibility class is authoritative for catalogued actions (P4.1 rule table),
    /// so the base is the kind's reversible category and the catalogue class escalates via the P4.4 flags.
    /// Uncatalogued requests fall back to P4.4's own `ax.<kind>` bridge.
    public static func forAction(_ r: ActionRequest) -> ConsentRequest {
        var req = ConsentRequest(r)
        // Only ids from the shipped catalogue ("mac.…", "browser.…" …) are trusted; anything else keeps P4.4's conservative path.
        guard let id = r.catalogID, let head = id.split(separator: ".").first, ActionCategory(rawValue: String(head)) != nil else { return req }
        switch r.kind {
        case .click: req.category = .click; case .fillField: req.category = .fill; case .typeText: req.category = .type
        case .scroll: req.category = .scroll; case .openURL, .openFile: req.category = .open
        case .focusApp, .focusWindow, .focusTab, .switchSpace, .windowOp, .shortcut: req.category = .focus
        }
        return req
    }
}
