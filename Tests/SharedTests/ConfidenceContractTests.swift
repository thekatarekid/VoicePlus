import Foundation
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

    /// P1.12 hardening: the O(log n) coverage index must agree with the brute-force overlap rule
    /// on random mixes of normal, touching, nested and zero-length ranges.
    @Test("coverage index matches brute force", arguments: [1, 2, 3, 4, 5])
    func coverageIndexMatchesBruteForce(seed: UInt64) {
        var state = seed &* 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 200) / 10 // 0.0 … 19.9 on a coarse grid → lots of exact touches
        }
        func span() -> TranscriptSpan {
            let a = next(), b = next()
            let zero = (state >> 20) % 4 == 0
            return TranscriptSpan(text: "x", confidence: 0.9, audioRange: zero ? a...a : min(a, b)...max(a, b), provenance: [.asr])
        }
        for _ in 0..<40 {
            let input = (0..<12).map { _ in span() }
            let output = (0..<6).map { _ in span() }
            let index = ConfidenceContract.CoverageIndex(output)
            for i in input {
                let brute = output.contains { ConfidenceContract.strictlyOverlaps($0.audioRange, i.audioRange) }
                #expect(index.covers(i.audioRange) == brute, "\(i.audioRange) vs \(output.map(\.audioRange))")
            }
        }
    }

    @Test func verifyStaysFastOnTenThousandSpans() {
        let input = (0..<10_000).map { i in
            TranscriptSpan(text: "w\(i)", confidence: 0.9, audioRange: (Double(i) * 0.3)...(Double(i) * 0.3 + 0.3), provenance: [.asr])
        }
        let output = input.map { $0.touched(by: .formatterProse) }
        let t0 = DispatchTime.now().uptimeNanoseconds
        #expect(ConfidenceContract.verify(input: input, output: output).isEmpty)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        #expect(ms < 500, "verify took \(ms) ms for 10k spans")
    }
}
