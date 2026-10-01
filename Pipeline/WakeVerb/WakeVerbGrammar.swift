import Foundation
import Shared

/// P5.2 — leading-verb grammar for latched mode (Infina pattern): `"type …"`, `"send"`,
/// `"<appname> …"`. Deterministic; parsed before rules/Bayes via `WakeVerbPreRoute`.
public struct WakeVerbParse: Equatable, Sendable {
    /// V5 N2: `note` — "note …" / "take a note …" routes the payload into Notes instead of the field.
    public enum Kind: String, Codable, Sendable { case type, send, app, note }
    public var kind: Kind
    /// Matched leading token count (the wake phrase), e.g. 1 for "type", 2 for "in slack".
    public var verbTokenCount: Int
    public var payload: String
    public var appName: String?
}

public struct WakeVerbGrammar: Sendable {
    public static let typeVerbs: Set<String> = ["type", "write", "dictate", "insert"]
    public static let sendVerbs: Set<String> = ["send", "send it", "send that"]
    /// V5 N2 — the `typeVerbs` family's note route: "note buy milk", "take a note buy milk",
    /// "make a note: …", "jot down …". Multi-word phrases are matched longest first. "notes …" stays
    /// the Notes *app* prefix (`appNames`), so "notes add milk" is still an app parse.
    public static let noteVerbs: Set<String> = ["note", "take a note", "make a note", "note down", "jot down", "note to self"]
    public static let appPrefixes: Set<String> = ["in", "to", "tell"]
    /// Known app display names (lower-cased); multi-word names allowed, e.g. "visual studio code".
    public var appNames: [String]

    public init(appNames: [String] = ["slack", "mail", "messages", "notes", "safari", "terminal", "xcode"]) {
        self.appNames = appNames.map { $0.lowercased() }.sorted { $0.count > $1.count }
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    public func parse(_ text: String) -> WakeVerbParse? {
        let words = Self.tokens(text)
        guard let first = words.first else { return nil }
        if let n = Self.noteVerbTokenCount(words) {
            return WakeVerbParse(kind: .note, verbTokenCount: n, payload: Self.payload(text, dropping: n), appName: nil)
        }
        if Self.typeVerbs.contains(first), words.count > 1 {
            return WakeVerbParse(kind: .type, verbTokenCount: 1, payload: Self.payload(text, dropping: 1), appName: nil)
        }
        if first == "send", words.count <= 2, words.count == 1 || ["it", "that", "this"].contains(words[1]) {
            return WakeVerbParse(kind: .send, verbTokenCount: words.count, payload: "", appName: nil)
        }
        // "<appname> …" or "<in|to|tell> <appname> …"
        let start = Self.appPrefixes.contains(first) ? 1 : 0
        for app in appNames {
            let parts = app.split(separator: " ").map(String.init)
            guard words.count > start + parts.count, Array(words[start ..< start + parts.count]) == parts else { continue }
            let n = start + parts.count
            return WakeVerbParse(kind: .app, verbTokenCount: n, payload: Self.payload(text, dropping: n), appName: app)
        }
        return nil
    }

    /// Tokens of the longest note phrase the utterance starts with, when a payload follows it.
    static func noteVerbTokenCount(_ words: [String]) -> Int? {
        let phrases = noteVerbs.map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
        for parts in phrases where words.count > parts.count && Array(words.prefix(parts.count)) == parts {
            return parts.count
        }
        return nil
    }

    /// Original-casing payload after the first `n` word tokens.
    static func payload(_ text: String, dropping n: Int) -> String {
        var remaining = n
        var scalars = Substring(text)
        while remaining > 0 {
            scalars = scalars.drop(while: { !$0.isLetter && !$0.isNumber })
            scalars = scalars.drop(while: { $0.isLetter || $0.isNumber || $0 == "'" })
            remaining -= 1
        }
        return scalars.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",:;")))
    }
}
