import Foundation

/// N9 — the one built-in table of known apps. It merges the three lists that used to disagree
/// (`AppCategoryTable.exact`, the `Injection` adapters' bundle sets, and the accessibility
/// enabler's Electron/Chromium ids). It is a **hint** for `SurfaceResolver` (medium weight):
/// an app that is not here loses nothing, it is resolved from structure alone.
public enum SeedHints {
    /// What kind of app a bundle id usually is.
    public enum Family: String, Codable, Sendable, CaseIterable {
        case mail, chat, code, terminal, browser, spreadsheet, prose
    }

    public struct Hint: Sendable, Equatable {
        public var family: Family
        /// How the app is built, when known. Evidence only; the bundle sniff wins (R4 Q2).
        public var runtime: SurfaceRuntime?
        public init(_ family: Family, _ runtime: SurfaceRuntime? = nil) { self.family = family; self.runtime = runtime }
    }

    /// The surface kind a family suggests, if any. A browser suggests no kind for its content
    /// (the URL and the field decide); a spreadsheet only with cell-like structure.
    public static func kind(for family: Family) -> SurfaceKind? {
        switch family {
        case .mail: return .emailBody
        case .chat: return .chatComposer
        case .code: return .codeEditor
        case .terminal: return .terminal
        case .spreadsheet: return .spreadsheetCell
        case .prose: return .prose
        case .browser: return nil
        }
    }

    public static func hint(for bundleID: String?) -> Hint? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let hit = table[bundleID] { return hit }
        // Release-channel siblings of a known browser (`com.google.Chrome.canary`).
        for (id, hint) in table where hint.family == .browser && bundleID.hasPrefix(id + ".") { return hint }
        return nil
    }

    /// Every bundle id of one family (for the adapters that still route by id).
    public static func bundleIDs(_ family: Family) -> Set<String> {
        Set(table.filter { $0.value.family == family }.map(\.key))
    }

    /// Bundle ids whose earlier auto-drafted persona / cold-start style came from a wrong
    /// substring guess (`com.openai.codex` → "code") and must be re-drafted once (N9).
    public static let personaResets: Set<String> = ["com.openai.codex"]

    private static let e = SurfaceRuntime.electron, c = SurfaceRuntime.chromium

    public static let table: [String: Hint] = {
        var t: [String: Hint] = [:]
        func add(_ family: Family, _ runtime: SurfaceRuntime? = nil, _ ids: [String]) {
            for id in ids { t[id] = Hint(family, runtime) }
        }
        add(.mail, nil, ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.mail",
                         "com.mimestream.Mimestream", "com.airmail.mac", "com.readdle.SparkDesktop", "it.bloop.airmail2",
                         "com.freron.MailMate", "org.mozilla.thunderbird", "io.canarymail.mac"])
        add(.mail, e, ["ch.protonmail.desktop"])
        add(.chat, nil, ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "us.zoom.xos",
                         "com.apple.FaceTime", "com.skype.skype", "com.openai.chat", "com.viber.osx",
                         "jp.naver.line.mac", "com.tencent.xinWeChat"])
        add(.chat, e, ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams2", "com.microsoft.teams",
                       "org.signal.Signal", "com.facebook.archon", "com.anthropic.claudefordesktop", "im.riot.app",
                       "Mattermost.Desktop", "org.zulip.zulip-electron", "com.automattic.beeper.desktop"])
        add(.code, nil, ["com.apple.dt.Xcode", "com.jetbrains.intellij", "com.sublimetext.4", "dev.zed.Zed",
                         "com.vim.MacVim", "org.gnu.Emacs", "com.jetbrains.pycharm", "com.jetbrains.WebStorm",
                         "com.jetbrains.goland", "com.jetbrains.CLion", "com.jetbrains.rider", "com.jetbrains.intellij.ce",
                         "com.jetbrains.fleet", "com.google.android.studio", "com.panic.Nova", "com.barebones.bbedit",
                         "com.sublimetext.3", "dev.zed.Zed-Preview"])
        add(.code, e, ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
                       "com.exafunction.windsurf", "com.vscodium", "com.visualstudio.code.oss"])
        add(.terminal, nil, ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                             "dev.warp.Warp", "io.alacritty", "org.alacritty", "net.kovidgoyal.kitty",
                             "com.github.wez.wezterm", "com.termius-dmg.mac"])
        add(.terminal, e, ["co.zeit.hyper", "org.tabby"])
        add(.browser, c, ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
                          "com.operasoftware.Opera", "com.vivaldi.Vivaldi"])
        add(.browser, .webkit, ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS"])
        add(.browser, nil, ["org.mozilla.firefox", "app.zen-browser.zen"])
        add(.spreadsheet, nil, ["com.microsoft.Excel", "com.apple.iWork.Numbers"])
        add(.prose, nil, ["com.apple.Notes", "com.apple.TextEdit", "com.microsoft.Word", "com.apple.iWork.Pages",
                          "com.culturedcode.ThingsMac", "com.bear-writer", "com.apple.iWork.Keynote",
                          "com.microsoft.Powerpoint", "com.microsoft.onenote.mac", "com.lukilabs.lukiapp",
                          "com.agiletortoise.Drafts-OSX", "net.shinyfrog.bear", "com.ulyssesapp.mac",
                          "com.literatureandlatte.scrivener3", "com.apple.reminders", "com.apple.iCal",
                          "com.omnigroup.OmniFocus3", "com.apple.Preview", "com.apple.freeform", "com.raycast.macos"])
        add(.prose, e, ["notion.id", "md.obsidian", "com.figma.Desktop", "com.linear", "com.todoist.mac.Todoist",
                        "com.evernote.Evernote", "com.logseq.logseq"])
        return t
    }()
}
