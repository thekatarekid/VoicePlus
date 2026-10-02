import Foundation
import Testing
@testable import Shared

/// N9 — the surface resolver: evidence added up, safe prose fallback, known AND unknown apps.
@Suite("Surface resolver (N9)")
struct SurfaceResolverTests {
    typealias E = SurfaceEvidence

    static let table: [(String, E, SurfaceKind)] = [
        // Unknown apps: structure alone, else safe prose.
        ("unknown plain text area", E(bundleID: "com.example.never", role: "AXTextArea"), .prose),
        ("unknown one-line field", E(bundleID: "com.example.never", role: "AXTextField"), .prose),
        ("unknown app, no tree", E(bundleID: "com.example.never"), .prose),
        ("unknown app, pty shell", E(bundleID: "com.example.newterm", role: "AXTextArea", shell: ShellContext(shellName: "zsh")), .terminal),
        ("unknown app, xterm.js", E(bundleID: "com.example.ide", role: "AXTextArea", hints: ["xterm-helper-textarea", "Terminal input"]), .terminal),
        ("unknown app, chatgpt.com web area", E(bundleID: "com.example.wrapper", role: "AXTextArea", isInWebArea: true, url: "https://chatgpt.com/c/123"), .chatComposer),
        ("unknown app, composer placeholder", E(bundleID: "com.example.agent", role: "AXTextArea", placeholder: "Ask anything"), .chatComposer),
        ("unknown app, search label + console", E(bundleID: "com.example.cloud", role: "AXTextField", label: "Search console"), .searchField),
        ("unknown app, AXSearchField console", E(bundleID: "com.example.cloud", role: "AXSearchField", label: "Console"), .searchField),
        ("unknown browser address bar", E(bundleID: "com.example.browser", role: "AXTextField", placeholder: "Search or enter website name"), .urlBar),
        ("unknown app, email form field", E(bundleID: "com.example.form", role: "AXTextField", label: "Email address", isInWebArea: true), .formField(label: "email")),
        ("unknown app, phone form field", E(bundleID: "com.example.form", role: "AXTextField", label: "Phone number", isInWebArea: true), .formField(label: "phone")),
        ("unknown app, canvas", E(bundleID: "com.example.draw", role: "AXCanvas", isEditable: false), .canvas),
        ("unknown app, cell hint", E(bundleID: "com.example.grid", role: "AXTextArea", hints: ["cell"]), .spreadsheetCell),
        ("unknown app, markdown hint", E(bundleID: "com.example.md", role: "AXTextArea", hints: ["markdown editor"]), .markdownEditor),
        // Codex: no longer "code" by substring; the surface decides.
        ("codex plain text area", E(bundleID: "com.openai.codex", role: "AXTextArea"), .prose),
        ("codex composer", E(bundleID: "com.openai.codex", role: "AXTextArea", placeholder: "Ask Codex anything"), .chatComposer),
        // Known apps.
        ("Terminal", E(bundleID: "com.apple.Terminal", role: "AXTextArea"), .terminal),
        ("Terminal find bar", E(bundleID: "com.apple.Terminal", role: "AXSearchField", label: "Find"), .searchField),
        ("WezTerm", E(bundleID: "com.github.wez.wezterm"), .terminal),
        ("VS Code terminal", E(bundleID: "com.microsoft.VSCode", role: "AXTextArea", hints: ["Terminal input"]), .terminal),
        ("VS Code console", E(bundleID: "com.microsoft.VSCode", role: "AXTextArea", hints: ["Console"]), .terminal),
        ("VS Code editor", E(bundleID: "com.microsoft.VSCode", role: "AXTextArea", hints: ["Monaco editor"]), .codeEditor),
        ("VS Code editor, no hints", E(bundleID: "com.microsoft.VSCode", role: "AXTextArea"), .codeEditor),
        ("VS Code find field", E(bundleID: "com.microsoft.VSCode", role: "AXTextField"), .prose),
        ("Slack", E(bundleID: "com.tinyspeck.slackmacgap", role: "AXTextArea"), .chatComposer),
        ("Mail body", E(bundleID: "com.apple.mail", role: "AXTextArea", label: "Message Body"), .emailBody),
        ("Mail plain", E(bundleID: "com.apple.mail", role: "AXTextArea"), .emailBody),
        ("Mail subject", E(bundleID: "com.apple.mail", role: "AXTextField", label: "Subject"), .formField(label: "subject")),
        ("Notes", E(bundleID: "com.apple.Notes", role: "AXTextArea"), .prose),
        ("Excel cell labelled Console", E(bundleID: "com.microsoft.Excel", role: "AXCell", hints: ["Console"]), .spreadsheetCell),
        ("Excel search box", E(bundleID: "com.microsoft.Excel", role: "AXTextField", hints: ["Search"]), .searchField),
        ("Chrome address bar", E(bundleID: "com.google.Chrome", role: "AXTextField", label: "Address and search bar"), .urlBar),
        ("Chrome toolbar field", E(bundleID: "com.google.Chrome", role: "AXTextField"), .urlBar),
        ("Chrome page, no URL match", E(bundleID: "com.google.Chrome", role: "AXTextArea", isInWebArea: true, url: "https://example.org/x"), .prose),
        ("Sheets cell", E(bundleID: "com.google.Chrome", role: "AXWebArea", isInWebArea: true, url: "https://docs.google.com/spreadsheets/d/1"), .spreadsheetCell),
        ("Sheets find box", E(bundleID: "com.google.Chrome", role: "AXTextField", label: "Find in sheet", isInWebArea: true, url: "https://docs.google.com/spreadsheets/d/1"), .searchField),
        ("Gmail compose", E(bundleID: "com.brave.Browser", role: "AXTextArea", label: "Message Body", isInWebArea: true, url: "https://mail.google.com/mail/u/0/"), .emailBody),
        ("GitHub issue comment", E(bundleID: "com.apple.Safari", role: "AXTextArea", isInWebArea: true, url: "https://github.com/a/b/issues/3"), .markdownEditor),
        ("Gemini in Safari", E(bundleID: "com.apple.Safari", role: "AXTextArea", isInWebArea: true, url: "https://gemini.google.com/app"), .chatComposer),
    ]

    @Test("table: known and unknown apps", arguments: table.indices)
    func resolves(_ i: Int) {
        let (name, evidence, want) = Self.table[i]
        let r = SurfaceResolver.resolve(evidence)
        #expect(r.kind == want, "\(name): got \(r.recordValue)")
        #expect(!r.signals.isEmpty, "\(name): every decision records its signals")
    }

    @Test("an unknown app with no evidence gets safe prose, flagged as fallback")
    func unknownIsSafeProse() {
        let r = SurfaceResolver.resolve(E(bundleID: "org.nobody.app", role: "AXTextArea"))
        #expect(r.kind == .prose && r.isFallback)
        #expect(r.signals.contains { $0.hasPrefix("fallback") })
        // An unreadable tree delivers as web content: ⇧↩, never Return.
        let empty = SurfaceResolver.resolve(E(bundleID: "org.nobody.app"))
        #expect(empty.isWebArea && empty.newline == .shiftReturn)
    }

    @Test("weak, conflicting evidence falls back to prose")
    func belowThreshold() {
        // Terminal 2.5 versus code editor 2.5 in an unknown app: a tie is ambiguous.
        let r = SurfaceResolver.resolve(E(bundleID: "com.example.never", role: "AXTextArea", hints: ["console", "monaco"]))
        #expect(r.kind == .prose && r.isFallback, "\(r.recordValue)")
        #expect(r.candidate == .terminal || r.candidate == .codeEditor)
    }

    @Test("secure is a veto")
    func secureVeto() {
        #expect(SurfaceResolver.resolve(E(bundleID: "com.apple.Terminal", secureInputActive: true, role: "AXTextArea")).kind == .secure)
        #expect(SurfaceResolver.resolve(E(role: "AXTextField", subrole: "AXSecureTextField")).kind == .secure)
        #expect(SurfaceResolver.resolve(E(role: "AXTextField", label: "Password", isInWebArea: true)).kind == .secure)
        #expect(SurfaceResolver.resolve(E(role: "AXTextField", label: "Password", appOverride: .terminal)).kind == .secure)
    }

    @Test("override and history are evidence, not vetoes")
    func overrideAndHistory() {
        #expect(SurfaceResolver.resolve(E(bundleID: "com.example.x", role: "AXTextArea", appOverride: .terminal)).kind == .terminal)
        #expect(SurfaceResolver.resolve(E(bundleID: "com.example.x", role: "AXSearchField", label: "Search", appOverride: .terminal)).kind == .searchField)
        let hist = E(bundleID: "com.example.x", role: "AXTextArea", previousKinds: [.chatComposer, .chatComposer, .chatComposer])
        #expect(SurfaceResolver.resolve(hist).kind == .chatComposer)
    }

    @Test("canvas only without an active text edit")
    func canvas() {
        #expect(SurfaceResolver.resolve(E(role: "AXCanvas", isEditable: false)).refusesTyping)
        #expect(SurfaceResolver.resolve(E(role: "AXCanvas", isEditable: true)).kind != .canvas)
    }

    @Test("line breaks are safe per surface")
    func newlines() {
        #expect(SurfaceResolver.resolve(E(bundleID: "com.apple.Terminal", role: "AXTextArea")).newline == .bracketedPaste)
        #expect(SurfaceResolver.resolve(E(bundleID: "com.microsoft.Excel", role: "AXCell")).newline == .optionReturn)
        #expect(SurfaceResolver.resolve(E(bundleID: "com.tinyspeck.slackmacgap", role: "AXTextArea")).newline == .shiftReturn)
        #expect(SurfaceResolver.resolve(E(bundleID: "com.apple.Notes", role: "AXTextArea")).newline == .newline)
        let electron = SurfaceResolver.resolve(E(bundleID: "com.example.electron", role: "AXTextArea", runtime: .electron))
        #expect(electron.kind == .prose && electron.newline == .shiftReturn)
    }

    @Test("window title is medium evidence")
    func title() {
        #expect(SurfaceResolver.resolve(E(bundleID: "com.example.t", role: "AXTextArea", windowTitle: "aditya@mac: ~ — -zsh — 80×24")).kind == .terminal)
        #expect(SurfaceResolver.resolve(E(bundleID: "com.example.t", role: "AXTextArea", windowTitle: "Codex")).kind == .prose)
    }

    @Test("seed table: one merged list, every former list's ids present")
    func seedMerge() {
        let adapters = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty"]
        for id in adapters { #expect(SeedHints.hint(for: id)?.family == .terminal, "\(id)") }
        for id in ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.anthropic.claudefordesktop"] {
            #expect(SeedHints.hint(for: id)?.family == .chat && SeedHints.hint(for: id)?.runtime == .electron)
        }
        for id in ["com.brave.Browser", "com.google.Chrome", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.google.Chrome.canary"] {
            #expect(SeedHints.hint(for: id)?.family == .browser, "\(id)")
        }
        #expect(SeedHints.bundleIDs(.spreadsheet) == ["com.microsoft.Excel", "com.apple.iWork.Numbers"])
        #expect(SeedHints.hint(for: "com.openai.codex") == nil)
        #expect(SeedHints.personaResets.contains("com.openai.codex"))
    }

    @Test("lexicon matches whole words")
    func words() {
        #expect(SurfaceLexicon.words("FancyMail") == ["fancy", "mail"])
        #expect(SurfaceLexicon.words("com.openai.codex") == ["com", "openai", "codex"])
        #expect(!SurfaceLexicon.contains(SurfaceLexicon.words("codex"), ["code"]))
        #expect(SurfaceLexicon.contains(SurfaceLexicon.words("Address and search bar"), ["search", "bar"]))
    }

    @Test("kind ids round-trip")
    func ids() {
        let all: [SurfaceKind] = [.terminal, .spreadsheetCell, .chatComposer, .urlBar, .searchField, .emailBody,
                                  .formField(label: "email"), .markdownEditor, .codeEditor, .canvas, .prose, .secure]
        for k in all { #expect(SurfaceKind(id: k.id) == k) }
        #expect(SurfaceKind(id: "nope") == nil)
        let r = SurfaceResolver.resolve(E(bundleID: "com.apple.Terminal", role: "AXTextArea"))
        #expect(r.recordValue.hasPrefix("terminal "))
    }

    @Test("shell context exposes commands and folders")
    func shell() {
        let s = ShellContext(currentDirectory: "/Users/a", entries: [.init(name: "Documents", isDirectory: true),
                                                                       .init(name: "a.txt", isDirectory: false)],
                             knownCommands: ["git"])
        #expect(s.allCommands.contains("cd") && s.allCommands.contains("git"))
        #expect(s.directories.map(\.displayName) == ["Documents/"])
    }
}
