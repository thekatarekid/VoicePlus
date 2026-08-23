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
        let lowered = text.lowercased().trimmingCharacters(in: .whitespaces)
        let forcedAgent = Self.agentPrefixes.contains { lowered.hasPrefix($0) }
        // Multi-step phrasing ("… and then …", "… then …") is the agent's job, not a fuzzy single match.
        let multiStep = [" and then ", " then ", " after that "].contains { " \(norm) ".contains($0) }
        if !forcedAgent, !multiStep, let m = catalog.match(text, appKind: appBundleID.flatMap { appKinds[$0] }, threshold: threshold),
           !Self.argumentIsCompound(m.argument) {
            return .deterministic(m, ActionRequest(m.entry, argument: m.argument))
        }
        return .agentic(goal: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
