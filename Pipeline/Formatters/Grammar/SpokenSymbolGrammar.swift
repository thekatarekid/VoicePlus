import Foundation
import Shared

/// N12 / R3 §E5 — spoken symbols need **structure or a cue**.
///
/// "slash", "dot", "dash", "plus", "at" and "colon" become symbols only when the words around
/// them form a URL, an email address, a file name, a path or a `X++` name, or when a cue word
/// says so ("plus sign", "literal slash"). Otherwise they stay words: "voice plus" stays
/// "voice plus", "slash the budget" stays prose. This replaces the fixed "always a symbol"
/// tables (F8's list, TerminalFormatter's "plus is always +").
public enum SpokenSymbolGrammar {
    public static let stageID: StageID = "grammar.symbols"

    /// Symbol words → the character, for cues and structure.
    static let symbolWords: [String: String] = [
        "slash": "/", "dot": ".", "dash": "-", "hyphen": "-", "plus": "+", "at": "@", "colon": ":",
        "underscore": "_", "tilde": "~", "hash": "#", "percent": "%", "ampersand": "&", "asterisk": "*",
        "star": "*", "equals": "=", "dollar": "$", "backslash": "\\", "pipe": "|", "caret": "^",
    ]
    /// Words after a symbol word that ask for the symbol ("plus sign", "at symbol").
    static let cueAfter: Set<String> = ["sign", "symbol", "character"]
    /// Words before a symbol word that ask for it ("literal slash").
    static let cueBefore: Set<String> = ["literal"]

    /// Top-level domains and file extensions: the last label of a dotted name must be one.
    static let suffixes: Set<String> = [
        "com", "org", "net", "io", "dev", "ai", "app", "co", "in", "uk", "us", "edu", "gov", "me", "info", "biz",
        "tv", "ly", "so", "sh", "xyz", "tech", "site", "online", "cloud", "page", "de", "fr", "jp", "ca", "au",
        "txt", "md", "swift", "py", "js", "ts", "tsx", "jsx", "json", "pdf", "doc", "docx", "xls", "xlsx", "csv",
        "png", "jpg", "jpeg", "gif", "svg", "html", "css", "yml", "yaml", "toml", "zip", "log", "rb", "go", "rs",
        "java", "kt", "c", "h", "cpp", "m", "mp3", "mp4", "mov", "wav", "key", "pages", "numbers", "env", "lock",
    ]
    /// Words that never act as a label of a dotted name.
    static let notLabels: Set<String> = ["plus", "dot", "slash", "at", "colon", "dash", "the", "a", "an", "and", "or", "to"]

    // MARK: - Entry points

    /// Prose-like surfaces: structures and cues inside running text.
    public static func apply(_ spans: [TranscriptSpan]) -> [TranscriptSpan] {
        let words = GrammarTokens.words(spans)
        guard words.contains(where: { symbolWords[$0.core] != nil }) else { return spans }
        let cores = words.map(\.core)
        var reps: [GrammarReplacement] = []
        var i = 0
        while i < words.count {
            if let (text, end) = structure(cores, words: words, at: i) {
                reps.append(GrammarReplacement(range: i...end, text: text)); i = end + 1; continue
            }
            i += 1
        }
        return GrammarTokens.apply(reps, to: spans, words: words, stage: stageID)
    }

    /// One structure starting at `i`: `(text, lastWordIndex)`.
    static func structure(_ cores: [String], words: [GrammarWord], at i: Int) -> (String, Int)? {
        // Interior punctuation (a comma, a sentence end) breaks a structure.
        func open(_ k: Int) -> Bool { words[k].trail.isEmpty }
        // Cues.
        if cueBefore.contains(cores[i]), i + 1 < cores.count, let s = symbolWords[cores[i + 1]], open(i) {
            return (s, i + 1)
        }
        if let s = symbolWords[cores[i]], i + 1 < cores.count, cueAfter.contains(cores[i + 1]), open(i) {
            return (s, i + 1)
        }
        // X++ ("c plus plus", "notepad plus plus").
        if i + 2 < cores.count, cores[i + 1] == "plus", cores[i + 2] == "plus", isLabel(cores[i]), open(i), open(i + 1),
           i + 3 >= cores.count || cores[i + 3] != "plus" {
            return (words[i].text + "++", i + 2)
        }
        if let url = url(cores, at: i, open: open) { return url }
        if let email = email(cores, at: i, open: open) { return email }
        if let path = path(cores, at: i, open: open) { return path }
        return nil
    }

    static func isLabel(_ w: String) -> Bool {
        !w.isEmpty && !notLabels.contains(w) && w.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// `label (dot label)+` ending in a known suffix: `(text, last index)`.
    static func dotted(_ cores: [String], at i: Int, open: (Int) -> Bool) -> (String, Int)? {
        guard i < cores.count, isLabel(cores[i]) else { return nil }
        var text = cores[i], j = i, best: (String, Int)?
        while j + 2 < cores.count, cores[j + 1] == "dot", isLabel(cores[j + 2]), open(j), open(j + 1) {
            text += "." + cores[j + 2]; j += 2
            if suffixes.contains(cores[j]) { best = (text, j) }
        }
        return best
    }

    /// `[https colon slash slash] [www dot] name.tld [colon port] [slash segment]*`.
    static func url(_ cores: [String], at i: Int, open: (Int) -> Bool) -> (String, Int)? {
        var j = i, prefix = ""
        if ["https", "http"].contains(cores[i]), i + 3 < cores.count, cores[i + 1] == "colon",
           cores[i + 2] == "slash", cores[i + 3] == "slash", (i...(i + 2)).allSatisfy(open) {
            prefix = cores[i] + "://"; j = i + 4
        }
        guard let (host, hostEnd) = dotted(cores, at: j, open: open) else { return nil }
        var text = prefix + host, end = hostEnd
        // An email's domain is not a URL.
        if i > 0, cores[i - 1] == "at" { return nil }
        if end + 2 < cores.count, cores[end + 1] == "colon", let port = Int(cores[end + 2]), open(end), open(end + 1) {
            text += ":\(port)"; end += 2
        }
        while end + 2 < cores.count, cores[end + 1] == "slash", isLabel(cores[end + 2]), open(end), open(end + 1) {
            if let (seg, segEnd) = dotted(cores, at: end + 2, open: open) { text += "/" + seg; end = segEnd }
            else { text += "/" + cores[end + 2]; end += 2 }
        }
        return (text, end)
    }

    /// `local [dot local]* at domain.tld`.
    static func email(_ cores: [String], at i: Int, open: (Int) -> Bool) -> (String, Int)? {
        guard isLabel(cores[i]) else { return nil }
        var local = cores[i], j = i
        while j + 2 < cores.count, ["dot", "underscore", "dash"].contains(cores[j + 1]), isLabel(cores[j + 2]), open(j), open(j + 1) {
            local += symbolWords[cores[j + 1]]! + cores[j + 2]; j += 2
        }
        guard j + 1 < cores.count, cores[j + 1] == "at", open(j), open(j + 1),
              let (domain, end) = dotted(cores, at: j + 2, open: open) else { return nil }
        return (local + "@" + domain, end)
    }

    /// A path: it starts at a root (`slash`, `tilde slash`, `dot slash`, `dot dot slash`) or has
    /// two or more slashes, or one of its segments is a file name. One bare "slash" between two
    /// words is not enough ("slash the budget", "documents slash voice plus" stay words).
    static func path(_ cores: [String], at i: Int, open: (Int) -> Bool) -> (String, Int)? {
        var text = "", j = i, rooted = false
        if cores[i] == "tilde", i + 1 < cores.count, cores[i + 1] == "slash", open(i) { text = "~/"; j = i + 2; rooted = true }
        else if cores[i] == "dot", i + 2 < cores.count, cores[i + 1] == "dot", cores[i + 2] == "slash", open(i), open(i + 1) { text = "../"; j = i + 3; rooted = true }
        else if cores[i] == "dot", i + 1 < cores.count, cores[i + 1] == "slash", open(i) { text = "./"; j = i + 2; rooted = true }
        guard j < cores.count, isLabel(cores[j]) else { return nil }
        var slashes = rooted ? 1 : 0, hasFile = false, end = j
        if let (seg, segEnd) = dotted(cores, at: j, open: open) { text += seg; end = segEnd; hasFile = true }
        else { text += cores[j]; end = j }
        while end + 2 < cores.count, cores[end + 1] == "slash", isLabel(cores[end + 2]), open(end), open(end + 1) {
            slashes += 1
            if let (seg, segEnd) = dotted(cores, at: end + 2, open: open) { text += "/" + seg; end = segEnd; hasFile = true }
            else { text += "/" + cores[end + 2]; end += 2 }
        }
        guard slashes >= 2 || (rooted && end >= j) || (slashes >= 1 && hasFile) else { return nil }
        return (text, end)
    }

}
