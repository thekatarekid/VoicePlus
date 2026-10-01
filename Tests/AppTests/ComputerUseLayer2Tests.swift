import Actions
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 CU4 + CU6 with the real encoder (M16's `NLSentenceEmbedder`, Apple's on-device sentence
/// embedding) — the Actions tests use the hashing embedder.
@Suite struct ComputerUseLayer2Tests {
    @Test("CU6: 200 actions × (exact + 3 paraphrases) through catalogue + retrieval meet > 99 % / > 90 %")
    func measureTheTwoHundredActions() async throws {
        let catalog = try ActionCatalog.load()
        let set = try ActCatalogEvalSet.load()
        let embedder = SentencePhraseEmbedding()
        let report = await ActCatalogEval.run(set, catalog: catalog,
                                              retrieval: CatalogRetrievalIndex(catalog: catalog, embedder: embedder))
        print(report.summaryLine)
        for f in report.failures { print("  CU6 \(f.outcome.rawValue) \(f.entry) '\(f.text)' -> \(f.routedTo ?? "-")") }
        if ProcessInfo.processInfo.environment["CU6_WRITE_RESULTS"] == "1",
           let dir = AppPaths.fixturesDirectory()?.deletingLastPathComponent().appendingPathComponent("Lab/results") {
            print("CU6 wrote \(try report.write(to: dir).path)")
        }
        #expect(report.exactHitRate > ActCatalogEvalReport.exactTarget)
        // The bar is for the M16 encoder; a Mac without Apple's English sentence embedding falls back
        // to hashing (reported, not gated).
        if embedder.name.hasPrefix("nl-sentence") {
            #expect(report.paraphraseHitRate > ActCatalogEvalReport.paraphraseTarget)
        }
    }

    @Test("CU4: the session installs retrieval + the CUA-S1 chooser source on the act router once")
    func layer2Install() async throws {
        let catalog = try ActionCatalog.load()
        let router = ActRouter(parser: ActIntentParser(catalog: catalog, activation: ActDomainState(active: true)),
                               consent: ConsentEngine(), executor: ActionExecutor(system: MockActionSystem()),
                               agent: NativeAgentBackend(planner: StubPlanner(), executor: ActionExecutor(system: MockActionSystem()),
                                                         consent: ConsentEngine()))
        #expect(ComputerUseLayer2.install(on: router, embedder: HashingPhraseEmbedder(), chooser: { nil }, prepare: false))
        #expect(router.retrieval != nil)
        #expect(router.chooserProvider != nil)
        #expect(!ComputerUseLayer2.install(on: router, embedder: HashingPhraseEmbedder(), chooser: { nil }, prepare: false))
    }

    @Test("CU4: the 8 GB plan offers no CUA-S1 chooser; 16 GB unloads after the turn, ≥ 24 GB keeps it warm")
    func chooserPerPlan() async throws {
        let r = ModelResidency(budgetBytes: 12 << 30)
        #expect(await ComputerUseChooserWiring.singleStep(plan: .for(.compact), residency: r) == nil)
        let standard = try #require(await ComputerUseChooserWiring.singleStep(plan: .for(.standard), residency: r))
        #expect(!standard.keepWarm)
        let roomy = try #require(await ComputerUseChooserWiring.singleStep(plan: .for(.roomy), residency: ModelResidency(budgetBytes: 20 << 30)))
        #expect(roomy.keepWarm)
    }
}

private struct StubPlanner: PlannerLLM {
    func plan(goal: String, observation: AXSummary, history: [StepRecord], tools: [AgentTool]) async throws -> PlannerTurn {
        .giveUp(reason: "stub")
    }
}
