import Foundation
import Shared
import Testing
@testable import Engine

/// V5 B1 verify — §10: the CTC boosting model loads only through `ModelResidency`
/// (`.onDemand`), so eviction drops it and the next utterance reloads it.
@Suite("CTC boosting residency (V5 B1)")
struct CTCBoostingResidencyTests {
    @Test(.timeLimit(.minutes(5)))
    func ctcModelLoadsThroughTheResidencyAndReloadsAfterEviction() async throws {
        let manager = ModelManager(maintenance: .skip)
        guard await manager.isPresent(.parakeetCTC110m) else {
            print("SKIPPED: parakeet-ctc-110m not on disk."); return
        }
        let residency = ModelResidency(budgetBytes: 8 * ResidencyBudget.gib)
        let source = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false, residency: residency)
        #expect(await !residency.isRegistered(source.residencyKey))
        let first = await source.runtime()
        #expect(first != nil)
        #expect(await residency.isRegistered(source.residencyKey))
        #expect(await residency.isResident(source.residencyKey))
        let tier = await residency.snapshot().entries.first { $0.key == source.residencyKey }?.tier
        #expect(tier == .onDemand)

        await residency.unload(source.residencyKey, reason: .memoryWarning)
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
        let source = ManagedCTCBoostingSource(manager: manager, fetchWhenMissing: false, residency: residency)
        #expect(await source.runtime() == nil)
        #expect(await !residency.isRegistered(source.residencyKey))
    }
}
