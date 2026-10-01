import Actions
import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// V5 CU2 — the chooser registers under the HW2 plan's computer-use key and tier.
@Suite("CU2 chooser wiring")
struct ComputerUseChooserWiringTests {
    @Test("Actions' residency key is HW2's computer-use key")
    func keyMatches() {
        #expect(CuaS1Catalog.residencyKey == ResidencyKey.computerUseS1)
    }

    @Test("16 GB: exclusive; 24 GB: on demand; 8 GB: no chooser")
    func plans() async {
        let r16 = ModelResidency(budgetBytes: 8 << 30)
        #expect(await ComputerUseChooserWiring.chooser(plan: .for(.standard), residency: r16) != nil)
        #expect(await r16.snapshot().entries.first { $0.key == ResidencyKey.computerUseS1 }?.tier == .exclusive)
        let r24 = ModelResidency(budgetBytes: 8 << 30)
        #expect(await ComputerUseChooserWiring.chooser(plan: .for(.roomy), residency: r24) != nil)
        #expect(await r24.snapshot().entries.first { $0.key == ResidencyKey.computerUseS1 }?.tier == .onDemand)
        let r8 = ModelResidency(budgetBytes: 8 << 30)
        #expect(await ComputerUseChooserWiring.chooser(plan: .for(.compact), residency: r8) == nil)
        #expect(await r8.isRegistered(ResidencyKey.computerUseS1) == false)
    }
}
