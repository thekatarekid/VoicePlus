import Foundation
import Shared

/// P2.5 — one plain-English text box per app (Kivi's pattern), plus per-recipient overrides.
public struct Persona: Codable, Equatable, Sendable {
    public var appBundleID: String
    /// The plain-English instruction ("casual, lowercase, no sign-off").
    public var text: String
    /// True until the user edits the box; auto-drafts are refreshed as style learnings change,
    /// edited personas are never overwritten.
    public var isAutoDrafted: Bool
    /// Recipient key (see `PersonaRecipient.key`) → override instruction for that person/thread.
    public var recipientOverrides: [String: String]
    public var updatedAt: Date

    public init(appBundleID: String, text: String, isAutoDrafted: Bool = false,
                recipientOverrides: [String: String] = [:], updatedAt: Date = Date()) {
        self.appBundleID = appBundleID; self.text = text; self.isAutoDrafted = isAutoDrafted
        self.recipientOverrides = recipientOverrides; self.updatedAt = updatedAt
    }
}

/// Normalizes recipient identifiers so "Priya Kothari", "priya kothari " and
/// "Priya Kothari <priya@x.io>" resolve to stable keys. Emails win when present.
public enum PersonaRecipient {
    public static func key(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let at = lower.firstIndex(of: "@") {
            let local = lower[..<at].split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "+") }).last ?? ""
            let domain = lower[lower.index(after: at)...].split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }).first ?? ""
            if !local.isEmpty, !domain.isEmpty { return "\(local)@\(domain)" }
        }
        return GatekeeperTokenizer.words(lower).joined(separator: " ")
    }
}

/// Who is in the current thread (To/Cc, channel members, chat partner). Supplied by the app
/// layer's AX/Mail/Slack adapters; the default reads `StageContext.extra["thread.participants"]`.
public protocol ContextParticipants: Sendable {
    func participants(context: StageContext) -> [String]
}

public struct StageContextParticipants: ContextParticipants {
    public static let key = "thread.participants"
    public init() {}
    public func participants(context: StageContext) -> [String] {
        (context.extra[Self.key] ?? "").split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct StaticParticipants: ContextParticipants {
    public let names: [String]
    public init(_ names: [String]) { self.names = names }
    public func participants(context: StageContext) -> [String] { names }
}

/// Drafts the plain-English persona from Phase 1 style learnings. Only features the profile is
/// confident about (or that the category prior makes decisive) are mentioned; the result reads
/// like a sentence a person would write, never a form.
public enum PersonaDrafter {
    public static func draft(from p: StyleProfile) -> String {
        var parts: [String] = []
        switch p.category {
        case .mail: parts.append("Professional but warm email voice")
        case .chat: parts.append("Relaxed chat voice")
        case .code: return "Terse, technical voice; keep identifiers and casing exactly as spoken."
        case .terminal: return "Verbatim; no prose."
        case .prose: parts.append("Clear, natural prose")
        }
        let t = StyleStage.decisionThreshold
        if p.capitalizationRate <= t { parts.append("mostly lowercase") }
        if p.terminalPeriodRate <= t { parts.append("no trailing periods") }
        if p.emojiRate >= 0.25 { parts.append("an occasional emoji is fine") } else if p.category == .chat, p.emojiRate < 0.05, p.isConfident { parts.append("no emoji") }
        if p.avgSentenceLength <= 9 { parts.append("short sentences") } else if p.avgSentenceLength >= 20 { parts.append("longer, flowing sentences") }
        if p.greetingRate >= 1 - t, let g = p.preferredGreeting { parts.append("open with \"\(g)\"") } else if p.greetingRate <= t, p.category == .mail, p.isConfident { parts.append("skip greetings") }
        if p.signOffRate >= 1 - t, let s = p.preferredSignOff { parts.append("sign off with \"\(s)\"") } else if p.signOffRate <= t, p.category == .mail, p.isConfident { parts.append("no sign-off") }
        return parts.joined(separator: "; ") + "."
    }
}
