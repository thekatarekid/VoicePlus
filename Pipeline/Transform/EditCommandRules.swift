import Foundation

/// H7 — the deterministic executor for every D entry of `EditCommandCatalog`: pure string
/// functions, no model, instant. Each returns the new selection text; returning the selection
/// unchanged means "no change" (the pill says so; nothing is written).
public enum EditCommandRules {
    /// The action for a phrase-matched D entry.
    public static func action(for id: String, selection s: String) -> EditCommandAction {
        switch id {
        case "delete": return .delete
        case "cut": return .cut
        case "copy": return .copy
        case "undo": return .undo
        default: return .rewrite(rewrite(id, s) ?? s)
        }
    }

    /// The rewritten text for a phrase-matched D entry (nil for ids that are not rewrites).
    public static func rewrite(_ id: String, _ s: String) -> String? {
        switch id {
        case "wrap.quotes": return wrap(s, "\"", "\"")
        case "wrap.singleQuotes": return wrap(s, "'", "'")
        case "wrap.brackets": return wrap(s, "[", "]")
        case "wrap.parentheses": return wrap(s, "(", ")")
        case "wrap.braces": return wrap(s, "{", "}")
        case "wrap.backticks": return wrap(s, "`", "`")
        case "case.upper": return s.uppercased()
        case "case.lower": return s.lowercased()
        case "case.title": return titleCase(s)
        case "case.sentence": return sentenceCase(s)
        case "case.firstLetter": return capitalizeFirst(s)
        case "list.bullets": return keepingEdges(s) { items($0).map { "- \($0)" }.joined(separator: "\n") }
        case "list.numbered": return keepingEdges(s) { items($0).enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") }
        case "lines.join": return keepingEdges(s) { items($0).joined(separator: " ") }
        case "lines.split": return keepingEdges(s) { items($0).flatMap(sentences).joined(separator: "\n") }
        case "lines.removeBreaks": return keepingEdges(s) { $0.replacingOccurrences(of: "[ \\t]*\\n+[ \\t]*", with: " ", options: .regularExpression) }
        case "tidy.fillers": return removeFillers(s)
        case "tidy.spacing": return fixSpacing(s)
        case "tidy.trim": return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case "tidy.emojis": return removeEmojis(s)
        case "tidy.punctuation": return removePunctuation(s)
        case "tidy.fullStop": return addFullStop(s)
        case "md.bold": return wrap(s, "**", "**")
        case "md.italic": return wrap(s, "*", "*")
        case "md.strike": return wrap(s, "~~", "~~")
        case "md.heading": return keepingEdges(s) { $0.hasPrefix("#") ? $0 : "# " + $0 }
        case "md.codeBlock": return keepingEdges(s) { "```\n\($0)\n```" }
        case "md.link": return keepingEdges(s) { looksLikeURL($0) ? "<\($0)>" : "[\($0)]()" }
        default: return nil
        }
    }

    // MARK: Edges

    /// Applies `body` to the selection without its leading/trailing whitespace, then puts that
    /// whitespace back (a selection that grabbed a trailing space keeps it).
    static func keepingEdges(_ s: String, _ body: (String) -> String) -> String {
        let core = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, let r = s.range(of: core) else { return s }
        return String(s[..<r.lowerBound]) + body(core) + String(s[r.upperBound...])
    }

    static func wrap(_ s: String, _ open: String, _ close: String) -> String {
        keepingEdges(s) { open + $0 + close }
    }

    // MARK: Case

    static let minorWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "on", "at", "to",
                                          "by", "of", "in", "up", "as", "via", "per", "vs"]

    static func titleCase(_ s: String) -> String {
        var out: [String] = []
        let tokens = s.components(separatedBy: " ")
        let wordIdx = tokens.indices.filter { !tokens[$0].isEmpty }
        for (i, t) in tokens.enumerated() {
            guard !t.isEmpty else { out.append(t); continue }
            let bare = t.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let edge = i == wordIdx.first || i == wordIdx.last
            if !edge, minorWords.contains(bare) { out.append(t.lowercased()) } else { out.append(capitalizeFirst(t)) }
        }
        return out.joined(separator: " ")
    }

    static func sentenceCase(_ s: String) -> String {
        var out = ""
        var startOfSentence = true
        for ch in s.lowercased() {
            if startOfSentence, ch.isLetter { out += ch.uppercased(); startOfSentence = false; continue }
            out.append(ch)
            if ".!?\n".contains(ch) { startOfSentence = true }
        }
        return out.replacingOccurrences(of: "(?<![\\p{L}'])i(?=[\\s'’,.!?;:]|$)", with: "I", options: .regularExpression)
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter) else { return s }
        return String(s[..<i]) + s[i].uppercased() + String(s[s.index(after: i)...])
    }

    // MARK: Lists and lines

    static let markerPattern = "^\\s*(?:[-*•‣◦]|\\d+[.)]|\\[[ xX]\\])\\s+"

    /// List items: the selection's lines when it has several, else its sentences; existing
    /// bullets / numbers are dropped.
    static func items(_ s: String) -> [String] {
        let lines = s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let base = lines.count > 1 ? lines : sentences(s)
        return base.map { $0.replacingOccurrences(of: markerPattern, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            if ch == "\n" { flush(); continue }
            current.append(ch)
            // A sentence ends at . ! ? followed by whitespace or the end ("3.5" and "e.g." mid-word stay).
            if ".!?".contains(ch), i + 1 == chars.count || chars[i + 1].isWhitespace { flush() }
        }
        flush()
        return out
        func flush() {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
    }

    // MARK: Tidy

    static let fillerPatterns = ["you know", "i mean", "um+", "uh+", "uhm", "erm", "er", "ah", "hmm+", "mm+", "basically", "literally"]

    static func removeFillers(_ s: String) -> String {
        var t = s
        for f in fillerPatterns {
            t = t.replacingOccurrences(of: "(?<![\\p{L}'])\(f)(?![\\p{L}'])[,]?[ \\t]*", with: "", options: [.regularExpression, .caseInsensitive])
        }
        t = fixSpacing(t)
        // A sentence that started with a filler starts with a capital again.
        if let f = s.first(where: \.isLetter), f.isUppercase { t = capitalizeFirst(t) }
        return t
    }

    /// Collapses runs of spaces, drops spaces before , . ; : ! ?, adds one after , ; : before a
    /// letter, trims every line. Line breaks stay.
    static func fixSpacing(_ s: String) -> String {
        let lines = s.components(separatedBy: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            l = l.replacingOccurrences(of: "[ \\t]+([,.;:!?])", with: "$1", options: .regularExpression)
            l = l.replacingOccurrences(of: "([,;:])(\\p{L})", with: "$1 $2", options: .regularExpression)
            return l.trimmingCharacters(in: .whitespaces)
        }
        return keepingEdges(s) { _ in lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func isEmojiScalar(_ u: Unicode.Scalar) -> Bool {
        let p = u.properties
        if p.isEmojiPresentation { return true }
        if p.isEmoji, u.value > 0x238C { return true }
        return u.value == 0x200D || u.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains(u.value) || (0xE0020...0xE007F).contains(u.value)
    }

    static func removeEmojis(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars where !isEmojiScalar(u) { scalars.append(u) }
        let stripped = String(scalars)
        return stripped == s ? s : fixSpacing(stripped)
    }

    static func removePunctuation(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, ch) in chars.enumerated() {
            let isPunct = ch.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
            if isPunct {
                // Keep apostrophes inside words ("don't").
                let inWord = (ch == "'" || ch == "’") && i > 0 && i + 1 < chars.count && chars[i - 1].isLetter && chars[i + 1].isLetter
                if !inWord { continue }
            }
            out.append(ch)
        }
        return out == s ? s : keepingEdges(s) { _ in
            out.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func addFullStop(_ s: String) -> String {
        keepingEdges(s) { core in
            guard let last = core.last else { return core }
            if ".!?…".contains(last) { return core }
            if ",;:".contains(last) { return String(core.dropLast()) + "." }
            return core + "."
        }
    }

    static func looksLikeURL(_ s: String) -> Bool {
        !s.contains(" ") && (s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("www."))
    }

    // MARK: Arguments

    static func prepend(_ x: String, to s: String) -> String {
        let sep = (s.first?.isWhitespace ?? true) || (x.last?.isWhitespace ?? false) ? "" : " "
        return x + sep + s
    }

    static func append(_ x: String, to s: String) -> String {
        let noSpace = (s.last?.isWhitespace ?? true) || (x.first.map { ",.;:!?)".contains($0) } ?? false)
        return s + (noSpace ? "" : " ") + x
    }

    static func pattern(for a: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: a)
        let lead = a.first.map { $0.isLetter || $0.isNumber } == true ? "(?<![\\p{L}\\p{N}])" : ""
        let trail = a.last.map { $0.isLetter || $0.isNumber } == true ? "(?![\\p{L}\\p{N}])" : ""
        return try? NSRegularExpression(pattern: lead + escaped + trail, options: [.caseInsensitive])
    }

    /// Matches the case of the text it replaces: ALL CAPS stays caps, a capitalised word stays capitalised.
    static func matchCase(_ replacement: String, like found: String) -> String {
        let letters = found.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return replacement.uppercased() }
        if let f = found.first(where: \.isLetter), f.isUppercase { return capitalizeFirst(replacement) }
        return replacement
    }

    /// "replace A with B" inside the selection, every occurrence; nil when A does not occur.
    static func findReplace(_ a: String, with b: String, in s: String) -> String? {
        guard !a.isEmpty, let re = pattern(for: a) else { return nil }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var out = s
        for m in matches.reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: matchCase(b, like: String(out[r])))
        }
        return out
    }

    /// "swap A and B": every A becomes B and every B becomes A; nil unless both occur.
    static func swap(_ a: String, _ b: String, in s: String) -> String? {
        guard let ra = pattern(for: a), let rb = pattern(for: b) else { return nil }
        let full = NSRange(location: 0, length: (s as NSString).length)
        let hits = (ra.matches(in: s, range: full).map { ($0.range, b) } + rb.matches(in: s, range: full).map { ($0.range, a) })
            .sorted { $0.0.location < $1.0.location }
        guard hits.contains(where: { $0.1 == b }), hits.contains(where: { $0.1 == a }) else { return nil }
        var out = s
        var lastStart = Int.max
        for (range, replacement) in hits.reversed() where range.location + range.length <= lastStart {
            guard let r = Range(range, in: out) else { continue }
            out.replaceSubrange(r, with: matchCase(replacement, like: String(out[r])))
            lastStart = range.location
        }
        return out
    }
}
