import Engine
import Foundation
import Injection
import Pipeline
import Shared
import Testing
@testable import VoicePlusApp

/// Context Writer §2 — the packet builder over synthetic key-down snapshots: destination
/// profiles and fields per surface, bounds, the secure and contextual-reading-off promises,
/// the raw heard words, and the injected sources (vocabulary, history, persona, language).
@Suite("Context Writer · packet builder")
struct ContextPacketBuilderTests {
    // MARK: Fixtures

    static func surface(_ kind: SurfaceKind, web: Bool = false) -> SurfaceResolution {
        SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: web, signals: ["test"])
    }

    static func resolved(_ bundle: String, pid: Int32 = 100, kind: SurfaceKind, shell: ShellContext? = nil,
                         before: String = "", after: String = "", title: String? = nil, app: String = "App",
                         secure: Bool = false) -> TurnSurfaceContext.Resolved {
        var r = TurnSurfaceContext.Resolved(bundleID: bundle, pid: pid, surface: surface(kind), shell: shell, shellDecided: false)
        r.nearCaret = TurnSurfaceContext.NearCaretContext(before: before, after: after, fieldLabel: nil, windowTitle: title,
                                                          appName: app, surfaceKind: kind, isSecure: secure)
        return r
    }

    static func contents(pid: Int32 = 100, title: String?, blocks: [String] = [], tail: String? = nil,
                         near: CaretNeighbourhood? = nil) -> TurnContextContents {
        let content = WindowContent(window: AXWindowID(pid: pid, windowNumber: 1), title: title,
                                    blocks: blocks.enumerated().map { TextBlock(role: "AXStaticText", text: $1, visibleRange: nil, totalCharacters: $1.count, depth: $0 + 2) },
                                    truncated: false, nodesVisited: blocks.count + 1, readAt: Date())
        return TurnContextContents(target: TurnContextTarget(pid: pid, bundleID: ""), content: content, documentTail: tail,
                                   startedAt: Date(), readMs: 5, nearCaret: near)
    }

    static func spans(_ text: String, uncertain: Set<String> = [], alternates: [String: [String]] = [:]) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            let word = String(w)
            let alts = (alternates[word] ?? []).enumerated().map { Alternate(text: $1, score: 1 - Float($0) * 0.1, source: .beam) }
            return TranscriptSpan(text: word, confidence: uncertain.contains(word) ? 0.3 : 0.9,
                                  audioRange: Double(i) * 0.4...Double(i) * 0.4 + 0.3, alternates: alts, provenance: [.asr])
        }
    }

    static func builder(reading: Bool = true) -> ContextPacketBuilder {
        let b = ContextPacketBuilder()
        b.contextualReading = { _ in reading }
        return b
    }

    static let slackTail = """
    Priya Kothari

    10:41 AM

    Can you send the Q3 deck before the call?

    You

    10:42 AM

    Sure, after lunch
    """

    // MARK: Surfaces

    @Test func slackDMIsAChatMessageWithChannelAndAuthoredThread() {
        let bundle = "com.tinyspeck.slackmacgap"
        var field = FieldContext(appBundleID: bundle, axRole: "AXTextArea", hints: ["Message to Priya Kothari"], textBeforeCursor: "")
        field.participants = ["Priya Kothari"]
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Slack"),
            resolved: Self.resolved(bundle, kind: .chatComposer, title: "Priya Kothari (DM) - Acme - Slack"),
            field: field,
            contents: Self.contents(title: "Priya Kothari (DM) - Acme - Slack", tail: Self.slackTail),
            spans: Self.spans("sure after lunch"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "chat.message")
        #expect(p.destination.surfaceKind == "chatComposer")
        #expect(p.destination.appName == "Slack")
        #expect(p.destination.fields["channel"] == "Priya Kothari")
        #expect(p.destination.fields["windowTitle"] == "Priya Kothari (DM) - Acme - Slack")
        #expect(p.thread.count == 2, "\(p.thread)")
        #expect(p.thread.first?.author == "Priya Kothari")
        #expect(p.thread.first?.text == "Can you send the Q3 deck before the call?")
        #expect(p.thread.first?.isSelf == false)
        #expect(p.thread.last?.author == "You")
        #expect(p.thread.last?.isSelf == true)
        #expect(p.thread.last?.text == "Sure, after lunch")
        #expect(!p.isSecure)
        #expect(p.heard.raw == "sure after lunch")
    }

    @Test func mailReplyCarriesToSubjectAndQuotedSender() {
        let bundle = "com.apple.mail"
        var field = FieldContext(appBundleID: bundle, axRole: "AXTextArea", isMultiline: true, textBeforeCursor: "Hi Rahul,\n\n")
        field.participants = ["Rahul Mehta <rahul@x.io>", "Sam Lee"]
        let tail = "Thanks for the numbers.\n\nOn 6 Oct 2026, at 09:12, Rahul Mehta <rahul@x.io> wrote:\n\nHere is the Q3 budget draft."
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Mail"),
            resolved: Self.resolved(bundle, kind: .emailBody, before: "Hi Rahul,\n\n", title: "Re: Q3 budget"),
            field: field,
            contents: Self.contents(title: "Re: Q3 budget", tail: tail),
            spans: Self.spans("looks good"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "email.body.reply")
        #expect(p.destination.fields["to"] == "Rahul Mehta <rahul@x.io>, Sam Lee")
        #expect(p.destination.fields["subject"] == "Re: Q3 budget")
        #expect(p.destination.fields["quotedFrom"] == "Rahul Mehta")
        #expect(p.textBefore == "Hi Rahul,\n\n")
        #expect(p.thread.contains { $0.text.contains("Q3 budget draft") })
    }

    @Test func mailWithObservationSplitsToFromCc() {
        let bundle = "com.apple.mail"
        let observation = ThreadParticipants.Observation(fields: [.init(label: "To:", value: "Rahul Mehta"), .init(label: "Cc:", value: "Sam Lee; Ana")],
                                                         title: "Budget")
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Mail"),
            resolved: Self.resolved(bundle, kind: .emailBody, title: "Budget"),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea", isMultiline: true),
            contents: Self.contents(title: "Budget"),
            participantObservation: observation, spans: Self.spans("hello"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "email.body.new", "no Re: and no quoted block → a new mail")
        #expect(p.destination.fields["to"] == "Rahul Mehta")
        #expect(p.destination.fields["cc"] == "Sam Lee, Ana")
        #expect(p.destination.fields["subject"] == "Budget")
        #expect(p.destination.fields["quotedFrom"] == nil)
    }

    @Test func mailSubjectFieldIsEmailSubject() {
        let bundle = "com.apple.mail"
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Mail"),
            resolved: Self.resolved(bundle, kind: .formField(label: "subject"), title: "New Message"),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextField", hints: ["Subject"]),
            spans: Self.spans("budget"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "email.subject")
        #expect(p.destination.fields["subject"] == nil)
    }

    @Test func claudeComposerIsAIChatWithABoundedOldestFirstThread() {
        let bundle = "com.anthropic.claudefordesktop"
        var paragraphs: [String] = []
        for i in 1...30 { paragraphs.append("Paragraph \(i) of the assistant's answer about the deployment plan and its rollback steps.") }
        let tail = paragraphs.joined(separator: "\n\n")
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Claude"),
            resolved: Self.resolved(bundle, kind: .chatComposer, title: "Deployment plan — Claude"),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea", hints: ["Write your prompt to Claude"]),
            contents: Self.contents(title: "Deployment plan — Claude", tail: tail),
            spans: Self.spans("now do the rollback"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "ai.chat")
        let total = p.thread.reduce(0) { $0 + $1.text.count }
        #expect(total <= 1_500)
        #expect(!p.thread.isEmpty)
        #expect(p.thread.last?.text.hasPrefix("Paragraph 30") == true, "the newest block is kept")
        #expect(p.thread.first?.text.contains("Paragraph 1 ") == false, "the oldest blocks are dropped first")
        let numbers = p.thread.compactMap { Int($0.text.split(separator: " ").dropFirst().first.map(String.init) ?? "") }
        #expect(numbers == numbers.sorted(), "oldest first")
    }

    @Test func claudeWebWithSaidHeadersSplitsAuthors() {
        let bundle = "com.google.Chrome"
        let tail = "You said:\nWhat is the capital of Bhutan?\n\nChatGPT said:\nThimphu is the capital of Bhutan."
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Google Chrome"),
            resolved: Self.resolved(bundle, kind: .chatComposer),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea", documentURL: "https://chatgpt.com/c/abc"),
            contents: Self.contents(title: "ChatGPT", tail: tail),
            spans: Self.spans("and its population"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "ai.chat")
        #expect(p.destination.fields["urlHost"] == "chatgpt.com")
        #expect(p.thread.map(\.author) == ["You", "ChatGPT"])
        #expect(p.thread.first?.isSelf == true)
        #expect(p.thread.last?.text == "Thimphu is the capital of Bhutan.")
    }

    static let shell = ShellContext(pid: 4300, shellName: "zsh", tty: "/dev/ttys004", currentDirectory: "/Users/me/proj",
                                    entries: [.init(name: "Sources", isDirectory: true), .init(name: "README.md", isDirectory: false)],
                                    knownCommands: ["git", "ls", "swift", "kubectl"])

    @Test func terminalAtThePromptIsShellWithCwdEntriesAndHeardCommands() {
        let bundle = "com.apple.Terminal"
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Terminal"),
            resolved: Self.resolved(bundle, kind: .terminal, shell: Self.shell, title: "me — zsh — 80×24"),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea"),
            contents: Self.contents(title: "me — zsh — 80×24", tail: "$ ls\nSources README.md\n$ "),
            foregroundProcess: nil,
            spans: Self.spans("git status then ls"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "shell")
        #expect(p.destination.fields["shell"] == "zsh")
        #expect(p.destination.fields["cwd"] == "/Users/me/proj")
        #expect(p.destination.fields["entries"] == "Sources/, README.md")
        #expect(p.destination.fields["knownCommands"] == "git, ls")
        #expect(p.destination.fields["foregroundProcess"] == nil)
    }

    @Test func terminalRunningClaudeCodeIsAnAgentCLI() {
        let bundle = "com.googlecode.iterm2"
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "iTerm2"),
            resolved: Self.resolved(bundle, kind: .terminal, shell: Self.shell),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea"),
            foregroundProcess: "claude",
            spans: Self.spans("fix the failing test"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "ai.agentCLI")
        #expect(p.destination.fields["foregroundProcess"] == "claude")
        #expect(p.destination.fields["cwd"] == "/Users/me/proj")
    }

    @Test func googleSheetsCellCarriesHeadersActiveCellAndHost() {
        let bundle = "com.google.Chrome"
        var field = FieldContext(appBundleID: bundle, axRole: "AXTextField", hints: ["B12", "Cell"],
                                 documentURL: "https://docs.google.com/spreadsheets/d/abc/edit", columnHeader: "Revenue")
        field.isInWebArea = true
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Google Chrome"),
            resolved: Self.resolved(bundle, kind: .spreadsheetCell, title: "Q3 - Google Sheets"),
            field: field,
            contents: Self.contents(title: "Q3 - Google Sheets"),
            spans: Self.spans("twelve thousand"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "spreadsheet.cell")
        #expect(p.destination.fields["headers"] == "Revenue")
        #expect(p.destination.fields["activeCell"] == "B12")
        #expect(p.destination.fields["urlHost"] == "docs.google.com")
    }

    @Test func codeEditorTellsCommentFromCodeAndNamesTheFile() {
        let bundle = "com.microsoft.VSCode"
        func packet(before: String, title: String) -> ContextPacket {
            Self.builder().build(ContextPacketBuilder.Input(
                app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Code"),
                resolved: Self.resolved(bundle, kind: .codeEditor, before: before, title: title),
                field: FieldContext(appBundleID: bundle, axRole: "AXTextArea", hints: ["Monaco editor"], textBeforeCursor: before),
                contents: Self.contents(title: title),
                spans: Self.spans("return nil")))
        }
        let comment = packet(before: "func land() {\n    // TODO: handle the ", title: "● Lander.swift — VoiceInput")
        #expect(comment.destination.profileID == "code.comment")
        #expect(comment.destination.fields["filePath"] == "Lander.swift")
        #expect(comment.destination.fields["language"] == "swift")
        #expect(comment.destination.fields["caretRegion"] == "comment")
        let code = packet(before: "func land() {\n    let x = ", title: "Lander.swift - VoiceInput - Visual Studio Code")
        #expect(code.destination.profileID == "code.body")
        #expect(code.destination.fields["caretRegion"] == "code")
        let string = packet(before: "print(\"hello ", title: "main.py — proj")
        #expect(string.destination.profileID == "code.comment")
        #expect(string.destination.fields["caretRegion"] == "string")
        #expect(string.destination.fields["language"] == "python")
        let commit = packet(before: "", title: "COMMIT_EDITMSG — VoiceInput")
        #expect(commit.destination.profileID == "commit")
    }

    @Test func documentKeepsTheHeadingAboveTheCaret() {
        let bundle = "com.apple.iWork.Pages"
        let near = CaretNeighbourhood(
            blocks: [TextBlock(role: "AXStaticText", text: "The rollout starts Monday.", visibleRange: nil, totalCharacters: 26, depth: 1),
                     TextBlock(role: "AXHeading", text: "Timeline", visibleRange: nil, totalCharacters: 8, depth: 2),
                     TextBlock(role: "AXHeading", text: "Q3 Plan", visibleRange: nil, totalCharacters: 7, depth: 3)],
            isBefore: [true, true, true], nodesVisited: 3)
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Pages"),
            resolved: Self.resolved(bundle, kind: .prose, before: "The rollout starts Monday. ", title: "Q3 Plan"),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea", textBeforeCursor: "The rollout starts Monday. "),
            contents: Self.contents(title: "Q3 Plan", near: near),
            spans: Self.spans("and ends friday"))
        let p = Self.builder().build(input)
        #expect(p.destination.profileID == "document")
        #expect(p.destination.fields["heading"] == "Timeline")
        #expect(p.thread.contains { $0.text == "Timeline" } || p.thread.contains { $0.text.contains("Q3 Plan") })
    }

    @Test func otherSurfacesMapToTheirProfiles() {
        func profile(_ bundle: String, _ kind: SurfaceKind, url: String? = nil, hints: [String] = [], multiline: Bool? = nil) -> String {
            Self.builder().build(ContextPacketBuilder.Input(
                app: FocusSnapshot(pid: 1, bundleID: bundle, appName: "X"),
                resolved: Self.resolved(bundle, kind: kind),
                field: FieldContext(appBundleID: bundle, axRole: "AXTextField", hints: hints, isMultiline: multiline, documentURL: url),
                spans: Self.spans("x"))).destination.profileID
        }
        #expect(profile("com.apple.Safari", .urlBar) == "browser.urlBar")
        #expect(profile("com.apple.finder", .searchField) == "search")
        #expect(profile("com.apple.Safari", .formField(label: "phone")) == "form")
        #expect(profile("com.apple.Notes", .prose) == "notes")
        #expect(profile("md.obsidian", .markdownEditor) == "markdown")
        #expect(profile("com.apple.iWork.Keynote", .prose, hints: ["Presenter Notes"]) == "slides.notes")
        #expect(profile("com.apple.iWork.Keynote", .prose, hints: ["Title"]) == "slides.title")
        #expect(profile("com.apple.iWork.Keynote", .prose) == "slides.body")
        #expect(profile("com.apple.iCal", .formField(label: "text"), hints: ["Title"]) == "calendar.title")
        #expect(profile("com.apple.iCal", .prose, multiline: true) == "calendar.notes")
        #expect(profile("com.google.Chrome", .prose, url: "https://x.com/compose/post") == "social")
        #expect(profile("com.google.Chrome", .prose, url: "https://www.linkedin.com/feed/") == "social")
        #expect(profile("com.github.GitHubClient", .formField(label: "text"), hints: ["Summary (required)"]) == "commit")
        #expect(profile("com.apple.TextEdit", .prose) == "document")
        #expect(profile("com.apple.Preview", .canvas) == "unknown")
    }

    // MARK: Privacy

    @Test func secureFieldGivesAnEmptyPacket() {
        let bundle = "com.1password.1password"
        var field = FieldContext(appBundleID: bundle, axRole: "AXTextField", axSubrole: "AXSecureTextField", textBeforeCursor: "hunter2")
        field.participants = ["Someone"]
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "1Password"),
            resolved: Self.resolved(bundle, kind: .secure, before: "hunter2", title: "Vault — Login", secure: true),
            field: field,
            contents: Self.contents(title: "Vault — Login", blocks: ["Password", "hunter2"], tail: "hunter2"),
            candidates: [ContextCandidate(text: "hunter2", source: .screenNear, caretDistance: 1)],
            spans: Self.spans("my password is hunter two"))
        let b = Self.builder()
        b.recentDictations = { _ in ["earlier dictation"] }
        b.persona = { _ in "casual" }
        let p = b.build(input)
        #expect(p.isSecure)
        #expect(p.destination.profileID == "secure")
        #expect(p.destination.fields.isEmpty)
        #expect(p.destination.appBundleID == nil && p.destination.appName == nil)
        #expect(p.textBefore.isEmpty && p.textAfter.isEmpty && p.thread.isEmpty && p.screenTerms.isEmpty)
        #expect(p.recentDictations.isEmpty && p.persona == nil)
        #expect(p.heard.raw.isEmpty && p.heard.words.isEmpty)
        let json = p.encoded()
        #expect(!json.contains("hunter"))
        #expect(!json.contains("Vault"))
        #expect(!json.contains("1Password"))
    }

    @Test func secureSubroleAloneIsEnough() {
        let field = FieldContext(appBundleID: "com.example", axRole: "AXTextField", axSubrole: "AXSecureTextField")
        let p = Self.builder().build(ContextPacketBuilder.Input(resolved: Self.resolved("com.example", kind: .prose), field: field,
                                                                spans: Self.spans("x")))
        #expect(p.isSecure && p.destination.profileID == "secure")
        let viaNeighbourhood = Self.builder().build(ContextPacketBuilder.Input(
            resolved: Self.resolved("com.example", kind: .prose),
            contents: Self.contents(title: "T", near: CaretNeighbourhood(secure: true)), spans: Self.spans("x")))
        #expect(viaNeighbourhood.isSecure)
    }

    @Test func contextualReadingOffKeepsOnlyTheProfileAndProcessFacts() {
        let bundle = "com.apple.Terminal"
        var field = FieldContext(appBundleID: bundle, axRole: "AXTextArea", hints: ["Terminal input"], textBeforeCursor: "git co")
        field.participants = ["Nobody"]
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Terminal"),
            resolved: Self.resolved(bundle, kind: .terminal, shell: Self.shell, before: "git co", title: "secret — zsh"),
            field: field,
            contents: Self.contents(title: "secret — zsh", blocks: ["secret output"], tail: "secret output"),
            candidates: [ContextCandidate(text: "SecretTerm", source: .screenNear, caretDistance: 1)],
            foregroundProcess: "claude",
            spans: Self.spans("commit it"))
        let b = Self.builder(reading: false)
        b.recentDictations = { _ in ["earlier"] }
        let p = b.build(input)
        #expect(!p.isSecure)
        #expect(p.destination.profileID == "ai.agentCLI")
        #expect(p.destination.appBundleID == bundle)
        #expect(p.destination.fields["cwd"] == "/Users/me/proj")
        #expect(p.destination.fields["foregroundProcess"] == "claude")
        #expect(p.destination.fields["windowTitle"] == nil)
        #expect(p.textBefore.isEmpty && p.textAfter.isEmpty)
        #expect(p.thread.isEmpty && p.screenTerms.isEmpty)
        #expect(p.recentDictations == ["earlier"], "history is the user's own text, not a screen read")
        #expect(p.heard.raw == "commit it")
        let json = p.encoded()
        #expect(!json.contains("secret") && !json.contains("SecretTerm") && !json.contains("Nobody"))
    }

    // MARK: Bounds and terms

    @Test func fieldTextAndTermsAreBounded() {
        let bundle = "com.apple.TextEdit"
        let long = String(repeating: "abcdefghij", count: 100)   // 1,000 chars
        var candidates: [ContextCandidate] = []
        for i in 0..<60 {
            candidates.append(ContextCandidate(text: "Zq\(i)term", source: .screenNear, caretDistance: 600 - i * 10))
        }
        candidates.append(ContextCandidate(text: "Priya Kothari", source: .contact))
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "TextEdit"),
            resolved: Self.resolved(bundle, kind: .prose, before: long, after: long),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea", textBeforeCursor: long, textAfterCursor: long),
            candidates: candidates,
            spans: Self.spans("hello"))
        let p = Self.builder().build(input)
        #expect(p.textBefore.count == 600 && p.textAfter.count == 600)
        #expect(p.textBefore == String(long.suffix(600)) && p.textAfter == String(long.prefix(600)))
        #expect(p.screenTerms.count <= 40)
        #expect(!p.screenTerms.isEmpty)
        #expect(!p.screenTerms.contains("Priya Kothari"), "Contacts never enter the packet")
        // Nearest the caret first: the highest index has the smallest distance.
        let indexes = p.screenTerms.compactMap { Int($0.dropFirst(2).dropLast(4)) }
        #expect(indexes == indexes.sorted(by: >), "\(p.screenTerms)")
    }

    @Test func composerTextIsNotRepeatedAsAThreadBlock() {
        let bundle = "com.tinyspeck.slackmacgap"
        let tail = "Priya Kothari\n10:41 AM\nCan you send it?\n\ndraft so far"
        let input = ContextPacketBuilder.Input(
            app: FocusSnapshot(pid: 100, bundleID: bundle, appName: "Slack"),
            resolved: Self.resolved(bundle, kind: .chatComposer, before: "draft so far"),
            field: FieldContext(appBundleID: bundle, axRole: "AXTextArea", textBeforeCursor: "draft so far"),
            contents: Self.contents(title: "Slack", tail: tail),
            spans: Self.spans("yes"))
        let p = Self.builder().build(input)
        #expect(p.thread.map(\.text) == ["Can you send it?"])
        #expect(p.textBefore == "draft so far")
    }

    // MARK: Heard

    @Test func heardIsTheRawOneBestWithConfidenceAlternatesAndBoostEvidence() {
        let spans = Self.spans("send it to rahul", uncertain: ["rahul"], alternates: ["rahul": ["Rahul", "raul", "rahul"]])
        let p = Self.builder().build(ContextPacketBuilder.Input(resolved: Self.resolved("com.apple.Notes", kind: .prose),
                                                                spans: spans, boostedText: "send it to Rahul"))
        #expect(p.heard.raw == "send it to rahul")
        #expect(p.heard.words.map(\.text) == ["send", "it", "to", "rahul"])
        #expect(p.heard.words.last?.isUncertain == true)
        // `HeardWords`: best first, the heard word itself left out — case and outer punctuation set
        // aside, so "Rahul" (formatting the writer may do anyway) is not an alternate of "rahul".
        #expect(p.heard.words.last?.alternates == ["raul"], "best first, the heard word itself left out")
        #expect(p.heard.marked == "send it to ⟦rahul⟧")
        #expect(p.heard.boosted == "send it to Rahul")
        let same = Self.builder().build(ContextPacketBuilder.Input(resolved: Self.resolved("com.apple.Notes", kind: .prose),
                                                                   spans: spans, boostedText: "send it to rahul"))
        #expect(same.heard.boosted == nil, "no evidence when the booster changed nothing")
    }

    @Test func multiWordSpanAlternatesAttachByPosition() {
        // `HeardWords` (the packet's splitter since wave 2): an alternate with the span's word count
        // is attributed word by word; a phrase alternate of another length cannot be pinned to one word.
        let span = TranscriptSpan(text: "hold to talk", confidence: 0.4, audioRange: 0...1,
                                  alternates: [Alternate(text: "hold-to-talk", score: 0.9, source: .repair),
                                               Alternate(text: "old two talk", score: 0.5, source: .beam)], provenance: [.asr])
        let heard = ContextPacketBuilder.heard([span], boosted: nil)
        #expect(heard.words.count == 3)
        #expect(heard.words[0].alternates == ["old"] && heard.words[1].alternates == ["two"] && heard.words[2].alternates.isEmpty)
        let allUncertain = heard.words.allSatisfy { $0.isUncertain }
        #expect(allUncertain)
    }

    // MARK: Sources

    struct MockVocabulary: VocabularyMatching {
        func matches(heard: ContextPacket.Heard, limit: Int) -> [ContextPacket.VocabularyMatch] {
            (0..<(limit + 5)).map { .init(term: "Term\($0)", spokenForm: "term \($0)", heard: "term", score: 0.9, source: "dictionary") }
        }
    }

    @Test func vocabularyComesFromTheInjectedMatcherAndIsCapped() {
        let b = Self.builder()
        b.vocabulary = MockVocabulary()
        let p = b.build(ContextPacketBuilder.Input(resolved: Self.resolved("com.apple.Notes", kind: .prose), spans: Self.spans("term")))
        #expect(p.vocabulary.count == 30)
        #expect(p.vocabulary.first?.term == "Term0")
        let none = Self.builder().build(ContextPacketBuilder.Input(resolved: Self.resolved("com.apple.Notes", kind: .prose), spans: Self.spans("term")))
        #expect(none.vocabulary.isEmpty)
    }

    @Test func recentDictationsPersonaAndLanguageComeFromTheAppSources() throws {
        let db = try AppDatabase.inMemory()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (i, text) in ["first", "second", "third", "fourth"].enumerated() {
            try db.insert(DictationRecord(startedAt: base.addingTimeInterval(Double(i)), endedAt: nil, register: "chat", route: "dictate",
                                          appBundleID: "com.tinyspeck.slackmacgap", rawText: text, finalText: text, spansJSON: "[]"))
        }
        try db.insert(DictationRecord(startedAt: base.addingTimeInterval(10), endedAt: nil, register: "chat", route: "dictate",
                                      appBundleID: "com.tinyspeck.slackmacgap", rawText: "held", finalText: "", spansJSON: "[]"))
        try db.insert(DictationRecord(startedAt: base.addingTimeInterval(11), endedAt: nil, register: "chat", route: "dictate",
                                      appBundleID: "com.apple.mail", rawText: "other", finalText: "other app", spansJSON: "[]"))
        let personas = PersonaManager(store: InMemoryPersonaStore())
        try personas.setText("casual, no sign-off", for: "com.tinyspeck.slackmacgap")
        _ = try personas.persona(for: "com.apple.mail")   // auto-drafted: not "set"
        let settings = InMemorySettingsStore()
        LanguagePreferences(languages: ["hi", "en"]).save(to: settings)

        let b = ContextPacketBuilder(database: db, personas: personas, settings: settings)
        b.contextualReading = { _ in true }
        let slack = b.build(ContextPacketBuilder.Input(resolved: Self.resolved("com.tinyspeck.slackmacgap", kind: .chatComposer),
                                                      spans: Self.spans("hi")))
        #expect(slack.recentDictations == ["fourth", "third", "second"], "newest first, held rows skipped, three at most")
        #expect(slack.persona == "casual, no sign-off")
        #expect(slack.language == "hi")
        let mail = b.build(ContextPacketBuilder.Input(resolved: Self.resolved("com.apple.mail", kind: .emailBody), spans: Self.spans("hi")))
        #expect(mail.recentDictations == ["other app"])
        #expect(mail.persona == nil, "an auto-drafted persona stays out of the packet")
        // A browser sub-app key reads history by its bundle and the persona by the key first.
        try personas.setText("terse", for: "com.google.Chrome|mail.google.com")
        #expect(b.persona("com.google.Chrome|mail.google.com") == "terse")
        #expect(b.persona("com.google.Chrome|docs.google.com") == nil)
    }

    // MARK: Transport

    @Test func writeIntoStageContextRoundTrips() {
        let bundle = "com.tinyspeck.slackmacgap"
        var ctx = StageContext(appBundleID: bundle)
        let packet = Self.builder().write(ContextPacketBuilder.Input(
            mode: .instruct, app: FocusSnapshot(pid: 1, bundleID: bundle, appName: "Slack"),
            resolved: Self.resolved(bundle, kind: .chatComposer), spans: Self.spans("reply to priya")), into: &ctx)
        #expect(ctx.extra[ContextPacket.modeKey] == "instruct")
        #expect(ContextPacket.read(from: ctx) == packet)
        #expect(ContextPacket.mode(of: ctx) == .instruct)
    }

    // MARK: Helpers

    @Test func foregroundProcessIsTheNonShellProcessInTheTTYsForegroundGroup() {
        let table = [
            ShellProcessRecord(pid: 10, ppid: 1, name: "iTerm2", tty: nil, pgid: 10, tpgid: 0),
            ShellProcessRecord(pid: 20, ppid: 10, name: "-zsh", tty: "/dev/ttys004", pgid: 20, tpgid: 31),
            ShellProcessRecord(pid: 30, ppid: 20, name: "node", tty: "/dev/ttys004", pgid: 31, tpgid: 31),
            ShellProcessRecord(pid: 31, ppid: 30, name: "claude", tty: "/dev/ttys004", pgid: 31, tpgid: 31),
            ShellProcessRecord(pid: 40, ppid: 10, name: "-zsh", tty: "/dev/ttys005", pgid: 40, tpgid: 40),
        ]
        #expect(TTYForegroundProcess.resolve(tty: "ttys004", shellPID: 20, table: table) == "claude")
        #expect(TTYForegroundProcess.resolve(tty: "/dev/ttys005", shellPID: 40, table: table) == nil, "a shell at its prompt")
        #expect(TTYForegroundProcess.resolve(tty: "/dev/ttys009", shellPID: nil, table: table) == nil)
        #expect(TTYForegroundProcess.isAgent("claude") && TTYForegroundProcess.isAgent("/usr/local/bin/codex"))
        #expect(!TTYForegroundProcess.isAgent("vim") && !TTYForegroundProcess.isAgent(nil))
        #expect(TTYForegroundProcess.live(ShellContext(pid: 20, shellName: "zsh", tty: "/dev/ttys004"), table: { table }) == "claude")
        #expect(TTYForegroundProcess.live(ShellContext(pid: 20, shellName: "zsh", tty: nil), table: { table }) == nil)
    }

    @Test func threadBlocksRecogniseHeadersAndSkipLabels() {
        let blocks = ThreadBlocks.split("""
        Note: the deck is attached.

        Rahul Mehta  10:41 AM
        Did you see the numbers?
        They look off.

        Sam Lee: I did, the Q3 column is wrong.

        Yesterday at 9:12
        Priya Kothari
        10:50
        Fixed.
        """)
        #expect(blocks.map(\.author) == [nil, "Rahul Mehta", "Sam Lee", "Priya Kothari"])
        #expect(blocks[0].text == "Note: the deck is attached.")
        #expect(blocks[1].text == "Did you see the numbers?\nThey look off.")
        #expect(blocks[2].text == "I did, the Q3 column is wrong.")
        #expect(blocks[3].text == "Fixed.")
        #expect(blocks[1].isSelf == false && blocks[0].isSelf == nil)
        #expect(ThreadBlocks.isTimestamp("10:41 AM") && ThreadBlocks.isTimestamp("Edited") && !ThreadBlocks.isTimestamp("Fixed."))
        #expect(ThreadBlocks.authorHeader("TODO: fix this") == nil)
        #expect(ThreadBlocks.authorHeader("Subject: hello") == nil)
    }

    @Test func threadBudgetCutsTheOldestKeptBlockToItsTail() {
        let a = ContextPacket.ThreadBlock(text: String(repeating: "a", count: 400))
        let b = ContextPacket.ThreadBlock(text: String(repeating: "b", count: 100))
        let kept = ThreadBlocks.budget([a, b], limit: 300, maxBlocks: 40)
        #expect(kept.count == 2)
        #expect(kept[0].text.hasPrefix("…") && kept[0].text.count == 200)
        #expect(kept[1].text == b.text)
        #expect(ThreadBlocks.budget([a, b], limit: 150, maxBlocks: 40).map(\.text) == [b.text], "no room for a useful tail of `a`")
    }

    @Test func emailAndCodeFactsAreRecognised() {
        #expect(EmailFacts.subject(windowTitle: nil, documentTitle: "Re: Q3 budget - me@x.io - Gmail", appName: "Google Chrome") == "Re: Q3 budget")
        #expect(EmailFacts.subject(windowTitle: "New Message", documentTitle: nil, appName: "Mail") == nil)
        #expect(EmailFacts.quotedFrom(in: "On Mon, 6 Oct 2026 at 09:12, Rahul Mehta <rahul@x.io> wrote:\n> hi") == "Rahul Mehta")
        #expect(EmailFacts.quotedFrom(in: "From: Sam Lee <sam@x.io>\nSent: Monday\n\nhi") == "Sam Lee")
        #expect(EmailFacts.quotedFrom(in: "nothing quoted here") == nil)
        #expect(EmailFacts.isReply(subject: "Fwd: deck", quotedFrom: nil, tail: nil))
        #expect(!EmailFacts.isReply(subject: "Deck", quotedFrom: nil, tail: "plain"))
        #expect(CodeFileFacts.filePath(fromTitle: "VoiceInput — Lander.swift") == "Lander.swift")
        #expect(CodeFileFacts.filePath(fromTitle: "Untitled — Code") == nil)
        #expect(CodeFileFacts.language(forPath: "a/b/main.rs") == "rust")
        #expect(CodeFileFacts.caretRegion(textBefore: "x = 1  # set ", language: "python") == .comment)
        #expect(CodeFileFacts.caretRegion(textBefore: "#!/bin/sh\necho ", language: "shell") == .code)
        #expect(CodeFileFacts.caretRegion(textBefore: "/* start\n * more ", language: "swift") == .comment)
        #expect(CodeFileFacts.caretRegion(textBefore: "let s = \"done\" + ", language: "swift") == .code)
    }
}
