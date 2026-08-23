import Foundation
import Testing
import Shared
@testable import Pipeline

private struct Upper: PipelineStage {
    let id: StageID
    func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
        spans.map { $0.isLowConfidence ? $0.flaggedForRepair(by: id) : $0.rewritten($0.text.uppercased(), by: id) }
    }
}

private let spans = [
    TranscriptSpan(text: "hi team", confidence: 0.9, audioRange: 0...0.5, provenance: [.asr]),
    TranscriptSpan(text: "see you thursday", confidence: 0.8, audioRange: 0.5...1.4, provenance: [.asr]),
]

@Suite struct InstrumentationTests {
    @Test func editDistance() {
        #expect(EditDistance.levenshtein("kitten", "sitting") == 3)
        #expect(EditDistance.levenshtein("", "abc") == 3)
        #expect(EditDistance.levenshtein("same", "same") == 0)
    }

    @Test func runnerRecordsMetricsPerStageAndSkipsByRegister() async throws {
        let sink = CollectingLabSink()
        let runner = PipelineRunner(stages: [Upper(id: .formatterChat), Upper(id: .formatterEmail)], sink: sink)
        let result = try await runner.run(spans, context: StageContext(appBundleID: "com.tinyspeck.slackmacgap"))
        #expect(result.decision.route == .dictate)
        #expect(result.decision.register == .chat)
        #expect(result.text == "HI TEAM SEE YOU THURSDAY")
        #expect(result.metrics.map(\.stage) == [.gatekeeper, .formatterChat, .formatterEmail])
        #expect(result.metrics[1].skipped == false && result.metrics[1].editDistance > 0)
        #expect(result.metrics[2].skipped == true)
        #expect(sink.skipRate(for: .formatterEmail) == 1)
        #expect(result.spans.allSatisfy { $0.provenance.prefix(2) == [.asr, .gatekeeper] })
        #expect(result.totalLatencyMs < 250)
    }

    @Test func runnerSkipsFormattersForCommands() async throws {
        let sink = CollectingLabSink()
        let runner = PipelineRunner(stages: [Upper(id: .style)], sink: sink)
        let cmd = [TranscriptSpan(text: "scratch that", confidence: 0.9, audioRange: 0...0.6, provenance: [.asr])]
        let result = try await runner.run(cmd, context: StageContext(register: .chat))
        #expect(result.decision.route == .repairCommand)
        #expect(result.text == "scratch that")
        #expect(result.metrics.map(\.stage) == [.gatekeeper])
    }

    @Test func metricsReachLogBuffer() async throws {
        let buffer = LogBuffer(capacity: 50)
        let runner = PipelineRunner(stages: [Upper(id: .style)], sink: LogBufferLabSink(buffer: buffer))
        _ = try await runner.run(spans, context: StageContext(register: .prose))
        let lines = buffer.snapshot(category: LogBufferLabSink.category)
        #expect(lines.count == 2)
        #expect(lines.last?.message.contains("stage=style") == true)
    }

    @Test func gatekeeperStageIsNoOpButStampsProvenance() async throws {
        let out = try await GatekeeperStage().process(spans, context: StageContext())
        #expect(ConfidenceContract.verify(input: spans, output: out).isEmpty)
        #expect(out.map(\.text) == spans.map(\.text))
    }

    @Test func standardRunnerBuildsFromRegistry() async throws {
        let runner = PipelineRunner.standard(sink: CollectingLabSink())
        let result = try await runner.run(spans, context: StageContext(register: .chat))
        #expect(result.decision.route == .dictate)
        #expect(ConfidenceContract.verify(input: spans, output: result.spans).isEmpty || result.metrics.contains { !$0.contractViolations.isEmpty })
    }
}
