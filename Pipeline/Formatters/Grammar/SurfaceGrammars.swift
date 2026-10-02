import Foundation
import Shared

/// N12 / R3 §E5 — one grammar per surface kind, general for the kind and independent of the app.
///
/// `verbatim` answers "is the whole utterance a value this surface takes as-is?" (a formula, a
/// URL, a phone number) — when it is, that value replaces the formatter's output. `post` runs
/// after the formatter on surfaces that hold text (spoken-symbol structures, Markdown cues,
/// name capitals). Nothing here ever produces a Return: the only newline a grammar can emit is
/// none at all.
public enum SurfaceGrammar {
    public static let stageID: StageID = "grammar.surface"

    /// The whole utterance as one value, or `nil` to format normally.
    public static func verbatim(_ spans: [TranscriptSpan], surface: SurfaceKind) -> [TranscriptSpan]? {
        let words = GrammarTokens.words(spans)
        guard !words.isEmpty else { return nil }
        let text: String?
        switch surface {
        case .spreadsheetCell: text = FormulaGrammar.parse(words.map(\.core))
        case .urlBar: text = URLGrammar.parse(words.map(\.core))
        case .formField(let label):
            switch label {
            case "email", "recipient": text = URLGrammar.email(words.map(\.core))
            case "url": text = URLGrammar.parse(words.map(\.core))
            case "phone": text = FormFieldGrammar.phone(words.map(\.core))
            case "number": text = FormFieldGrammar.number(words.map(\.core))
            default: text = nil
            }
        default: text = nil
        }
        guard let text else { return nil }
        return GrammarTokens.replaceAll(spans, with: text, stage: stageID)
    }

    /// After the formatter, for surfaces that hold text.
    public static func post(_ spans: [TranscriptSpan], surface: SurfaceKind) -> [TranscriptSpan] {
        switch surface {
        case .terminal, .codeEditor, .secure, .canvas, .spreadsheetCell:
            return spans
        case .formField(let label) where label == "name":
            return FormFieldGrammar.capitalizeName(spans)
        case .formField(let label) where ["email", "url", "phone", "number", "recipient"].contains(label):
            return spans
        case .markdownEditor:
            return MarkdownGrammar.apply(SpokenSymbolGrammar.apply(spans))
        default:
            return SpokenSymbolGrammar.apply(spans)
        }
    }
}

// MARK: - Spreadsheet formulas

/// "equals sum a one to a ten" → `=SUM(A1:A10)`. Only an utterance that starts with "equals"
/// is a formula; without it a cell gets plain text (no period, handled by `FieldRules`).
enum FormulaGrammar {
    static let functions: [String: String] = [
        "sum": "SUM", "average": "AVERAGE", "avg": "AVERAGE", "mean": "AVERAGE", "min": "MIN", "minimum": "MIN",
        "max": "MAX", "maximum": "MAX", "count": "COUNT", "counta": "COUNTA", "if": "IF", "round": "ROUND",
        "abs": "ABS", "product": "PRODUCT", "median": "MEDIAN", "vlookup": "VLOOKUP", "xlookup": "XLOOKUP",
        "concat": "CONCAT", "concatenate": "CONCATENATE", "len": "LEN", "today": "TODAY", "now": "NOW",
        "and": "AND", "or": "OR", "not": "NOT", "sqrt": "SQRT", "power": "POWER", "upper": "UPPER",
        "lower": "LOWER", "trim": "TRIM", "sumif": "SUMIF", "countif": "COUNTIF", "averageif": "AVERAGEIF",
        "index": "INDEX", "match": "MATCH", "stdev": "STDEV", "rand": "RAND",
    ]
    static let operators: [[String]: String] = [
        ["plus"]: "+", ["minus"]: "-", ["times"]: "*", ["multiplied", "by"]: "*", ["divided", "by"]: "/",
        ["over"]: "/", ["to", "the", "power", "of"]: "^", ["percent"]: "%", ["greater", "than"]: ">",
        ["less", "than"]: "<", ["equals"]: "=", ["open", "paren"]: "(", ["close", "paren"]: ")",
    ]
    static let rangeWords: Set<String> = ["to", "through", "thru", "colon"]
    static let argWords: Set<String> = ["comma"]

    static func parse(_ raw: [String]) -> String? {
        var w = raw.filter { !$0.isEmpty }
        if w.first == "=" { w[0] = "equals" }
        guard let first = w.first, first == "equals" || first == "equal" else { return nil }
        var i = 1
        if i < w.count, w[i] == "to" || w[i] == "sign" { i += 1 }
        guard i < w.count else { return nil }
        var out = "=", open = 0, lastWasRef = false, inFunction = 0
        while i < w.count {
            let word = w[i]
            if let fn = functions[word], i + 1 >= w.count || w[i + 1] != "paren" {
                // "and" / "or" between arguments is a separator, not the function.
                if (word == "and" || word == "or"), inFunction > 0, lastWasRef || out.last?.isNumber == true {
                    out += ","; i += 1; lastWasRef = false; continue
                }
                out += fn + "("; open += 1; inFunction += 1; i += 1; lastWasRef = false
                if i < w.count, w[i] == "of" { i += 1 }
                continue
            }
            if let (ref, n) = cellRef(w, at: i) {
                out += ref; i += n; lastWasRef = true; continue
            }
            if rangeWords.contains(word), lastWasRef, cellRef(w, at: i + 1) != nil {
                out += ":"; i += 1; lastWasRef = false; continue
            }
            if argWords.contains(word), inFunction > 0 { out += ","; i += 1; lastWasRef = false; continue }
            if let (op, n) = op(w, at: i) {
                if op == ")" { guard open > 0 else { return nil }; open -= 1; inFunction = max(0, inFunction - 1) }
                if op == "(" { open += 1 }
                out += op; i += n; lastWasRef = false; continue
            }
            if let (value, n) = SpokenNumbers.cardinal(w, at: i) {
                var number = String(value)
                var j = i + n
                if j + 1 < w.count, w[j] == "point" {
                    var frac = ""
                    j += 1
                    while j < w.count, let d = SpokenNumbers.digits(w[j]) { frac += d; j += 1 }
                    guard !frac.isEmpty else { return nil }
                    number += "." + frac
                }
                out += number; i = j; lastWasRef = false; continue
            }
            if let d = Double(word) { out += word; _ = d; i += 1; lastWasRef = false; continue }
            return nil
        }
        guard out.count > 1 else { return nil }
        out += String(repeating: ")", count: open)
        return out
    }

    /// "a one" → A1, "b twelve" → B12, "a1" → A1, "see three" → C3.
    static func cellRef(_ w: [String], at i: Int) -> (String, Int)? {
        guard i < w.count else { return nil }
        let word = w[i]
        let letters = word.prefix(while: { $0.isASCII && $0.isLetter }), digits = word.dropFirst(letters.count)
        if (1...2).contains(letters.count), !digits.isEmpty, digits.count <= 7, digits.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return (letters.uppercased() + digits, 1)
        }
        if let letter = SpokenNumbers.letter(word), functions[word] == nil || word.count == 1,
           let (row, n) = SpokenNumbers.cardinal(w, at: i + 1), row > 0 {
            return (letter.uppercased() + String(row), 1 + n)
        }
        return nil
    }

    static func op(_ w: [String], at i: Int) -> (String, Int)? {
        for (phrase, symbol) in operators.sorted(by: { $0.key.count > $1.key.count })
        where i + phrase.count <= w.count && Array(w[i..<(i + phrase.count)]) == phrase {
            return (symbol, phrase.count)
        }
        return nil
    }
}

// MARK: - URL bar, links, addresses

/// "google dot com" → `google.com`. An utterance that does not parse as an address is a search
/// phrase (the formatter then gives it no period and no invented capital).
enum URLGrammar {
    static func parse(_ w: [String]) -> String? {
        let words = w.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        // Already written as one address by the recogniser ("google.com").
        if words.count == 1, words[0].contains("."), !words[0].contains(" "),
           let last = words[0].split(separator: ".").last, SpokenSymbolGrammar.suffixes.contains(String(last)) || words[0].contains("/") {
            return words[0]
        }
        guard let (text, end) = SpokenSymbolGrammar.url(words, at: 0, open: { _ in true }), end == words.count - 1 else { return nil }
        return text
    }

    static func email(_ w: [String]) -> String? {
        let words = w.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        if words.count == 1, words[0].contains("@") { return words[0] }
        guard let (text, end) = SpokenSymbolGrammar.email(words, at: 0, open: { _ in true }), end == words.count - 1 else { return nil }
        return text
    }
}

// MARK: - Label-typed form fields

/// The label decides the format: a phone box gets digits, a number box a number, a name box
/// capitals. A value that does not parse is left as heard.
enum FormFieldGrammar {
    static func phone(_ w: [String]) -> String? {
        var out = "", i = 0
        while i < w.count {
            let word = w[i]
            if word == "plus", out.isEmpty { out = "+"; i += 1; continue }
            if word == "dash" || word == "-" || word == "hyphen" { i += 1; continue }
            if word == "double" || word == "triple", i + 1 < w.count, let d = SpokenNumbers.digits(w[i + 1]), d.count == 1 {
                out += String(repeating: d, count: word == "double" ? 2 : 3); i += 2; continue
            }
            let cleaned = word.filter { $0.isNumber }
            if !cleaned.isEmpty, word.allSatisfy({ $0.isNumber || "()-+.".contains($0) }) { out += cleaned; i += 1; continue }
            if let d = SpokenNumbers.digits(word) { out += d; i += 1; continue }
            return nil
        }
        return out.filter(\.isNumber).count >= 3 ? out : nil
    }

    static func number(_ w: [String]) -> String? {
        if w.count == 1, Double(w[0].replacingOccurrences(of: ",", with: "")) != nil { return w[0] }
        var i = 0, out = ""
        if w.first == "minus" || w.first == "negative" { out = "-"; i = 1 }
        guard let (value, n) = SpokenNumbers.cardinal(w, at: i) else { return nil }
        out += String(value); i += n
        if i < w.count, w[i] == "point" {
            i += 1
            var frac = ""
            while i < w.count, let d = SpokenNumbers.digits(w[i]) { frac += d; i += 1 }
            guard !frac.isEmpty else { return nil }
            out += "." + frac
        }
        return i == w.count ? out : nil
    }

    /// "jane van der berg" → "Jane van der Berg"; particles stay lowercase, nothing else changes.
    static func capitalizeName(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        let particles: Set<String> = ["van", "der", "de", "da", "del", "von", "la", "le", "di", "bin", "al"]
        var first = true
        return spans.map { span in
            guard !span.isLowConfidence else { return span }
            let words = span.text.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
                var s = String(word)
                while let l = s.last, l == "." || l == "," { s.removeLast() }
                defer { first = false }
                guard let c = s.first, c.isLowercase, first || !particles.contains(s) else { return s }
                return c.uppercased() + s.dropFirst()
            }
            let text = words.joined(separator: " ")
            return text == span.text ? span : span.rewritten(text, by: SurfaceGrammar.stageID)
        }
    }
}

// MARK: - Markdown, only where the surface accepts it

/// "heading two release notes" → `## Release notes`; "bullet buy milk" → `- buy milk`;
/// "to do call mum" → `- [ ] call mum`; "link docs to example dot com" → `[docs](example.com)`.
/// Runs on `markdownEditor` only; everywhere else these words stay words.
enum MarkdownGrammar {
    static let levels: [String: Int] = ["one": 1, "two": 2, "three": 3, "1": 1, "2": 2, "3": 3]

    static func apply(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        let words = GrammarTokens.words(spans)
        guard !words.isEmpty else { return spans }
        var reps: [GrammarReplacement] = []
        let cores = words.map(\.core)
        // Line-start cues: only the first word of the utterance.
        if cores[0] == "heading" || cores[0] == "header", cores.count > 1 {
            var level = 1, end = 0
            if let l = levels[cores[1]], cores.count > 2 { level = l; end = 1 }
            reps.append(GrammarReplacement(range: 0...end, text: String(repeating: "#", count: level), keepTrail: false))
        } else if cores[0] == "bullet", cores.count > 1 {
            let end = cores[1] == "point" && cores.count > 2 ? 1 : 0
            reps.append(GrammarReplacement(range: 0...end, text: "-", keepTrail: false))
        } else if cores.count > 2, cores[0] == "to", cores[1] == "do" {
            reps.append(GrammarReplacement(range: 0...1, text: "- [ ]", keepTrail: false))
        }
        // Inline links: "link <one to four words> to <address>".
        var i = 0
        while i < cores.count {
            guard cores[i] == "link" else { i += 1; continue }
            var found = false
            for toIndex in (i + 2)..<min(cores.count, i + 6) where cores[toIndex] == "to" {
                let written = toIndex + 1 < cores.count ? URLGrammar.parse([cores[toIndex + 1]]).map { ($0, toIndex + 1) } : nil
                if let (url, end) = written ?? SpokenSymbolGrammar.url(cores, at: toIndex + 1, open: { _ in true }) {
                    let label = words[(i + 1)..<toIndex].map(\.text).joined(separator: " ")
                    reps.append(GrammarReplacement(range: i...end, text: "[\(label)](\(url))"))
                    i = end + 1; found = true
                    break
                }
            }
            if !found { i += 1 }
        }
        var out = GrammarTokens.apply(reps, to: spans, words: words, stage: SurfaceGrammar.stageID)
        // A heading carries no sentence period.
        if let first = reps.first, first.range.lowerBound == 0, first.text.hasPrefix("#"), var last = out.last,
           last.text.hasSuffix("."), !last.isLowConfidence {
            last.text.removeLast(); out[out.count - 1] = last
        }
        return out
    }
}
