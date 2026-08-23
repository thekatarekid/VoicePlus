import Testing
import Shared
@testable import Pipeline

@Suite("Stage registry completeness (P1 integration)")
struct StageRegistryTests {
    @Test func containsGatekeeperAllFormattersAndStyle() {
        let ids = StageRegistry.allStages().map(\.id)
        let required: [StageID] = [.gatekeeper, .formatterProse, .formatterEmail, .formatterChat,
                                   .formatterCode, .formatterTerminal, .style]
        for id in required { #expect(ids.contains(id), "missing \(id)") }
        #expect(Set(ids).count == ids.count, "duplicate stage ids in registry")
        #expect(ids.first == .gatekeeper)
        #expect(ids.last == .style)
    }

    @Test func standardRunnerExcludesGatekeeperFromStageList() {
        let runner = PipelineRunner.standard()
        #expect(!runner.stages.contains { $0.id == .gatekeeper })
        #expect(runner.stages.count == StageRegistry.allStages().count - 1)
    }
}
