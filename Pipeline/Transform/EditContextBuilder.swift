import Foundation
import Shared

/// H15 — where an LLM edit lands, as labelled metadata for the model: app name, window title,
/// field label and surface kind. Screen text: data, never instructions (fenced in the prompt).
/// In memory only — never persisted or logged as text.
public struct EditDestination: Equatable, Sendable, Codable {
    public var appName: String?
    public var windowTitle: String?
    public var fieldLabel: String?
    /// Plain word for the surface ("chat", "email", "document", "code"…), from `SurfaceKind`.
    public var surface: String?

    public init(appName: String? = nil, windowTitle: String? = nil, fieldLabel: String? = nil, surface: String? = nil) {
        self.appName = Self.clean(appName); self.windowTitle = Self.clean(windowTitle)
        self.fieldLabel = Self.clean(fieldLabel); self.surface = Self.clean(surface)
    }

    public var isEmpty: Bool { appName == nil && windowTitle == nil && fieldLabel == nil && surface == nil }

    /// Labelled lines for the prompt (`App: Mail`), in a fixed order; empty fields are left out.
    public var lines: [String] {
        [("App", appName), ("Window", windowTitle), ("Field", fieldLabel), ("Surface", surface)]
            .compactMap { label, value in value.map { "\(label): \($0)" } }
    }

    /// One line each, bounded: a title or label never carries a page of text into the prompt.
    static let maxValueLength = 120

    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let flat = s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > maxValueLength ? String(flat.prefix(maxValueLength)) + "…" : flat
    }
}

/// H15 — the context an LLM edit sees: the sentence and paragraph around the selection plus the
/// previous paragraph, aligned to sentence boundaries and capped at ~1,200 tokens
/// (`TransformRequest.contextTokenCap`), plus `EditDestination`. A secure field yields nothing.
public enum EditContextBuilder {
    /// At most this many UTF-16 units are looked at either side of the selection — a paragraph
    /// longer than this is cut and then re-aligned to a sentence boundary.
    public static let scanLimit = 8_000

    /// The text before and after `selectedRange` in `value` (UTF-16 range, AX convention):
    /// before = previous non-blank paragraph + the current paragraph up to the selection;
    /// after = the current paragraph after the selection. Paragraphs end at line breaks.
    /// Sentence-aligned and within `cap` tokens; the text nearest the selection is kept.
    public static func surrounding(value: String, selectedRange: Range<Int>,
                                   cap: Int = TransformRequest.contextTokenCap) -> (before: String, after: String) {
        let units = Array(value.utf16)
        guard selectedRange.lowerBound >= 0, selectedRange.upperBound <= units.count,
              selectedRange.lowerBound <= selectedRange.upperBound else { return ("", "") }
        let scanStart = max(0, selectedRange.lowerBound - scanLimit)
        let scanEnd = min(units.count, selectedRange.upperBound + scanLimit)
        var before = String(decoding: units[scanStart..<selectedRange.lowerBound], as: UTF16.self)
        var after = String(decoding: units[selectedRange.upperBound..<scanEnd], as: UTF16.self)
        // A raw cut lands mid-sentence: start / end on a sentence boundary instead.
        if scanStart > 0 { before = TransformRequest.dropLeadingSentence(before) }
        if scanEnd < units.count { after = TransformRequest.dropTrailingSentence(after) }
        before = previousAndCurrentParagraph(before)
        after = restOfParagraph(after)
        let budget = TransformRequest.budgetedContext(before: before, after: after, cap: cap)
        return budget
    }

    /// Keeps the current paragraph's start and the previous non-blank paragraph before it.
    static func previousAndCurrentParagraph(_ before: String) -> String {
        guard let lastBreak = before.lastIndex(where: \.isNewline) else { return before }
        // Walk back over the break(s) and any blank lines to the previous paragraph's text.
        var i = lastBreak
        while i > before.startIndex {
            let p = before.index(before: i)
            if before[p].isNewline || before[p] == " " || before[p] == "\t" { i = p } else { break }
        }
        guard i > before.startIndex else { return String(before[before.index(after: lastBreak)...]) }
        let prevEnd = i
        let prevStart = before[..<prevEnd].lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex
        return String(before[prevStart...])
    }

    /// The current paragraph after the selection: up to the next line break.
    static func restOfParagraph(_ after: String) -> String {
        guard let br = after.firstIndex(where: \.isNewline) else { return after }
        return String(after[..<br])
    }

    /// The destination for a turn's `StageContext` (FieldRole keys) and the frontmost app's
    /// name. `nil` for a secure field — nothing about it reaches a model.
    public static func destination(context: StageContext, appName: String?) -> EditDestination? {
        let field = FieldContext(stageContext: context)
        let kind = context.extra[FieldContext.Keys.surfaceKind].flatMap(SurfaceKind.init(id:))
        if kind == .secure || field.axSubrole == "AXSecureTextField" || field.axRole == "AXSecureTextField" { return nil }
        let label = field.hints.first { !$0.isEmpty && !$0.hasPrefix("_") }
        let d = EditDestination(appName: appName, windowTitle: field.documentTitle, fieldLabel: label,
                                surface: kind.map(surfaceWord))
        return d.isEmpty ? nil : d
    }

    /// `snapshot` with its destination filled in (kept if already set: a chained edit keeps the
    /// first turn's). A secure context clears the snapshot's surrounding text too.
    public static func enrich(_ snapshot: SelectionSnapshot, context: StageContext, appName: String?) -> SelectionSnapshot {
        var s = snapshot
        let kind = context.extra[FieldContext.Keys.surfaceKind].flatMap(SurfaceKind.init(id:))
        if kind == .secure { s.before = ""; s.after = ""; s.destination = nil; return s }
        if s.destination == nil { s.destination = destination(context: context, appName: appName) }
        return s
    }

    /// A plain word the model understands for each surface kind.
    public static func surfaceWord(_ kind: SurfaceKind) -> String {
        switch kind {
        case .terminal: return "terminal"
        case .spreadsheetCell: return "spreadsheet cell"
        case .chatComposer: return "chat message"
        case .urlBar: return "address bar"
        case .searchField: return "search box"
        case .emailBody: return "email"
        case .formField(let label): return label == "text" ? "form field" : "form field (\(label))"
        case .markdownEditor: return "markdown document"
        case .codeEditor: return "code"
        case .canvas: return "canvas"
        case .prose: return "document"
        case .secure: return "secure field"
        }
    }
}
