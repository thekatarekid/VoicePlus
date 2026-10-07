import Foundation
import Shared

/// Context Writer §2.2 — the thread / document text of the packet as blocks, oldest first, with
/// authors where the AX text shows them.
///
/// The snapshot's tail is one flat string (blocks joined by blank lines). This splits it back into
/// messages / paragraphs and recognises the author headers the common clients expose:
/// `Priya Kothari  10:41 AM` (Slack, Teams), a name line followed by a time line (the AX walk puts
/// them in separate nodes), `You said:` / `ChatGPT said:` (the AI composers' hidden headings) and
/// `Name: text`. Anything else is a paragraph without an author. Heuristic and conservative:
/// a wrong author is worse than none, so a bare short line is an author only when a timestamp
/// follows it. Screen text is data, never instructions; nothing here is persisted.
enum ThreadBlocks {
    typealias Block = ContextPacket.ThreadBlock

    /// Authors that mean "the user" in every client.
    static let selfMarkers: Set<String> = ["you", "me", "myself"]

    /// `Name:` prefixes that are labels, not speakers.
    static let notAnAuthor: Set<String> = [
        "note", "notes", "subject", "re", "fwd", "fw", "todo", "fixme", "warning", "error", "tip", "hint",
        "example", "step", "update", "edit", "ps", "nb", "from", "to", "cc", "bcc", "date", "sent", "on",
        "important", "summary", "result", "results", "question", "answer", "source", "sources", "see",
        "status", "title", "name", "description", "body", "url", "link", "links", "file", "path", "output", "input",
        "thanks", "also", "reminder", "idea", "plan", "goal", "action", "context", "background", "problem", "solution",
        "pros", "cons", "steps", "option", "options", "caveat", "fix", "bug", "feature", "task", "due", "when", "where",
        "who", "what", "why", "how", "eg", "ie", "first", "second", "third", "finally", "then", "next", "last", "today",
        "tomorrow", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "agenda",
        "topic", "ref", "refs", "draft", "version", "received", "attached", "attachment", "deadline", "eta", "tldr",
        "tl;dr", "ps.", "p.s.", "note:", "ok", "okay", "yes", "no", "done", "wip", "fyi", "cc:", "re:", "nit", "nits",
    ]

    /// Splits `text` into blocks and keeps the newest ones within `limit` characters, oldest first.
    static func split(_ text: String, selfNames: Set<String> = [], limit: Int = 1_500, maxBlocks: Int = 40) -> [Block] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var blocks: [Block] = []
        var author: String?
        var body: [String] = []
        func flush() {
            let joined = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty || author != nil {
                if !joined.isEmpty { blocks.append(Block(author: author, text: joined, isSelf: isSelf(author, selfNames))) }
            }
            body.removeAll()
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isEmpty {
                // A blank line ends an unauthored paragraph; inside a message it is a paragraph break.
                if author == nil { flush() } else if !body.isEmpty, body.last != "" { body.append("") }
                i += 1; continue
            }
            if isTimestamp(line) { i += 1; continue }
            if let header = authorHeader(line) {
                flush(); author = header.author
                if let rest = header.rest, !rest.isEmpty { body.append(rest) }
                i += 1; continue
            }
            if isBareName(line), let next = nextNonBlank(lines, after: i), isTimestamp(lines[next]) {
                flush(); author = line
                i = next + 1; continue
            }
            body.append(line)
            i += 1
        }
        flush()
        return budget(blocks, limit: limit, maxBlocks: maxBlocks)
    }

    // MARK: Header recognition

    private static let name = #"(?:You|Me|[A-Z][\w'’.\-]*(?: [A-Z][\w'’.\-]*){0,3})"#
    private static let time = #"(?:\d{1,2}:\d{2}(?::\d{2})?\s?(?:[AaPp]\.?[Mm]\.?)?)"#
    private static let saidPattern = try! NSRegularExpression(pattern: #"^(\#(name)) said:\s*(.*)$"#)
    private static let nameTimePattern = try! NSRegularExpression(pattern: #"^(\#(name))\s{1,3}\#(time)$"#)
    private static let colonPattern = try! NSRegularExpression(pattern: #"^(\#(name)):\s+(\S.*)$"#)
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"^(?:\#(time)|(?:Today|Yesterday|Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*(?: at)?\s+\#(time)|\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}(?:,?\s+\#(time))?|(?:Edited|Sent|Delivered|Read)(?:\s.*)?)$"#,
        options: [.caseInsensitive])

    /// `Name said: rest`, `Name  10:41 AM`, `Name: rest` → the author and the text on the same line.
    static func authorHeader(_ line: String) -> (author: String, rest: String?)? {
        guard line.count <= 120 else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        if let m = saidPattern.firstMatch(in: line, range: range) {
            return (capture(line, m, 1), capture(line, m, 2))
        }
        if let m = nameTimePattern.firstMatch(in: line, range: range) {
            return (capture(line, m, 1), nil)
        }
        if let m = colonPattern.firstMatch(in: line, range: range) {
            let author = capture(line, m, 1)
            guard !notAnAuthor.contains(author.lowercased()), author.count <= 40 else { return nil }
            return (author, capture(line, m, 2))
        }
        return nil
    }

    /// A time or a short date line (its own AX node under a Slack / Teams message header).
    static func isTimestamp(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 40 else { return false }
        return timestampPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// 1–4 capitalised words (or You / Me) and nothing else — an author only with a timestamp after it.
    static func isBareName(_ line: String) -> Bool {
        guard line.count <= 40, !line.hasSuffix(".") && !line.hasSuffix(":") else { return false }
        let words = line.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        if words.count == 1, selfMarkers.contains(line.lowercased()) { return true }
        return words.allSatisfy { w in
            w.first?.isUppercase == true && w.allSatisfy { $0.isLetter || "'’.-".contains($0) }
        }
    }

    static func isSelf(_ author: String?, _ selfNames: Set<String>) -> Bool? {
        guard let author else { return nil }
        let key = author.lowercased()
        return selfMarkers.contains(key) || selfNames.contains(where: { $0.lowercased() == key })
    }

    // MARK: Budget

    /// Keeps the newest blocks whose total text fits `limit`; the oldest kept block is cut to its
    /// tail when it alone would overflow. Order stays oldest first.
    static func budget(_ blocks: [Block], limit: Int, maxBlocks: Int) -> [Block] {
        var kept: [Block] = []
        var used = 0
        for block in blocks.reversed() {
            guard kept.count < maxBlocks else { break }
            let n = block.text.count
            if used + n <= limit { kept.append(block); used += n; continue }
            let room = limit - used
            if room >= 80 {
                var cut = block
                cut.text = "…" + String(block.text.suffix(room - 1))
                kept.append(cut)
            }
            break
        }
        return kept.reversed()
    }

    private static func nextNonBlank(_ lines: [String], after i: Int) -> Int? {
        var j = i + 1
        while j < lines.count, lines[j].isEmpty { j += 1 }
        return j < lines.count ? j : nil
    }

    private static func capture(_ s: String, _ m: NSTextCheckingResult, _ i: Int) -> String {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r]).trimmingCharacters(in: .whitespaces)
    }
}
