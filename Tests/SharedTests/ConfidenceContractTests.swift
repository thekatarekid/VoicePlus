import Testing
@testable import Shared

@Suite struct ConfidenceContractTests {
    let input: [TranscriptSpan] = [
        TranscriptSpan(text: "hello", confidence: 0.95, audioRange: 0...0.5, provenance: [.asr]),
        TranscriptSpan(text: "kothari", confidence: 0.3, audioRange: 0.5...1.2, provenance: [.asr]),
        TranscriptSpan(text: "there", confidence: 0.9, audioRange: 1.2...1.6, provenance: [.asr]),
    ]

    @Test func compliantStageHasNoViolations() {
        let output = input.map { span -> TranscriptSpan in
            span.isLowConfidence ? span.flaggedForRepair(by: .style) : span.rewritten(span.text.capitalized, by: .style)
        }
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
    }

    @Test func rewritingLowConfidenceSpanIsViolation() {
        var output = input.map { $0.touched(by: .style) }
        output[1].text = "Kothari"
        let violations = ConfidenceContract.verify(input: input, output: output)
        #expect(violations.count == 1)
        #expect(violations.first?.contains("rewrote low-confidence span") == true)
    }

    @Test func rewritingLowConfidenceSpanWithRepairFlagIsAllowed() {
        var output = input.map { $0.touched(by: .style) }
        output[1].text = "Kothari"
        output[1].needsRepair = true
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
    }

    @Test func droppedAudioRangeIsViolation() {
        let output = [input[0], input[2]].map { $0.touched(by: .gatekeeper) }
        let violations = ConfidenceContract.verify(input: input, output: output)
        #expect(violations.count == 1)
        #expect(violations.first?.contains("was dropped") == true)
    }

    @Test func missingProvenanceAppendIsViolation() {
        let violations = ConfidenceContract.verify(input: input, output: input)
        #expect(violations.count == 3)
        #expect(violations.allSatisfy { $0.contains("did not append provenance") })
    }

    @Test func emptyProvenanceIsViolation() {
        var output = input.map { $0.touched(by: .style) }
        output[0].provenance = []
        let violations = ConfidenceContract.verify(input: input, output: output)
        #expect(violations.count == 1)
        #expect(violations.first?.contains("empty provenance") == true)
    }

    @Test func changedConfidenceIsViolation() {
        var output = input.map { $0.touched(by: .style) }
        output[1].confidence = 0.99
        let violations = ConfidenceContract.verify(input: input, output: output)
        #expect(violations.count == 1)
        #expect(violations.first?.contains("changed confidence") == true)
    }

    @Test func mergedSpansCoveringAllRangesPass() {
        let merged = TranscriptSpan(text: "hello kothari there", confidence: 0.3, audioRange: 0...1.6, provenance: [.asr, .style])
        #expect(ConfidenceContract.verify(input: input, output: [merged]) == [])
    }

    @Test func pipelineStageProtocolWalk() async throws {
        struct Upper: PipelineStage {
            let id: StageID = .formatterChat
            func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
                spans.map { $0.isLowConfidence ? $0.flaggedForRepair(by: id) : $0.rewritten($0.text.uppercased(), by: id) }
            }
        }
        let context = StageContext(register: .chat, appBundleID: "com.tinyspeck.slackmacgap", flags: ["voiceRepair": false])
        #expect(!context.isEnabled(.voiceRepair))
        #expect(context.isEnabled(.contextBiasing))
        let output = try await Upper().process(input, context: context)
        #expect(ConfidenceContract.verify(input: input, output: output) == [])
        #expect(output[0].text == "HELLO")
        #expect(output[1].needsRepair)
    }
}
