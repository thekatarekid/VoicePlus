import Foundation
import Shared
#if canImport(AppKit)
import AppKit
#endif

public extension StageID {
    /// V5 P1 — macOS Text Replacements (System Settings › Keyboard › Text Replacements).
    static let textReplacement: StageID = "dictionary.replacement"
    /// V5 P3 — brand/tech casing of exact-match tokens.
    static let casing: StageID = "dictionary.casing"
    /// V5 P6 — script transliteration (LANG).
    static let transliteration: StageID = "dictionary.transliteration"
}

/// Where the shortcut → phrase table comes from. Must be cheap: called once per utterance.
public protocol TextReplacementSource: Sendable {
    func replacements() -> [String: String]
}

/// A fixed table (tests, Lab, an empty default).
public struct StaticTextReplacements: TextReplacementSource {
    public let table: [String: String]
    public init(_ table: [String: String] = [:]) { self.table = table }
    public func replacements() -> [String: String] { table }
}

/// V5 P1 — the user's macOS Text Replacements.
///
/// `NSSpellChecker.userReplacementsDictionary` is the documented reader; it belongs on the main
/// thread, so the table is read by `refresh()` (call it on main: at launch, when Settings opens) and
/// served from a cache to the pipeline, which runs off main. Off main, or before the first
/// refresh, the same table is read from the global `NSUserDictionaryReplacementItems` default the
/// spell checker itself reads — enabled items only.
public final class SystemTextReplacements: TextReplacementSource, @unchecked Sendable {
    public static let shared = SystemTextReplacements()
    private let lock = NSLock()
    private var cache: [String: String]?

    public init() {}

    public func replacements() -> [String: String] {
        if let cached = lock.withLock({ cache }) { return cached }
        let table = Self.readDefaults()
        lock.withLock { cache = table }
        return table
    }

    /// Re-read the table. On the main thread this asks `NSSpellChecker`; elsewhere the defaults.
    @discardableResult
    public func refresh() -> [String: String] {
        var table: [String: String] = [:]
        #if canImport(AppKit)
        if Thread.isMainThread {
            table = NSSpellChecker.shared.userReplacementsDictionary
        }
        #endif
        if table.isEmpty { table = Self.readDefaults() }
        lock.withLock { cache = table }
        return table
    }

    /// `NSUserDictionaryReplacementItems`: `[{replace, with, on}]` in the global domain.
    static func readDefaults() -> [String: String] {
        let items = UserDefaults(suiteName: UserDefaults.globalDomain)?
            .array(forKey: "NSUserDictionaryReplacementItems") as? [[String: Any]] ?? []
        return parse(items)
    }

    static func parse(_ items: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for item in items {
            guard let shortcut = item["replace"] as? String, let phrase = item["with"] as? String else { continue }
            if let on = item["on"] as? Int, on == 0 { continue }
            if let on = item["on"] as? Bool, !on { continue }
            out[shortcut] = phrase
        }
        return out
    }
}

/// V5 P1 — expands macOS Text Replacements. Runs after ITN (the formatters) and before cleanup.
///
/// Matching is whole-token and exact (case-insensitive, because the recogniser's casing is not the
/// user's), on word sequences inside one span: "omw" or "OMW" → "On my way!", never "omwx". Edge
/// punctuation the recogniser attached ("omw.") survives. A shortcut that is an ordinary word the
/// user also dictates is still the user's own rule — macOS expands it when typed, so do we.
/// Code and terminal registers are verbatim (macOS does not expand there either).
/// Bet 9: a low-confidence span holding a shortcut is flagged for repair, never rewritten.
public struct TextReplacementStage: PipelineStage {
    public let id: StageID = .textReplacement
    public let source: any TextReplacementSource
    /// `StageContext.extra` key; "false" disables the stage for one run.
    public static let enabledKey = "dictionary.replacement.enabled"

    public init(source: any TextReplacementSource = PublicDictionaries.shared.textReplacementSource) {
        self.source = source
    }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard context.extra[Self.enabledKey] != "false", !Self.isVerbatim(context) else {
            return spans.map { $0.touched(by: id) }
        }
        let table = Self.normalized(source.replacements())
        guard !table.isEmpty else { return spans.map { $0.touched(by: id) } }
        let maxWords = table.keys.map { $0.count }.max() ?? 1
        return spans.map { span in
            guard let replaced = Self.apply(table, maxWords: maxWords, to: span.text), replaced != span.text else {
                return span.touched(by: id)
            }
            return span.isLowConfidence ? span.flaggedForRepair(by: id) : span.rewritten(replaced, by: id)
        }
    }

    static func isVerbatim(_ context: StageContext) -> Bool {
        context.register == .code || context.register == .terminal
    }

    /// Shortcut word sequence (lowercased) → phrase. Empty shortcuts and phrases are dropped.
    static func normalized(_ table: [String: String]) -> [[String]: String] {
        var out: [[String]: String] = [:]
        for (shortcut, phrase) in table where !phrase.isEmpty {
            let words = shortcut.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            out[words] = phrase
        }
        return out
    }

    /// Longest-match-first replacement over whitespace tokens; nil when nothing matched.
    static func apply(_ table: [[String]: String], maxWords: Int, to text: String) -> String? {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out: [String] = []
        var i = 0
        var changed = false
        while i < tokens.count {
            var matched = false
            for n in stride(from: min(maxWords, tokens.count - i), through: 1, by: -1) {
                let window = Array(tokens[i..<(i + n)])
                let (lead, _, _) = TokenEdges.split(window.first!)
                let (_, _, trail) = TokenEdges.split(window.last!)
                let cores = window.map { TokenEdges.split($0).1.lowercased() }
                // Inner tokens must carry no edge punctuation: "on, my way" is not "on my way".
                let innerClean = window.enumerated().allSatisfy { k, token in
                    let (l, _, t) = TokenEdges.split(token)
                    return (k == 0 || l.isEmpty) && (k == window.count - 1 || t.isEmpty)
                }
                guard innerClean, !cores.contains(""), let phrase = table[cores] else { continue }
                out.append(lead + phrase + Self.trailing(trail, after: phrase))
                i += n
                matched = true
                changed = true
                break
            }
            if !matched { out.append(tokens[i]); i += 1 }
        }
        return changed ? out.joined(separator: " ") : nil
    }

    /// Keep the recogniser's trailing punctuation unless the phrase already ends in the same mark
    /// ("omw." → "On my way!" not "On my way!.").
    static func trailing(_ trail: String, after phrase: String) -> String {
        guard let last = phrase.last, ".!?".contains(last), let first = trail.first, ".!?".contains(first) else { return trail }
        return String(trail.dropFirst())
    }
}

/// Leading / core / trailing split of one whitespace token, so dictionary stages compare words, not
/// punctuation: `"(GitHub's),"` → `("(", "GitHub's", "),")`.
enum TokenEdges {
    static let leading: Set<Character> = ["\"", "'", "(", "[", "{", "“", "‘", "«", "¿", "¡"]
    static let trailing: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»", ".", ",", ";", ":", "!", "?", "…"]

    static func split(_ token: String) -> (String, String, String) {
        var core = Substring(token)
        var lead = ""
        while let c = core.first, leading.contains(c) { lead.append(c); core = core.dropFirst() }
        var trail = ""
        while let c = core.last, trailing.contains(c) { trail.insert(c, at: trail.startIndex); core = core.dropLast() }
        return (lead, String(core), trail)
    }
}
