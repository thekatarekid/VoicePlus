import Foundation
import Shared

/// P1.7 T6 — verbatim command register (Terminal, iTerm, VS Code terminal). Deterministic.
///
/// Spoken symbols become shell characters ("dash m" → `-m`, "tilde slash" → `~/`, "dollar home"
/// → `$HOME`, "pipe" → `|`), digit words join ("seven five five" → `755`), "in quotes …" wraps
/// literal text, fillers are removed. No smart punctuation, no capitalization: ASR sentence
/// punctuation and casing are stripped outside quotes.
///
/// Confidence contract (Bet 9): spans with `confidence < 0.5` are never rewritten or merged;
/// they are flagged `needsRepair` and act as hard boundaries. Removed words are never dropped —
/// their audioRange is merged into a neighbouring high-confidence span.
public struct TerminalFormatter: PipelineStage {
    public let id: StageID = .formatterTerminal

    public init() {}

    public func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        let shell = ShellContext(stageContext: context)
        return Self.format(spans, commands: CommandLexicon.commands(for: shell), shell: shell, stage: id)
    }

    /// N12 — the command-line grammar. `commands` is what the first word is validated against:
    /// the shell's real commands when the app read them (`ShellContext`), else the stand-in set.
    /// N13 — `shell.entries` (the current folder, listed only with the user's Settings OK) feed the
    /// path matcher; without them no folder name is ever guessed.
    static func format(_ spans: [TranscriptSpan], commands: Set<String>, shell: ShellContext? = nil, stage id: StageID) -> [TranscriptSpan] {
        var toks = spans.map { Tok($0, stage: id) }
        toks = Self.recoverCommand(toks, commands: commands)
        toks = Self.removeFillers(toks)
        toks = Self.resolveQuotes(toks, stage: id)
        toks = Self.resolveSymbols(toks)
        toks = Self.joinDigits(toks)
        toks = Self.resolveEnvVars(toks)
        toks = Self.markCommandPositions(toks, commands: commands)
        toks = Self.matchPaths(toks, entries: shell?.entries ?? [])
        toks = Self.glue(toks)
        return toks.map { $0.finished() }
    }

    /// Joins span texts for display: single spaces between spans.
    public static func render(_ spans: [TranscriptSpan]) -> String {
        spans.map(\.text).filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Token model

    enum Kind { case word, number, symbol, spaced, quoteOpen, quoteClose, quoted, literal }

    struct Tok {
        var span: TranscriptSpan
        var text: String
        var kind: Kind
        var glueLeft = false
        var glueRight = false
        /// True for numbers built from spoken digit words ("seven five five"); only those join.
        var spokenDigit = false
        /// True for a command word in command position ("cd" in `cd dot dot`, "grep" after a pipe).
        var commandPosition = false
        var editable: Bool

        init(_ span: TranscriptSpan, stage: StageID) {
            editable = !span.isLowConfidence
            self.span = editable ? span.touched(by: stage) : span.flaggedForRepair(by: stage)
            if editable {
                let t = TerminalFormatter.normalize(span.text)
                text = t
                kind = t.allSatisfy(\.isNumber) && !t.isEmpty ? .number : .word
            } else {
                // F9/N12 — a shell has no sentences: even a low-confidence word loses the
                // recogniser's sentence punctuation (the word itself is left as heard, flagged).
                var t = span.text
                let edge: Set<Character> = [".", ",", "!", "?", ";"]
                while let l = t.last, edge.contains(l), t.count > 1 { t.removeLast() }
                text = t
                kind = .literal
            }
        }

        func finished() -> TranscriptSpan {
            var s = span
            if editable { s.text = text }
            return s
        }
    }

    /// Strips ASR punctuation at word edges, straightens quotes, lowercases.
    static func normalize(_ word: String) -> String {
        var t = word.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        let edge: Set<Character> = [".", ",", "!", "?", ";", ":"]
        while let l = t.last, edge.contains(l) { t.removeLast() }
        while let f = t.first, edge.contains(f) { t.removeFirst() }
        return t.lowercased()
    }

    static func mergeSpans(_ a: TranscriptSpan, _ b: TranscriptSpan) -> TranscriptSpan {
        var out = a
        out.confidence = min(a.confidence, b.confidence)
        out.audioRange = min(a.audioRange.lowerBound, b.audioRange.lowerBound)...max(a.audioRange.upperBound, b.audioRange.upperBound)
        out.alternates = a.alternates + b.alternates
        out.needsRepair = a.needsRepair || b.needsRepair
        return out
    }

    /// Merges editable `toks[range]` into one token carrying `tok`'s text/kind/glue.
    static func merged(_ toks: [Tok], _ range: ClosedRange<Int>, as tok: Tok) -> Tok {
        var out = tok
        out.span = toks[range].dropFirst().reduce(toks[range.lowerBound].span) { mergeSpans($0, $1.span) }
        out.editable = true
        return out
    }

    static func allEditable(_ toks: [Tok], _ range: ClosedRange<Int>) -> Bool {
        range.lowerBound >= 0 && range.upperBound < toks.count && toks[range].allSatisfy(\.editable)
    }

    /// Longest phrase (≤ maxWords) of editable word tokens ending at `end` that `matches`.
    static func phrase(endingAt end: Int, in toks: [Tok], maxWords: Int, matches: (String) -> Bool) -> Int? {
        var best: Int?
        for length in 1...maxWords {
            let start = end - length + 1
            guard start >= 0, allEditable(toks, start...end), toks[start...end].allSatisfy({ [.word, .number, .quoted].contains($0.kind) }) else { break }
            if matches(toks[start...end].map(\.text).joined(separator: " ")) { best = start }
        }
        return best
    }

    // MARK: - Vocabulary

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "hmm", "hm", "er", "erm", "ah", "mhm"]

    struct Symbol { let text: String; let kind: Kind; let left: Bool; let right: Bool }
    static func both(_ t: String) -> Symbol { Symbol(text: t, kind: .symbol, left: true, right: true) }
    static func rightOnly(_ t: String) -> Symbol { Symbol(text: t, kind: .symbol, left: false, right: true) }
    static func leftOnly(_ t: String) -> Symbol { Symbol(text: t, kind: .symbol, left: true, right: false) }
    static func spaced(_ t: String) -> Symbol { Symbol(text: t, kind: .spaced, left: false, right: false) }

    static let symbols: [String: Symbol] = [
        "dash": rightOnly("-"), "hyphen": rightOnly("-"), "minus": rightOnly("-"),
        "dollar": rightOnly("$"), "dollar sign": rightOnly("$"), "tilde": rightOnly("~"),
        "open paren": rightOnly("("), "open parenthesis": rightOnly("("), "close paren": leftOnly(")"), "close parenthesis": leftOnly(")"),
        "open bracket": rightOnly("["), "close bracket": leftOnly("]"), "open brace": rightOnly("{"), "close brace": leftOnly("}"),
        "dot": both("."), "period": both("."), "slash": both("/"), "forward slash": both("/"),
        "backslash": both("\\"), "back slash": both("\\"), "underscore": both("_"), "colon": both(":"),
        "equals": both("="), "equal sign": both("="), "equals sign": both("="), "star": both("*"), "asterisk": both("*"),
        "at sign": both("@"), "at": both("@"), "hash": both("#"), "pound": both("#"), "percent": both("%"),
        "caret": both("^"), "backtick": both("`"),
        // N12 — "plus" is a symbol only with structure ("c plus plus" → `c++`) or a cue
        // ("plus sign"); a lone "plus" stays a word ("voice plus").
        "plus plus": leftOnly("++"), "plus sign": both("+"), "plus symbol": both("+"), "literal plus": both("+"),
        "question mark": leftOnly("?"), "bang": leftOnly("!"), "exclamation mark": leftOnly("!"), "exclamation point": leftOnly("!"),
        "semicolon": leftOnly(";"), "comma": leftOnly(","),
        "pipe": spaced("|"), "vertical bar": spaced("|"), "double pipe": spaced("||"), "or or": spaced("||"),
        "ampersand": spaced("&"), "double ampersand": spaced("&&"), "and and": spaced("&&"),
        "greater than": spaced(">"), "redirect to": spaced(">"), "less than": spaced("<"),
        "double greater than": spaced(">>"), "append to": spaced(">>"),
    ]
    static let maxSymbolWords = 3

    static let digits: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
    ]

    static let quoteOpeners: [String: String] = [
        "in quotes": "\"", "in quote": "\"", "open quote": "\"", "open quotes": "\"", "begin quote": "\"", "quote": "\"",
        "in single quotes": "'", "in single quote": "'", "single quote": "'", "single quotes": "'", "open single quote": "'",
    ]
    static let quoteClosers: Set<String> = ["end quote", "end quotes", "close quote", "close quotes", "unquote", "end of quote", "quote", "quotes"]

    /// Separators after which the next word is in command position.
    static let commandSeparators: Set<String> = ["|", "&&", "||", ";", "&"]
    // N12 — no hardcoded command list: command position is decided against `CommandLexicon`
    // (the shell's real commands when known), plus its sub-command and wrapper data.

    // MARK: - Passes

    static func removeFillers(_ toks: [Tok]) -> [Tok] {
        var out = toks
        var i = 0
        while i < out.count {
            guard out[i].editable, out[i].kind == .word, fillers.contains(out[i].text) else { i += 1; continue }
            if i > 0, out[i - 1].editable {
                out[i - 1] = merged(out, (i - 1)...i, as: out[i - 1]); out.remove(at: i)
            } else if i + 1 < out.count, out[i + 1].editable {
                out[i] = merged(out, i...(i + 1), as: out[i + 1]); out.remove(at: i + 1)
            } else {
                i += 1
            }
        }
        return out
    }

    static func resolveQuotes(_ toks: [Tok], stage: StageID) -> [Tok] {
        var out = toks
        var i = 0
        while i < out.count {
            guard let start = phrase(endingAt: i, in: out, maxWords: 3, matches: { quoteOpeners[$0] != nil }) else { i += 1; continue }
            let mark = quoteOpeners[out[start...i].map(\.text).joined(separator: " ")]!
            var opener = out[start]
            opener.text = mark; opener.kind = .quoteOpen; opener.glueRight = true; opener.glueLeft = false
            out.replaceSubrange(start...i, with: [merged(out, start...i, as: opener)])
            var j = start + 1
            var closed = false
            while j < out.count {
                if let cStart = phrase(endingAt: j, in: out, maxWords: 3, matches: { quoteClosers.contains($0) }), cStart > start {
                    var closer = out[cStart]
                    closer.text = mark; closer.kind = .quoteClose; closer.glueLeft = true; closer.glueRight = false
                    out.replaceSubrange(cStart...j, with: [merged(out, cStart...j, as: closer)])
                    closed = true
                    j = cStart + 1
                    break
                }
                if out[j].editable {
                    // Literal content: keep the spoken word's casing, strip only ASR edge punctuation.
                    var t = out[j].span.text
                    let edge: Set<Character> = [".", ",", "!", "?", ";", ":"]
                    while let l = t.last, edge.contains(l) { t.removeLast() }
                    out[j].text = t; out[j].kind = .quoted
                }
                j += 1
            }
            if !closed {
                let lastIndex = out.count - 1
                if out[lastIndex].editable {
                    out[lastIndex].text += mark
                } else {
                    let end = out[lastIndex].span.audioRange.upperBound
                    var synthetic = Tok(TranscriptSpan(text: mark, confidence: out[start].span.confidence, audioRange: end...end, provenance: [stage]), stage: stage)
                    synthetic.span.provenance = [stage]
                    synthetic.text = mark; synthetic.kind = .quoteClose; synthetic.glueLeft = true
                    out.append(synthetic)
                }
            }
            i = j
        }
        return out
    }

    static func resolveSymbols(_ toks: [Tok]) -> [Tok] {
        var out = toks
        var i = 0
        while i < out.count {
            if out[i].kind == .word, let start = phrase(endingAt: i, in: out, maxWords: maxSymbolWords, matches: { symbols[$0] != nil }) {
                let sym = symbols[out[start...i].map(\.text).joined(separator: " ")]!
                var tok = out[start]
                tok.text = sym.text; tok.kind = sym.kind; tok.glueLeft = sym.left; tok.glueRight = sym.right
                out.replaceSubrange(start...i, with: [merged(out, start...i, as: tok)])
                i = start + 1
            } else if out[i].kind == .word, out[i].editable, let d = digits[out[i].text] {
                out[i].text = d; out[i].kind = .number; out[i].spokenDigit = true
                i += 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func joinDigits(_ toks: [Tok]) -> [Tok] {
        var out = toks
        var i = 1
        while i < out.count {
            if out[i].spokenDigit, out[i - 1].spokenDigit {
                var tok = out[i - 1]
                tok.text += out[i].text
                out.replaceSubrange((i - 1)...i, with: [merged(out, (i - 1)...i, as: tok)])
            } else {
                i += 1
            }
        }
        return out
    }

    /// `dollar home` → `$HOME`; `export path equals …` → `export PATH=…`.
    static func resolveEnvVars(_ toks: [Tok]) -> [Tok] {
        var out = toks
        for i in out.indices where out[i].kind == .word && out[i].editable {
            let afterDollar = i > 0 && out[i - 1].text == "$" && out[i - 1].kind == .symbol
            let exported = i > 0 && out[i - 1].text == "export" && out[i - 1].kind == .word
                && i + 1 < out.count && out[i + 1].text == "=" && out[i + 1].kind == .symbol
            if afterDollar || exported { out[i].text = out[i].text.uppercased() }
        }
        return out
    }

    /// A command word is in command position at the start, after a separator, or right after
    /// another command-position word ("git add", "sudo rm"). `rm -rf node_modules`: "node" is not.
    static func markCommandPositions(_ toks: [Tok], commands: Set<String>) -> [Tok] {
        var out = toks
        var root: String?
        for i in out.indices {
            guard out[i].editable, out[i].kind == .word else { root = nil; continue }
            let word = out[i].text
            let prevIsSeparator = i == 0 || commandSeparators.contains(out[i - 1].text) && out[i - 1].kind != .word && out[i - 1].kind != .quoted
            if prevIsSeparator, commands.contains(word) {
                out[i].commandPosition = true; root = word
            } else if i > 0, out[i - 1].commandPosition, let r = root {
                if CommandLexicon.wrappers.contains(r) || CommandLexicon.wrappers.contains(out[i - 1].text), commands.contains(word) {
                    out[i].commandPosition = true; root = word
                } else if CommandLexicon.subcommands[r]?.contains(word) == true {
                    out[i].commandPosition = true
                }
            }
        }
        return out
    }

    /// N13 — folder and file names from the shell's current folder. Only on a line that starts
    /// with a real command, only on unquoted argument words. Silent replacement (`documents` →
    /// `Documents/`) needs a close match *and* an argument slot (right after the command or
    /// sub-command, after a flag, or after another matched path); anything else keeps the spoken
    /// words and carries the entry as a `.biasing` alternate (a suggestion). Never adds a Return.
    static func matchPaths(_ toks: [Tok], entries: [ShellContext.Entry]) -> [Tok] {
        guard !entries.isEmpty, toks.first?.commandPosition == true else { return toks }
        var out = toks
        var lastMatched = -1
        var i = 1
        func candidate(_ k: Int) -> Bool {
            k < out.count && out[k].editable && out[k].kind == .word && !out[k].commandPosition && !out[k].text.hasPrefix("-")
        }
        while i < out.count {
            guard candidate(i), !out[i - 1].glueRight else { i += 1; continue }
            var end = i
            while end + 1 < out.count, end - i < 3, candidate(end + 1) { end += 1 }
            let slot = isArgumentSlot(out, i, lastMatched: lastMatched)
            var applied = false
            var suggestion: ShellContext.Entry?
            for e in stride(from: end, through: i, by: -1) {
                let spoken = out[i...e].map(\.text).joined(separator: " ")
                switch PathMatcher.match(spoken, in: entries) {
                case .silent(let entry)? where slot:
                    let nextIsSlash = e + 1 < out.count && out[e + 1].kind == .symbol && out[e + 1].text == "/"
                    var tok = out[i]
                    tok.text = shellEscaped(entry.name) + (entry.isDirectory && !nextIsSlash ? "/" : "")
                    tok.kind = .word; tok.glueLeft = false; tok.glueRight = false
                    var m = merged(out, i...e, as: tok)
                    let original = out[i...e].map(\.span.text).joined(separator: " ")
                    m.span.alternates = [Alternate(text: original, score: m.span.confidence, source: .repair)]
                        + m.span.alternates.filter { $0.text != original }
                    out.replaceSubrange(i...e, with: [m])
                    applied = true
                case .silent(let entry)?, .suggest(let entry)?:
                    if suggestion == nil { suggestion = entry }
                case nil:
                    break
                }
                if applied { break }
            }
            if applied {
                lastMatched = i
            } else if let suggestion {
                let alt = Alternate(text: shellEscaped(suggestion.displayName), score: PathMatcher.suggestionScore, source: .biasing)
                if !out[i].span.alternates.contains(alt) { out[i].span.alternates.append(alt) }
            }
            i += 1
        }
        return out
    }

    /// An argument position a path can silently fill: right after the command or a sub-command,
    /// after a flag (`-la`, `--all`), or right after another matched path (`cp notes documents`).
    static func isArgumentSlot(_ toks: [Tok], _ i: Int, lastMatched: Int) -> Bool {
        let prev = toks[i - 1]
        if prev.commandPosition || lastMatched == i - 1 { return true }
        if prev.text.hasPrefix("-"), prev.kind == .word || prev.kind == .symbol, prev.text.count > 1 { return true }
        if prev.kind == .word, i >= 2, toks[i - 2].kind == .symbol, toks[i - 2].text.hasPrefix("-"), toks[i - 2].glueRight {
            return prev.text.count <= 3
        }
        return false
    }

    /// Backslash-escapes the characters a shell would split or interpret in a name.
    static func shellEscaped(_ name: String) -> String {
        let special: Set<Character> = [" ", "(", ")", "'", "\"", "&", ";", "|", "<", ">", "$", "`", "\\", "*", "?", "[", "]", "!", "#"]
        return String(name.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// N12 — "CD", "C D", "see dee" → `cd` because `cd` is a command this shell has (not because
    /// of a list of fixes). Only the first word, only spelled letters, only a real command.
    static func recoverCommand(_ toks: [Tok], commands: Set<String>) -> [Tok] {
        guard !toks.isEmpty, toks[0].editable, !commands.contains(toks[0].text) else { return toks }
        for length in stride(from: min(3, toks.count), through: 2, by: -1) {
            let range = 0...(length - 1)
            guard allEditable(toks, range) else { continue }
            let letters = toks[range].map { SpokenNumbers.letter($0.text) }
            guard letters.allSatisfy({ $0 != nil }) else { continue }
            let word = letters.compactMap { $0 }.joined()
            guard commands.contains(word) else { continue }
            var tok = toks[0]
            tok.text = word; tok.kind = .word
            var out = toks
            out.replaceSubrange(range, with: [merged(toks, range, as: tok)])
            return out
        }
        return toks
    }

    static func attaches(_ tok: Tok, after prev: Tok, next: Tok?) -> Bool {
        guard tok.editable, prev.editable else { return false }
        if tok.kind == .quoted, prev.kind == .quoted { return true }
        if prev.glueRight { return true }
        guard tok.glueLeft else {
            // Kebab-case dash: "--save dash dev" → `--save-dev`, "my dash file" → `my-file`. Only when a
            // multi-letter word follows; single letters are flags ("-l -a", "--oneline -n").
            guard tok.text == "-", tok.kind == .symbol, let next, next.editable, next.kind == .word, next.text.count >= 2 else { return false }
            if prev.text.hasPrefix("--"), prev.text.count > 2 { return true }
            return prev.kind == .word && !prev.commandPosition
        }
        if prev.kind == .spaced || prev.kind == .quoteClose { return false }
        if prev.kind == .word, prev.commandPosition { return false }
        return true
    }

    static func glue(_ toks: [Tok]) -> [Tok] {
        var out = toks
        var i = 1
        while i < out.count {
            let prev = out[i - 1], tok = out[i]
            if attaches(tok, after: prev, next: i + 1 < out.count ? out[i + 1] : nil) {
                var m = prev
                m.text = prev.text + (tok.kind == .quoted && prev.kind == .quoted ? " " : "") + tok.text
                m.glueRight = tok.glueRight
                m.kind = tok.kind == .quoted ? .quoted : (tok.kind == .quoteClose ? .quoteClose : .symbol)
                out.replaceSubrange((i - 1)...i, with: [merged(out, (i - 1)...i, as: m)])
            } else {
                i += 1
            }
        }
        return out
    }
}
