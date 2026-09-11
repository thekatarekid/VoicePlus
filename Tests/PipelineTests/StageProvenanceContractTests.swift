import Foundation
import Shared
import Testing
@testable import Pipeline

/// R4.1a — the two stages that used to be silent no-ops.
///
/// A `PipelineStage` must append its `id` to the provenance of *every* span it returns, including
/// the spans it decided not to change. `WakeVerbStage` returned its input array untouched whenever
/// the session was not latched or the utterance carried no wake verb — which is nearly every dictation — so
/// `ConfidenceContract.verify` reported "did not append provenance" and `ContractEnforcingStage`
/// discarded the stage's output under the production policy. The same bug in the `adapt.lexicon`
/// stage is covered in `Tests/AppTests/ProvenanceReplayTests.swift`, because that stage type
/// (`RegressionGuardStage`) lives in `App/Services/` and `PipelineTests` cannot see it.
@Suite struct StageProvenanceContractTests {

    static func hf(_ register: Utterance.Register = .unknown) -> StageContext {
        StageContext(register: register, extra: [WakeVerbPreRoute.modeKey: WakeVerbPreRoute.latchedValue])
    }

    /// One span per word, `[.asr]` provenance, contiguous non-zero audio ranges.
    static func spans(_ text: String, confidence: Float = 0.9) -> [TranscriptSpan] {
        text.split(separator: " ").enumerated().map { i, w in
            TranscriptSpan(text: String(w), confidence: confidence,
                           audioRange: Double(i) * 0.3...Double(i) * 0.3 + 0.3, provenance: [.asr])
        }
    }

    static func assertContract(_ input: [TranscriptSpan], _ output: [TranscriptSpan], _ id: StageID) {
        #expect(ConfidenceContract.verify(input: input, output: output).isEmpty)
        #expect(output.allSatisfy { $0.provenance.last == id }, "every output span records \(id)")
        #expect(output.count == input.count)
        for (i, o) in zip(input, output) {
            #expect(o.confidence == i.confidence, "confidence survives")
            #expect(o.audioRange == i.audioRange, "audioRange survives")
            #expect(o.provenance.dropLast() == i.provenance, "earlier provenance survives, in order")
        }
    }

    // MARK: wakeVerb

    @Test func wakeVerbAppendsProvenanceOnPassThroughOutsideLatch() async throws {
        let input = Self.spans("send the deck to Priya before the standup")
        let out = try await WakeVerbStage(preRoute: WakeVerbPreRoute()).process(input, context: StageContext())
        Self.assertContract(input, out, .wakeVerb)
        #expect(out.map(\.text) == input.map(\.text), "no wake verb is stripped outside latch")
    }

    @Test func wakeVerbAppendsProvenanceOnPassThroughWithNoWakeVerb() async throws {
        let input = Self.spans("the quick brown fox jumps over the lazy dog")
        let out = try await WakeVerbStage(preRoute: WakeVerbPreRoute()).process(input, context: Self.hf())
        Self.assertContract(input, out, .wakeVerb)
        #expect(out.map(\.text) == input.map(\.text))
    }

    @Test func wakeVerbAppendsProvenanceOnModification() async throws {
        let hook = WakeVerbPreRoute()
        let input = Self.spans("type hello world")
        _ = hook.preRoute(input.joinedText, context: Self.hf())
        let out = try await WakeVerbStage(preRoute: hook).process(input, context: Self.hf())
        #expect(out.map(\.text) == ["", "hello", "world"], "the verb is stripped")
        Self.assertContract(input, out, .wakeVerb)
    }

    @Test func wakeVerbNeverRewritesLowConfidenceText() async throws {
        let input = Self.spans("type hello world", confidence: 0.3)
        let out = try await WakeVerbStage(preRoute: WakeVerbPreRoute()).process(input, context: Self.hf())
        #expect(out.map(\.text) == input.map(\.text), "Bet 9: low-confidence words are not rewritten")
        Self.assertContract(input, out, .wakeVerb)
    }

    @Test func wakeVerbSurvivesTheEnforcingWrapper() async throws {
        // Before the fix this logged "contract violation in wakeVerb" and the wrapper fell back to
        // the input, so the stage could never ship a strip.
        let hook = WakeVerbPreRoute()
        let input = Self.spans("type hello world")
        _ = hook.preRoute(input.joinedText, context: Self.hf())
        let sink = CollectingLabSink()
        let out = try await ContractEnforcingStage(WakeVerbStage(preRoute: hook), policy: .fallbackToInput, sink: sink)
            .process(input, context: Self.hf())
        #expect(out.map(\.text) == ["", "hello", "world"], "the wrapper keeps the stage's output")
        #expect(sink.all.allSatisfy { $0.contractViolations.isEmpty })
    }

    /// The shape both stages had before R4.1a: return the input array as-is when there is nothing
    /// to change. Pinned here so the cost of that shortcut stays visible — the wrapper reports a
    /// violation and throws the stage's output away, which is why the two stages were dead.
    struct UntouchedPassThroughStage: PipelineStage {
        let id: StageID = "test.untouched"
        func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] { spans }
    }

    @Test func aStageThatReturnsItsInputUnchangedIsAContractViolation() async throws {
        let input = Self.spans("hello world")
        let sink = CollectingLabSink()
        _ = try await ContractEnforcingStage(UntouchedPassThroughStage(), policy: .fallbackToInput, sink: sink)
            .process(input, context: StageContext())
        let reported = sink.all.flatMap(\.contractViolations)
        #expect(reported.count == input.count, "one 'did not append provenance' per span: \(reported)")
        #expect(reported.allSatisfy { $0.contains("did not append provenance") })
    }

    // MARK: real-room corpus replay (Pipeline-visible stages)

    /// The stage list `AppContainer` builds, minus `adapt.lexicon` (an `App/Services/` type that
    /// `PipelineTests` cannot import). The full list is replayed in `AppTests`.
    static func appContainerPipelineStages() -> [any PipelineStage] {
        [WakeVerbStage(preRoute: WakeVerbPreRoute()), SnippetStage(store: InMemorySnippetStore())]
            + StageRegistry.allStages().filter { $0.id != .gatekeeper }.map { stage in
                stage.id == .style ? StyleStage(store: InMemoryStyleProfileStore()) : stage
            }
    }

    /// The twenty reference sentences of `Fixtures/real-room/script.md`, in script order.
    static func corpusLines() -> [String] {
        guard let dir = AppPaths.fixturesDirectory(),
              let text = try? String(contentsOf: dir.appendingPathComponent("real-room/script.md"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count > 4, line.prefix(2).allSatisfy(\.isNumber) else { return nil }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
    }

    @Test func realRoomCorpusReplayHasNoContractViolations() async throws {
        let lines = Self.corpusLines()
        try #require(lines.count == 20, "Fixtures/real-room/script.md holds the twenty reference sentences")
        let runner = PipelineRunner(stages: Self.appContainerPipelineStages())
        var violations: [String] = []
        var stagesRun = 0
        for (i, line) in lines.enumerated() {
            for context in [StageContext(), Self.hf()] {
                let result = try await runner.run(Self.spans(line), context: context)
                stagesRun += result.metrics.count
                for m in result.metrics where !m.contractViolations.isEmpty {
                    violations.append("\(String(format: "%02d", i + 1)) \(m.stage): \(m.contractViolations.joined(separator: "; "))")
                }
            }
        }
        #expect(violations.isEmpty, "contract violations:\n\(violations.joined(separator: "\n"))")
        #expect(stagesRun > 0)
        print("R4.1a: replayed \(lines.count) real-room utterances x2 contexts, \(stagesRun) stage runs, \(violations.count) contract violations")
    }
}
