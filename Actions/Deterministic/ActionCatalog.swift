import Foundation
import Shared

public enum ActionCategory: String, Codable, CaseIterable, Sendable { case mac, browser, editor, chat, mail, files }
public enum Reversibility: String, Codable, Sendable { case reversible, semi, irreversible }

/// What the action does, independent of app. `params` slots: `name`, `keys`, `value`, `direction`, `amount`, `target`, `op`, `move`.
public enum ActionKind: String, Codable, Sendable {
    case click, fillField, focusApp, focusWindow, focusTab, windowOp, switchSpace, scroll, shortcut, typeText, openURL, openFile
}

public struct CatalogEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let phrasings: [String]         // may end with "{arg}" to capture a trailing argument
    public let category: ActionCategory
    public let reversibility: Reversibility
    public let kind: ActionKind
    public let params: [String: String]
    /// App kinds the action applies to; empty = every app.
    public let apps: [ActionCategory]
    public init(id: String, phrasings: [String], category: ActionCategory, reversibility: Reversibility,
                kind: ActionKind, params: [String: String] = [:], apps: [ActionCategory] = []) {
        self.id = id; self.phrasings = phrasings; self.category = category; self.reversibility = reversibility
        self.kind = kind; self.params = params; self.apps = apps
    }
    public func applies(to appKind: ActionCategory) -> Bool { apps.isEmpty || apps.contains(appKind) }
}

public struct CatalogMatch: Equatable, Sendable {
    public let entry: CatalogEntry
    public let phrasing: String
    public let argument: String?
    public let score: Double
}

/// The 200-action catalogue (`Actions/Deterministic/catalog.json`).
public struct ActionCatalog: Sendable {
    public let entries: [CatalogEntry]
    private struct Indexed { let entry: CatalogEntry; let phrasing: String; let normalized: String; let isTemplate: Bool; let headTokens: Int }
    private let index: [Indexed]
    public init(entries: [CatalogEntry]) {
        self.entries = entries
        index = entries.flatMap { e in e.phrasings.map { p in
            let t = p.hasSuffix("{arg}"), head = t ? String(p.dropLast(5)) : p
            return Indexed(entry: e, phrasing: p, normalized: FuzzyMatch.normalize(head), isTemplate: t, headTokens: FuzzyMatch.tokens(head).count)
        } }
    }

    /// Bundle first, source checkout second: the `#filePath` copy does not exist on a user's Mac,
    /// so trying it first left the shipping lookup unexercised by every dev build.
    public static func defaultURL() -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("catalog.json"), FileManager.default.fileExists(atPath: r.path) { return r }
        var url = URL(fileURLWithPath: #filePath); url.deleteLastPathComponent()
        let local = url.appendingPathComponent("catalog.json")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        return nil
    }

    public static func load(from url: URL? = defaultURL()) throws -> ActionCatalog {
        guard let url else { throw ActionSystemError.notFound("catalog.json") }
        let entries = try JSONDecoder().decode([CatalogEntry].self, from: Data(contentsOf: url))
        return ActionCatalog(entries: entries)
    }

    public func entry(id: String) -> CatalogEntry? { entries.first { $0.id == id } }

    /// Resolve a spoken phrase to a catalogue entry. Exact/prefix/token/Levenshtein over every phrasing; `{arg}` templates capture the tail.
    public func match(_ phrase: String, appKind: ActionCategory? = nil, threshold: Double = FuzzyMatch.defaultThreshold) -> CatalogMatch? {
        let q = FuzzyMatch.normalize(phrase)
        var best: CatalogMatch?
        let qTokens = q.split(separator: " ").map(String.init)
        let rawTokens = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        for i in index where appKind.map(i.entry.applies(to:)) ?? true {
            let candidate: CatalogMatch?
            if i.isTemplate {
                guard let split = Self.splitArgument(tokens: qTokens, head: i.normalized, headTokens: i.headTokens, threshold: threshold) else { continue }
                candidate = CatalogMatch(entry: i.entry, phrasing: i.phrasing, argument: Self.rawArgument(rawTokens, after: i.headTokens) ?? split.arg, score: split.score)
            } else {
                let s = FuzzyMatch.score(query: q, candidate: i.normalized)
                candidate = s >= threshold ? CatalogMatch(entry: i.entry, phrasing: i.phrasing, argument: nil, score: s) : nil
            }
            if let c = candidate, c.score > (best?.score ?? 0) { best = c }
        }
        return best
    }

    /// The argument as spoken/typed (keeps "~/", ".", "@"): drop raw tokens until `n` normalized tokens have been consumed.
    private static func rawArgument(_ raw: [String], after n: Int) -> String? {
        var consumed = 0, i = 0
        while i < raw.count, consumed < n { consumed += FuzzyMatch.tokens(raw[i]).count; i += 1 }
        guard consumed == n, i < raw.count else { return nil }
        return raw[i...].joined(separator: " ")
    }

    /// "open url example dot com" vs head "open url": fuzzy-match the first N query tokens to the head, rest is the argument.
    /// Templates score slightly below exact full phrasings; longer heads beat shorter ones ("open url {arg}" over "open {arg}").
    private static func splitArgument(tokens qt: [String], head: String, headTokens n: Int, threshold: Double) -> (arg: String, score: Double)? {
        guard qt.count > n else { return nil }
        let s = FuzzyMatch.score(query: qt.prefix(n).joined(separator: " "), candidate: head)
        guard s >= threshold else { return nil }
        return (qt.dropFirst(n).joined(separator: " "), s * 0.96 + 0.004 * Double(min(n, 5)))
    }
}
