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
    ]

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
