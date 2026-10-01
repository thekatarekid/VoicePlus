import Foundation
import Shared

/// V5 E5 — browser sub-app routing.
///
/// A browser's bundle ID says "prose" for every tab, but Gmail is mail, Slack's web client is chat
/// and a GitHub file editor is code. The focused `AXWebArea`'s URL (and, failing that, the page
/// title) names the sub-app; its host decides the category and keys the persona as `bundle|host`.
///
/// Pure: the URL and title come in as strings (`FieldContext.documentURL` / `.documentTitle`).
/// Only the host and the first path components are looked at — never the query or fragment, and
/// nothing is stored or logged.
public struct BrowserSubApp: Equatable, Sendable {
    /// Lower-cased host, `www.` stripped (`mail.google.com`, `github.com`). For a title-only match,
    /// the canonical host of the matched app.
    public var host: String
    public var category: AppCategory
    /// Google Sheets and friends: a cell, not a sentence (E2 decides the role from this).
    public var isSpreadsheet: Bool

    public init(host: String, category: AppCategory, isSpreadsheet: Bool = false) {
        self.host = host; self.category = category; self.isSpreadsheet = isSpreadsheet
    }

    /// Separator of the persona key: `com.google.Chrome|mail.google.com`. `|` cannot occur in a
    /// bundle ID or a host.
    public static let keySeparator: Character = "|"

    /// `bundle|host` — the persona / style key for a sub-app. Plain `bundle` when there is no host.
    public static func personaKey(bundleID: String, host: String?) -> String {
        guard let host, !host.isEmpty else { return bundleID }
        return "\(bundleID)\(keySeparator)\(host)"
    }

    /// The parts of a `bundle|host` key; `host == nil` for a plain bundle ID.
    public static func split(key: String) -> (bundleID: String, host: String?) {
        guard let i = key.firstIndex(of: keySeparator) else { return (key, nil) }
        let host = String(key[key.index(after: i)...])
        return (String(key[..<i]), host.isEmpty ? nil : host)
    }

    // MARK: Routing table

    /// One row: a host (exact, or any subdomain of it), an optional path prefix, a category.
    public struct Route: Sendable {
        public var host: String
        public var pathPrefix: String?
        public var category: AppCategory
        public var isSpreadsheet: Bool
        public init(_ host: String, _ category: AppCategory, path: String? = nil, spreadsheet: Bool = false) {
            self.host = host; self.pathPrefix = path; self.category = category; self.isSpreadsheet = spreadsheet
        }
    }

    /// Ordered: the first matching row wins, so path-specific rows come before their host's
    /// catch-all.
    public static let routes: [Route] = [
        // mail (Gmail's embedded chat first: a path row precedes its host's catch-all)
        Route("mail.google.com", .chat, path: "/chat"),
        Route("mail.google.com", .mail), Route("outlook.live.com", .mail), Route("outlook.office.com", .mail),
        Route("outlook.office365.com", .mail), Route("mail.yahoo.com", .mail), Route("app.fastmail.com", .mail),
        Route("mail.proton.me", .mail), Route("mail.zoho.com", .mail), Route("icloud.com", .mail, path: "/mail"),
        Route("hey.com", .mail), Route("app.hey.com", .mail), Route("superhuman.com", .mail),
        // spreadsheets (E2): cells
        Route("docs.google.com", .prose, path: "/spreadsheets", spreadsheet: true),
        Route("airtable.com", .prose, spreadsheet: true),
        Route("icloud.com", .prose, path: "/numbers", spreadsheet: true),
        // documents
        Route("docs.google.com", .prose), Route("notion.so", .prose), Route("www.notion.so", .prose),
        Route("coda.io", .prose), Route("quip.com", .prose), Route("dropbox.com", .prose, path: "/paper"),
        // chat
        Route("app.slack.com", .chat), Route("web.whatsapp.com", .chat), Route("discord.com", .chat, path: "/channels"),
        Route("teams.microsoft.com", .chat), Route("teams.live.com", .chat), Route("web.telegram.org", .chat),
        Route("messenger.com", .chat), Route("chat.google.com", .chat),
        Route("web.skype.com", .chat), Route("app.element.io", .chat), Route("linkedin.com", .chat, path: "/messaging"),
        Route("chatgpt.com", .chat), Route("chat.openai.com", .chat), Route("claude.ai", .chat),
        Route("gemini.google.com", .chat), Route("instagram.com", .chat, path: "/direct"),
        // code: GitHub's prose surfaces (issues, pull requests, discussions) stay prose — a
        // review comment is a sentence; the rest of the site (file editor, gists) is code.
        Route("github.com", .prose, path: "/*/*/issues"), Route("github.com", .prose, path: "/*/*/pull"),
        Route("github.com", .prose, path: "/*/*/discussions"),
        Route("github.com", .code), Route("gist.github.com", .code), Route("github.dev", .code),
        Route("vscode.dev", .code), Route("gitlab.com", .code), Route("bitbucket.org", .code),
        Route("codepen.io", .code), Route("codesandbox.io", .code), Route("replit.com", .code),
        Route("colab.research.google.com", .code), Route("stackblitz.com", .code),
        Route("leetcode.com", .code, path: "/problems"),
        // terminals in the browser
        Route("shell.cloud.google.com", .terminal), Route("ssh.cloud.google.com", .terminal),
        Route("console.aws.amazon.com", .terminal, path: "/cloudshell"),
    ]

    /// Window-title fallback (no URL, e.g. an app that hides `AXURL`): the title's last
    /// " - " / " | " / " – " segment, or the whole title, matched against these names.
    static let titleNames: [(name: String, host: String, category: AppCategory)] = [
        ("gmail", "mail.google.com", .mail), ("outlook", "outlook.office.com", .mail),
        ("slack", "app.slack.com", .chat), ("whatsapp", "web.whatsapp.com", .chat),
        ("discord", "discord.com", .chat), ("microsoft teams", "teams.microsoft.com", .chat),
        ("telegram", "web.telegram.org", .chat), ("messenger", "messenger.com", .chat),
        ("google sheets", "docs.google.com", .prose), ("google docs", "docs.google.com", .prose),
        ("github", "github.com", .code), ("chatgpt", "chatgpt.com", .chat), ("claude", "claude.ai", .chat),
    ]

    /// The sub-app for a browser document, from its URL first and its title second. `nil` when
    /// neither names a known sub-app (the browser's own category then applies).
    public static func resolve(url: String?, title: String? = nil) -> BrowserSubApp? {
        if let parsed = url.flatMap(URL.init(string:)), let rawHost = parsed.host?.lowercased(), !rawHost.isEmpty {
            let host = normalized(host: rawHost)
            let path = parsed.path.lowercased()
            for route in routes where matches(host: host, route.host) && matches(path: path, route.pathPrefix) {
                return BrowserSubApp(host: host, category: route.category, isSpreadsheet: route.isSpreadsheet)
            }
            return nil
        }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let segments = title.lowercased().components(separatedBy: CharacterSet(charactersIn: "-|–—"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The app name is the last segment ("Inbox (3) - me@x.io - Gmail"), or the first for
        // apps that lead with it ("Slack | general | Acme"); match whole segments only.
        for candidate in [segments.last, segments.first].compactMap({ $0 }) {
            let bare = candidate.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            if let hit = titleNames.first(where: { $0.name == bare }) {
                let sheet = bare == "google sheets"
                return BrowserSubApp(host: hit.host, category: hit.category, isSpreadsheet: sheet)
            }
        }
        return nil
    }

    static func normalized(host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func matches(host: String, _ pattern: String) -> Bool {
        let p = normalized(host: pattern)
        return host == p || host.hasSuffix("." + p)
    }

    /// `nil` matches any path; `*` matches one path component (`/*/*/pull` = `/owner/repo/pull…`).
    static func matches(path: String, _ prefix: String?) -> Bool {
        guard let prefix else { return true }
        guard prefix.contains("*") else { return path.hasPrefix(prefix) }
        let want = prefix.split(separator: "/"), have = path.split(separator: "/")
        guard have.count >= want.count else { return false }
        for (w, h) in zip(want, have) where w != "*" && w != h { return false }
        return true
    }
}

public extension AppCategoryTable {
    /// V5 E5 — category for a `bundle|host` persona key: the host's sub-app when it has one, the
    /// bundle's category otherwise. A plain bundle ID behaves exactly like `category(for:)`.
    static func category(forKey key: String?) -> AppCategory {
        guard let key else { return .prose }
        let (bundle, host) = BrowserSubApp.split(key: key)
        if let host, let sub = BrowserSubApp.resolve(url: "https://\(host)/") { return sub.category }
        return category(for: bundle)
    }
}
