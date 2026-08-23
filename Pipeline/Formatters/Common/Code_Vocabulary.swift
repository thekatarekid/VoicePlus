import Foundation

/// Word lists and symbol tables for `CodeFormatter`. Prefixed `Code` to avoid collisions
/// with sibling formatter agents' Common helpers.
enum CodeVocabulary {
    enum CaseStyle { case camel, snake, kebab, pascal, constant }

    /// A spoken symbol: the word sequence that produces it and how it glues to neighbours.
    struct Symbol {
        let words: [String]
        let text: String
        let glueBefore: Bool
        let glueAfter: Bool
    }

    static let fillers: Set<String> = ["um", "umm", "uh", "uhm", "uhh", "er", "erm", "ah", "hmm", "hm", "mm", "mhm"]

    /// Words before a bare "no" that make it an ordinary word, not a correction marker.
    static let noNotCorrection: Set<String> = [
        "is", "are", "has", "have", "the", "a", "of", "with", "if", "return", "returns", "there", "be", "was", "were", "and", "or",
    ]

    /// English function words that end a spoken-identifier group ("camel case get user profile returns ...").
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "with", "returns", "return", "is", "are", "then", "that", "which",
        "in", "on", "at", "from", "as", "if", "else", "for", "while", "this", "it", "be", "by", "not", "into", "when",
        "should", "will", "was", "where", "equals", "equal", "nil", "null",
    ]

    /// Case-style commands, longest phrase first.
    static let caseCommands: [([String], CaseStyle)] = [
        (["screaming", "snake", "case"], .constant), (["upper", "camel", "case"], .pascal),
        (["constant", "case"], .constant), (["screaming", "snake"], .constant),
        (["camel", "case"], .camel), (["camelcase"], .camel), (["camel"], .camel),
        (["snake", "case"], .snake), (["snakecase"], .snake), (["snake"], .snake),
        (["kebab", "case"], .kebab), (["kebabcase"], .kebab), (["kebab"], .kebab), (["dash", "case"], .kebab),
        (["pascal", "case"], .pascal), (["pascalcase"], .pascal), (["pascal"], .pascal),
    ]

    /// Single-word casing commands: all caps / lowercase / capital.
    enum WordCase { case upper, lower, capital }
    static let wordCaseCommands: [([String], WordCase)] = [
        (["all", "caps"], .upper), (["upper", "case"], .upper), (["uppercase"], .upper), (["caps"], .upper),
        (["lower", "case"], .lower), (["lowercase"], .lower), (["capital"], .capital), (["capitalize"], .capital),
    ]

    /// Words that, when preceding a "slash", mean the slash starts a new path ("open /etc/hosts").
    static let pathPreceders: Set<String> = [
        "cd", "open", "cat", "ls", "vim", "vi", "nano", "rm", "cp", "mv", "mkdir", "touch", "source", "in", "at", "to",
        "from", "under", "into", "of", "run", "edit", "the", "and", "with", "is", "path", "grep", "find", "code", "chmod",
    ]

    static let symbols: [Symbol] = [
        // Multi-word first (matching is longest-first anyway, but keep readable).
        Symbol(words: ["less", "than", "or", "equal", "to"], text: "<=", glueBefore: false, glueAfter: false),
        Symbol(words: ["greater", "than", "or", "equal", "to"], text: ">=", glueBefore: false, glueAfter: false),
        Symbol(words: ["less", "than", "or", "equals"], text: "<=", glueBefore: false, glueAfter: false),
        Symbol(words: ["greater", "than", "or", "equals"], text: ">=", glueBefore: false, glueAfter: false),
        Symbol(words: ["open", "square", "bracket"], text: "[", glueBefore: true, glueAfter: true),
        Symbol(words: ["close", "square", "bracket"], text: "]", glueBefore: true, glueAfter: false),
        Symbol(words: ["open", "curly", "brace"], text: "{", glueBefore: false, glueAfter: false),
        Symbol(words: ["close", "curly", "brace"], text: "}", glueBefore: false, glueAfter: false),
        Symbol(words: ["open", "angle", "bracket"], text: "<", glueBefore: true, glueAfter: true),
        Symbol(words: ["close", "angle", "bracket"], text: ">", glueBefore: true, glueAfter: false),
        Symbol(words: ["does", "not", "equal"], text: "!=", glueBefore: false, glueAfter: false),
        Symbol(words: ["open", "paren"], text: "(", glueBefore: true, glueAfter: true),
        Symbol(words: ["left", "paren"], text: "(", glueBefore: true, glueAfter: true),
        Symbol(words: ["open", "parenthesis"], text: "(", glueBefore: true, glueAfter: true),
        Symbol(words: ["close", "paren"], text: ")", glueBefore: true, glueAfter: false),
        Symbol(words: ["right", "paren"], text: ")", glueBefore: true, glueAfter: false),
        Symbol(words: ["close", "parenthesis"], text: ")", glueBefore: true, glueAfter: false),
        Symbol(words: ["open", "bracket"], text: "[", glueBefore: true, glueAfter: true),
        Symbol(words: ["close", "bracket"], text: "]", glueBefore: true, glueAfter: false),
        Symbol(words: ["open", "brace"], text: "{", glueBefore: false, glueAfter: false),
        Symbol(words: ["close", "brace"], text: "}", glueBefore: false, glueAfter: false),
        Symbol(words: ["open", "curly"], text: "{", glueBefore: false, glueAfter: false),
        Symbol(words: ["close", "curly"], text: "}", glueBefore: false, glueAfter: false),
        Symbol(words: ["open", "angle"], text: "<", glueBefore: true, glueAfter: true),
        Symbol(words: ["close", "angle"], text: ">", glueBefore: true, glueAfter: false),
        Symbol(words: ["double", "equals"], text: "==", glueBefore: false, glueAfter: false),
        Symbol(words: ["equals", "equals"], text: "==", glueBefore: false, glueAfter: false),
        Symbol(words: ["triple", "equals"], text: "===", glueBefore: false, glueAfter: false),
        Symbol(words: ["not", "equals"], text: "!=", glueBefore: false, glueAfter: false),
        Symbol(words: ["not", "equal"], text: "!=", glueBefore: false, glueAfter: false),
        Symbol(words: ["bang", "equals"], text: "!=", glueBefore: false, glueAfter: false),
        Symbol(words: ["plus", "equals"], text: "+=", glueBefore: false, glueAfter: false),
        Symbol(words: ["minus", "equals"], text: "-=", glueBefore: false, glueAfter: false),
        Symbol(words: ["equal", "sign"], text: "=", glueBefore: false, glueAfter: false),
        Symbol(words: ["fat", "arrow"], text: "=>", glueBefore: false, glueAfter: false),
        Symbol(words: ["thick", "arrow"], text: "=>", glueBefore: false, glueAfter: false),
        Symbol(words: ["less", "than"], text: "<", glueBefore: false, glueAfter: false),
        Symbol(words: ["greater", "than"], text: ">", glueBefore: false, glueAfter: false),
        Symbol(words: ["plus", "plus"], text: "++", glueBefore: true, glueAfter: false),
        Symbol(words: ["double", "ampersand"], text: "&&", glueBefore: false, glueAfter: false),
        Symbol(words: ["and", "and"], text: "&&", glueBefore: false, glueAfter: false),
        Symbol(words: ["double", "pipe"], text: "||", glueBefore: false, glueAfter: false),
        Symbol(words: ["or", "or"], text: "||", glueBefore: false, glueAfter: false),
        Symbol(words: ["question", "mark"], text: "?", glueBefore: true, glueAfter: false),
        Symbol(words: ["exclamation", "mark"], text: "!", glueBefore: false, glueAfter: true),
        Symbol(words: ["exclamation", "point"], text: "!", glueBefore: false, glueAfter: true),
        Symbol(words: ["dollar", "sign"], text: "$", glueBefore: false, glueAfter: true),
        Symbol(words: ["at", "sign"], text: "@", glueBefore: false, glueAfter: true),
        Symbol(words: ["hash", "tag"], text: "#", glueBefore: false, glueAfter: true),
        Symbol(words: ["end", "quote"], text: "\"", glueBefore: true, glueAfter: false),
        Symbol(words: ["close", "quote"], text: "\"", glueBefore: true, glueAfter: false),
        Symbol(words: ["open", "quote"], text: "\"", glueBefore: false, glueAfter: true),
        Symbol(words: ["double", "quote"], text: "\"", glueBefore: false, glueAfter: false),
        Symbol(words: ["single", "quote"], text: "'", glueBefore: false, glueAfter: false),
        Symbol(words: ["back", "tick"], text: "`", glueBefore: false, glueAfter: false),
        Symbol(words: ["new", "line"], text: "\n", glueBefore: true, glueAfter: true),
        Symbol(words: ["empty", "array"], text: "[]", glueBefore: false, glueAfter: false),
        Symbol(words: ["empty", "list"], text: "[]", glueBefore: false, glueAfter: false),
        Symbol(words: ["empty", "dictionary"], text: "[:]", glueBefore: false, glueAfter: false),
        Symbol(words: ["empty", "dict"], text: "[:]", glueBefore: false, glueAfter: false),
        Symbol(words: ["empty", "string"], text: "\"\"", glueBefore: false, glueAfter: false),
        Symbol(words: ["empty", "object"], text: "{}", glueBefore: false, glueAfter: false),
        Symbol(words: ["divided", "by"], text: "/", glueBefore: false, glueAfter: false),
        Symbol(words: ["multiplied", "by"], text: "*", glueBefore: false, glueAfter: false),
        // Single words.
        Symbol(words: ["equals"], text: "=", glueBefore: false, glueAfter: false),
        Symbol(words: ["dash"], text: "-", glueBefore: false, glueAfter: true),
        Symbol(words: ["hyphen"], text: "-", glueBefore: false, glueAfter: true),
        Symbol(words: ["slash"], text: "/", glueBefore: true, glueAfter: true),
        Symbol(words: ["colon"], text: ":", glueBefore: true, glueAfter: false),
        Symbol(words: ["arrow"], text: "->", glueBefore: false, glueAfter: false),
        Symbol(words: ["dot"], text: ".", glueBefore: true, glueAfter: true),
        Symbol(words: ["period"], text: ".", glueBefore: true, glueAfter: true),
        Symbol(words: ["comma"], text: ",", glueBefore: true, glueAfter: false),
        Symbol(words: ["semicolon"], text: ";", glueBefore: true, glueAfter: false),
        Symbol(words: ["semi"], text: ";", glueBefore: true, glueAfter: false),
        Symbol(words: ["backslash"], text: "\\", glueBefore: true, glueAfter: true),
        Symbol(words: ["tilde"], text: "~", glueBefore: false, glueAfter: true),
        Symbol(words: ["dollar"], text: "$", glueBefore: false, glueAfter: true),
        Symbol(words: ["hash"], text: "#", glueBefore: false, glueAfter: true),
        Symbol(words: ["pound"], text: "#", glueBefore: false, glueAfter: true),
        Symbol(words: ["percent"], text: "%", glueBefore: false, glueAfter: false),
        Symbol(words: ["modulo"], text: "%", glueBefore: false, glueAfter: false),
        Symbol(words: ["mod"], text: "%", glueBefore: false, glueAfter: false),
        Symbol(words: ["ampersand"], text: "&", glueBefore: false, glueAfter: false),
        Symbol(words: ["pipe"], text: "|", glueBefore: false, glueAfter: false),
        Symbol(words: ["star"], text: "*", glueBefore: false, glueAfter: false),
        Symbol(words: ["asterisk"], text: "*", glueBefore: false, glueAfter: false),
        Symbol(words: ["times"], text: "*", glueBefore: false, glueAfter: false),
        Symbol(words: ["caret"], text: "^", glueBefore: false, glueAfter: false),
        Symbol(words: ["underscore"], text: "_", glueBefore: true, glueAfter: true),
        Symbol(words: ["plus"], text: "+", glueBefore: false, glueAfter: false),
        Symbol(words: ["minus"], text: "-", glueBefore: false, glueAfter: false),
        Symbol(words: ["bang"], text: "!", glueBefore: false, glueAfter: true),
        Symbol(words: ["quote"], text: "\"", glueBefore: false, glueAfter: true),
        Symbol(words: ["unquote"], text: "\"", glueBefore: true, glueAfter: false),
        Symbol(words: ["backtick"], text: "`", glueBefore: false, glueAfter: false),
        Symbol(words: ["newline"], text: "\n", glueBefore: true, glueAfter: true),
        Symbol(words: ["enter"], text: "\n", glueBefore: true, glueAfter: true),
    ]

    /// Longest symbol phrase, for lookahead bounds.
    static let maxSymbolWords = symbols.map(\.words.count).max() ?? 1

    /// Spoken forms of common identifiers / acronyms → canonical spelling.
    static let identifiers: [([String], String)] = [
        (["git", "hub"], "GitHub"), (["type", "script"], "TypeScript"), (["java", "script"], "JavaScript"),
        (["swift", "ui"], "SwiftUI"), (["i", "o", "s"], "iOS"), (["mac", "o", "s"], "macOS"), (["x", "code"], "Xcode"),
        (["std", "out"], "stdout"), (["std", "err"], "stderr"), (["std", "in"], "stdin"), (["reg", "ex"], "regex"),
        (["json"], "JSON"), (["html"], "HTML"), (["url"], "URL"), (["api"], "API"), (["http"], "HTTP"),
        (["https"], "HTTPS"), (["css"], "CSS"), (["sql"], "SQL"), (["uuid"], "UUID"), (["npm"], "npm"),
        (["github"], "GitHub"), (["typescript"], "TypeScript"), (["javascript"], "JavaScript"), (["xcode"], "Xcode"),
        (["swiftui"], "SwiftUI"), (["ios"], "iOS"), (["macos"], "macOS"), (["todo"], "TODO"), (["fixme"], "FIXME"),
    ]

    static let numberUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    static let numberTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let numberScales: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000]

    static func isNumberWord(_ key: String) -> Bool {
        numberUnits[key] != nil || numberTens[key] != nil || numberScales[key] != nil
    }

    /// Parses a run of number words ("one hundred twenty three") into an integer, or nil.
    static func parseNumber(_ keys: [String]) -> Int? {
        guard !keys.isEmpty else { return nil }
        var total = 0, current = 0
        for key in keys {
            if let unit = numberUnits[key] {
                current += unit
            } else if let tens = numberTens[key] {
                current += tens
            } else if let scale = numberScales[key] {
                if scale == 100 {
                    current = max(current, 1) * scale
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
            } else {
                return nil
            }
        }
        return total + current
    }

    static func apply(_ style: CaseStyle, to words: [String]) -> String {
        let lower = words.map { $0.lowercased() }
        switch style {
        case .camel:
            return lower.enumerated().map { $0.offset == 0 ? $0.element : $0.element.capitalized }.joined()
        case .pascal:
            return lower.map { $0.capitalized }.joined()
        case .snake:
            return lower.joined(separator: "_")
        case .kebab:
            return lower.joined(separator: "-")
        case .constant:
            return lower.joined(separator: "_").uppercased()
        }
    }
}
