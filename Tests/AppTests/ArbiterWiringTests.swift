import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 O4 + L4 — the app side of the arbiter: Layer 0 adapters over Pipeline/Actions, decision-model
/// registration with ModelResidency, settling on the O3 hub (Q13 shape), settings-backed bands.
@Suite("V5 O4 ArbiterWiring")
struct ArbiterWiringTests {
    final class FixedModel: DecisionModel, @unchecked Sendable {
        let id = "mock"
        var addressed: Double
        var capability: UtteranceOwner
        init(addressed: Double, capability: UtteranceOwner) { self.addressed = addressed; self.capability = capability }
        func decide(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
            var cap: [String: Double] = [:]
            for o in UtteranceOwner.allCases { cap[o.rawValue] = o == capability ? 0.9 : 0.02 }
            return DecisionAnswers([.addressed: ["no": 1 - addressed, "yes": addressed], .complete: ["no": 0.1, "yes": 0.9],
                                    .capability: cap, .continuation: ["no": 0.5, "yes": 0.5],
                                    .needsAgent: ["no": 0.9, "yes": 0.1], .worthNoting: ["no": 0.9, "yes": 0.1]])
        }
    }

    @Test("Layer 0 adapters: wake verb, gatekeeper rules; plain speech falls through")
    func layer0() {
        let wake = WakeVerbDecider()
        #expect(wake.decide("note buy milk")?.owner == .note)
        #expect(wake.decide("type hello there")?.owner == .dictate)
        #expect(wake.decide("send it")?.owner == .act)
        #expect(wake.decide("we should get lunch") == nil)
        let gate = GatekeeperDecider()
        #expect(gate.decide("we should get lunch tomorrow with the team") == nil)
        let layer0 = ArbiterWiring.layer0(actParser: nil)
        #expect(layer0.map(\.id) == ["wakeVerb", "gatekeeper"])
    }

    @Test("decisions settle on the hub as arbiter decisions; Q13 row carries every question, no text")
    func settlesOnHub() async throws {
        let hub = UtteranceDecisionHub()
        var logged: [TurnDiagnosticsEvent] = []
        hub.diagnostics = { e, _ in logged.append(e) }
        let model = FixedModel(addressed: 0.9, capability: .act)
        let arbiter = IntentArbiter(layer0: ArbiterWiring.layer0(actParser: nil), model: { model })
        arbiter.onDecision = ArbiterWiring.settle(on: hub)
        let t = Date()
        await arbiter.decide(ArbiterInput(utteranceID: "a1", range: t...t.addingTimeInterval(1),
                                          state: DecisionState(utterance: "open my private calendar")))
        let event = try #require(logged.first)
        guard case .decision(let d) = event else { Issue.record("not a decision"); return }
        #expect(d.owner == "act")
        #expect(d.band == "act")
        #expect(d.reason == "arbiter:layer1.mock")
        #expect(d.questionProbabilities["addressed"] == 0.9)
        #expect(d.questionProbabilities["capability.act"] == 0.9)
        let json = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
        #expect(!json.contains("private"))
        // One decision per utterance: a second settle for the same id is dropped.
        await arbiter.decide(ArbiterInput(utteranceID: "a1", range: t...t, state: DecisionState(utterance: "x")))
        #expect(logged.count == 1)
    }

    @Test("make: registers the HW2-planned model + lighter alternative with ModelResidency; no weights → nothing acts")
    func makeRegisters() async {
        let residency = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("arb-\(UUID().uuidString)")
        let settings = InMemorySettingsStore()
        let hub = UtteranceDecisionHub()
        let arbiter = await ArbiterWiring.make(settings: settings, actParser: nil, residency: residency,
                                               plan: .for(.standard), hub: hub,
                                               makeModel: { ResidentDecisionModel.fluidUse($0, residency: residency, cacheDirectory: empty) })
        #expect(await residency.isRegistered(ResidencyKey.decisionKev))
        #expect(await residency.isRegistered(ResidencyKey.decisionLaya))
        let r = await arbiter.decide(ArbiterInput(utteranceID: "b", range: Date()...Date(),
                                                  state: DecisionState(utterance: "open mail")))
        #expect(r.decision.owner == .ignore)
        #expect(r.decision.reason == "layer1.kev.unavailable")
        // Stored choice is honoured.
        settings.set("intern", for: DecisionModelChoice.settingsKey)
        let residency2 = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        _ = await ArbiterWiring.make(settings: settings, actParser: nil, residency: residency2, plan: .for(.standard),
                                     hub: hub, makeModel: { ResidentDecisionModel.fluidUse($0, residency: residency2, cacheDirectory: empty) })
        #expect(await residency2.isRegistered(DecisionResidencyKey.intern))
    }

    @Test("bands persist; Not-for-you nudges the frontmost app")
    func bands() {
        let settings = InMemorySettingsStore()
        let store = DecisionBandsSettings(settings: settings)
        #expect(store.bands == .defaults)
        let teacher = BandNudgingTeacher(inner: nil, bands: store, frontmostApp: { "com.zoom" })
        teacher.learn(DirectedSpeechExample(utteranceID: UUID(), label: .notDirected, reason: .notTalkingToYou))
        #expect(store.bands.perAppOffset["com.zoom"] == DecisionBands.nudgeStep)
        teacher.learn(DirectedSpeechExample(utteranceID: UUID(), label: .directed, reason: .accepted))
        #expect(store.bands.perAppOffset["com.zoom"] == DecisionBands.nudgeStep)
        settings.set("{garbage", for: DecisionBandsSettings.key)
        #expect(store.bands == .defaults)
    }
}
