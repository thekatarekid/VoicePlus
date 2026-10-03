import Testing
import Shared
@testable import Pipeline

/// Golden input→output cases for the chat formatter (P1.7 T3). Each case feeds word-level
/// spans (as the ASR produces them) and checks rendered text plus the confidence contract.
@Suite struct ChatFormatterTests {
    struct Golden: Sendable {
        let input: String
        let expected: String
        var lowercaseFirst = false
        init(_ input: String, _ expected: String, lowercaseFirst: Bool = false) {
            self.input = input; self.expected = expected; self.lowercaseFirst = lowercaseFirst
        }
    }

    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, word in
            TranscriptSpan(text: String(word), confidence: confidence,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func run(_ spans: [TranscriptSpan], lowercaseFirst: Bool = false) async throws -> [TranscriptSpan] {
        var context = StageContext(register: .chat, appBundleID: "com.tinyspeck.slackmacgap")
        if lowercaseFirst { context.extra[ChatFormatter.lowercaseFirstKey] = "true" }
        return try await ChatFormatter().process(spans, context: context)
    }

    static let golden: [Golden] = [
        // Fillers
        Golden("um I'll ping you later", "I'll ping you later"),
        Golden("I'll uh ping you later", "I'll ping you later"),
        Golden("yeah um sounds good", "yeah sounds good"),
        Golden("so, um, I think we should ship", "so I think we should ship"),
        Golden("it's, you know, fine", "it's fine"),
        Golden("erm hmm ok", "ok"),
        Golden("see you there uh.", "see you there."),
        // Light punctuation
        Golden("sounds good.", "sounds good."),
        Golden("on my way.", "on my way."),
        Golden("are you coming?", "are you coming?"),
        Golden("let's go!", "let's go!"),
        Golden("running late. be there in ten.", "running late. be there in ten."),
        Golden("wait...", "wait..."),
        Golden("ok", "ok"),
        // Spoken punctuation
        Golden("are you coming question mark", "are you coming?"),
        Golden("nice exclamation mark", "nice!"),
        Golden("ok comma see you then", "ok, see you then"),
        Golden("first line new line second line", "first line\nsecond line"),
        Golden("done period next", "done. next"),
        // Self-correction
        Golden("let's meet Friday no Thursday", "let's meet Thursday"),
        Golden("let's meet Friday, no, Thursday", "let's meet Thursday"),
        Golden("let's meet on Friday no on Thursday", "let's meet on Thursday"),
        Golden("send it to Bob I mean Alice", "send it to Alice"),
        Golden("send it to Bob sorry Alice", "send it to Alice"),
        Golden("the demo is at three actually four", "the demo is at four"),
        Golden("call me tomorrow scratch that call me tonight", "call me tonight"),
        Golden("no I can't make it", "no I can't make it"),
        Golden("no worries", "no worries"),
        Golden("it's Friday, no, Thursday.", "it's Thursday."),
        // Emoji words
        Golden("thumbs up emoji", "👍"),
        Golden("great work thumbs up emoji", "great work 👍"),
        Golden("that's hilarious laughing emoji", "that's hilarious 😂"),
        Golden("shipped it rocket emoji", "shipped it 🚀"),
        Golden("fire emoji fire emoji", "🔥 🔥"),
        Golden("love it heart emoji", "love it ❤️"),
        Golden("eyes emoji on this", "👀 on this"),
        Golden("party emoji we did it!", "🎉 we did it!"),
        Golden("thinking emoji not sure", "🤔 not sure"),
        Golden("lol skull emoji", "lol 💀"),
        Golden("thanks praying hands emoji", "thanks 🙏"),
        Golden("an emoji would help", "an emoji would help"),
        // Slash commands
        Golden("slash remind me in ten minutes", "/remind me in ten minutes"),
        Golden("slash giphy cats", "/giphy cats"),
        Golden("slash status lunch", "/status lunch"),
        Golden("Slash away", "/away"),
        Golden("coffee and slash or tea", "coffee and/or tea"),
        Golden("use the slash", "use the slash"),
        // Lowercase-first (opt-in)
        Golden("Sounds good.", "sounds good.", lowercaseFirst: true),
        Golden("I'll be there", "I'll be there", lowercaseFirst: true),
        Golden("OK cool", "OK cool", lowercaseFirst: true),
        Golden("Sounds good.", "Sounds good."),
        // Combined
        Golden("um yeah Friday no Thursday works thumbs up emoji.", "yeah Thursday works 👍."),
        Golden("slash remind me um tomorrow question mark", "/remind me tomorrow?"),
    ]

    @Test(arguments: golden)
    func goldenCase(_ g: Golden) async throws {
        let input = Self.spans(g.input)
        let output = try await Self.run(input, lowercaseFirst: g.lowercaseFirst)
        #expect(ChatFormatter.render(output) == g.expected, "input: \(g.input)")
        #expect(ConfidenceContract.verify(input: input, output: output) == [], "contract: \(g.input)")
        #expect(output.allSatisfy { $0.provenance.last == .formatterChat })
    }

    @Test func goldenCaseCountMeetsSpec() {
        #expect(Self.golden.count >= 40)
    }

    @Test func lowConfidenceSpanIsFlaggedNotRewritten() async throws {
        var input = Self.spans("yeah I'll ping Kothari after standup lol.")
        input[3].confidence = 0.29
        input[5].confidence = 0.47
        let output = try await Self.run(input)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        let kothari = try #require(output.first { $0.audioRange == input[3].audioRange })
        #expect(kothari.text == "Kothari" && kothari.needsRepair && kothari.confidence == 0.29)
        #expect(ChatFormatter.render(output) == "yeah I'll ping Kothari after standup lol.")
    }

    @Test func lowConfidenceBoundaryBlocksCorrectionAndEmoji() async throws {
        var input = Self.spans("meet Friday no Thursday thumbs up emoji")
        input[1].confidence = 0.2 // "Friday" garbled: must not be replaced
        input[4].confidence = 0.3 // "thumbs" garbled: emoji must not resolve
        let output = try await Self.run(input)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(ChatFormatter.render(output) == "meet Friday no Thursday thumbs up emoji")
        #expect(output.filter(\.needsRepair).count == 2)
    }

    @Test func fillerBetweenLowConfidenceSpansIsKept() async throws {
        var input = Self.spans("a um b")
        input[0].confidence = 0.1
        input[2].confidence = 0.1
        let output = try await Self.run(input)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(output.count == 3)
        #expect(ChatFormatter.render(output) == "a um b")
    }

    @Test func mergedSpansKeepAlternatesAndMinConfidence() async throws {
        var input = Self.spans("um hello")
        input[1].alternates = [Alternate(text: "hallo", score: 0.2, source: .beam)]
        input[1].confidence = 0.7
        let output = try await Self.run(input)
        #expect(output.count == 1)
        #expect(output[0].alternates.count == 1)
        #expect(output[0].confidence == 0.7)
        #expect(output[0].audioRange == 0...0.6)
        #expect(output[0].provenance == [.asr, .formatterChat])
    }

    @Test func emptyInput() async throws {
        #expect(try await Self.run([]).isEmpty)
    }

    @Test func fixtureChatNoisy() async throws {
        let spans = try TranscriptFixture.load(named: "chat_noisy").spans.map(\.span)
        let output = try await Self.run(spans)
        #expect(ConfidenceContract.verify(input: spans, output: output) == [])
        #expect(output.contains { $0.needsRepair })
    }

    @Test func registeredInStageRegistry() {
        #expect(StageRegistry.stage(for: .formatterChat) is ChatFormatter)
        #expect(StageRegistry.formatter(for: .chat)?.id == .formatterChat)
    }
}
