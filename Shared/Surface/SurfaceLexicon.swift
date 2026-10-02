import Foundation

/// N9 — the resolver's data: field-label phrases and web URL patterns, each pointing at a
/// surface kind with a weight (R3 §E1). This is data, not code: a new site or label is a row.
/// Phrases are matched as whole words ("codex" never matches "code", "curl" never "url").
public enum SurfaceLexicon {
    public struct Phrase: Sendable {
        public var words: [String]
        public var kind: SurfaceKind
        public var weight: Double
        /// Only on a one-line field (form-field labels).
        public var singleLineOnly: Bool
        /// Only outside web content (browser chrome: the address bar).
        public var outsideWebOnly: Bool
        public init(_ phrase: String, _ kind: SurfaceKind, _ weight: Double,
                    singleLineOnly: Bool = false, outsideWebOnly: Bool = false) {
            self.words = SurfaceLexicon.words(phrase); self.kind = kind; self.weight = weight
            self.singleLineOnly = singleLineOnly; self.outsideWebOnly = outsideWebOnly
        }
    }

    static func form(_ label: String) -> SurfaceKind { .formField(label: label) }

    /// Field label / placeholder / description phrases. Strong (3–4) for explicit labels,
    /// 2.5 for implementation hints (xterm, monaco), lower for loose words.
    public static let phrases: [Phrase] = {
        var p: [Phrase] = []
        // Address bar (browser chrome only).
        for s in ["address and search bar", "search or enter website name", "search or type url",
                  "search or type a url", "search or enter address", "smart search field", "address bar",
                  "location bar", "enter address", "omnibox"] {
            p.append(Phrase(s, .urlBar, 4, outsideWebOnly: true))
        }
        // Terminals and REPLs.
        for s in ["terminal", "terminal input", "xterm", "console", "repl", "shell", "shell prompt",
                  "command line", "tmux", "pty"] { p.append(Phrase(s, .terminal, 2.5)) }
        // Source editors.
        for s in ["monaco", "monaco editor", "code editor", "source editor", "codemirror", "cm content",
                  "ace text input", "editor content", "sourceeditor", "source code"] { p.append(Phrase(s, .codeEditor, 2.5)) }
        // Markdown-aware editors.
        for s in ["markdown", "markdown editor", "markdown value"] { p.append(Phrase(s, .markdownEditor, 2.5)) }
        // Chat / prompt composers.
        for s in ["message", "send a message", "type a message", "write a message", "new message", "reply",
                  "chat", "chat input", "ask", "ask anything", "prompt", "composer", "message composer",
                  "start a new message", "write a reply"] { p.append(Phrase(s, .chatComposer, 2.5)) }
        // Mail compose bodies.
        for s in ["message body", "email body", "mail body", "compose body"] { p.append(Phrase(s, .emailBody, 3)) }
        p.append(Phrase("body", .emailBody, 1.5))
        // Search / find.
        for s in ["search", "find", "filter", "query", "search mail", "find in page"] { p.append(Phrase(s, .searchField, 3)) }
        // Spreadsheets.
        for s in ["formula bar", "formula", "cell editor"] { p.append(Phrase(s, .spreadsheetCell, 3)) }
        // Canvas.
        p.append(Phrase("canvas", .canvas, 3))
        // Label-typed form fields (one-line only).
        let forms: [(String, [String])] = [
            ("email", ["email", "e mail", "email address", "mail address"]),
            ("phone", ["phone", "telephone", "mobile", "tel", "cell phone", "phone number", "mobile number"]),
            ("url", ["url", "website", "web address", "homepage", "web site", "link"]),
            ("name", ["name", "first name", "last name", "full name", "your name", "given name", "family name", "surname"]),
            ("number", ["number", "amount", "quantity", "zip", "zip code", "postal code", "postcode", "age", "price"]),
            ("date", ["date", "birthday", "date of birth", "dob"]),
            ("subject", ["subject", "title"]),
            ("recipient", ["to", "cc", "bcc", "recipients"]),
            ("address", ["street address", "address line", "street", "city"]),
        ]
        for (label, list) in forms { for s in list { p.append(Phrase(s, form(label), 3, singleLineOnly: true)) } }
        return p
    }()

    /// Phrases that also name a password field: a veto on a text-entry role.
    public static let passwordWords: [[String]] = ["password", "passcode", "passwort", "contraseña",
                                                   "mot de passe", "passphrase"].map(words)

    public struct URLPattern: Sendable {
        public var host: String
        /// `nil` = any path; `*` matches one path component.
        public var path: String?
        public var kind: SurfaceKind
        public var weight: Double
        public init(_ host: String, _ kind: SurfaceKind, _ weight: Double = 2.5, path: String? = nil) {
            self.host = host; self.path = path; self.kind = kind; self.weight = weight
        }
    }

    /// Web content: host (and any subdomain) plus optional path prefix → kind. Every matching
    /// row adds its weight; nothing here is "first match wins".
    public static let urlPatterns: [URLPattern] = [
        // spreadsheets (gated on cell-like structure by the resolver)
        URLPattern("docs.google.com", .spreadsheetCell, path: "/spreadsheets"),
        URLPattern("airtable.com", .spreadsheetCell), URLPattern("icloud.com", .spreadsheetCell, path: "/numbers"),
        // mail
        URLPattern("mail.google.com", .emailBody, 2), URLPattern("outlook.live.com", .emailBody, 2),
        URLPattern("outlook.office.com", .emailBody, 2), URLPattern("outlook.office365.com", .emailBody, 2),
        URLPattern("mail.yahoo.com", .emailBody, 2), URLPattern("app.fastmail.com", .emailBody, 2),
        URLPattern("mail.proton.me", .emailBody, 2), URLPattern("icloud.com", .emailBody, 2, path: "/mail"),
        URLPattern("mail.google.com", .chatComposer, 3, path: "/chat"),
        // chat and assistants
        URLPattern("chatgpt.com", .chatComposer), URLPattern("chat.openai.com", .chatComposer),
        URLPattern("claude.ai", .chatComposer), URLPattern("gemini.google.com", .chatComposer),
        URLPattern("app.slack.com", .chatComposer), URLPattern("discord.com", .chatComposer, path: "/channels"),
        URLPattern("web.whatsapp.com", .chatComposer), URLPattern("messenger.com", .chatComposer),
        URLPattern("teams.microsoft.com", .chatComposer), URLPattern("teams.live.com", .chatComposer),
        URLPattern("web.telegram.org", .chatComposer), URLPattern("chat.google.com", .chatComposer),
        URLPattern("perplexity.ai", .chatComposer), URLPattern("linkedin.com", .chatComposer, path: "/messaging"),
        // Markdown-accepting editors
        URLPattern("github.com", .markdownEditor, 2, path: "/*/*/issues"),
        URLPattern("github.com", .markdownEditor, 2, path: "/*/*/pull"),
        URLPattern("github.com", .markdownEditor, 2, path: "/*/*/discussions"),
        URLPattern("gitlab.com", .markdownEditor, 1.5, path: "/*/*/-/issues"),
        URLPattern("notion.so", .markdownEditor, 2), URLPattern("coda.io", .markdownEditor, 1.5),
        URLPattern("hackmd.io", .markdownEditor, 2),
        // code
        URLPattern("github.com", .codeEditor, 2, path: "/*/*/edit"), URLPattern("gist.github.com", .codeEditor, 2),
        URLPattern("github.dev", .codeEditor), URLPattern("vscode.dev", .codeEditor),
        URLPattern("codepen.io", .codeEditor, 2), URLPattern("codesandbox.io", .codeEditor, 2),
        URLPattern("replit.com", .codeEditor, 2), URLPattern("colab.research.google.com", .codeEditor, 2),
        URLPattern("stackblitz.com", .codeEditor, 2),
        // documents
        URLPattern("docs.google.com", .prose, 1.5, path: "/document"),
        // terminals in the browser
        URLPattern("shell.cloud.google.com", .terminal), URLPattern("ssh.cloud.google.com", .terminal),
        URLPattern("console.aws.amazon.com", .terminal, path: "/cloudshell"),
    ]

    /// Lowercased letter/digit runs, camelCase split ("FancyMail" → fancy, mail).
    public static func words(_ text: String) -> [String] {
        var spaced = ""
        var prev: Character?
        for ch in text {
            if let p = prev, p.isLowercase, ch.isUppercase { spaced.append(" ") }
            spaced.append(ch); prev = ch
        }
        return spaced.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// True when `needle` occurs in `haystack` as a contiguous run of whole words.
    public static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle { return true }
        return false
    }

    static func matches(host: String, _ pattern: String) -> Bool {
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h == pattern || h.hasSuffix("." + pattern)
    }

    static func matches(path: String, _ prefix: String?) -> Bool {
        guard let prefix else { return true }
        guard prefix.contains("*") else { return path.hasPrefix(prefix) }
        let want = prefix.split(separator: "/"), have = path.split(separator: "/")
        guard have.count >= want.count else { return false }
        for (w, h) in zip(want, have) where w != "*" && w != h { return false }
        return true
    }

    /// Every URL pattern row the URL matches.
    public static func urlMatches(_ url: String?) -> [(host: String, pattern: URLPattern)] {
        guard let url, let parsed = URL(string: url), let host = parsed.host?.lowercased(), !host.isEmpty else { return [] }
        let path = parsed.path.lowercased()
        return urlPatterns.filter { matches(host: host, $0.host) && matches(path: path, $0.path?.lowercased()) }
            .map { (host, $0) }
    }
}
