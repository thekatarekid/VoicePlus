import Foundation
import Shared
import Testing
@testable import Engine

private actor FakeBackend: DecisionBackend {
    let tag: String
    private(set) var loads = 0
    private(set) var loaded = false
    init(tag: String) { self.tag = tag }
    var isLoaded: Bool { loaded }
    func load() async throws { loads += 1; loaded = true }
    func unload() { loaded = false }
    func answer(state: String, questions: [DecisionQuestion]) async throws -> DecisionAnswers {
        guard loaded else { throw DecisionModelError.notInstalled(tag) }
        return MockDecisionModel.answers(addressed: tag == "kev" ? 0.9 : 0.5, capability: .act)
    }
}

@Suite("V5 O4 decision models through ModelResidency (HW1)")
struct DecisionModelResidencyTests {
    @Test("choice resolution: default Kev; an 8 GB plan forces Laya")
    func resolve() {
        let big = ResidencyPlan.for(.standard)
        #expect(DecisionModelChoice.resolve(stored: nil, plan: big) == .kev)
        #expect(DecisionModelChoice.resolve(stored: "intern", plan: big) == .intern)
        #expect(DecisionModelChoice.resolve(stored: "garbage", plan: big) == .kev)
        let small = ResidencyPlan.for(.compact)
        #expect(DecisionModelChoice.resolve(stored: nil, plan: small) == .laya)
        #expect(DecisionModelChoice.resolve(stored: "kev", plan: small) == .laya)
        #expect(DecisionModelChoice.kev.residencyKey == ResidencyKey.decisionKev)
        #expect(DecisionModelChoice.laya.residencyKey == ResidencyKey.decisionLaya)
    }

    @Test("the model registers with the residency and loads only through it")
    func registersAndLoads() async throws {
        let residency = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        let backend = FakeBackend(tag: "kev")
        let model = ResidentDecisionModel(choice: .kev, backend: backend, residency: residency)
        await model.register(plan: .for(.standard))
        #expect(await residency.isRegistered(ResidencyKey.decisionKev))
        #expect(await residency.isResident(ResidencyKey.decisionKev) == false)
        let a = try await model.decide(state: "s", questions: DecisionQuestion.all)
        #expect(a.yes(.addressed) == 0.9)
        #expect(await residency.isResident(ResidencyKey.decisionKev))
        #expect(await backend.loads == 1)
        let entry = await residency.snapshot().entries.first { $0.key == ResidencyKey.decisionKev }
        #expect(entry?.estimatedBytes == DecisionModelChoice.kev.estimatedBytes)
        #expect(entry?.tier == .onDemand)
        await residency.unload(ResidencyKey.decisionKev)
        #expect(await backend.isLoaded == false)
    }

    @Test("registry: Kev registers Laya as its lighter alternative; critical pressure swaps to Laya")
    func hw3Swap() async throws {
        let residency = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        let registry = DecisionModelRegistry(residency: residency, chosen: .kev)
        await registry.install(.kev, plan: .for(.standard)) { c in
            ResidentDecisionModel(choice: c, backend: FakeBackend(tag: c.rawValue), residency: residency)
        }
        #expect(await residency.isRegistered(ResidencyKey.decisionLaya))
        #expect(await registry.current()?.id == "kev")
        await residency.handleMemoryPressure(.critical)
        #expect(await registry.current()?.id == "laya")
        let arbiter = IntentArbiter(registry: registry)
        let d = await arbiter.evaluate(ArbiterInput(utteranceID: "x", range: Date()...Date(),
                                                    state: DecisionState(utterance: "open mail"))).decision
        #expect(d.reason == "layer1.laya")
    }

    @Test("a missing snapshot is .notInstalled, never a download")
    func notInstalled() async {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("decide-\(UUID().uuidString)")
        for c in DecisionModelChoice.allCases {
            #expect(DecisionModelInstaller.isInstalled(c, cacheDirectory: empty) == false)
            let residency = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
            let m = ResidentDecisionModel.fluidUse(c, residency: residency, cacheDirectory: empty)
            await m.register(plan: .for(.standard))
            await #expect(throws: DecisionModelError.notInstalled(c.rawValue)) {
                _ = try await m.decide(state: "s", questions: DecisionQuestion.all)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: empty.path))
    }
}
