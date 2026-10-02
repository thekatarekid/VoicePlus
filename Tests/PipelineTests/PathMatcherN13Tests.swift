import Testing
import Shared
@testable import Pipeline

/// N13 (F26) — folder names in Terminal: matched against the focused shell's current folder,
/// silent only when close, otherwise the spoken words stay and the entry is a suggestion.
@Suite struct PathMatcherN13Tests {
    static let folder = ShellContext(
        pid: 4242, shellName: "zsh", tty: "/dev/ttys004", currentDirectory: "/Users/me/VoicePlusTest",
        entries: [
            .init(name: "Documents", isDirectory: true), .init(name: "Downloads", isDirectory: true),
            .init(name: "VoicePlus", isDirectory: true), .init(name: "My Project", isDirectory: true),
            .init(name: "notes.txt", isDirectory: false), .init(name: "Application Support", isDirectory: true),
        ],
        knownCommands: ["ls", "cd", "git", "cat", "cp", "open"])

    static func spans(_ text: String, low: Set<Int> = []) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: low.contains(i) ? 0.3 : 0.9,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func run(_ text: String, shell: ShellContext? = folder, low: Set<Int> = []) async throws -> [TranscriptSpan] {
        var ctx = StageContext(register: .terminal, appBundleID: "com.apple.Terminal")
        shell?.write(into: &ctx)
        return try await TerminalFormatter().process(spans(text, low: low), context: ctx)
    }

    static func line(_ text: String, shell: ShellContext? = folder, low: Set<Int> = []) async throws -> String {
        TerminalFormatter.render(try await run(text, shell: shell, low: low))
    }

    // MARK: Matcher

    @Test func exactAfterNormalisationIsSilent() {
        let e = Self.folder.entries
        #expect(PathMatcher.match("documents", in: e) == .silent(e[0]))
        #expect(PathMatcher.match("voice plus", in: e) == .silent(e[2]))
        #expect(PathMatcher.match("my project", in: e) == .silent(e[3]))
        #expect(PathMatcher.match("notes txt", in: e) == .silent(e[4]))
    }

    @Test func oneEditOnLongUniqueNameIsSilent() {
        let e = Self.folder.entries
        #expect(PathMatcher.match("documens", in: e) == .silent(e[0]))
    }

    @Test func looserMatchesOnlySuggest() {
        let e = Self.folder.entries
        #expect(PathMatcher.match("docs", in: e) == .suggest(e[0]))         // abbreviates one name
        #expect(PathMatcher.match("download", in: e) != nil)
        #expect(PathMatcher.match("voyce plas", in: e) == .suggest(e[2]))
        #expect(PathMatcher.match("banana", in: e) == nil)
        #expect(PathMatcher.match("documents", in: []) == nil)
    }

    // MARK: Formatter

    @Test func cdDocumentsBecomesFolder() async throws {
        #expect(try await Self.line("cd documents") == "cd Documents/")
        #expect(try await Self.line("CD documents.") == "cd Documents/")
    }

    @Test func nestedPathKeepsSpokenSlash() async throws {
        #expect(try await Self.line("cd documents slash voiceplus") == "cd Documents/voiceplus")
    }

    @Test func multiWordAndSpacesAreEscaped() async throws {
        #expect(try await Self.line("cd voice plus") == "cd VoicePlus/")
        #expect(try await Self.line("cd my project") == "cd My\\ Project/")
        #expect(try await Self.line("cat notes dot txt") == "cat notes.txt")
    }

    @Test func afterFlagAndAfterAnotherPath() async throws {
        #expect(try await Self.line("ls dash la documents") == "ls -la Documents/")
        #expect(try await Self.line("cp notes txt documents") == "cp notes.txt Documents/")
    }

    @Test func notCloseKeepsWordsWithSuggestion() async throws {
        let out = try await Self.run("cd docs")
        #expect(TerminalFormatter.render(out) == "cd docs")
        let docs = try #require(out.first { $0.text == "docs" })
        #expect(docs.alternates.contains { $0.text == "Documents/" && $0.source == .biasing })
    }

    @Test func silentMatchKeepsOriginalAsAlternateAndAudio() async throws {
        let out = try await Self.run("cd voice plus")
        let tok = try #require(out.last)
        #expect(tok.text == "VoicePlus/")
        #expect(tok.alternates.first == Alternate(text: "voice plus", score: tok.confidence, source: .repair))
        #expect(abs(tok.audioRange.lowerBound - 0.3) < 1e-9 && abs(tok.audioRange.upperBound - 0.9) < 1e-9)
        #expect(tok.provenance.contains(.formatterTerminal))
    }

    @Test func noPermissionNoListingNoMatch() async throws {
        var bare = Self.folder; bare.entries = []
        #expect(try await Self.line("cd documents", shell: bare) == "cd documents")
        #expect(try await Self.line("cd documents", shell: nil) == "cd documents")
    }

    @Test func proseWordsInMessagesOnlySuggest() async throws {
        // Not an argument slot ("the documents") → never silently rewritten.
        let out = try await Self.run("git commit dash m fix the documents")
        #expect(TerminalFormatter.render(out).hasSuffix("the documents"))
    }

    @Test func notACommandLineNoMatch() async throws {
        #expect(try await Self.line("hello documents") == "hello documents")
    }

    @Test func quotedAndLowConfidenceUntouched() async throws {
        #expect(try await Self.line("echo in quotes documents end quote") == "echo \"documents\"")
        let out = try await Self.run("cd documents", low: [1])
        #expect(out.last?.text == "documents")
        #expect(out.last?.needsRepair == true)
    }

    @Test func neverAddsReturn() async throws {
        for s in ["cd documents", "cd my project", "ls dash la downloads"] {
            #expect(try await !Self.line(s).contains("\n"))
        }
    }
}
