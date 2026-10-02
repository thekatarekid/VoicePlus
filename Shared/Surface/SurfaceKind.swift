import Foundation

/// N9 — what kind of surface the caret is in, independent of which app draws it (Investigation
/// R3 §E1). App knowledge only raises confidence; the kind decides formatting (N12 grammars),
/// write plans (N5) and line-break safety.
public enum SurfaceKind: Hashable, Codable, Sendable {
    /// A shell prompt or REPL: a newline runs something. Bracketed paste, never Return.
    case terminal
    /// A spreadsheet cell or its in-cell editor. ⌥↩ for a line break, never Return.
    case spreadsheetCell
    /// A chat / prompt composer: Return sends, so line breaks are ⇧↩.
    case chatComposer
    /// A browser address bar: a URL or a search phrase.
    case urlBar
    /// A search or find box.
    case searchField
    /// A mail compose body.
    case emailBody
    /// A labelled form field. `label` is the normalised kind the label names
    /// (`email`, `phone`, `number`, `name`, `date`, `url`, `subject`, `recipient`, `address`),
    /// or `"text"` for a labelled field of no known type.
    case formField(label: String)
    /// An editor that accepts Markdown (GitHub, Notion, Obsidian…).
    case markdownEditor
    /// A source-code editor.
    case codeEditor
    /// A drawing / design canvas with no text edit active: hold, never type.
    case canvas
    /// Ordinary prose, and the safe fallback below the confidence threshold.
    case prose
    /// A password field or macOS secure input: never typed into, never read.
    case secure

    /// Stable identifier for logs, `turn_records` and settings (`formField:email`).
    public var id: String {
        switch self {
        case .terminal: return "terminal"
        case .spreadsheetCell: return "spreadsheetCell"
        case .chatComposer: return "chatComposer"
        case .urlBar: return "urlBar"
        case .searchField: return "searchField"
        case .emailBody: return "emailBody"
        case .formField(let label): return "formField:\(label)"
        case .markdownEditor: return "markdownEditor"
        case .codeEditor: return "codeEditor"
        case .canvas: return "canvas"
        case .prose: return "prose"
        case .secure: return "secure"
        }
    }

    /// Inverse of `id`; `nil` for an unrecognised string.
    public init?(id: String) {
        if id.hasPrefix("formField:") {
            let label = String(id.dropFirst("formField:".count))
            self = .formField(label: label.isEmpty ? "text" : label)
            return
        }
        switch id {
        case "terminal": self = .terminal
        case "spreadsheetCell": self = .spreadsheetCell
        case "chatComposer": self = .chatComposer
        case "urlBar": self = .urlBar
        case "searchField": self = .searchField
        case "emailBody": self = .emailBody
        case "formField": self = .formField(label: "text")
        case "markdownEditor": self = .markdownEditor
        case "codeEditor": self = .codeEditor
        case "canvas": self = .canvas
        case "prose": self = .prose
        case "secure": self = .secure
        default: return nil
        }
    }

    /// One-line surfaces: no paragraph breaks, no trailing period.
    public var isSingleLine: Bool {
        switch self {
        case .urlBar, .searchField, .formField, .secure: return true
        default: return false
        }
    }

    /// Kinds whose text is a value or a command rather than a sentence.
    public var isVerbatim: Bool {
        switch self {
        case .terminal, .codeEditor, .urlBar: return true
        default: return false
        }
    }
}

/// How the app is built, sniffed from the bundle once per version (R4 Q2). Only one decision
/// truly needs it (which accessibility switch to flip); here it is medium evidence that text
/// lands in web content.
public enum SurfaceRuntime: String, Codable, Sendable, CaseIterable {
    case native, electron, chromium, webkit, unknown

    /// Web content: Return may send or submit, so line breaks must be ⇧↩ (R3 §E7).
    public var isWebContent: Bool { self == .electron || self == .chromium || self == .webkit }
}

/// The key a line break is typed as on a surface (R3 §E7, safety-only). Never a plain Return
/// where Return could send, submit or run.
public enum SurfaceNewline: String, Codable, Sendable {
    /// A native text view: `\n` inserted through Accessibility, no key is sent.
    case newline
    /// Web content / Electron / unknown tree: ⇧↩.
    case shiftReturn
    /// Spreadsheet cell: ⌥↩.
    case optionReturn
    /// Terminal: multi-line text inside bracketed-paste markers.
    case bracketedPaste
    /// Single-line or held surfaces: line breaks become spaces.
    case none
}
