import Foundation
import Shared

/// N24 — rich paste keyed on the resolver's surface kind (never on app names):
/// * a table into a spreadsheet cell → TSV plain text + an HTML `<table>`, so each value lands in
///   its own cell (Sheets, Numbers, Excel all read one of the two);
/// * Markdown into a Markdown editor (Notion, Obsidian, GitHub…) → pasted as Markdown text plus the
///   Markdown type, so the editor converts headings/lists/tables instead of receiving keystrokes; a
///   spoken TSV table becomes a Markdown pipe table there.
/// Every other surface gets `nil` (the ordinary write plan). Secure, terminal and chat surfaces
/// never get a payload, and the injector only asks after its secure-field / ladder checks passed.
public struct RichPastePayload: Equatable, Sendable {
    public enum Kind: String, Sendable { case spreadsheetTable, markdown }
    public var kind: Kind
    /// Pasteboard type → bytes. Always carries `public.utf8-plain-text`.
    public var types: [String: Data]

    public var plainText: String? { types[RichPaste.plainType].map { String(decoding: $0, as: UTF8.self) } }
    public var html: String? { types[RichPaste.htmlType].map { String(decoding: $0, as: UTF8.self) } }
}

public enum RichPaste {
    public static let plainType = "public.utf8-plain-text"
    public static let htmlType = "public.html"
    public static let markdownType = "net.daringfireball.markdown"

    /// The payload for `text` on `surface`, or `nil` when a plain write is right.
    /// `allowFormulas` — the speaker said "equals": a leading `=` stays a formula. Otherwise cells
    /// that a spreadsheet would run (`=`, `@`, a non-numeric `+`/`-`) are guarded with `'`.
    public static func payload(for text: String, surface: SurfaceKind?, allowFormulas: Bool = false) -> RichPastePayload? {
        guard let surface else { return nil }
        switch surface {
        case .spreadsheetCell:
            guard let rows = table(in: text) else { return nil }
            let guarded = rows.map { $0.map { FormulaGuard.guardCell($0, allowEquals: allowFormulas) } }
            let tsv = guarded.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            return RichPastePayload(kind: .spreadsheetTable,
                                    types: [plainType: Data(tsv.utf8), htmlType: Data(htmlTable(guarded).utf8)])
        case .markdownEditor:
            let markdown: String
            if let rows = tabSeparated(text) { markdown = markdownTable(rows) }
            else if looksLikeMarkdown(text) { markdown = text }
            else { return nil }
            return RichPastePayload(kind: .markdown,
                                    types: [plainType: Data(markdown.utf8), markdownType: Data(markdown.utf8)])
        default:
            return nil
        }
    }

    // MARK: Tables

    /// Rows × cells from a TSV block or a Markdown pipe table: ≥ 2 rows, ≥ 2 columns, rectangular.
    public static func table(in text: String) -> [[String]]? {
        tabSeparated(text) ?? pipeTable(text)
    }

    static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func tabSeparated(_ text: String) -> [[String]]? {
        let ls = lines(text)
        guard ls.count >= 2, ls.allSatisfy({ $0.contains("\t") }) else { return nil }
        let rows = ls.map { $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) } }
        guard let width = rows.first?.count, width >= 2, rows.allSatisfy({ $0.count == width }) else { return nil }
        return rows
    }

    static func pipeTable(_ text: String) -> [[String]]? {
        let ls = lines(text).map { $0.trimmingCharacters(in: .whitespaces) }
        guard ls.count >= 3, ls.allSatisfy({ $0.hasPrefix("|") }), isSeparator(ls[1]) else { return nil }
        let rows = ([ls[0]] + ls.dropFirst(2)).map(pipeCells)
        guard let width = rows.first?.count, width >= 2, rows.allSatisfy({ $0.count == width }) else { return nil }
        return rows
    }

    static func pipeCells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func isSeparator(_ line: String) -> Bool {
        let cells = pipeCells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func htmlTable(_ rows: [[String]]) -> String {
        let body = rows.map { "<tr>" + $0.map { "<td>\(escape($0))</td>" }.joined() + "</tr>" }.joined()
        return "<meta charset=\"utf-8\"><table>\(body)</table>"
    }

    static func markdownTable(_ rows: [[String]]) -> String {
        func line(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        let header = rows[0]
        let sep = "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"
        return ([line(header), sep] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Markdown

    /// Block-level Markdown worth converting: a heading, a list, a quote, a fence, a pipe table, or
    /// emphasis/links on a multi-line block. A single plain sentence is not.
    public static func looksLikeMarkdown(_ text: String) -> Bool {
        if pipeTable(text) != nil { return true }
        for raw in lines(text) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.range(of: #"^#{1,6} \S"#, options: .regularExpression) != nil { return true }
            if l.range(of: #"^([-*+]|\d+[.)]) \S"#, options: .regularExpression) != nil { return true }
            if l.hasPrefix("> ") || l.hasPrefix("```") { return true }
        }
        let multiline = lines(text).count > 1
        if multiline, text.range(of: #"\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^)\s]+\)"#, options: .regularExpression) != nil { return true }
        return false
    }
}

/// N24 — a spreadsheet runs a cell that starts with `=`, `@`, or a non-numeric `+`/`-`. Dictated
/// text should not become a formula unless the speaker said "equals".
public enum FormulaGuard {
    public static func needsGuard(_ cell: String, allowEquals: Bool) -> Bool {
        guard let first = cell.first else { return false }
        switch first {
        case "=": return !allowEquals
        case "@": return true
        case "+", "-":
            let rest = cell.dropFirst()
            guard let next = rest.first else { return false }      // a lone "-" is a dash
            if next == " " { return false }                        // "- item" is text, not an expression
            return Double(rest.replacingOccurrences(of: ",", with: "")) == nil
        default: return false
        }
    }

    public static func guardCell(_ cell: String, allowEquals: Bool) -> String {
        needsGuard(cell, allowEquals: allowEquals) ? "'" + cell : cell
    }
}

/// N24 — a marked (transient/auto-generated/concealed, N18) pasteboard write of several types.
/// Separate from `TransientPasteboardWriting` so existing conformers compile unchanged.
public protocol RichPasteboardWriting: AnyObject {
    /// Writes one item carrying `types` plus `PasteboardMarkers.all`; returns the changeCount.
    @discardableResult func writeTransientPasteboard(types: [String: Data]) -> Int
}
