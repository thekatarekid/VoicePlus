import Foundation
import Shared

/// R4.2 — the formatting contract for one insertion point, decided by **AX role + app**.
///
/// Rules, not behaviour: nothing here rewrites text. `FieldRoleFormatterStage` reads them, and
/// `Injection` reads `allowSubmit` (it is the only thing that can press Return).
public struct FieldRules: Sendable, Equatable {
    /// Which register's formatter runs.
    public var category: AppCategory
    /// Capitalize a sentence start. False for terminals and code — `Grep` is not `grep`.
    public var autoCapitalize: Bool
    /// Append a period when the utterance ends without terminal punctuation. False at an unknown
    /// caret and when text follows the caret. The continuation plan narrows it further (D2/D3:
    /// no period after a word, a full clause only in an empty field).
    public var trailingPeriod: Bool
    /// Whether the injector may press Return after the text. **Always false for a terminal role**,
    /// even when the caller says the field submits on Return: a stray newline in a shell runs a
    /// command the user never confirmed.
    public var allowSubmit: Bool
    /// Whether a newline may be part of the inserted text at all (a paragraph break needs it).
    public var allowParagraphBreak: Bool
    /// Keep `user_session_token`, `camelCase`, `--flag` and paths exactly as spoken/heard.
    public var preserveIdentifiers: Bool
    /// A password field: format nothing, inject nothing.
    public var refusesDictation: Bool
    /// The field role these rules were derived from.
    public var role: FieldRole
    /// V5 E2/E3 — numbers are always digits here ("five" → "5"): a cell, a phone / email / URL box.
    public var alwaysNormalizeNumbers: Bool
    /// V5 E2 — a newline is the in-cell one (⌥↩, Q1); Return never commits the cell for the user.
    public var newlineInCell: Bool
    /// V5 E3 — what a labelled form field asks for (`FieldInputKind.from(hints:)`).
    public var inputKind: FieldInputKind?
    /// V5 E2 — at or under this many words the first letter is not capitalised (a cell label).
    public static let shortLabelMaxWords = 3

    /// Register handed to the inner formatter stage.
    public var register: Utterance.Register {
        switch category {
        case .mail: return .email
        case .chat: return .chat
        case .code: return .code
        case .terminal: return .terminal
        case .prose: return .prose
        }
    }

    public init(category: AppCategory, autoCapitalize: Bool, trailingPeriod: Bool, allowSubmit: Bool,
                allowParagraphBreak: Bool, preserveIdentifiers: Bool, refusesDictation: Bool = false,
                role: FieldRole = .unknown, alwaysNormalizeNumbers: Bool = false, newlineInCell: Bool = false,
                inputKind: FieldInputKind? = nil) {
        self.category = category
        self.autoCapitalize = autoCapitalize
        self.trailingPeriod = trailingPeriod
        self.allowSubmit = allowSubmit
        self.allowParagraphBreak = allowParagraphBreak
        self.preserveIdentifiers = preserveIdentifiers
        self.refusesDictation = refusesDictation
        self.role = role
        self.alwaysNormalizeNumbers = alwaysNormalizeNumbers
        self.newlineInCell = newlineInCell
        self.inputKind = inputKind
    }

    /// The rule table. Role decides first; the app class only picks the formatter for ordinary
    /// text fields.
    public static func rules(for field: FieldContext) -> FieldRules {
        let role = FieldRole.classify(field)
        let inputKind = FieldInputKind.from(hints: field.hints)
        let searchField = field.axRole == "AXSearchField" || field.axSubrole == "AXSearchField"
        // V5 E3 — a box labelled "Search" gets search formatting (no period) but, unlike a real
        // `AXSearchField`, no permission to press Return: a label is weaker evidence than a role.
        let searchLike = searchField || inputKind == .search

        switch role {
        case .secure:
            return FieldRules(category: .prose, autoCapitalize: false, trailingPeriod: false,
                              allowSubmit: false, allowParagraphBreak: false, preserveIdentifiers: true,
                              refusesDictation: true, role: role, inputKind: inputKind)

        case .spreadsheetCell:
            // V5 E2 — a value or a label. `autoCapitalize` false means "do not invent a capital";
            // `FieldRoleFormatterStage` still lets a longer, sentence-like entry keep its own.
            return FieldRules(category: appCategory(for: field), autoCapitalize: false, trailingPeriod: false,
                              allowSubmit: false, allowParagraphBreak: false, preserveIdentifiers: false,
                              role: role, alwaysNormalizeNumbers: true, newlineInCell: true)

        case .terminal:
            // The decisive case. `allowSubmit` ignores `submitsOnReturn` on purpose.
            return FieldRules(category: .terminal, autoCapitalize: false, trailingPeriod: false,
                              allowSubmit: false, allowParagraphBreak: false, preserveIdentifiers: true,
                              role: role)

        case .codeEditor:
            return FieldRules(category: .code, autoCapitalize: false, trailingPeriod: false,
                              allowSubmit: false, allowParagraphBreak: true, preserveIdentifiers: true,
                              role: role)

        case .singleLineText, .multilineText, .unknown:
            let category = appCategory(for: field)
            let multiline = !role.isSingleLine && field.isMultiline != false
            // Inserting *into* a sentence: the sentence already has its full stop further along,
            // so a period here would land in the middle of it. An unknown caret has no "end" to
            // speak of (V4.2): no invented period there either.
            let endOfField = field.caret.textAfter.map { !ContinuationPlanner.textFollowsOnLine($0) } ?? false
            // Default: a search field and a one-line chat composer submit; nothing else does.
            // An explicit `submitsOnReturn` can only ever confirm, never widen — a mail body
            // that claims to submit on Return still does not get its Send pressed for it.
            let submits = field.submitsOnReturn ?? (searchField || (category == .chat && !multiline))
            // V5 E3 — an email / phone / URL box holds a value, not a sentence.
            let valueField = inputKind == .email || inputKind == .phone || inputKind == .url
            return FieldRules(
                category: category,
                autoCapitalize: category != .code && category != .terminal && !valueField,
                trailingPeriod: (category == .mail || category == .prose) && !searchLike && !valueField && endOfField,
                allowSubmit: submits && (searchField || category == .chat),
                allowParagraphBreak: multiline && !valueField,
                preserveIdentifiers: category == .code || category == .terminal,
                role: role,
                alwaysNormalizeNumbers: valueField,
                inputKind: inputKind
            )
        }
    }

    /// Bundle ID first (the learned table), then the gatekeeper's register, then prose.
    static func appCategory(for field: FieldContext) -> AppCategory {
        // V5 E5 — inside a browser, the sub-app (Gmail, Slack web, GitHub…) decides.
        if let sub = field.subApp { return sub.category }
        // N9 — the surface decides chat versus code (a composer in a coding app is chat), but
        // only when it is confident; prose-like kinds leave the app's category standing.
        let surface = field.surface
        if !surface.isFallback, [.chatComposer, .emailBody, .codeEditor, .terminal].contains(surface.kind),
           let c = AppCategoryTable.category(for: surface.kind) {
            return c
        }
        if let bundleID = field.appBundleID, !bundleID.isEmpty,
           AppCategoryTable.exact[bundleID] != nil || AppCategoryTable.category(for: bundleID) != .prose {
            return AppCategoryTable.category(for: bundleID)
        }
        if let register = field.register, register != .unknown { return AppCategoryTable.category(for: register) }
        return .prose
    }
}
