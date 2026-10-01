import Foundation
import Shared

/// V5 F2 — what the user taught VoicePlus, in one shape every generative prompt reads: the app's
/// persona (with recipient override), the user's Dictionary spellings, and the style habits learned
/// from their edits (F1). `PersonaManager.decorate` writes the parts into `StageContext.extra` under
/// plain string keys, so consumers in any module read them without an adapter or a Pipeline import:
///
/// | key                   | value                                                   | read by                        |
/// |-----------------------|---------------------------------------------------------|--------------------------------|
/// | `persona`             | `ResolvedPersona.promptText` (unchanged since P2.5)      | `PromptBuilder`, QA, transform |
/// | `personal.dictionary` | newline-separated Dictionary spellings (capped)         | D2 cleanup, D3 guard, CU8      |
/// | `personal.style`      | `; `-separated learned habits (only once confident)     | D2 cleanup, CU8                |
///
/// The prompt block is rendered at the point of use — `Personalisation.read(from: ctx).promptBlock`
/// (D2, in Pipeline) or the same three keys rendered by the consumer (CU8, in Actions) — never stored
/// pre-rendered, so an app rule that removes `persona` (Verbatim) or switches the style pass off
/// (`StyleStage.enabledKey = "false"`) removes it from every prompt too.
/// Nothing here leaves the Mac by itself; it only reaches a provider the user routed the stage to.
public struct Personalisation: Equatable, Sendable {
    public static let personaKey = PersonaManager.promptKey
    public static let dictionaryKey = "personal.dictionary"
    public static let styleKey = "personal.style"
    /// Upper bounds so a big Dictionary never crowds out the transcript.
    public static let maxTerms = 60
    public static let maxPromptCharacters = 1200
    public static let openTag = "<personalisation>", closeTag = "</personalisation>"

    public var persona: String?
    public var dictionary: [String]
    public var style: [String]

    public init(persona: String? = nil, dictionary: [String] = [], style: [String] = []) {
        self.persona = persona.map(Self.clean).flatMap { $0.isEmpty ? nil : $0 }
        var seen = Set<String>()
        self.dictionary = dictionary.map(Self.clean).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(Self.maxTerms).map { $0 }
        self.style = style.map(Self.clean).filter { !$0.isEmpty }
    }

    public var isEmpty: Bool { persona == nil && dictionary.isEmpty && style.isEmpty }

    /// Delimited block for a system prompt. Everything inside is the user's data, never instructions
    /// to follow beyond style; angle brackets are stripped so it cannot close the block early.
    public var promptBlock: String {
        guard !isEmpty else { return "" }
        var lines: [String] = []
        if let persona { lines.append("Writing instructions: \(persona)") }
        if !dictionary.isEmpty { lines.append("Spell these exactly as written: \(dictionary.joined(separator: ", "))") }
        if !style.isEmpty { lines.append("Habits learned from the user's edits (writing instructions win): \(style.joined(separator: "; "))") }
        var body = lines.joined(separator: "\n")
        let budget = Self.maxPromptCharacters - Self.openTag.count - Self.closeTag.count - 2
        if body.count > budget { body = String(body.prefix(budget)) }
        return "\(Self.openTag)\n\(body)\n\(Self.closeTag)"
    }

    /// Same context with the three keys filled in. Keys already present are kept (a test, the Lab
    /// or an earlier stage set them on purpose).
    public func apply(to context: StageContext) -> StageContext {
        var c = context
        func put(_ key: String, _ value: String) {
            if c.extra[key] == nil, !value.isEmpty { c.extra[key] = value }
        }
        put(Self.personaKey, persona ?? "")
        put(Self.dictionaryKey, dictionary.joined(separator: "\n"))
        put(Self.styleKey, style.joined(separator: "; "))
        return c
    }

    /// What a consumer sees in a decorated context.
    /// What a consumer sees in a decorated context. Learned style is withheld when the run's style
    /// pass is off (Verbatim app rule).
    public static func read(from context: StageContext) -> Personalisation {
        let styleOff = context.extra[StyleStage.enabledKey] == "false"
        return Personalisation(persona: context.extra[personaKey],
                               dictionary: (context.extra[dictionaryKey] ?? "").split(separator: "\n").map(String.init),
                               style: styleOff ? [] : (context.extra[styleKey] ?? "").components(separatedBy: "; "))
    }

    /// Habits stated in words, only for features the profile is confident about. Verbatim
    /// registers (code, terminal) have none: the style pass never touches them.
    public static func styleHints(from p: StyleProfile) -> [String] {
        guard p.isConfident, p.dictationCount > 0, p.category != .code, p.category != .terminal else { return [] }
        let t = StyleStage.decisionThreshold
        var out: [String] = []
        if p.capitalizationRate <= t { out.append("mostly lowercase") } else if p.capitalizationRate >= 1 - t { out.append("sentence case") }
        if p.terminalPeriodRate <= t { out.append("no trailing period") }
        if p.emojiRate >= 0.25 { out.append("uses emoji") }
        if p.avgSentenceLength <= 9 { out.append("short sentences") } else if p.avgSentenceLength >= 20 { out.append("long sentences") }
        if p.greetingRate >= 1 - t, let g = p.preferredGreeting { out.append("opens with \"\(g)\"") }
        if p.signOffRate >= 1 - t, let s = p.preferredSignOff { out.append("signs off with \"\(s)\"") }
        return out
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The user's Dictionary spellings, for prompts. Production: `DatabasePersonaStore` (same database);
/// tests: `StaticPersonalDictionary`.
public protocol PersonalDictionarySource: Sendable {
    func personalTerms() throws -> [String]
}

public struct StaticPersonalDictionary: PersonalDictionarySource {
    public var terms: [String]
    public init(_ terms: [String]) { self.terms = terms }
    public func personalTerms() throws -> [String] { terms }
}

extension DatabasePersonaStore: PersonalDictionarySource {
    public func personalTerms() throws -> [String] { try database.dictionaryTerms().map(\.term) }
}
