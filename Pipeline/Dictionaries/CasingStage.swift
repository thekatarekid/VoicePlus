import Foundation
import Shared

/// V5 P3 — lowercase key → canonical form ("github" → "GitHub", "postgresql" → "PostgreSQL").
///
/// Built from `casing.txt` (one canonical per line, `#` comments). The generator already drops any
/// name whose lowercase form is an English word, so a lexicon hit is never an ordinary word.
public struct CasingLexicon: Sendable, Equatable {
    public private(set) var canonical: [String: String] = [:]

    public init(lines: some Sequence<Substring>) {
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.contains(" ") else { continue }
            let key = line.lowercased()
            if canonical[key] == nil { canonical[key] = line }
        }
    }

    public init(text: String) { self.init(lines: text.split(whereSeparator: \.isNewline)) }
    public init(_ words: [String]) { self.init(text: words.joined(separator: "\n")) }

    public var count: Int { canonical.count }
    public var isEmpty: Bool { canonical.isEmpty }

    /// Canonical form of one word core, handling a plural or possessive suffix on a lexicon name
    /// ("iphones" → "iPhones", "github's" → "GitHub's"). Nil when the word is not a lexicon name.
    public func canonicalForm(of word: String) -> String? {
        let key = word.lowercased()
        if let hit = canonical[key] { return hit }
        for suffix in ["'s", "’s", "s'", "s"] where key.count > suffix.count + 1 && key.hasSuffix(suffix) {
            let stem = String(key.dropLast(suffix.count))
            if let hit = canonical[stem] { return hit + String(word.suffix(suffix.count)) }
        }
        return nil
    }

    /// First found: a downloaded/regenerated list in Application Support, the dev checkout's
    /// `Fixtures/dictionaries/casing.txt`, then the copy compiled into the app.
    public static func installed() -> CasingLexicon {
        var candidates = [PublicDictionaries.directory().appendingPathComponent("casing.txt")]
        if let fixtures = AppPaths.fixturesDirectory() {
            candidates.append(fixtures.appendingPathComponent("dictionaries/casing.txt"))
        }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let lexicon = CasingLexicon(text: text)
                if !lexicon.isEmpty { return lexicon }
            }
        }
        return bundled
    }

    /// The list compiled into the binary (`CasingLexicon+Bundled.swift`, generated from casing.txt).
    public static let bundled = CasingLexicon(text: bundledCasingList)
}

/// V5 P3 — fixes the case of exact-match tokens only. "i pushed it to github" → "… to GitHub".
///
/// - A token is the word between whitespace, minus edge punctuation; only a token whose lowercase
///   form is a lexicon key changes, and only its letters' case — never its spelling.
/// - Tokens with inner punctuation are left alone ("github.com", "foo-github").
/// - Code and terminal registers are verbatim (a lowercase `github` in a command is right).
/// - Bet 9: a low-confidence span is never re-cased (it is passed through, not flagged — case is
///   not a repair-worthy change).
public struct CasingStage: PipelineStage {
    public let id: StageID = .casing
    /// `StageContext.extra` key; "false" disables the stage for one run.
    public static let enabledKey = "dictionary.casing.enabled"
    private let lexicon: (@Sendable () -> CasingLexicon)

    public init(lexicon: CasingLexicon) { self.lexicon = { lexicon } }
    /// Default: the process-wide lexicon (`PublicDictionaries.shared.casing`), loaded on first use.
    public init() { self.lexicon = { PublicDictionaries.shared.casing } }

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        guard context.extra[Self.enabledKey] != "false",
              context.register != .code, context.register != .terminal else {
            return spans.map { $0.touched(by: id) }
        }
        let lexicon = lexicon()
        guard !lexicon.isEmpty else { return spans.map { $0.touched(by: id) } }
        return spans.map { span in
            guard !span.isLowConfidence, let fixed = Self.apply(lexicon, to: span.text) else { return span.touched(by: id) }
            return span.rewritten(fixed, by: id)
        }
    }

    /// The text with lexicon tokens re-cased, or nil when nothing changed.
    public static func apply(_ lexicon: CasingLexicon, to text: String) -> String? {
        var changed = false
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map { raw -> String in
            let (lead, core, trail) = TokenEdges.split(String(raw))
            guard core.count >= 2, core.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }),
                  let canonical = lexicon.canonicalForm(of: core), canonical != core,
                  canonical.lowercased() == core.lowercased() else { return String(raw) }
            changed = true
            return lead + canonical + trail
        }
        return changed ? tokens.joined(separator: " ") : nil
    }
}
