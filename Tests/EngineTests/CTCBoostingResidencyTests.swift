import Foundation
import Shared
import Testing
@testable import Engine

/// V5 B1 verify — §10: the CTC boosting model loads only through `ModelResidency`.
/// N6: it is `.resident` under a stable key — a memory warning keeps it, critical pressure drops it,
/// and a background prepare reloads it.
@Suite("CTC boosting residency (V5 B1)")
struct CTCBoostingResidencyTests {
    @Test(.timeLimit(.minutes(5)))
    func ctcModelLoadsThroughTheResidencyAndReloadsAfterEviction() async throws {
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetCTC110m) else {
            print("SKIPPED: parakeet-ctc-110m not on disk."); return
        }
        let residency = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        let source = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false, residency: residency,
                                              scope: "live-\(UUID().uuidString.prefix(6))", prepareAtLaunch: false)
        #expect(await !residency.isRegistered(source.residencyKey))
        let first = await source.runtime()
        #expect(first != nil)
        #expect(await residency.isRegistered(source.residencyKey))
        #expect(await residency.isResident(source.residencyKey))
        let tier = await residency.snapshot().entries.first { $0.key == source.residencyKey }?.tier
        #expect(tier == .resident)

        await residency.handleMemoryPressure(.warning)
        #expect(await residency.isResident(source.residencyKey), "N6: a warning never drops the booster")
        await residency.handleMemoryPressure(.critical)
        #expect(await !residency.isResident(source.residencyKey))
        let again = await source.runtime()
        #expect(again != nil)
        #expect(await residency.isResident(source.residencyKey))
    }

    @Test func missingModelNeverRegisters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctc-res-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelManager(root: root, fetchers: [:], externalCaches: [:], maintenance: .skip)
        let residency = ModelResidency(budgetBytes: ResidencyBudget.gib)
        let source = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false, residency: residency,
                                              scope: "missing", prepareAtLaunch: false, status: SpeechModelPreparation())
        #expect(await source.runtime() == nil)
        #expect(await !residency.isRegistered(source.residencyKey))
    }
}
