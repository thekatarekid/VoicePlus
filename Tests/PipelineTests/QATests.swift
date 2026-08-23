import Testing
import Foundation
import Shared
@testable import Pipeline

/// P2.4 — question route: answer appended below the selection, attributed, never replacing.
@Suite struct QATests {
    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence, audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }
    static let selection = "The launch slipped to March 3. Churn rose to 4.2% last quarter. We need two more engineers."
    static func ctx(_ sel: String? = selection, surrounding: String? = nil) -> StageContext {
        var c = StageContext(register: .email, appBundleID: "com.apple.mail")
        if let sel { c.extra[QuestionAnswerStage.selectionKey] = sel }
        if let surrounding { c.extra[QuestionAnswerStage.surroundingKey] = surrounding }
        return c
    }
    struct FixedAnswerer: QuestionAnswering {
        let text: String
        func answer(question: String, selection: String, surrounding: String?, context: StageContext) async throws -> String { text }
    }
    struct RecordingRouting: PipelineProviderRouting, @unchecked Sendable {
        let enabled: Bool; let reply: String?
        final class Box: @unchecked Sendable { var prompts: [String] = [] }
        let box = Box()
        func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { enabled }
        func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String {
            box.prompts.append(prompt)
            guard let reply else { throw ProviderRoutingError.unavailable }
            return reply
        }
    }

    // MARK: Stage output shape

    @Test func answerIsAppendedBelowWithAttribution() async throws {
        let input = Self.spans("what is the deadline")
        let out = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "March 3")).answer(input, context: Self.ctx())
        #expect(out.answer == "March 3")
        #expect(out.spans.count == input.count + 1)
        #expect(out.spans.last?.text == "answer: March 3")
        #expect(out.insertion == "\nanswer: March 3")
        #expect(out.intent == .insertBelow(selectionLength: Self.selection.count))
    }

    @Test func questionSpansAreNeverRewritten() async throws {
        let input = Self.spans("what is the deadline")
        let out = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "March 3")).answer(input, context: Self.ctx())
        for (i, s) in input.enumerated() {
            #expect(out.spans[i].text == s.text && out.spans[i].confidence == s.confidence && out.spans[i].audioRange == s.audioRange)
            #expect(out.spans[i].provenance == [.asr, .questionAnswer])
        }
    }

    @Test func outputHonoursConfidenceContract() async throws {
        let input = Self.spans("what does this say", confidence: 0.4)
        let out = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "It says hi")).process(input, context: Self.ctx())
        #expect(ConfidenceContract.verify(input: input, output: out).isEmpty)
        let last = try #require(out.last)
        #expect(last.confidence == 1 && last.provenance == [.questionAnswer])
        #expect(last.audioRange.lowerBound == last.audioRange.upperBound)
        #expect(last.audioRange.upperBound == input.last!.audioRange.upperBound)
    }

    @Test func selectionTextNeverAppearsReplacedInOutput() async throws {
        let out = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "4.2%")).answer(Self.spans("what is the churn"), context: Self.ctx())
        #expect(out.intent != .replaceSelection)
        #expect(!out.spans.contains { $0.text == Self.selection })
    }

    @Test func noSelectionMeansNoAnswer() async throws {
        let out = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "x")).answer(Self.spans("what is this"), context: Self.ctx(nil))
        #expect(out.answer == nil && out.intent == .none && out.insertion == "")
        #expect(out.spans.count == 3 && out.spans.allSatisfy { $0.provenance.last == .questionAnswer })
        let blank = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "x")).answer(Self.spans("what is this"), context: Self.ctx("  \n"))
        #expect(blank.intent == .none)
    }

    @Test func emptyQuestionOrEmptyAnswerYieldsNothing() async throws {
        let out = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "   \n")).answer(Self.spans("why"), context: Self.ctx())
        #expect(out.answer == nil && out.intent == .none)
        let none = try await QuestionAnswerStage(answerer: FixedAnswerer(text: "x")).answer([], context: Self.ctx())
        #expect(none.spans.isEmpty && none.intent == .none)
    }

    @Test func sanitizeStripsEchoedAttributionAndBlankLines() {
        #expect(QuestionAnswerStage.sanitize("Answer: March 3") == "March 3")
        #expect(QuestionAnswerStage.sanitize("answer:  answer: nested") == "nested")
        #expect(QuestionAnswerStage.sanitize("  line one \n\n  line two  ") == "line one\nline two")
        #expect(QuestionAnswerStage.sanitize("answer:") == nil)
        #expect(QuestionAnswerStage.sanitize("Answers are hard") == "Answers are hard")
    }

    @Test func attributionPrefixIsVisibleAndStable() {
        #expect(QuestionAnswerStage.attributionPrefix == "answer:")
        #expect(QuestionAnswerStage.attribution("x").hasPrefix("answer: "))
    }

    @Test func stageIdMatchesQuestionRoute() {
        #expect(QuestionAnswerStage().id.rawValue == Utterance.Route.question.rawValue)
    }

    // MARK: Provider answerer

    @Test func providerAnswererUsesProviderWhenEnabled() async throws {
        let routing = RecordingRouting(enabled: true, reply: "Answer: 4.2%")
        let out = try await QuestionAnswerStage(answerer: ProviderAnswerer(providers: routing))
            .answer(Self.spans("what is the churn"), context: Self.ctx(surrounding: "Subject: Q3 update"))
        #expect(out.answer == "4.2%")
        let prompt = try #require(routing.box.prompts.first)
        #expect(prompt.contains("SELECTED TEXT:\n\(Self.selection)") && prompt.contains("QUESTION: what is the churn"))
        #expect(prompt.contains("SURROUNDING CONTEXT:\nSubject: Q3 update"))
    }

    @Test func providerAnswererFallsBackWhenDisabledOrFailing() async throws {
        let disabled = ProviderAnswerer(providers: RecordingRouting(enabled: false, reply: "cloud"), fallback: FixedAnswerer(text: "local"))
        #expect(try await disabled.answer(question: "q", selection: "s", surrounding: nil, context: Self.ctx()) == "local")
        let failing = ProviderAnswerer(providers: RecordingRouting(enabled: true, reply: nil), fallback: FixedAnswerer(text: "local"))
        #expect(try await failing.answer(question: "q", selection: "s", surrounding: nil, context: Self.ctx()) == "local")
    }

    @Test func providerPromptCarriesPersona() {
        let p = ProviderAnswerer.prompt(question: "q", selection: "s", surrounding: nil, persona: "casual, lowercase")
        #expect(p.contains("Voice: casual, lowercase"))
        #expect(!ProviderAnswerer.prompt(question: "q", selection: "s", surrounding: nil, persona: nil).contains("Voice:"))
    }

    // MARK: Heuristic answerer (offline)

    @Test func heuristicCounts() async throws {
        let h = HeuristicAnswerer()
        #expect(try await h.answer(question: "how many words is this", selection: "one two three", surrounding: nil, context: Self.ctx()) == "3 words")
        #expect(try await h.answer(question: "how many sentences are there", selection: Self.selection, surrounding: nil, context: Self.ctx()) == "3 sentences")
        #expect(try await h.answer(question: "how many characters", selection: "abcd", surrounding: nil, context: Self.ctx()) == "4 characters")
    }

    @Test func heuristicGistAndKeywordLookup() async throws {
        let h = HeuristicAnswerer()
        #expect(try await h.answer(question: "what does this say", selection: Self.selection, surrounding: nil, context: Self.ctx()) == "The launch slipped to March 3.")
        #expect(try await h.answer(question: "what is the churn number", selection: Self.selection, surrounding: nil, context: Self.ctx()) == "Churn rose to 4.2% last quarter.")
        #expect(try await h.answer(question: "how many engineers do we need", selection: Self.selection, surrounding: nil, context: Self.ctx()) == "We need two more engineers.")
    }

    @Test func heuristicAdmitsWhenItCannotAnswer() async throws {
        let a = try await HeuristicAnswerer().answer(question: "is this correct", selection: Self.selection, surrounding: nil, context: Self.ctx())
        #expect(a == HeuristicAnswerer.cannotAnswer)
    }

    @Test func endToEndDefaultStageAppendsHeuristicAnswer() async throws {
        let out = try await QuestionAnswerStage().answer(Self.spans("what is the deadline for this"), context: Self.ctx())
        #expect(out.spans.last?.text == "answer: The launch slipped to March 3.")
        #expect(out.intent == .insertBelow(selectionLength: Self.selection.count))
    }
}
