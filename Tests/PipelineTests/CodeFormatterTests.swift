import Foundation
import Testing
@testable import Pipeline
@testable import Shared

@Suite struct CodeFormatterTests {
    // MARK: Golden cases (spoken → code). Each word is a fully-confident span.

    static let golden: [(String, String)] = [
        // Casing
        ("camel case user id", "userId"),
        ("snake case user id", "user_id"),
        ("kebab case my cool app", "my-cool-app"),
        ("pascal case transcript span", "TranscriptSpan"),
        ("screaming snake case max retries", "MAX_RETRIES"),
        ("camel case get user profile returns an optional user", "getUserProfile returns an optional user"),
        ("let camel case user count equals zero", "let userCount = 0"),
        ("all caps path", "PATH"),
        ("capital user", "User"),
        ("upper camel case http client", "HttpClient"),
        // Symbols
        ("foo open paren bar close paren", "foo(bar)"),
        ("x equals y", "x = y"),
        ("a double equals b", "a == b"),
        ("a not equals b", "a != b"),
        ("count plus equals one", "count += 1"),
        ("func run arrow void", "func run -> void"),
        ("x fat arrow x times two", "x => x * 2"),
        ("self dot name", "self.name"),
        ("open bracket one comma two close bracket", "[1, 2]"),
        ("if x less than ten open brace", "if x < 10 {"),
        ("a double ampersand b double pipe c", "a && b || c"),
        ("name colon string", "name: string"),
        ("return x semicolon", "return x;"),
        ("quote hello world end quote", "\"hello world\""),
        ("first underscore name", "first_name"),
        ("hash include", "#include"),
        ("user question mark", "user?"),
        // Paths
        ("slash users slash foo", "/users/foo"),
        ("users slash foo slash bar", "users/foo/bar"),
        ("cd tilde slash Documents slash VoiceInput and run swift build", "cd ~/Documents/VoiceInput and run swift build"),
        ("open slash etc slash hosts with sudo nano", "open /etc/hosts with sudo nano"),
        ("export PATH equals dollar HOME slash bin colon dollar PATH", "export PATH=$HOME/bin:$PATH"),
        // Math and numbers
        ("x equals one hundred twenty three", "x = 123"),
        ("total equals price times quantity minus discount", "total = price * quantity - discount"),
        ("twenty five percent", "25 %"),
        ("a divided by b modulo c", "a / b % c"),
        ("i plus plus", "i++"),
        ("x greater than or equal to zero", "x >= 0"),
        // Identifiers
        ("parse json from the url", "parse JSON from the URL"),
        ("push to git hub", "push to GitHub"),
        ("import swift ui", "import SwiftUI"),
        ("print to std out", "print to stdout"),
        // Fillers and self-correction
        ("um set timeout to five no ten seconds", "set timeout to 10 seconds"),
        ("user id no user name", "user name"),
        ("return foo scratch that return bar", "return bar"),
        ("camel case get user i mean get account", "getAccount"),
        ("the value is uh nil", "the value is nil"),
        // Flags and terminal-ish
        ("git commit dash m quote fix login bug end quote", "git commit -m \"fix login bug\""),
        ("npm install dash dash save dev typescript", "npm install --save dev TypeScript"),
        ("grep dash r n todo space dot space pipe head", "grep -rn TODO . | head"),
        ("kebab case voice dash plus dash app dot swift", "voice-plus-app.swift"),
        ("snake case user id equals request dot params dot user id", "user_id = request.params.user_id"),
        ("let transcript colon array of transcript span equals empty array", "let transcript: [TranscriptSpan] = []"),
        // No sentence punctuation / capitalization
        ("Returns nil when the cache is cold.", "returns nil when the cache is cold"),
        ("Hello, world", "hello world"),
        ("console dot log open paren quote hi end quote close paren", "console.log(\"hi\")"),
        ("new line", "\n"),
    ]

    @Test(arguments: golden)
    func golden(input: String, expected: String) {
        #expect(CodeFormatter.format(input) == expected, "input: \(input)")
    }

    @Test func goldenHasAtLeastFortyCases() {
        #expect(Self.golden.count >= 40)
    }

    // MARK: Technical audio fixture transcripts (Fixtures/audio/technical/manifest.json)

    struct ManifestEntry: Decodable { let file: String; let transcript: String }

    static let technicalExpected: [String: String] = [
        "technical_01_samantha.wav": "git commit -m \"fix login bug\"",
        "technical_02_daniel.wav": "user_id = request.params.user_id",
        "technical_03_rishi.wav": "getUserProfile returns an optional user",
        "technical_04_samantha.wav": "cd ~/Documents/VoiceInput and run swift build",
        "technical_05_daniel.wav": "open /etc/hosts with sudo nano",
        "technical_06_rishi.wav": "npm install --save dev TypeScript",
        "technical_07_samantha.wav": "voice-plus-app.swift",
        "technical_08_daniel.wav": "grep -rn TODO . | head",
        "technical_09_rishi.wav": "export PATH=$HOME/bin:$PATH",
        "technical_10_samantha.wav": "let transcript: [TranscriptSpan] = []",
    ]

    @Test func technicalManifestTranscripts() throws {
        let url = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("audio/technical/manifest.json")
        let entries = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: url))
        #expect(entries.count == 10)
        for entry in entries {
            let expected = try #require(Self.technicalExpected[entry.file])
            #expect(CodeFormatter.format(entry.transcript) == expected, Comment(rawValue: entry.file))
        }
    }

    // MARK: Confidence contract (Bet 9)

    func spans(_ words: [(String, Float)]) -> [TranscriptSpan] {
        words.enumerated().map { i, w in
            TranscriptSpan(text: w.0, confidence: w.1, audioRange: Double(i) * 0.5...Double(i + 1) * 0.5, provenance: [.asr])
        }
    }

    @Test func lowConfidenceSpanIsFlaggedNotRewritten() async throws {
        let input = spans([("camel", 0.9), ("case", 0.9), ("user", 0.9), ("kothari", 0.3), ("equals", 0.9), ("nil", 0.9)])
        let output = try await CodeFormatter().process(input, context: StageContext(register: .code))
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        let frozen = try #require(output.first { $0.text == "kothari" })
        #expect(frozen.needsRepair)
        #expect(frozen.confidence == 0.3)
        #expect(frozen.provenance == [.asr, .formatterCode])
        #expect(CodeFormatter.render(output) == "user kothari = nil")
    }

    @Test func mergedSpansKeepMinimumConfidenceAndAlternates() async throws {
        var input = spans([("snake", 0.95), ("case", 0.9), ("user", 0.8), ("id", 0.7)])
        input[3].alternates = [Alternate(text: "I.D.", score: 0.2, source: .beam)]
        let output = try await CodeFormatter().process(input, context: StageContext(register: .code))
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(output.count == 1)
        #expect(output[0].text == "user_id")
        #expect(output[0].confidence == 0.7)
        #expect(output[0].audioRange == 0...2.0)
        #expect(output[0].alternates.count == 1)
        #expect(output[0].provenance == [.asr, .formatterCode])
    }

    @Test func deletedWordsKeepTheirAudioRange() async throws {
        let input = spans([("um", 0.9), ("five", 0.9), ("no", 0.9), ("ten", 0.9), ("seconds", 0.9)])
        let output = try await CodeFormatter().process(input, context: StageContext(register: .code))
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(CodeFormatter.render(output) == "10 seconds")
        #expect(output.first?.audioRange.lowerBound == 0)
        #expect(output.last?.audioRange.upperBound == 2.5)
    }

    @Test func selfCorrectionNeverDeletesLowConfidenceSpan() async throws {
        let input = spans([("five", 0.2), ("no", 0.9), ("ten", 0.9)])
        let output = try await CodeFormatter().process(input, context: StageContext(register: .code))
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(output.contains { $0.text == "five" && $0.needsRepair })
        #expect(CodeFormatter.render(output) == "five no 10")
    }

    @Test func unchangedHighConfidenceSpansOnlyGetProvenance() async throws {
        let input = spans([("return", 0.9), ("value", 0.9)])
        let output = try await CodeFormatter().process(input, context: StageContext(register: .code))
        #expect(output.map(\.text) == ["return", "value"])
        #expect(output.allSatisfy { $0.provenance == [.asr, .formatterCode] && !$0.needsRepair })
    }

    @Test func codeCommentFixtureSurvivesContract() async throws {
        let url = try #require(AppPaths.fixturesDirectory()).appendingPathComponent("transcripts/code_comment.json")
        let fixture = try JSONDecoder().decode(TranscriptFixture.self, from: Data(contentsOf: url))
        let input = fixture.spans.map { $0.span }
        let output = try await CodeFormatter().process(input, context: StageContext(register: .code))
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(output.contains { $0.text == "memoized" && $0.needsRepair })
        #expect(CodeFormatter.render(output) == "returns nil when the cache is cold otherwise the memoized value")
    }

    @Test func emptyInputIsEmptyOutput() async throws {
        let output = try await CodeFormatter().process([], context: StageContext(register: .code))
        #expect(output.isEmpty)
    }

    @Test func registeredInStageRegistry() {
        #expect(StageRegistry.formatter(for: .code)?.id == .formatterCode)
    }
}
