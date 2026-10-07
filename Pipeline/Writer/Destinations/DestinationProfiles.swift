import Foundation
import Shared

// Context Writer (plan §3) — the profile table and its two resolvers.
//
// - `resolve(profileID:)` is what `ContextWriterStage` calls with the packet's id (the App's packet
//   builder decided the destination from the AX tree, URL and tty). An unknown id resolves to the
//   `unknown` profile, never to nil: the stage always has rules to render.
// - `resolve(surfaceKind:appBundleID:urlHost:fieldRole:)` is the fallback for callers that have no
//   packet (Lab replays, the legacy cleanup path): the surface resolver's kind plus the app and host
//   pick the closest row. It cannot see reply state, the caret region or the tty's foreground
//   process, so it prefers the conservative sibling (`email.body.reply`, `code.body`, `shell`).

public enum DestinationProfiles {

    /// Every row of plan §3, in the plan's order.
    public static let all: [DestinationProfile] = catalog

    /// Every profile id, for the Lab and the packet builder's validation.
    public static var ids: [String] { all.map(\.id) }

    public static let unknownID = "unknown"
    public static let secureID = "secure"

    private static let byID: [String: DestinationProfile] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The profile for an id, or `nil` when no row has it.
    public static func lookup(_ id: String) -> DestinationProfile? { byID[id] }

    /// The profile for a packet's `profileID`; the `unknown` row for an id no row has.
    public static func resolve(profileID: String) -> DestinationProfile {
        byID[profileID] ?? byID[unknownID]!
    }

    // MARK: Fallback from the surface

    /// Picks the closest profile from what the surface resolver and the field reader know.
    /// - `surfaceKind`: `SurfaceKind.id` (`chatComposer`, `formField:subject`, …).
    /// - `fieldRole`: the field classification when the caller has one (`.secure` always wins).
    public static func resolve(surfaceKind: String?, appBundleID: String? = nil, urlHost: String? = nil,
                               fieldRole: FieldRole? = nil) -> DestinationProfile {
        resolve(profileID: profileID(surfaceKind: surfaceKind, appBundleID: appBundleID, urlHost: urlHost, fieldRole: fieldRole))
    }

    /// The id the fallback resolver would pick (exposed for tests and the Lab's packet builder).
    public static func profileID(surfaceKind: String?, appBundleID: String? = nil, urlHost: String? = nil,
                                 fieldRole: FieldRole? = nil) -> String {
        if fieldRole == .secure || surfaceKind == SurfaceKind.secure.id { return secureID }
        let host = normalizedHost(urlHost)
        let kind = surfaceKind.flatMap(SurfaceKind.init(id:))
        switch kind {
        case .terminal:
            return "shell"
        case .spreadsheetCell:
            return "spreadsheet.cell"
        case .chatComposer:
            return isAIChat(bundleID: appBundleID, host: host) ? "ai.chat" : "chat.message"
        case .urlBar:
            return "browser.urlBar"
        case .searchField:
            return "search"
        case .emailBody:
            return "email.body.reply"
        case .formField(let label):
            if label == "subject" { return "email.subject" }
            if label == "text", let app = appProfile(bundleID: appBundleID, host: host) { return app }
            return "form"
        case .markdownEditor:
            return "markdown"
        case .codeEditor:
            return "code.body"
        case .canvas:
            return unknownID
        case .secure:
            return secureID
        case .prose, .none:
            if let app = appProfile(bundleID: appBundleID, host: host) { return app }
            if fieldRole == .terminal { return "shell" }
            if fieldRole == .codeEditor { return "code.body" }
            if fieldRole == .spreadsheetCell { return "spreadsheet.cell" }
            return unknownID
        }
    }

    // MARK: App and host tables (hints only; structure decides first)

    static func isAIChat(bundleID: String?, host: String?) -> Bool {
        if let bundleID, aiChatBundleIDs.contains(bundleID) { return true }
        if let host, aiChatHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        return false
    }

    /// A profile the app or site alone implies for a prose / unlabelled field, if any.
    static func appProfile(bundleID: String?, host: String?) -> String? {
        if isAIChat(bundleID: bundleID, host: host) { return "ai.chat" }
        if let bundleID, let hit = bundleProfiles[bundleID] { return hit }
        if let host {
            for (site, id) in hostProfiles where host == site || host.hasSuffix("." + site) { return id }
        }
        if let bundleID, let family = SeedHints.hint(for: bundleID)?.family {
            switch family {
            case .mail: return "email.body.reply"
            case .chat: return "chat.message"
            case .code: return "code.body"
            case .terminal: return "shell"
            case .spreadsheet: return "spreadsheet.cell"
            case .prose, .browser: return nil
            }
        }
        return nil
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static let aiChatBundleIDs: Set<String> = ["com.openai.chat", "com.anthropic.claudefordesktop", "ai.perplexity.mac"]
    static let aiChatHosts: [String] = ["claude.ai", "chatgpt.com", "chat.openai.com", "perplexity.ai", "gemini.google.com",
                                        "copilot.microsoft.com", "chat.mistral.ai", "poe.com"]

    static let bundleProfiles: [String: String] = [
        "com.apple.Notes": "notes", "com.apple.reminders": "notes", "com.culturedcode.ThingsMac": "notes",
        "com.omnigroup.OmniFocus4": "notes", "com.todoist.mac.Todoist": "notes", "com.bear-writer": "notes",
        "com.apple.iCal": "calendar.notes", "com.flexibits.fantastical2.mac": "calendar.notes",
        "com.apple.iWork.Pages": "document", "com.microsoft.Word": "document", "notion.id": "document",
        "md.obsidian": "markdown", "com.apple.TextEdit": "document", "abnerworks.Typora": "markdown",
        "com.apple.iWork.Keynote": "slides.body", "com.microsoft.Powerpoint": "slides.body",
        "com.github.GitHubClient": "commit", "com.fournova.Tower3": "commit",
    ]

    static let hostProfiles: [(String, String)] = [
        ("docs.google.com", "document"), ("notion.so", "document"), ("slides.google.com", "slides.body"),
        ("sheets.google.com", "spreadsheet.cell"), ("x.com", "social"), ("twitter.com", "social"),
        ("linkedin.com", "social"), ("threads.net", "social"), ("mastodon.social", "social"), ("bsky.app", "social"),
        ("mail.google.com", "email.body.reply"), ("outlook.live.com", "email.body.reply"), ("outlook.office.com", "email.body.reply"),
        ("calendar.google.com", "calendar.notes"), ("slack.com", "chat.message"), ("discord.com", "chat.message"),
        ("teams.microsoft.com", "chat.message"), ("web.whatsapp.com", "chat.message"),
    ]
}
