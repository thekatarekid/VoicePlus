import Testing
import Shared
@testable import Pipeline

/// Golden input→output cases for the terminal formatter (P1.7 T6). Each case feeds word-level
/// spans (as the ASR produces them) and checks rendered text plus the confidence contract.
@Suite struct TerminalFormatterTests {
    struct Golden: Sendable {
        let input: String
        let expected: String
        init(_ input: String, _ expected: String) { self.input = input; self.expected = expected }
    }

    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, word in
            TranscriptSpan(text: String(word), confidence: confidence,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func run(_ spans: [TranscriptSpan]) async throws -> [TranscriptSpan] {
        try await TerminalFormatter().process(spans, context: StageContext(register: .terminal, appBundleID: "com.apple.Terminal"))
    }

    static let golden: [Golden] = [
        // Flags
        Golden("git commit dash m", "git commit -m"),
        Golden("ls dash la", "ls -la"),
        Golden("rm dash rf node underscore modules", "rm -rf node_modules"),
        Golden("git push origin main dash dash force", "git push origin main --force"),
        Golden("npm install dash dash save dash dev typescript", "npm install --save-dev typescript"),
        Golden("git log dash dash oneline dash n five", "git log --oneline -n 5"),
        Golden("ls dash l dash a", "ls -l -a"),
        Golden("git checkout dash b feature slash login", "git checkout -b feature/login"),
        Golden("kill dash nine 1234", "kill -9 1234"),
        Golden("git commit dash dash no dash verify", "git commit --no-verify"),
        Golden("python dash m pip install requests", "python -m pip install requests"),
        // Paths
        Golden("cd tilde slash projects", "cd ~/projects"),
        Golden("cd dot dot", "cd .."),
        Golden("cd dot dot slash src", "cd ../src"),
        Golden("git add dot", "git add ."),
        Golden("dot slash build dot sh", "./build.sh"),
        Golden("cd slash tmp", "cd /tmp"),
        Golden("cat file dot txt", "cat file.txt"),
        Golden("ls dash la tilde slash downloads", "ls -la ~/downloads"),
        Golden("cd tilde", "cd ~"),
        Golden("ls star dot log", "ls *.log"),
        Golden("rm star dot log", "rm *.log"),
        Golden("open my dash file dot md", "open my-file.md"),
        Golden("ssh user at host dot com", "ssh user@host.com"),
        Golden("curl dash s https colon slash slash example dot com", "curl -s https://example.com"),
        Golden("curl localhost colon 8080 slash health", "curl localhost:8080/health"),
        // Pipes and redirects
        Golden("ls pipe grep foo", "ls | grep foo"),
        Golden("ls dash l pipe wc dash l", "ls -l | wc -l"),
        Golden("cat file dot txt greater than out dot txt", "cat file.txt > out.txt"),
        Golden("echo hi double greater than log dot txt", "echo hi >> log.txt"),
        Golden("make and and make install", "make && make install"),
        Golden("cd foo semicolon ls", "cd foo; ls"),
        Golden("npm test or or echo failed", "npm test || echo failed"),
        Golden("ls dash l pipe grep dot txt", "ls -l | grep .txt"),
        // Quoting
        Golden("git commit dash m in quotes fix the bug", "git commit -m \"fix the bug\""),
        Golden("git commit dash m in quotes Fix login end quote dash dash amend", "git commit -m \"Fix login\" --amend"),
        Golden("grep dash r in quotes todo end quote dot", "grep -r \"todo\" ."),
        Golden("echo in single quotes hello world", "echo 'hello world'"),
        Golden("git commit dash m quote wip quote", "git commit -m \"wip\""),
        Golden("echo in quotes dash dash not a flag", "echo \"dash dash not a flag\""),
        // Env vars
        Golden("echo dollar home", "echo $HOME"),
        Golden("dollar home slash bin", "$HOME/bin"),
        Golden("export foo equals bar", "export FOO=bar"),
        Golden("export path equals dollar home slash bin colon dollar path", "export PATH=$HOME/bin:$PATH"),
        Golden("echo dollar open paren pwd close paren", "echo $(pwd)"),
        // Numbers
        Golden("chmod seven five five file dot sh", "chmod 755 file.sh"),
        Golden("curl localhost colon eight zero eight zero", "curl localhost:8080"),
        // No smart punctuation, no capitalization, no fillers
        Golden("Git status.", "git status"),
        Golden("Ls, dash la.", "ls -la"),
        Golden("um git status", "git status"),
        Golden("git uh push", "git push"),
        Golden("Echo hello world", "echo hello world"),
        Golden("ls", "ls"),
        Golden("dash", "-"),
        Golden("git push origin main dash dash force dash with dash lease", "git push origin main --force-with-lease"),
    ]

    @Test(arguments: golden)
    func goldenCase(_ g: Golden) async throws {
        let input = Self.spans(g.input)
        let output = try await Self.run(input)
        #expect(TerminalFormatter.render(output) == g.expected, "input: \(g.input)")
        #expect(ConfidenceContract.verify(input: input, output: output) == [], "contract: \(g.input)")
        #expect(output.allSatisfy { $0.provenance.last == .formatterTerminal })
    }

    @Test func goldenCaseCountMeetsSpec() {
        #expect(Self.golden.count >= 40)
    }

    @Test func lowConfidenceSpanIsFlaggedNotRewritten() async throws {
        var input = Self.spans("git commit dash m in quotes fix Kothari bug")
        input[7].confidence = 0.29
        let output = try await Self.run(input)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        let flagged = try #require(output.first { $0.audioRange == input[7].audioRange })
        #expect(flagged.text == "Kothari" && flagged.needsRepair && flagged.confidence == 0.29)
        #expect(TerminalFormatter.render(output) == "git commit -m \"fix Kothari bug\"")
    }

    @Test func lowConfidenceSymbolWordIsNotResolved() async throws {
        var input = Self.spans("cd tilde slash projects")
        input[1].confidence = 0.2 // "tilde" garbled: must stay literal
        let output = try await Self.run(input)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(TerminalFormatter.render(output) == "cd tilde /projects")
        #expect(output.filter(\.needsRepair).count == 1)
    }

    @Test func unclosedQuoteEndingInLowConfidenceSpanStillCloses() async throws {
        var input = Self.spans("echo in quotes hello there")
        input[4].confidence = 0.1
        let output = try await Self.run(input)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(TerminalFormatter.render(output) == "echo \"hello there \"")
        #expect(output.last?.text == "\"")
    }

    @Test func fillerBetweenLowConfidenceSpansIsKept() async throws {
        var input = Self.spans("a um b")
        input[0].confidence = 0.1
        input[2].confidence = 0.1
        let output = try await Self.run(input)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(output.count == 3)
        #expect(TerminalFormatter.render(output) == "a um b")
    }

    @Test func mergedSpansKeepAlternatesAndCoverAudio() async throws {
        var input = Self.spans("git commit dash m")
        input[3].alternates = [Alternate(text: "n", score: 0.2, source: .beam)]
        let output = try await Self.run(input)
        let flag = try #require(output.first { $0.text == "-m" })
        #expect(flag.alternates.map(\.text) == ["n"])
        #expect(flag.audioRange == input[2].audioRange.lowerBound...input[3].audioRange.upperBound)
        #expect(flag.confidence == 0.9)
    }

    @Test func emptyInput() async throws {
        #expect(try await Self.run([]).isEmpty)
    }

    @Test func registeredInStageRegistry() {
        #expect(StageRegistry.formatter(for: .terminal)?.id == .formatterTerminal)
        #expect(StageRegistry.stage(for: .formatterTerminal) != nil)
    }
}
