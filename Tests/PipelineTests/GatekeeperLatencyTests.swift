import Foundation
import Testing
import Shared
@testable import Pipeline

@Suite struct GatekeeperLatencyTests {
    @Test func classifyStaysUnderBudget() {
        let gk = LocalGatekeeper.shared
        let ctx = StageContext(appBundleID: "com.apple.mail")
        let long = Array(repeating: "the quick brown fox jumps over the lazy dog near the river bank", count: 8).joined(separator: " ")
        let samples = ["no, Thursday", "make this shorter", long, "hi team the deploy is Thursday", ""]
        _ = gk.classify("warm up", context: ctx)
        var worst = 0.0
        for _ in 0..<50 {
            for s in samples {
                let d = gk.classify(s, context: ctx)
                worst = max(worst, d.latencyMs)
            }
        }
        #expect(worst < 15, "worst-case gatekeeper latency \(worst)ms")
    }

    @Test func stageDecideFallsBackWhenOverBudget() {
        struct Slow: GatekeeperClassifying {
            func classify(_ text: String, context: StageContext) -> GatekeeperDecision {
                GatekeeperDecision(route: .transform, register: .chat, routeConfidence: 0.9, registerConfidence: 0.9,
                                   routeSource: .rules, registerSource: .context, latencyMs: 40)
            }
        }
        let stage = GatekeeperStage(local: Slow())
        let d = stage.decide([TranscriptSpan(text: "make it shorter", confidence: 0.9, audioRange: 0...1)], context: StageContext())
        #expect(d.route == .dictate)
        #expect(d.routeSource == .fallback)
        #expect(d.register == .chat)
    }

    @Test func providerHookUsedOnlyWhenEnabled() async {
        struct Router: PipelineProviderRouting {
            let enabled: Bool
            func isProviderEnabled(for stage: StageID, context: StageContext) -> Bool { enabled }
            func complete(stage: StageID, prompt: String, input: String, context: StageContext) async throws -> String { "" }
        }
        struct Cloud: ProviderGatekeeperClassifying {
            func classify(_ text: String, context: StageContext) async throws -> GatekeeperDecision? {
                GatekeeperDecision(route: .question, register: .prose, routeConfidence: 1, registerConfidence: 1,
                                   routeSource: .provider, registerSource: .provider)
            }
        }
        let stage = GatekeeperStage(provider: Cloud())
        let spans = [TranscriptSpan(text: "no, Thursday", confidence: 0.9, audioRange: 0...1)]
        let off = await stage.decide(spans, context: StageContext(), providers: Router(enabled: false))
        #expect(off.route == .repairCommand && off.routeSource == .rules)
        let on = await stage.decide(spans, context: StageContext(), providers: Router(enabled: true))
        #expect(on.route == .question && on.routeSource == .provider)
        let local = await stage.decide(spans, context: StageContext(), providers: LocalOnlyProviderRouting())
        #expect(local.route == .repairCommand)
    }

    @Test func completeOrLocalFallsBackOnFailure() async throws {
        let out = try await LocalOnlyProviderRouting().completeOrLocal(stage: .style, prompt: "p", input: "x", context: StageContext()) { "local" }
        #expect(out == "local")
    }
}
