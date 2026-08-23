import Foundation
import Testing
import Shared
@testable import Pipeline

/// P1.7 T8 — walks every registered stage with a poisoned (low-confidence) span under every
/// register and asserts the Bet 9 contract holds: the garbled entity is flagged, not smoothed.
@Suite struct ContractLintTests {
    static let poisoned: [TranscriptSpan] = [
        TranscriptSpan(text: "conference call with", confidence: 0.93, audioRange: 0...0.9, provenance: [.asr]),
        TranscriptSpan(text: "team fuel h e", confidence: 0.21, audioRange: 0.9...1.7,
                       alternates: [Alternate(text: "TeamViewer AG", score: 0.4, source: .beam)], provenance: [.asr]),
        TranscriptSpan(text: "on thursday no friday", confidence: 0.88, audioRange: 1.7...2.8, provenance: [.asr]),
        TranscriptSpan(text: "kothari", confidence: 0.0, audioRange: 2.8...3.2, provenance: [.asr]),
    ]

    static func allStages() -> [any PipelineStage] {
        var stages: [any PipelineStage] = [GatekeeperStage()]
        for s in StageRegistry.allStages() where !stages.contains(where: { $0.id == s.id }) { stages.append(s) }
        return stages
    }

    @Test func registryIncludesGatekeeperAndFormatters() {
        let ids = Set(Self.allStages().map(\.id))
        #expect(ids.contains(.gatekeeper))
    }

    @Test func everyRegisteredStageSurvivesPoisonedSpan() async throws {
        for stage in Self.allStages() {
            for register in Utterance.Register.allCases {
                let ctx = StageContext(register: register, appBundleID: "com.example.lint")
                let out = try await stage.process(Self.poisoned, context: ctx)
                let violations = ConfidenceContract.verify(input: Self.poisoned, output: out)
                #expect(violations.isEmpty, "stage \(stage.id) / \(register): \(violations.joined(separator: "; "))")
                // A low-confidence span must keep its audio map (Bet 9 rule 4).
                #expect(out.contains { $0.audioRange.lowerBound < 1.7 && $0.audioRange.upperBound > 0.9 }, "stage \(stage.id) lost poisoned audioRange")
            }
        }
    }

    @Test func enforcingWrapperFallsBackToInputOnViolation() async throws {
        struct Smoother: PipelineStage {
            let id: StageID = .style
            func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
                spans.map { $0.rewritten($0.text == "team fuel h e" ? "TeamViewer AG" : $0.text, by: id) }
            }
        }
        let sink = CollectingLabSink()
        let out = try await ContractEnforcingStage(Smoother(), policy: .fallbackToInput, sink: sink).process(Self.poisoned, context: StageContext(register: .prose))
        #expect(out[1].text == "team fuel h e")
        #expect(out[1].provenance == [.asr, .style])
        #expect(sink.all.first?.contractViolations.isEmpty == false)
        await #expect(throws: ConfidenceContractViolation.self) {
            _ = try await ContractEnforcingStage(Smoother(), policy: .strict, sink: sink).process(Self.poisoned, context: StageContext(register: .prose))
        }
        let passthrough = try await ContractEnforcingStage(Smoother(), policy: .flagOnly, sink: sink).process(Self.poisoned, context: StageContext(register: .prose))
        #expect(passthrough[1].text == "TeamViewer AG")
    }

    @Test func enforcingWrapperAllowsFlaggingInsteadOfSmoothing() async throws {
        struct Flagger: PipelineStage {
            let id: StageID = .style
            func process(_ spans: [TranscriptSpan], context: StageContext) async throws -> [TranscriptSpan] {
                spans.map { $0.isLowConfidence ? $0.flaggedForRepair(by: id) : $0.rewritten($0.text.capitalized, by: id) }
            }
        }
        let out = try await ContractEnforcingStage(Flagger(), policy: .strict).process(Self.poisoned, context: StageContext())
        #expect(out[1].needsRepair && out[1].text == "team fuel h e")
        #expect(out[0].text == "Conference Call With")
    }
}
