import Foundation
import Shared

/// Cold-start bucket for an app. Used when no learned `StyleProfile` exists for a bundle ID.
public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case mail, chat, code, terminal, prose
}

/// bundle-id → category. Exact matches first, then substring heuristics, then `.prose`.
public enum AppCategoryTable {
    /// N9 — derived from the one merged seed table (`SeedHints`), so the formatters, the
    /// adapters and the accessibility enabler can no longer disagree about an app.
    public static let exact: [String: AppCategory] = SeedHints.table.mapValues { category(for: $0.family) }

    /// The formatting category a seed family implies. Browsers and spreadsheets are prose apps:
    /// the surface (URL, cell) decides.
    public static func category(for family: SeedHints.Family) -> AppCategory {
        switch family {
        case .mail: return .mail
        case .chat: return .chat
        case .code: return .code
        case .terminal: return .terminal
        case .browser, .spreadsheet, .prose: return .prose
        }
    }

    /// N9 — the formatting category a resolved surface implies (`nil` when the surface says
    /// nothing about it and the app's category should stand).
    public static func category(for surface: SurfaceKind) -> AppCategory? {
        switch surface {
        case .terminal: return .terminal
        case .codeEditor: return .code
        case .chatComposer: return .chat
        case .emailBody: return .mail
        case .prose, .markdownEditor, .urlBar, .searchField, .formField, .spreadsheetCell: return .prose
        case .canvas, .secure: return nil
        }
    }

    /// V5 E2 — spreadsheet apps: a focused field in one of these is a cell unless it is a search box.
    public static let spreadsheetBundleIDs: Set<String> = SeedHints.bundleIDs(.spreadsheet)

    public static func isSpreadsheet(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return spreadsheetBundleIDs.contains(bundleID)
    }

    /// V5 E2 — a Google Sheets document (`docs.google.com/spreadsheets/…`), from the web area's `AXURL`.
    public static func isSpreadsheetDocument(_ url: String?) -> Bool {
        guard let url, let parsed = URL(string: url), let host = parsed.host?.lowercased() else { return false }
        return host == "docs.google.com" && parsed.path.hasPrefix("/spreadsheets")
    }

    /// V5 E4 — true when the bundle ID is in the exact table (not a substring guess).
    public static func isKnown(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return exact[bundleID] != nil
    }

    /// V5 E4 — `category(for:)` that also records a bundle ID it had to guess for, so the table can
    /// grow from real use. Logged once per bundle ID per launch (`UnknownApps`); the ID only —
    /// never a window title or any text.
    public static func categoryNotingUnknown(for bundleID: String?, log: UnknownApps = .shared) -> AppCategory {
        let category = category(for: bundleID)
        if let bundleID, !bundleID.isEmpty, !isKnown(bundleID) { log.note(bundleID, guessed: category) }
        return category
    }

    /// Whole-word tokens of an unknown bundle id (split on `.`, `-`, `_` and camelCase). N9:
    /// matched as **words**, never substrings — `com.openai.codex` is not "code", and
    /// `com.googlecode.iterm2` is not "code" either. Generic words ("code", "editor", "chat")
    /// are gone: they guessed wrong more often than right.
    static let substrings: [(String, AppCategory)] = [
        ("mail", .mail), ("outlook", .mail),
        ("slack", .chat), ("discord", .chat), ("messages", .chat), ("telegram", .chat), ("whatsapp", .chat),
        ("signal", .chat), ("teams", .chat),
        ("terminal", .terminal), ("iterm", .terminal), ("iterm2", .terminal), ("warp", .terminal), ("kitty", .terminal),
        ("alacritty", .terminal),
        ("vscode", .code), ("xcode", .code), ("jetbrains", .code), ("intellij", .code), ("vim", .code), ("emacs", .code),
        ("zed", .code),
    ]

    public static func category(for bundleID: String?) -> AppCategory {
        guard let bundleID, !bundleID.isEmpty else { return .prose }
        // V5 E5 — a `bundle|host` persona key: the browser sub-app decides.
        if bundleID.contains(BrowserSubApp.keySeparator) { return category(forKey: bundleID) }
        if let hit = exact[bundleID] { return hit }
        if let hint = SeedHints.hint(for: bundleID) { return category(for: hint.family) }
        let tokens = Set(SurfaceLexicon.words(bundleID))
        for (word, cat) in substrings where tokens.contains(word) { return cat }
        return .prose
    }

    /// Category implied by a detected register, for when the bundle ID is unknown.
    public static func category(for register: Utterance.Register) -> AppCategory {
        switch register {
        case .email: return .mail
        case .chat: return .chat
        case .code: return .code
        case .terminal: return .terminal
        case .prose, .list, .unknown: return .prose
        }
    }
}

/// V5 E4 — bundle IDs `AppCategoryTable` had no exact entry for. In memory; each one is logged once
/// (Q13's log buffer, exported with diagnostics) so the next table revision can add it.
public final class UnknownApps: @unchecked Sendable {
    public static let shared = UnknownApps()

    private let lock = NSLock()
    private var seen: [String: AppCategory] = [:]
    private let log: Log

    public init(log: Log = .pipeline) { self.log = log }

    /// Every unknown bundle ID seen so far and the category it was guessed as.
    public var recorded: [String: AppCategory] { lock.withLock { seen } }

    /// Returns true the first time `bundleID` is noted.
    @discardableResult
    public func note(_ bundleID: String, guessed: AppCategory) -> Bool {
        let first = lock.withLock { () -> Bool in
            guard seen[bundleID] == nil else { return false }
            seen[bundleID] = guessed
            return true
        }
        if first { log.notice("app category: unknown bundle \(bundleID) → \(guessed.rawValue) (add to AppCategoryTable)") }
        return first
    }
}
