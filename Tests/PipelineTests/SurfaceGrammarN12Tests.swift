import Testing
import Shared
@testable import Pipeline

/// N12 — surface grammars (R3 §E5): symbols need structure or a cue, the command line is
/// validated against real commands, formulas, URL vs search, label-typed fields, Markdown only
/// where accepted, never a Return.
@Suite struct SurfaceGrammarN12Tests {
    static func spans(_ text: String, confidence: Float = 0.9, low: Set<Int> = []) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, word in
            TranscriptSpan(text: String(word), confidence: low.contains(i) ? 0.3 : confidence,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func terminal(_ text: String, shell: ShellContext? = nil, low: Set<Int> = []) async -> String {
        var ctx = StageContext(register: .terminal, appBundleID: "com.apple.Terminal")
        shell?.write(into: &ctx)
        return TerminalFormatter.render(try! await TerminalFormatter().process(spans(text, low: low), context: ctx))
    }

    static func field(_ text: String, _ field: FieldContext, low: Set<Int> = []) async -> FormattedField {
        try! await FieldRoleFormatter().format(spans(text, low: low), field: field)
    }

    static let terminalField = FieldContext(appBundleID: "com.apple.Terminal", axRole: "AXTextArea")
    static let prose = FieldContext(appBundleID: "com.apple.TextEdit", axRole: "AXTextArea", isMultiline: true)
    static let excel = FieldContext(appBundleID: "com.microsoft.Excel", axRole: "AXCell")
    static let addressBar = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextField",
                                         hints: ["Address and search bar"])
    static func form(_ label: String) -> FieldContext {
        var f = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextField", hints: [label],
                             documentURL: "http://localhost:8000/form")
        f.isInWebArea = true
        return f
    }

    // MARK: Spoken symbols: structure or cue

    @Test func plusNeedsStructureInTerminal() async throws {
        #expect(await Self.terminal("c plus plus") == "c++")
        #expect(await Self.terminal("cd documents slash voice plus") == "cd documents/voice plus")
        #expect(await Self.terminal("echo plus sign") == "echo +")
        #expect(await Self.terminal("g plus plus main dot cpp") == "g++ main.cpp")
    }

    @Test func proseKeepsSymbolWordsWithoutStructure() async throws {
        let a = await Self.field("we built voice plus this week", Self.prose).text
        #expect(a.contains("voice plus") && !a.contains("+"))
        let b = await Self.field("we need to slash the budget", Self.prose).text
        #expect(b.contains("slash the budget"))
        let c = await Self.field("open documents slash voice plus", Self.prose).text
        #expect(c.contains("documents slash voice plus"))
    }

    @Test func proseConvertsStructures() async throws {
        #expect(await Self.field("I write c plus plus every day", Self.prose).text.contains("c++"))
        #expect(await Self.field("visit google dot com for that", Self.prose).text.contains("google.com"))
        #expect(await Self.field("mail jo dot smith at example dot com today", Self.prose).text.contains("jo.smith@example.com"))
        #expect(await Self.field("see tilde slash projects slash notes dot md", Self.prose).text.contains("~/projects/notes.md"))
        #expect(await Self.field("press the plus sign now", Self.prose).text.contains("the + now"))
    }

    @Test func lowConfidenceStructureIsLeftAsHeard() async throws {
        let t = await Self.field("visit google dot com", Self.prose, low: [1]).text
        #expect(!t.contains("google.com"))
    }

    // MARK: Command-line grammar

    @Test func commandRecoveredOnlyWhenItIsARealCommand() async throws {
        #expect(await Self.terminal("CD documents") == "cd documents")
        #expect(await Self.terminal("see dee dot dot") == "cd ..")
        #expect(await Self.terminal("C D slash tmp") == "cd /tmp")
        // Validated against the shell's real commands: `ls` is not one here, `cd` is a builtin.
        let shell = ShellContext(currentDirectory: "/Users/me", knownCommands: ["git", "mytool"])
        #expect(await Self.terminal("l s", shell: shell) == "l s")
        #expect(await Self.terminal("see dee dot dot", shell: shell) == "cd ..")
        // A user command is in command position ("mytool ."), an unknown word is not.
        #expect(await Self.terminal("mytool dot", shell: shell) == "mytool .")
        #expect(await Self.terminal("mytool dot") == "mytool.")
    }

    @Test func replay113444Transcript() async throws {
        // The recogniser's text for 2026-10-02-113444 after N1 (no Contacts swaps):
        // "C Dinda reputation. Document slash voice plus." — "Dinda" heard with low confidence.
        let out = await Self.field("C Dinda reputation. Document slash voice plus.", Self.terminalField, low: [1])
        #expect(!out.text.contains("."))
        #expect(!out.text.contains("+"))
        #expect(!out.text.contains("akash") && !out.text.contains("Akash"))
        #expect(out.text.contains("document/voice plus"))
        #expect(!out.text.contains("\n") && !out.text.contains("\r"))
        #expect(out.allowSubmit == false)
        #expect(out.spans.contains { $0.needsRepair })
    }

    @Test func terminalNeverReturns() async throws {
        let out = await Self.field("git status enter", Self.terminalField)
        #expect(!out.text.contains("\n") && out.allowSubmit == false)
    }

    @Test func shellContextRoundTripsThroughStageContext() {
        var ctx = StageContext()
        let shell = ShellContext(shellName: "zsh", currentDirectory: "/tmp",
                                 entries: [.init(name: "Documents", isDirectory: true)], knownCommands: ["git"])
        shell.write(into: &ctx)
        #expect(ShellContext(stageContext: ctx) == shell)
        #expect(CommandLexicon.commands(for: shell).contains("cd"))
        #expect(!CommandLexicon.commands(for: shell).contains("ls"))
        #expect(CommandLexicon.commands(for: nil).contains("ls"))
    }

    // MARK: Spreadsheet formulas

    @Test func formulaFromEquals() async throws {
        #expect(await Self.field("equals sum a one to a ten", Self.excel).text == "=SUM(A1:A10)")
        #expect(await Self.field("Equals sum A1 to A10.", Self.excel).text == "=SUM(A1:A10)")
        #expect(await Self.field("equals a one plus b two", Self.excel).text == "=A1+B2")
        #expect(await Self.field("equals average of b two through b twenty", Self.excel).text == "=AVERAGE(B2:B20)")
        #expect(FormulaGrammar.parse(["equals", "round", "c", "three", "comma", "two"]) == "=ROUND(C3,2)")
    }

    @Test func cellWithoutEqualsIsPlainText() async throws {
        let t = await Self.field("total sales", Self.excel).text
        #expect(!t.hasPrefix("=") && !t.hasSuffix("."))
        #expect(FormulaGrammar.parse(["sum", "a", "one"]) == nil)
        #expect(FormulaGrammar.parse(["equals", "the", "best", "results"]) == nil)
    }

    // MARK: URL bar vs search

    @Test func addressBarURLOrSearch() async throws {
        #expect(await Self.field("google dot com", Self.addressBar).text == "google.com")
        #expect(await Self.field("Google dot com.", Self.addressBar).text == "google.com")
        #expect(await Self.field("github dot com slash anthropics", Self.addressBar).text == "github.com/anthropics")
        let search = await Self.field("Weather in Paris.", Self.addressBar)
        #expect(search.text == "weather in Paris")
        #expect(search.allowSubmit == false)
    }

    // MARK: Label-typed form fields

    @Test func labelDecidesFormat() async throws {
        #expect(await Self.field("five five five one two three four", Self.form("Phone number")).text == "5551234")
        #expect(await Self.field("plus one four one five five five five one two one two", Self.form("Mobile")).text == "+14155551212")
        #expect(await Self.field("forty two", Self.form("Quantity")).text == "42")
        #expect(await Self.field("jane van der berg", Self.form("Full name")).text == "Jane van der Berg")
        #expect(await Self.field("jo at example dot com", Self.form("Email address")).text == "jo@example.com")
        // An unparseable value is left as heard, never forced.
        #expect(await Self.field("call me later", Self.form("Phone number")).text.contains("call me later"))
    }

    // MARK: Markdown only where accepted

    @Test func markdownOnlyOnMarkdownSurfaces() async throws {
        var issue = FieldContext(appBundleID: "com.google.Chrome", axRole: "AXTextArea", isMultiline: true,
                                 documentURL: "https://github.com/acme/app/issues/new")
        issue.upstreamSurface = .markdownEditor
        let md = await Self.field("heading two release notes", issue).text
        #expect(md.hasPrefix("## "))
        #expect(await Self.field("bullet buy milk", issue).text.hasPrefix("- "))
        let link = await Self.field("link docs to example dot com", issue).text
        #expect(link.lowercased().contains("[docs](example.com)"), "\(link)")
        let plain = await Self.field("heading two release notes", Self.prose).text
        #expect(!plain.contains("#"))
    }

    @Test func provenanceAndConfidenceSurviveMerges() async throws {
        let out = await Self.field("google dot com", Self.addressBar)
        #expect(out.spans.count == 1)
        #expect(out.spans[0].provenance.contains(.asr))
        #expect(out.spans[0].provenance.contains(SurfaceGrammar.stageID))
        #expect(out.spans[0].audioRange.lowerBound == 0 && abs(out.spans[0].audioRange.upperBound - 0.9) < 1e-9)
    }
}
