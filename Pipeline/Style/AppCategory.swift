import Foundation
import Shared

/// Cold-start bucket for an app. Used when no learned `StyleProfile` exists for a bundle ID.
public enum AppCategory: String, Codable, CaseIterable, Sendable {
    case mail, chat, code, terminal, prose
}

/// bundle-id → category. Exact matches first, then substring heuristics, then `.prose`.
public enum AppCategoryTable {
    public static let exact: [String: AppCategory] = [
        // mail
        "com.apple.mail": .mail, "com.microsoft.Outlook": .mail, "com.readdle.smartemail-Mac": .mail,
        "com.superhuman.mail": .mail, "com.mimestream.Mimestream": .mail, "com.airmail.mac": .mail,
        // chat
        "com.tinyspeck.slackmacgap": .chat, "com.apple.MobileSMS": .chat, "com.hnc.Discord": .chat,
        "com.microsoft.teams2": .chat, "net.whatsapp.WhatsApp": .chat, "ru.keepcoder.Telegram": .chat,
        "org.signal.Signal": .chat, "com.facebook.archon": .chat,
        // code
        "com.microsoft.VSCode": .code, "com.apple.dt.Xcode": .code, "com.jetbrains.intellij": .code,
        "com.sublimetext.4": .code, "com.todesktop.230313mzl4w4u92": .code, "dev.zed.Zed": .code,
        "com.vim.MacVim": .code, "org.gnu.Emacs": .code,
        // terminal
        "com.apple.Terminal": .terminal, "com.googlecode.iterm2": .terminal, "dev.warp.Warp-Stable": .terminal,
        "io.alacritty": .terminal, "net.kovidgoyal.kitty": .terminal, "com.github.wez.wezterm": .terminal,
        // prose
        "com.apple.Notes": .prose, "com.apple.TextEdit": .prose, "md.obsidian": .prose, "notion.id": .prose,
        "com.microsoft.Word": .prose, "com.apple.iWork.Pages": .prose, "com.google.Chrome": .prose,
        "com.apple.Safari": .prose, "com.culturedcode.ThingsMac": .prose, "com.bear-writer": .prose,

        // V5 E4 — coverage. Browsers stay prose (E5 routes their sub-apps by host).
        "company.thebrowser.Browser": .prose, "com.brave.Browser": .prose, "com.microsoft.edgemac": .prose,
        "org.mozilla.firefox": .prose, "com.operasoftware.Opera": .prose, "com.vivaldi.Vivaldi": .prose,
        "com.kagi.kagimacOS": .prose, "app.zen-browser.zen": .prose, "com.apple.SafariTechnologyPreview": .prose,
        // mail
        "com.readdle.SparkDesktop": .mail, "it.bloop.airmail2": .mail, "com.freron.MailMate": .mail,
        "org.mozilla.thunderbird": .mail, "io.canarymail.mac": .mail, "ch.protonmail.desktop": .mail,
        // chat / calls
        "us.zoom.xos": .chat, "com.microsoft.teams": .chat, "com.apple.FaceTime": .chat, "com.skype.skype": .chat,
        "com.openai.chat": .chat, "com.anthropic.claudefordesktop": .chat, "com.viber.osx": .chat,
        "jp.naver.line.mac": .chat, "com.tencent.xinWeChat": .chat, "im.riot.app": .chat,
        "Mattermost.Desktop": .chat, "org.zulip.zulip-electron": .chat, "com.automattic.beeper.desktop": .chat,
        // code
        "com.exafunction.windsurf": .code, "com.microsoft.VSCodeInsiders": .code, "com.vscodium": .code,
        "com.visualstudio.code.oss": .code, "com.jetbrains.pycharm": .code, "com.jetbrains.WebStorm": .code,
        "com.jetbrains.goland": .code, "com.jetbrains.CLion": .code, "com.jetbrains.rider": .code,
        "com.jetbrains.intellij.ce": .code, "com.jetbrains.fleet": .code, "com.google.android.studio": .code,
        "com.panic.Nova": .code, "com.barebones.bbedit": .code, "com.sublimetext.3": .code,
        "dev.zed.Zed-Preview": .code,
        // terminal
        "com.mitchellh.ghostty": .terminal, "dev.warp.Warp": .terminal, "co.zeit.hyper": .terminal,
        "org.tabby": .terminal, "com.termius-dmg.mac": .terminal,
        // prose: documents, slides, spreadsheets (E2 decides the cell), notes, tasks, design, issues
        "com.apple.iWork.Keynote": .prose, "com.apple.iWork.Numbers": .prose, "com.microsoft.Excel": .prose,
        "com.microsoft.Powerpoint": .prose, "com.microsoft.onenote.mac": .prose, "com.figma.Desktop": .prose,
        "com.linear": .prose, "com.lukilabs.lukiapp": .prose, "com.agiletortoise.Drafts-OSX": .prose,
        "net.shinyfrog.bear": .prose, "com.ulyssesapp.mac": .prose, "com.literatureandlatte.scrivener3": .prose,
        "com.apple.reminders": .prose, "com.apple.iCal": .prose, "com.todoist.mac.Todoist": .prose,
        "com.omnigroup.OmniFocus3": .prose, "com.evernote.Evernote": .prose, "com.logseq.logseq": .prose,
        "com.apple.Preview": .prose, "com.apple.freeform": .prose, "com.raycast.macos": .prose,
    ]

    /// V5 E2 — spreadsheet apps: a focused field in one of these is a cell unless it is a search box.
    public static let spreadsheetBundleIDs: Set<String> = ["com.microsoft.Excel", "com.apple.iWork.Numbers"]

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

    static let substrings: [(String, AppCategory)] = [
        ("mail", .mail), ("outlook", .mail),
        ("slack", .chat), ("discord", .chat), ("messages", .chat), ("telegram", .chat), ("whatsapp", .chat),
        ("signal", .chat), ("teams", .chat), ("chat", .chat),
        ("terminal", .terminal), ("iterm", .terminal), ("warp", .terminal), ("kitty", .terminal), ("alacritty", .terminal),
        ("code", .code), ("xcode", .code), ("jetbrains", .code), ("intellij", .code), ("vim", .code), ("emacs", .code),
        ("editor", .code), ("zed", .code),
    ]

    public static func category(for bundleID: String?) -> AppCategory {
        guard let bundleID, !bundleID.isEmpty else { return .prose }
        if let hit = exact[bundleID] { return hit }
        let lower = bundleID.lowercased()
        for (needle, cat) in substrings where lower.contains(needle) { return cat }
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
