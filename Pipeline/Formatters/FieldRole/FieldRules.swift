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
    /// Append a period when the utterance ends without terminal punctuation.
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
                role: FieldRole = .unknown) {
        self.category = category
        self.autoCapitalize = autoCapitalize
        self.trailingPeriod = trailingPeriod
        self.allowSubmit = allowSubmit
        self.allowParagraphBreak = allowParagraphBreak
        self.preserveIdentifiers = preserveIdentifiers
        self.refusesDictation = refusesDictation
        self.role = role
    }

    /// The rule table. Role decides first; the app class only picks the formatter for ordinary
    /// text fields.
    public static func rules(for field: FieldContext) -> FieldRules {
        let role = FieldRole.classify(field)
        let searchField = field.axRole == "AXSearchField" || field.axSubrole == "AXSearchField"

        switch role {
        case .secure:
            return FieldRules(category: .prose, autoCapitalize: false, trailingPeriod: false,
                              allowSubmit: false, allowParagraphBreak: false, preserveIdentifiers: true,
                              refusesDictation: true, role: role)

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
            // so a period here would land in the middle of it.
            let endOfField = field.textAfterCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Default: a search field and a one-line chat composer submit; nothing else does.
            // An explicit `submitsOnReturn` can only ever confirm, never widen — a mail body
            // that claims to submit on Return still does not get its Send pressed for it.
            let submits = field.submitsOnReturn ?? (searchField || (category == .chat && !multiline))
            return FieldRules(
                category: category,
                autoCapitalize: category != .code && category != .terminal,
                trailingPeriod: (category == .mail || category == .prose) && !searchField && endOfField,
                allowSubmit: submits && (searchField || category == .chat),
                allowParagraphBreak: multiline,
                preserveIdentifiers: category == .code || category == .terminal,
                role: role
            )
        }
    }

    /// Bundle ID first (the learned table), then the gatekeeper's register, then prose.
    static func appCategory(for field: FieldContext) -> AppCategory {
        if let bundleID = field.appBundleID, !bundleID.isEmpty,
           AppCategoryTable.exact[bundleID] != nil || AppCategoryTable.category(for: bundleID) != .prose {
            return AppCategoryTable.category(for: bundleID)
        }
        if let register = field.register, register != .unknown { return AppCategoryTable.category(for: register) }
        return .prose
    }
}
