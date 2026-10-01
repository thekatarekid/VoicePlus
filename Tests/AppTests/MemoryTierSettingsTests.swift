import Engine
import Foundation
import Testing
@testable import VoicePlusApp

/// V5 HW2 — Settings › Models memory tier: shows the detected class, overrides it, explains hidden
/// features. The SwiftUI view itself is not rendered (no UI tests on this toolchain).
@Suite("Memory tier settings (HW2)")
@MainActor
struct MemoryTierSettingsTests {
    private static let gb: UInt64 = 1 << 30

    private static func store(_ ram: UInt64) -> ResidencyPlanStore {
        let name = "voiceplus-hw2-ui-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return ResidencyPlanStore(defaults: d, physicalMemory: ram)
    }

    @Test func automaticShowsDetectedTier() {
        let m = MemoryTierSettingsModel(store: Self.store(16 * Self.gb))
        #expect(m.choice == .automatic)
        #expect(m.title(for: .automatic) == "Automatic (16 GB Mac)")
        #expect(m.plan.memoryClass == .standard)
        #expect(m.warning == nil)
        #expect(MemoryTierChoice.all.count == 4)
    }

    @Test func overrideChangesPlanAndPersists() {
        let s = Self.store(16 * Self.gb)
        let m = MemoryTierSettingsModel(store: s)
        m.select(.fixed(.compact))
        #expect(m.plan.memoryClass == .compact)
        #expect(m.detail.contains("8 GB"))           // explanation for hidden features
        #expect(MemoryTierSettingsModel(store: s).choice == .fixed(.compact))
        m.select(.fixed(.roomy))
        #expect(m.warning != nil)                    // asks for more than the Mac has
        m.select(.automatic)
        #expect(s.overrideClass == nil && m.plan.memoryClass == .standard)
    }
}
