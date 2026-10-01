import Engine
import Foundation
import Providers
import Shared
import Testing
@testable import VoicePlusApp

/// V5 CU9 — the 4B planner and CUA-S1-4B never share memory on a 16 GB plan.
@Suite struct ComputerUseExclusiveTests {
    @Test("16 GB: a picked 4B planner registers .exclusive (like CUA-S1); 2B and ≥ 24 GB keep the plan's tier")
    func plannerTier() {
        let standard = ResidencyPlan.for(.standard), roomy = ResidencyPlan.for(.roomy), compact = ResidencyPlan.for(.compact)
        #expect(standard.tier(for: .computerUse) == .exclusive)
        #expect(ComputerUseSettings.plannerTier(for: LocalLLMCatalog.qwen35_4B, plan: standard) == .exclusive)
        #expect(ComputerUseSettings.plannerTier(for: LocalLLMCatalog.qwen35_2B, plan: standard) == standard.tier(for: .localLLM))
        #expect(ComputerUseSettings.plannerTier(for: LocalLLMCatalog.qwen35_4B, plan: roomy) == roomy.tier(for: .localLLM))
        #expect(ComputerUseSettings.plannerTier(for: LocalLLMCatalog.qwen35_4B, plan: compact) == .onDemand)
    }
}
