import Foundation
import Pipeline
import Shared

/// Context Writer §2.1 / §3 — the destination record: a profile id and the surface-specific
/// fields, from the surface the resolver already produced, the app (seed family), the browser
/// sub-app (URL host), the field's AX labels, the window title and — for terminals — the tty's
/// foreground process. Only what was actually found goes into `fields`; nothing is inferred
/// from the text being dictated.
enum DestinationProfiles {
    /// Everything the record is made from (the builder fills it from the turn snapshot).
    struct Facts {
        var surface: SurfaceResolution
        var bundleID: String?
        var appName: String?
        var hints: [String] = []
        /// `www.`-stripped host of the web document, when the field is in one.
        var host: String?
        var urlPath: String?
        var windowTitle: String?
        var documentTitle: String?
        var isMultiline: Bool?
        var textBefore = ""
        /// The thread / document tail (quoted-mail detection).
        var tail: String?
        var shell: ShellContext?
        var foregroundProcess: String?
        var participants: [String] = []
        var observation: ThreadParticipants.Observation?
        var columnHeader: String?
        var heardWords: [String] = []
        /// Headings above the caret, nearest first (H21 neighbourhood).
        var headings: [String] = []
        /// The app rule allows screen text (titles, labels, hosts are screen reads too).
        var screenAllowed = true
    }

    struct Limits {
        var value = 200
        var entries = 240
        var commands = 40
    }

    // MARK: Detection tables (bundle ids and hosts; data, not instructions)

    static let aiAssistantBundles: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "ai.perplexity.mac", "com.google.Gemini",
        "ai.perplexity.comet", "com.mistral.lechat",
    ]
    static let aiAssistantHosts: [String] = [
        "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "perplexity.ai", "chat.deepseek.com",
        "chat.mistral.ai", "grok.com", "copilot.microsoft.com", "poe.com", "t3.chat", "chat.qwen.ai", "kimi.com",
        "aistudio.google.com", "notebooklm.google.com", "huggingface.co",
    ]
    static let slidesBundles: Set<String> = ["com.apple.iWork.Keynote", "com.microsoft.Powerpoint"]
    static let calendarBundles: Set<String> = [
        "com.apple.iCal", "com.flexibits.fantastical2.mac", "com.flexibits.fantastical3.mac", "com.busymac.busycal3",
        "com.busymac.busycal", "com.notion.calendar",
    ]
    static let calendarHosts: [String] = ["calendar.google.com", "calendar.notion.so", "cal.com", "calendly.com"]
    static let socialHosts: [String] = [
        "x.com", "twitter.com", "linkedin.com", "threads.net", "threads.com", "bsky.app", "mastodon.social",
        "instagram.com", "facebook.com", "reddit.com", "news.ycombinator.com", "producthunt.com",
    ]
    static let socialBundles: Set<String> = ["com.twitter.twitter-mac", "maccatalyst.com.atebits.Tweetie2", "app.bsky.deck"]
    static let notesBundles: Set<String> = [
        "com.apple.Notes", "net.shinyfrog.bear", "com.agiletortoise.Drafts-OSX", "com.culturedcode.ThingsMac",
        "com.apple.reminders", "com.omnigroup.OmniFocus4", "com.omnigroup.OmniFocus3", "com.todoist.mac.Todoist",
        "com.lukilabs.lukiapp", "com.reflect.ReflectDesktop", "com.apple.Stickies",
    ]
    static let notesHosts: [String] = ["keep.google.com", "todoist.com", "app.todoist.com"]
    static let gitClientBundles: Set<String> = [
        "com.github.GitHubClient", "com.fournova.Tower3", "com.fournova.Tower2", "com.DanPristupov.Fork",
        "com.torusknot.SourceTreeNotMAS", "com.sublimemerge", "com.gitkraken.GitKraken", "com.jeffpanici.gitup",
    ]

    static func hostMatches(_ host: String?, _ list: [String]) -> Bool {
        guard let host, !host.isEmpty else { return false }
        return list.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func hintsContain(_ hints: [String], _ needles: String...) -> Bool {
        hints.contains { h in needles.contains { h.range(of: $0, options: .caseInsensitive) != nil } }
    }

    // MARK: Classification

    static func family(_ f: Facts) -> SeedHints.Family? { SeedHints.hint(for: f.bundleID)?.family }

    static func subAppCategory(_ f: Facts) -> AppCategory? {
        guard f.screenAllowed else { return nil }
        guard let host = f.host else { return nil }
        return BrowserSubApp.resolve(url: "https://\(host)\(f.urlPath ?? "/")")?.category
    }

    static func isAIAssistant(_ f: Facts) -> Bool {
        if let b = f.bundleID, aiAssistantBundles.contains(b) { return true }
        return hostMatches(f.host, aiAssistantHosts)
    }

    static func isMail(_ f: Facts) -> Bool { family(f) == .mail || subAppCategory(f) == .mail }
    static func isChat(_ f: Facts) -> Bool { family(f) == .chat || subAppCategory(f) == .chat }
    static func isSlides(_ f: Facts) -> Bool {
        if let b = f.bundleID, slidesBundles.contains(b) { return true }
        return f.host == "docs.google.com" && (f.urlPath ?? "").hasPrefix("/presentation")
    }
    static func isCalendar(_ f: Facts) -> Bool {
        if let b = f.bundleID, calendarBundles.contains(b) { return true }
        if hostMatches(f.host, calendarHosts) { return true }
        return hostMatches(f.host, ["outlook.office.com", "outlook.live.com"]) && (f.urlPath ?? "").hasPrefix("/calendar")
    }
    static func isSocial(_ f: Facts) -> Bool {
        if let b = f.bundleID, socialBundles.contains(b) { return true }
        return hostMatches(f.host, socialHosts)
    }
    static func isNotes(_ f: Facts) -> Bool {
        if let b = f.bundleID, notesBundles.contains(b) { return true }
        return hostMatches(f.host, notesHosts)
    }
    static func isCommit(_ f: Facts) -> Bool {
        if let b = f.bundleID, gitClientBundles.contains(b) { return true }
        if f.windowTitle?.contains("COMMIT_EDITMSG") == true { return true }
        return hintsContain(f.hints, "commit", "source control")
    }

    /// Slides / calendar boxes from the field's labels.
    static func box(_ f: Facts) -> String {
        if hintsContain(f.hints, "note") { return "notes" }
        if hintsContain(f.hints, "title") { return "title" }
        if f.isMultiline == false { return "title" }
        return "body"
    }

    static func profileID(_ f: Facts) -> String {
        switch f.surface.kind {
        case .secure: return "secure"
        case .canvas: return "unknown"
        case .terminal: return TTYForegroundProcess.isAgent(f.foregroundProcess) ? "ai.agentCLI" : "shell"
        case .spreadsheetCell: return "spreadsheet.cell"
        case .urlBar: return "browser.urlBar"
        case .searchField: return "search"
        case .chatComposer: return isAIAssistant(f) ? "ai.chat" : "chat.message"
        case .emailBody: return emailBody(f)
        case .codeEditor:
            if isCommit(f) { return "commit" }
            let language = CodeFileFacts.language(forPath: CodeFileFacts.filePath(fromTitle: f.windowTitle))
            return CodeFileFacts.caretRegion(textBefore: f.textBefore, language: language) == .code ? "code.body" : "code.comment"
        case .markdownEditor: return isCommit(f) ? "commit" : "markdown"
        case .formField(let label):
            if isCommit(f) { return "commit" }
            if isMail(f), label == "subject" || hintsContain(f.hints, "subject") { return "email.subject" }
            if isCalendar(f) { return "calendar.\(box(f) == "notes" ? "notes" : "title")" }
            if isSlides(f) { return "slides.\(box(f))" }
            return "form"
        case .prose:
            if isCommit(f) { return "commit" }
            if isSlides(f) { return "slides.\(box(f))" }
            if isCalendar(f) { return f.isMultiline == false ? "calendar.title" : "calendar.notes" }
            if isSocial(f) { return "social" }
            if isNotes(f) { return "notes" }
            if isAIAssistant(f) { return "ai.chat" }
            if isChat(f) { return "chat.message" }
            if isMail(f), f.isMultiline != false { return emailBody(f) }
            return "document"
        }
    }

    static func emailBody(_ f: Facts) -> String {
        let subject = EmailFacts.subject(windowTitle: f.windowTitle, documentTitle: f.documentTitle, appName: f.appName)
        let quoted = EmailFacts.quotedFrom(in: f.tail)
        return EmailFacts.isReply(subject: subject, quotedFrom: quoted, tail: f.tail) ? "email.body.reply" : "email.body.new"
    }

    // MARK: The record

    static func record(_ f: Facts, limits: Limits = Limits()) -> ContextPacket.Destination {
        let profile = profileID(f)
        var fields: [String: String] = [:]
        func put(_ key: String, _ value: String?, cap: Int? = nil) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            fields[key] = String(v.prefix(cap ?? limits.value))
        }
        // Process-tree facts are not screen text: they stay even with contextual reading off.
        if let shell = f.shell, f.surface.kind == .terminal {
            put("shell", shell.shellName)
            put("cwd", shell.currentDirectory)
            put("entries", shell.entries.isEmpty ? nil : shell.entries.map(\.displayName).joined(separator: ", "), cap: limits.entries)
            put("knownCommands", heardCommands(f.heardWords, shell: shell, cap: limits.commands))
            put("foregroundProcess", f.foregroundProcess)
        }
        guard f.screenAllowed, f.surface.kind != .secure else {
            return ContextPacket.Destination(profileID: profile, appName: f.appName, appBundleID: f.bundleID,
                                             surfaceKind: f.surface.kind.id, fields: fields)
        }
        put("windowTitle", f.windowTitle)
        if f.documentTitle != f.windowTitle { put("documentTitle", f.documentTitle) }
        put("urlHost", f.host)
        switch profile {
        case "chat.message", "ai.chat":
            let channel = f.participants.first ?? f.windowTitle.flatMap(ThreadParticipants.chatTitle(from:))
            put("channel", channel)
            if f.participants.count > 1 { put("participants", f.participants.joined(separator: ", ")) }
        case "email.body.reply", "email.body.new", "email.subject":
            let recipients = EmailFacts.recipients(observation: f.observation, participants: f.participants)
            put("to", recipients.to)
            put("cc", recipients.cc)
            if profile != "email.subject" {
                put("subject", EmailFacts.subject(windowTitle: f.windowTitle, documentTitle: f.documentTitle, appName: f.appName))
                put("quotedFrom", EmailFacts.quotedFrom(in: f.tail))
            }
        case "code.body", "code.comment", "commit":
            let path = CodeFileFacts.filePath(fromTitle: f.windowTitle)
            let language = CodeFileFacts.language(forPath: path)
            put("filePath", path)
            put("language", language)
            if f.surface.kind == .codeEditor {
                put("caretRegion", CodeFileFacts.caretRegion(textBefore: f.textBefore, language: language).rawValue)
            }
        case "document", "markdown", "notes":
            put("heading", f.headings.first)
        case "slides.title", "slides.body", "slides.notes", "calendar.title", "calendar.notes":
            put("box", profile.split(separator: ".").last.map(String.init))
        case "spreadsheet.cell":
            put("headers", f.columnHeader)
            put("activeCell", f.hints.first { isCellReference($0) })
        case "form", "search":
            put("label", fieldLabel(f.hints))
            if case .formField(let kind) = f.surface.kind, kind != "text" { put("inputType", kind) }
        default: break
        }
        return ContextPacket.Destination(profileID: profile, appName: f.appName, appBundleID: f.bundleID,
                                         surfaceKind: f.surface.kind.id, fields: fields)
    }

    /// The shell's commands the user may have said: a heard word (or `a-b` / `a_b` spelling of two
    /// adjacent words) that is a known command. The whole `$PATH` would not fit a record.
    static func heardCommands(_ words: [String], shell: ShellContext, cap: Int) -> String? {
        let known = shell.allCommands
        var out: [String] = []
        var seen: Set<String> = []
        let cleaned = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        func add(_ w: String) { if known.contains(w), seen.insert(w).inserted { out.append(w) } }
        for (i, w) in cleaned.enumerated() {
            add(w)
            if i + 1 < cleaned.count {
                add(w + "-" + cleaned[i + 1]); add(w + "_" + cleaned[i + 1]); add(w + cleaned[i + 1])
            }
        }
        return out.isEmpty ? nil : out.prefix(cap).joined(separator: ", ")
    }

    static let roleDescriptions: Set<String> = [
        "text field", "text area", "text entry area", "search text field", "text", "edit text", "combo box",
        "secure text field", "editable text", "textbox", "textarea", "contenteditable",
    ]

    /// The field's own label: the first hint that is not an identifier or a role description.
    static func fieldLabel(_ hints: [String]) -> String? {
        hints.first { h in
            !h.isEmpty && !h.hasPrefix("_") && !roleDescriptions.contains(h.lowercased()) && h.count <= 80
                && !h.contains("-") && h.contains(where: \.isLetter)
        }
    }

    static func isCellReference(_ s: String) -> Bool {
        let letters = s.prefix { $0.isLetter }
        let digits = s.dropFirst(letters.count)
        return (1...3).contains(letters.count) && letters.allSatisfy(\.isUppercase)
            && (1...7).contains(digits.count) && digits.allSatisfy(\.isNumber)
    }
}
