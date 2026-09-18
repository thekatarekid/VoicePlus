import Foundation
import Shared

/// R4.2 — what the focused field *is*, as opposed to what app it is in.
///
/// The decisive case the build doc names: an integrated terminal inside an editor. The app is
/// VS Code (`AppCategory.code`), but the field is a shell prompt, so it must get terminal rules —
/// no auto-capitalization, no trailing period, and never submit. App class alone cannot tell
/// those apart; the accessibility tree can.
public enum FieldRole: String, Codable, Sendable, CaseIterable, Equatable {
    /// A shell prompt, REPL or console — anywhere a newline runs something.
    case terminal
    /// A source-code editor surface (Monaco, CodeMirror, Xcode's editor, a `<textarea>` in an IDE).
    case codeEditor
    /// One-line field: text field, search field, combo box, a chat composer that sends on Return.
    case singleLineText
    /// Multi-line body text: a mail body, a note, a document.
    case multilineText
    /// A password field. Dictation must never be posted into one (R2.3).
    case secure
    /// Nothing usable came back from the accessibility tree.
    case unknown

    public var isSingleLine: Bool { self == .singleLineText || self == .secure }
}

/// Everything `Pipeline` needs to know about the insertion point, as a plain value.
///
/// Nothing here is AppKit or AX: `Injection`/`App` read the accessibility tree and fill this in
/// (see `FieldContext.Keys` for the `StageContext` carrier). Pipeline stays testable without a
/// running app, and `Pipeline` gains no dependency on `Injection`.
public struct FieldContext: Sendable, Equatable {
    public var appBundleID: String?
    /// `kAXRoleAttribute`, e.g. `AXTextArea`, `AXTextField`, `AXSearchField`.
    public var axRole: String?
    /// `kAXSubroleAttribute`, e.g. `AXSecureTextField`.
    public var axSubrole: String?
    /// Any descriptive string the tree exposes about the field: `AXIdentifier`, `AXDescription`,
    /// `AXTitle`, `AXRoleDescription`, an ARIA label, a DOM class list. Order is irrelevant;
    /// this is what tells a VS Code integrated terminal (`"Terminal input"`) from its editor
    /// (`"Monaco editor"`), because both are `AXTextArea` in the same bundle ID.
    public var hints: [String]
    /// Explicit override when the caller knows better than the role does.
    public var isMultiline: Bool?
    /// True when Return sends rather than inserting a newline (a chat composer). Never honoured
    /// for a terminal role — a terminal is never submitted for the user.
    public var submitsOnReturn: Bool?
    /// D1 (V4.2) — where the caret is: `known(before, after)`, `endOfField(before)` or `unknown`.
    /// `unknown` is never read as "end of field": the continuation planner gives it no leading
    /// space, no invented capital and no invented period.
    public var caret: CaretState
    /// The gatekeeper's register, used only when the bundle ID says nothing.
    public var register: Utterance.Register?
    /// D6 — Settings → Spacing.
    public var spacing: SpacingPreference
    /// D3 — Settings → how text lands at an unknown caret.
    public var unknownCaretStyle: UnknownCaretStyle

    /// Text immediately before the caret, as read back. May be a bounded tail, not the whole
    /// field. `""` when the caret is `unknown` — check `caret` before reading "empty" into it.
    public var textBeforeCursor: String { caret.textBefore ?? "" }
    /// Text immediately after the caret; `""` at the end of the field or when the caret is unknown.
    public var textAfterCursor: String { caret.textAfter ?? "" }

    /// `caret` wins when given. Without it, `textBeforeCursor`/`textAfterCursor` describe a caret
    /// the caller *did* read (tests, goldens, the Lab): `endOfField` when nothing follows it,
    /// `known` otherwise.
    public init(appBundleID: String? = nil, axRole: String? = nil, axSubrole: String? = nil,
                hints: [String] = [], isMultiline: Bool? = nil, submitsOnReturn: Bool? = nil,
                textBeforeCursor: String = "", textAfterCursor: String = "",
                register: Utterance.Register? = nil, caret: CaretState? = nil,
                spacing: SpacingPreference = .automatic, unknownCaretStyle: UnknownCaretStyle = .sentence) {
        self.appBundleID = appBundleID
        self.axRole = axRole
        self.axSubrole = axSubrole
        self.hints = hints
        self.isMultiline = isMultiline
        self.submitsOnReturn = submitsOnReturn
        self.caret = caret ?? Self.caret(before: textBeforeCursor, after: textAfterCursor)
        self.register = register
        self.spacing = spacing
        self.unknownCaretStyle = unknownCaretStyle
    }

    /// A caret the caller read: `endOfField` when nothing follows it.
    public static func caret(before: String, after: String) -> CaretState {
        after.isEmpty ? .endOfField(before: before) : .known(before: before, after: after)
    }

    /// Both formatting settings as one value.
    public var preferences: FormattingPreferences {
        get { FormattingPreferences(spacing: spacing, unknownCaretStyle: unknownCaretStyle) }
        set { spacing = newValue.spacing; unknownCaretStyle = newValue.unknownCaretStyle }
    }
}

// MARK: - StageContext carrier

public extension FieldContext {
    /// Keys `App`/`Injection` write into `StageContext.extra` / `.flags`. `StageContext` lives in
    /// `Shared` and carries only strings and bools, so the field context travels as strings —
    /// no change to `Shared` and no new module dependency.
    enum Keys {
        public static let axRole = "field.axRole"
        public static let axSubrole = "field.axSubrole"
        /// Hints joined by `FieldContext.hintSeparator`.
        public static let hints = "field.hints"
        public static let textBefore = "field.textBefore"
        public static let textAfter = "field.textAfter"
        /// D1 — `CaretState.Kind.rawValue`. Absent means the run has no caret reading at all
        /// (the Lab, a test without a field): the text keys then describe the caret, as before.
        public static let caret = "field.caret"
        public static let multiline = "field.multiline"
        public static let submitsOnReturn = "field.submitsOnReturn"
        /// D6 — `SpacingPreference.rawValue`; also the settings key.
        public static let spacing = "formatting.spacing"
        /// D3 — `UnknownCaretStyle.rawValue`; also the settings key.
        public static let unknownCaretStyle = "formatting.unknownCaretStyle"
    }

    /// ASCII unit separator: cannot occur in an AX label, so no escaping is needed.
    static let hintSeparator = "\u{1F}"

    init(stageContext: StageContext) {
        let e = stageContext.extra, f = stageContext.flags
        let hintBlob = e[Keys.hints] ?? ""
        let before = e[Keys.textBefore] ?? "", after = e[Keys.textAfter] ?? ""
        let caret: CaretState
        switch e[Keys.caret].flatMap(CaretState.Kind.init(rawValue:)) {
        case .unknown?: caret = .unknown
        case .endOfField?: caret = .endOfField(before: before)
        case .known?: caret = .known(before: before, after: after)
        case nil: caret = Self.caret(before: before, after: after)
        }
        self.init(
            appBundleID: stageContext.appBundleID,
            axRole: e[Keys.axRole],
            axSubrole: e[Keys.axSubrole],
            hints: hintBlob.isEmpty ? [] : hintBlob.components(separatedBy: Self.hintSeparator),
            isMultiline: f[Keys.multiline],
            submitsOnReturn: f[Keys.submitsOnReturn],
            register: stageContext.register,
            caret: caret,
            spacing: e[Keys.spacing].flatMap(SpacingPreference.init(rawValue:)) ?? .automatic,
            unknownCaretStyle: e[Keys.unknownCaretStyle].flatMap(UnknownCaretStyle.init(rawValue:)) ?? .sentence
        )
    }

    /// The inverse: what `App`/`Injection` writes when it builds the context for a run.
    func write(into stageContext: inout StageContext) {
        stageContext.appBundleID = appBundleID ?? stageContext.appBundleID
        if let axRole { stageContext.extra[Keys.axRole] = axRole }
        if let axSubrole { stageContext.extra[Keys.axSubrole] = axSubrole }
        if !hints.isEmpty { stageContext.extra[Keys.hints] = hints.joined(separator: Self.hintSeparator) }
        stageContext.extra[Keys.caret] = caret.kind.rawValue
        stageContext.extra[Keys.textBefore] = textBeforeCursor
        stageContext.extra[Keys.textAfter] = textAfterCursor
        stageContext.extra[Keys.spacing] = spacing.rawValue
        stageContext.extra[Keys.unknownCaretStyle] = unknownCaretStyle.rawValue
        if let isMultiline { stageContext.flags[Keys.multiline] = isMultiline }
        if let submitsOnReturn { stageContext.flags[Keys.submitsOnReturn] = submitsOnReturn }
    }
}

// MARK: - Classification

public extension FieldRole {
    /// Substrings that mark a shell/REPL surface. Checked against every hint, lowercased.
    ///
    /// Field-tested shapes: VS Code / Cursor integrated terminal exposes an xterm.js textarea
    /// labelled "Terminal input"; Xcode's console is "Console"; a Jupyter/Swift REPL cell reads
    /// "repl". Bundle ID cannot see any of them.
    static let terminalHints = ["terminal", "xterm", "console", "repl", "shell", "command line", "tmux"]
    /// Substrings that mark a source-editor surface.
    static let editorHints = ["monaco", "code editor", "source editor", "codemirror", "cm-content",
                              "ace_text-input", "editor content", "sourceeditor"]

    static let singleLineRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox", "AXPopUpButton"]
    static let multilineRoles: Set<String> = ["AXTextArea", "AXWebArea", "AXScrollArea", "AXGroup", "AXStaticText"]

    /// Role + app, in that order of authority. A terminal *hint* beats the app class, which is the
    /// whole point of R4.2: `com.microsoft.VSCode` with a "Terminal input" label is a terminal.
    static func classify(_ field: FieldContext) -> FieldRole {
        if field.axRole == FieldRole.secureRoleName || field.axSubrole == FieldRole.secureRoleName { return .secure }

        let haystack = field.hints.map { $0.lowercased() }
        if haystack.contains(where: { h in terminalHints.contains(where: h.contains) }) { return .terminal }
        if haystack.contains(where: { h in editorHints.contains(where: h.contains) }) { return .codeEditor }

        let appCategory = field.appBundleID.map(AppCategoryTable.category(for:))
        let role = field.axRole ?? ""
        let looksSingleLine = singleLineRoles.contains(role) || field.isMultiline == false

        if appCategory == .terminal { return .terminal }
        // A find field in an IDE is a one-line field, not the code surface.
        if appCategory == .code { return looksSingleLine ? .singleLineText : .codeEditor }

        if looksSingleLine { return .singleLineText }
        if multilineRoles.contains(role) || field.isMultiline == true { return .multilineText }
        return .unknown
    }

    /// Matches `FocusedElementInfo.secureRole` in `Injection` without depending on it.
    static let secureRoleName = "AXSecureTextField"
}
