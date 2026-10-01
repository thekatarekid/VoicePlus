import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 HW3 — the pill chip hookup: critical memory pressure raises the residency's lighter mode and
/// the pill shows "Running lighter models — memory is low"; normal pressure clears it. Driven on a
/// private `ModelResidency`; real `DispatchSource` pressure events are T1.
@Suite("Lighter-models pill chip (HW3)")
struct LighterModelsChipHW3Tests {
    @MainActor
    private func waitFor(_ pill: PillViewModel, _ value: String?) async -> Bool {
        for _ in 0..<400 {
            if pill.memoryNote == value { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return pill.memoryNote == value
    }

    @Test @MainActor func criticalPressureShowsTheChipAndNormalClearsIt() async {
        let residency = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        let pill = PillViewModel()
        LighterModelsChip.wire(residency, pill: pill)
        #expect(await waitFor(pill, nil))
        // Let the observer install before pressure arrives.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await residency.handleMemoryPressure(.critical)
        #expect(await waitFor(pill, ModelResidency.lighterModelsMessage))
        #expect(pill.memoryNote == "Running lighter models — memory is low")
        await residency.handleMemoryPressure(.normal)
        #expect(await waitFor(pill, nil))
    }

    @Test @MainActor func wiringAppliesTheCurrentValue() async {
        let residency = ModelResidency(budgetBytes: 4 * ResidencyBudget.gib)
        await residency.handleMemoryPressure(.critical)
        let pill = PillViewModel()
        LighterModelsChip.wire(residency, pill: pill)
        #expect(await waitFor(pill, ModelResidency.lighterModelsMessage))
    }

    @Test func noteCopy() {
        #expect(LighterModelsChip.note(runningLighter: true) == ModelResidency.lighterModelsMessage)
        #expect(LighterModelsChip.note(runningLighter: false) == nil)
    }
}
