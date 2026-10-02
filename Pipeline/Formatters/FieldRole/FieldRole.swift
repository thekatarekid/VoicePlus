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
    /// V5 E2 — a spreadsheet cell (Excel, Numbers, Google Sheets): a value or a short label, not a
    /// sentence. No trailing period, no invented capital on a short label, numbers as digits, and
    /// Return never commits (a newline is the in-cell one, Q1).
    case spreadsheetCell
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
    /// V5 E2 — `AXURL` of the web document around the field (`docs.google.com/spreadsheets/…`
    /// makes a Sheets cell). `nil` for native fields.
    public var documentURL: String?
    /// V5 E2 — the spreadsheet column header over the focused cell (`AXColumnHeaderUIElements`).
    /// Context for the cleanup prompt, never a classification hint (a column named "Terminal"
    /// must not turn a cell into a shell).
    public var columnHeader: String?
    /// V5 E5 — the title of the web document around the field (`AXTitle` of its `AXWebArea`, or
    /// the window title). Routes a browser sub-app when the URL is missing. Never a hint.
    public var documentTitle: String?
    /// V5 E6 — who the text is for: To/Cc of a mail compose, the chat or channel of a messenger.
    /// Written to `StageContext.extra["thread.participants"]` (comma-separated).
    public var participants: [String] = []
    /// N9 — the surface kind the app already resolved with its full evidence (see
    /// `Keys.surfaceKind`). `nil` → `surface` resolves from this field's own evidence.
    public var upstreamSurface: SurfaceKind?
    /// N9 — the field has an `AXWebArea` ancestor. `nil` = not read (a URL then implies it).
    public var isInWebArea: Bool?

    /// N9 — what the field's own evidence says (role, labels, URL, window title, seed hint).
    public var surfaceEvidence: SurfaceEvidence {
        SurfaceEvidence(bundleID: appBundleID.map { BrowserSubApp.split(key: $0).bundleID },
                        role: axRole, subrole: axSubrole, isMultiline: isMultiline, hints: hints,
                        isInWebArea: isInWebArea ?? (documentURL?.isEmpty == false),
                        url: documentURL, windowTitle: documentTitle)
    }

    /// N9 — the surface this field is. The upstream answer (richer evidence) wins when given.
    public var surface: SurfaceResolution {
        if let upstreamSurface {
            return SurfaceResolution(kind: upstreamSurface, confidence: 1, isWebArea: isInWebArea ?? false,
                                     signals: ["upstream"])
        }
        return SurfaceResolver.resolve(surfaceEvidence)
    }

    /// V5 E5 — the browser sub-app this field sits in (Gmail, Slack web, GitHub…), from
    /// `documentURL` then `documentTitle`. `nil` for native apps and unknown sites.
    public var subApp: BrowserSubApp? {
        guard documentURL != nil || documentTitle != nil else { return nil }
        return BrowserSubApp.resolve(url: documentURL, title: documentTitle)
    }

    /// V5 E5 — the persona key: `bundle|host` inside a known browser sub-app, else the bundle ID.
    public var personaKey: String? {
        guard let appBundleID, !appBundleID.isEmpty else { return nil }
        return BrowserSubApp.personaKey(bundleID: appBundleID, host: subApp?.host)
    }

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
                spacing: SpacingPreference = .automatic, unknownCaretStyle: UnknownCaretStyle = .sentence,
                documentURL: String? = nil, columnHeader: String? = nil, documentTitle: String? = nil,
                participants: [String] = []) {
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
        self.documentURL = documentURL
        self.columnHeader = columnHeader
        self.documentTitle = documentTitle
        self.participants = participants
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
        /// V5 E2 — `FieldContext.documentURL`.
        public static let documentURL = "field.documentURL"
        /// V5 E2 — `FieldContext.columnHeader` (context for the cleanup prompt).
        public static let columnHeader = "field.columnHeader"
        /// V5 E5 — `FieldContext.documentTitle`.
        public static let documentTitle = "field.documentTitle"
        /// V5 E5 — the persona key (`bundle|host`) when the field is inside a browser sub-app.
        public static let personaKey = "app.personaKey"
        /// V5 E5 — the sub-app's `AppCategory.rawValue` (absent outside a known sub-app).
        public static let subAppCategory = "app.subAppCategory"
        /// V5 E6 — the thread's participants, comma-separated. Same key `Personas` reads
        /// (`StageContextParticipants.key`).
        public static let participants = "thread.participants"
        /// N9 — the surface the app resolved upstream with its full evidence (pty shell, window
        /// title, override, history): `SurfaceKind.id`. When present, `FieldRole.classify` uses it.
        public static let surfaceKind = "surface.kind"
        /// N9 — the resolution's confidence ("0.72") and signals (joined by `hintSeparator`),
        /// for `turn_records` and diagnostics.
        public static let surfaceConfidence = "surface.confidence"
        public static let surfaceSignals = "surface.signals"
        /// N9 — "true" when the resolution was the below-threshold prose fallback.
        public static let surfaceFallback = "surface.fallback"
        /// N9 — the field sits in web content (⇧↩ line breaks, keystrokes not AX writes).
        public static let surfaceWeb = "surface.web"
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
            unknownCaretStyle: e[Keys.unknownCaretStyle].flatMap(UnknownCaretStyle.init(rawValue:)) ?? .sentence,
            documentURL: e[Keys.documentURL],
            columnHeader: e[Keys.columnHeader],
            documentTitle: e[Keys.documentTitle],
            participants: Self.participants(from: e[Keys.participants])
        )
        self.upstreamSurface = e[Keys.surfaceKind].flatMap(SurfaceKind.init(id:))
        self.isInWebArea = f[Keys.surfaceWeb]
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
        if let documentURL, !documentURL.isEmpty { stageContext.extra[Keys.documentURL] = documentURL }
        if let columnHeader, !columnHeader.isEmpty { stageContext.extra[Keys.columnHeader] = columnHeader }
        if let documentTitle, !documentTitle.isEmpty { stageContext.extra[Keys.documentTitle] = documentTitle }
        if let sub = subApp, let key = personaKey {
            stageContext.extra[Keys.personaKey] = key
            stageContext.extra[Keys.subAppCategory] = sub.category.rawValue
        }
        if !participants.isEmpty { stageContext.extra[Keys.participants] = Self.participantsValue(participants) }
        if let upstreamSurface { stageContext.extra[Keys.surfaceKind] = upstreamSurface.id }
        if let isInWebArea { stageContext.flags[Keys.surfaceWeb] = isInWebArea }
    }

    /// N9 — writes a resolution (kind, confidence, signals, web) so later stages and the turn
    /// record see the same answer.
    static func write(_ resolution: SurfaceResolution, into stageContext: inout StageContext) {
        stageContext.extra[Keys.surfaceKind] = resolution.kind.id
        stageContext.extra[Keys.surfaceConfidence] = String(format: "%.2f", resolution.confidence)
        stageContext.extra[Keys.surfaceSignals] = resolution.signals.joined(separator: hintSeparator)
        stageContext.extra[Keys.surfaceFallback] = resolution.isFallback ? "true" : "false"
        stageContext.flags[Keys.surfaceWeb] = resolution.isWebArea
    }

    /// V5 E6 — participants as one `extra` value: names joined by ", " (commas inside a name are
    /// replaced so the list splits back the same way `StageContextParticipants` splits it).
    static func participantsValue(_ names: [String]) -> String {
        names.map { $0.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ";", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func participants(from value: String?) -> [String] {
        (value ?? "").split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - Classification

public extension FieldRole {
    // N9 — the terminal / editor hint lists moved into `SurfaceLexicon.phrases` (word-level,
    // weighted, added up). Field-tested shapes still hold: VS Code's integrated terminal is an
    // xterm.js textarea labelled "Terminal input"; Xcode's console is "Console"; Monaco says so.

    static let singleLineRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox", "AXPopUpButton"]
    static let multilineRoles: Set<String> = ["AXTextArea", "AXWebArea", "AXScrollArea", "AXGroup", "AXStaticText"]

    /// Role + labels + app, added up by `SurfaceResolver` (N9). A terminal *label* still beats the
    /// app class (R4.2): `com.microsoft.VSCode` with a "Terminal input" label is a terminal.
    static func classify(_ field: FieldContext) -> FieldRole {
        if field.axRole == FieldRole.secureRoleName || field.axSubrole == FieldRole.secureRoleName { return .secure }
        // V5 E3 — a web password field that only says so in its label (`aria-label`, the
        // `<label>` via `AXTitleUIElement`, the placeholder) is still a password field.
        if FieldInputKind.from(hints: field.hints) == .password, textEntryRoles.contains(field.axRole ?? "") { return .secure }
        // V5 E2 — a spreadsheet cell, before the hint scan: a column header or cell text
        // reading "console" must not make a cell a shell.
        if isSpreadsheetCell(field) { return .spreadsheetCell }

        // N9 — the surface resolver adds the evidence up (role, labels word by word, URL,
        // title, seed hint) instead of the first substring that matched: "Search console" is a
        // search box, and an app id containing "codex" is not a code editor.
        let role = field.axRole ?? ""
        let looksSingleLine = singleLineRoles.contains(role) || field.isMultiline == false
        let surface = field.surface
        switch surface.kind {
        case .secure: return .secure
        case .spreadsheetCell: return .spreadsheetCell
        case .terminal: return .terminal
        // A find field in an IDE is a one-line field, not the code surface.
        case .codeEditor: return looksSingleLine ? .singleLineText : .codeEditor
        default: break
        }
        if looksSingleLine || surface.kind.isSingleLine && field.isMultiline != true { return .singleLineText }
        if multilineRoles.contains(role) || field.isMultiline == true { return .multilineText }
        return .unknown
    }

    /// Matches `FocusedElementInfo.secureRole` in `Injection` without depending on it.
    static let secureRoleName = "AXSecureTextField"

    /// Roles a typed value goes into (the E3 password-by-label rule applies only to these).
    static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// V5 E2 — roles a spreadsheet app reports for a selected cell or its in-cell editor.
    static let spreadsheetCellRoles: Set<String> = ["AXCell", "AXTable", "AXLayoutItem", "AXGroup",
                                                    "AXTextArea", "AXTextField", "AXGrid"]

    /// V5 E2 — `AXCell`, a "cell" role description, a field inside Excel / Numbers, or a field in
    /// a Google Sheets document. A search field (Excel's "Tell me", Sheets' find box) is not a cell.
    static func isSpreadsheetCell(_ field: FieldContext) -> Bool {
        let role = field.axRole ?? ""
        if role == "AXSearchField" || field.axSubrole == "AXSearchField" { return false }
        if role == "AXCell" { return true }
        let hints = field.hints.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if hints.contains(where: { $0 == "cell" || $0.hasSuffix(" cell") }) { return true }
        if FieldInputKind.from(hints: field.hints) == .search { return false }
        if AppCategoryTable.isSpreadsheet(bundleID: field.appBundleID) {
            return role.isEmpty || spreadsheetCellRoles.contains(role)
        }
        if AppCategoryTable.isSpreadsheetDocument(field.documentURL) || field.subApp?.isSpreadsheet == true {
            return role.isEmpty || spreadsheetCellRoles.contains(role) || role == "AXWebArea"
        }
        return false
    }
}

// MARK: - V5 E3 · what a web form field asks for

/// What a labelled form field expects, read from its label / description / `aria-label` /
/// placeholder (`FieldContext.hints`). Drives ITN (digits, compact addresses) and refusal.
public enum FieldInputKind: String, Sendable, Equatable, CaseIterable {
    case email, phone, url, search, password

    /// Word-level matches, so "curl" is not a URL and "telephone" is a phone. Password first:
    /// a "Password or email" box is refused rather than formatted.
    static let vocabulary: [(FieldInputKind, Set<String>)] = [
        (.password, ["password", "passcode", "passwort", "contraseña", "mot de passe", "passphrase"]),
        (.email, ["email", "e-mail", "mail address", "email address"]),
        (.phone, ["phone", "telephone", "mobile", "tel", "cell phone", "phone number"]),
        (.url, ["url", "website", "web address", "homepage", "web site", "link"]),
        (.search, ["search", "find", "query"]),
    ]

    public static func from(hints: [String]) -> FieldInputKind? {
        guard !hints.isEmpty else { return nil }
        let phrases = hints.map { " " + words($0).joined(separator: " ") + " " }
        for (kind, needles) in vocabulary {
            for needle in needles {
                let padded = " " + words(needle).joined(separator: " ") + " "
                if phrases.contains(where: { $0.contains(padded) }) { return kind }
            }
        }
        return nil
    }

    /// Lowercased letter/digit runs ("E-mail address:" → ["e", "mail", "address"]).
    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }
}
