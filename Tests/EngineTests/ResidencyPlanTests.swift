import Foundation
import Shared
import Testing
@testable import Engine

/// V5 HW2 — RAM-aware defaults: class detection, the plan per class, first-launch persistence and the
/// Settings override. Real 8/24 GB hardware is not exercised; `physicalMemory` is injected.
@Suite("Residency plan (HW2)")
struct ResidencyPlanTests {
    private static let gb: UInt64 = 1 << 30

    private static func defaults() -> UserDefaults {
        let name = "voiceplus-hw2-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func detectsClassFromPhysicalMemory() {
        #expect(MemoryClass.detect(physicalMemory: 8 * Self.gb) == .compact)
        #expect(MemoryClass.detect(physicalMemory: 16 * Self.gb) == .standard)
        #expect(MemoryClass.detect(physicalMemory: 18 * Self.gb) == .standard)
        #expect(MemoryClass.detect(physicalMemory: 24 * Self.gb) == .roomy)
        #expect(MemoryClass.detect(physicalMemory: 64 * Self.gb) == .roomy)
    }

    @Test func sixteenGigPlan() {
        let p = ResidencyPlan.for(.standard)
        #expect(p.key(for: .cleanup) == ResidencyKey.cleanup && p.tier(for: .cleanup) == .onDemand)
        #expect(p.key(for: .localLLM) == ResidencyKey.localLLM2B && p.tier(for: .localLLM) == .onDemand)
        #expect(p.key(for: .decision) == ResidencyKey.decisionKev && p.tier(for: .decision) == .onDemand)
        #expect(p.key(for: .computerUse) == ResidencyKey.computerUseS1 && p.tier(for: .computerUse) == .exclusive)
        #expect(!p.keepComputerUseWarm)
        #expect(p.hidden.isEmpty && p.explanation == nil)
        #expect(p.localLLMName == "Qwen3.5-2B" && p.decisionModelName == "Kev")
    }

    @Test func roomyPlan() {
        let p = ResidencyPlan.for(.roomy)
        #expect(p.key(for: .localLLM) == ResidencyKey.localLLM4B)
        #expect(p.tier(for: .decision) == .always)          // Kev resident
        #expect(p.tier(for: .computerUse) == .onDemand)     // CUA-S1 warm, not exclusive
        #expect(p.keepComputerUseWarm)
        #expect(p.localLLMName == "Qwen3.5-4B")
    }

    @Test func compactPlanHidesHeavyFeaturesWithExplanation() {
        let p = ResidencyPlan.for(.compact)
        #expect(p.key(for: .cleanup) == ResidencyKey.cleanup)
        #expect(p.key(for: .decision) == ResidencyKey.decisionLaya && p.decisionModelName == "Laya")
        #expect(p.key(for: .computerUse) == nil && p.tier(for: .computerUse) == nil)
        #expect(p.key(for: .localLLM) == nil && p.localLLMName == nil)
        for f in MemoryGatedFeature.allCases { #expect(p.isHidden(f)) }
        #expect(p.explanation?.contains("8 GB") == true)
    }

    @Test func lighterAlternativesMatchHW3() {
        let p = ResidencyPlan.for(.roomy)
        #expect(p.lighterAlternative(for: ResidencyKey.decisionKev) == ResidencyKey.decisionLaya)
        #expect(p.lighterAlternative(for: ResidencyKey.localLLM4B) == ResidencyKey.localLLM2B)
        #expect(p.lighterAlternative(for: ResidencyKey.localLLM2B) == nil)
    }

    @Test func plansFitTheirBudget() {
        // V5 §HW sizes: cleanup 0.8B ~0.55 GB, Qwen3.5-2B ~1.6 GB, 4B ~3.2 GB, Kev ~2.1 GB,
        // Laya e8 ~0.5 GB, CUA-S1-4B ~3.9 GB; dictation stack (TDT v3 + EOU) ~0.7 GB.
        let sizes: [String: Int64] = [ResidencyKey.cleanup: 550_000_000,
                                      ResidencyKey.localLLM2B: 1_600_000_000, ResidencyKey.localLLM4B: 3_200_000_000,
                                      ResidencyKey.decisionKev: 2_100_000_000, ResidencyKey.decisionLaya: 500_000_000,
                                      ResidencyKey.computerUseS1: 3_900_000_000]
        let asr: Int64 = 700_000_000
        for (cls, ram) in [(MemoryClass.compact, 8 * Self.gb), (.standard, 16 * Self.gb), (.roomy, 24 * Self.gb)] {
            let p = ResidencyPlan.for(cls)
            let budget = ResidencyBudget.bytes(forPhysicalMemory: ram)
            var always = asr
            for role in ResidencyRole.allCases where p.tier(for: role) == .always { always += sizes[p.key(for: role)!]! }
            #expect(always <= budget, "\(cls): always-tier \(always) > \(budget)")
            // No offered model is ever refused: each fits beside the always-resident set.
            for role in ResidencyRole.allCases {
                guard let key = p.key(for: role), p.tier(for: role) != .always else { continue }
                #expect(always + sizes[key]! <= budget, "\(cls): \(key) cannot fit")
            }
            // An ordinary dictation turn (dictation + decision + cleanup) is resident at once.
            let turn = asr + sizes[ResidencyKey.cleanup]! + sizes[p.decisionKey]!
            #expect(turn <= budget, "\(cls): turn \(turn) > \(budget)")
        }
    }

    @Test func firstLaunchRecordsOnceAndOverrideWins() {
        let d = Self.defaults()
        let store = ResidencyPlanStore(defaults: d, physicalMemory: 16 * Self.gb)
        #expect(store.applyFirstLaunchDefaults())
        #expect(!store.applyFirstLaunchDefaults())
        #expect(store.detectedClass == .standard)
        #expect(store.plan == .for(.standard))

        // A later launch on different RAM keeps the recorded class (first launch only).
        let later = ResidencyPlanStore(defaults: d, physicalMemory: 32 * Self.gb)
        #expect(!later.applyFirstLaunchDefaults())
        #expect(later.effectiveClass == .standard)

        later.setOverride(.compact)
        #expect(later.effectiveClass == .compact)
        #expect(ResidencyPlanStore(defaults: d, physicalMemory: 16 * Self.gb).plan == .for(.compact))
        later.setOverride(nil)
        #expect(later.effectiveClass == .standard)

        later.resetToDetected()
        #expect(later.effectiveClass == .roomy)
    }

    @Test func overridePostsChange() async {
        let store = ResidencyPlanStore(defaults: Self.defaults(), physicalMemory: 8 * Self.gb)
        final class Flag: @unchecked Sendable { var hit = 0 }
        let flag = Flag()
        let token = NotificationCenter.default.addObserver(forName: ResidencyPlanStore.didChangeNotification,
                                                           object: store, queue: nil) { _ in flag.hit += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.setOverride(.roomy)
        store.setOverride(.roomy)   // no change → no post
        #expect(flag.hit == 1)
    }

    @Test func prewarmKeysAreTheCleanupModel() {
        for c in MemoryClass.allCases { #expect(ResidencyPlan.for(c).prewarmKeys == [ResidencyKey.cleanup]) }
    }
}
