import Foundation
import Shared
import Testing
@testable import Pipeline

/// CLAUDE.md's stage contract is `[TranscriptSpan] -> [TranscriptSpan]`. A stage that cannot do
/// its optional job — a provider that is switched off, a store that would not open — has to
/// return its input, not take the user's words down with it.
///
/// Before 1.7.10 a throw from any stage unwound `PipelineRunner.run`, and `UtteranceLander`'s
/// rescue landed the *raw* spans: every earlier stage's work was discarded too.
@Suite("a stage that fails degrades to pass-through")
struct StageFailurePassthroughTests {
    struct Boom: Error { let stage: String }

    /// Stands in for any optional stage that can be off: it throws the way a provider-backed
    /// stage does when nothing is configured for it.
    struct DisabledStage: PipelineStage {
        let id: StageID
        func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
            throw Boom(stage: id.rawValue)
        }
    }

    /// Appends a marker so we can prove a later stage still ran on the earlier stage's output.
    struct SuffixStage: PipelineStage {
        let id: StageID
        let suffix: String
        func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
            guard var last = spans.last else { return spans }
            last = TranscriptSpan(text: last.text + suffix, confidence: last.confidence, audioRange: last.audioRange,
                                  alternates: last.alternates, provenance: last.provenance + [id],
                                  needsRepair: last.needsRepair)
            return spans.dropLast() + [last]
        }
    }

    static let input = [TranscriptSpan(text: "ship the release notes", confidence: 0.95,
                                       audioRange: 0...1.4, provenance: [.asr])]

    @Test("the wrapper returns the stage's input instead of throwing")
    func wrapperPassesInputThrough() async throws {
        let id = StageID("act.planner")
        let out = try await ContractEnforcingStage(DisabledStage(id: id), policy: .fallbackToInput)
            .process(Self.input, context: StageContext())
        #expect(out.joinedText == Self.input.joinedText)
        #expect(out.count == Self.input.count)
        // Never drop confidence / audioRange / provenance (CLAUDE.md).
        #expect(out[0].confidence == Self.input[0].confidence)
        #expect(out[0].audioRange == Self.input[0].audioRange)
        #expect(out[0].provenance.contains(.asr))
        #expect(out[0].provenance.contains(id))
    }

    @Test("the failure is recorded, so a disabled stage is visible in the Lab")
    func failureIsRecorded() async throws {
        let sink = CollectingLabSink()
        _ = try await ContractEnforcingStage(DisabledStage(id: StageID("act.planner")),
                                             policy: .fallbackToInput, sink: sink)
            .process(Self.input, context: StageContext())
        #expect(sink.all.count == 1)
        #expect(sink.all[0].stage == StageID("act.planner"))
        #expect(!sink.all[0].contractViolations.isEmpty)
    }

    @Test("strict mode still rethrows — only production degrades")
    func strictStillThrows() async {
        await #expect(throws: Boom.self) {
            _ = try await ContractEnforcingStage(DisabledStage(id: StageID("act.planner")), policy: .strict)
                .process(Self.input, context: StageContext())
        }
    }

    @Test("one failing stage never swallows the turn, and later stages keep running")
    func runnerLandsTextAndKeepsGoing() async throws {
        let runner = PipelineRunner(
            stages: [SuffixStage(id: StageID("test.before"), suffix: " A"),
                     DisabledStage(id: StageID("act.planner")),
                     SuffixStage(id: StageID("test.after"), suffix: " B")],
            providers: LocalOnlyProviderRouting())
        let result = try await runner.run(Self.input, context: StageContext(register: .prose))
        #expect(result.decision.route == .dictate)
        #expect(result.text == "ship the release notes A B",
                "the earlier stage's output must survive the disabled stage in the middle")
    }
}
