import Actions
import Engine
import Foundation
import Shared

// MARK: - V5 CU2 · CUA-S1 chooser wiring
//
// Registers CUA-S1-4B with `ModelResidency` under the HW2 plan's key and tier (`act.cua-s1-4b`,
// `.exclusive` on 16 GB, `.onDemand` + kept warm on ≥ 24 GB) and hands back the chooser. Nil on an
// 8 GB Mac (the plan offers no computer-use model). CU4 routes single-step commands to it; CU9 owns
// the load-for-the-turn / unload-after policy.

public enum ComputerUseChooserWiring {
    public static func chooser(plan: ResidencyPlan = ResidencyPlanStore.shared.plan,
                               residency: ModelResidency = .shared,
                               backend: any CuaS1Backend = UnavailableCuaS1Backend()) async -> CuaS1Chooser? {
        guard let key = plan.key(for: .computerUse), let tier = plan.tier(for: .computerUse) else { return nil }
        let resident = ResidentCuaS1(backend: backend, residency: residency, residencyKey: key)
        await resident.register(tier: tier)
        return CuaS1Chooser(model: resident)
    }
}
