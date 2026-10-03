import Foundation
import Testing
import Pipeline
import Providers
import Shared
@testable import VoicePlusApp

// X5 — skipped in onboarding → one notch offer on the first rewrite command with no model → then
// Settings only. The router raises the offer; the notch (L2) shows it and records it.

@Suite struct ModelManagerNotchOfferTests {
    final class Flag: @unchecked Sendable { let lock = NSLock(); var count = 0
        func hit() { lock.withLock { count += 1 } } }

    @Test func rewriteWithNoModelRaisesTheOfferForTransformOnly() {
        let flag = Flag()
        let route = OnDeviceEditRoute(providerID: "local.llamacpp.shared", isReady: { false },
                                      onModelMissing: { flag.hit() })
        let r = RoutingTableProviderRouting(table: RoutingTable(providers: [], logger: InMemoryNetworkLogger()),
                                            settings: InMemorySettingsStore(), onDevice: route)
        #expect(!r.isProviderEnabled(for: .transform, context: StageContext()))
        #expect(flag.count == 1)
        _ = r.isProviderEnabled(for: .question, context: StageContext())
        _ = r.isProviderEnabled(for: .cleanup, context: StageContext())
        #expect(flag.count == 1)
    }

    @Test func readyModelNeverRaisesTheOffer() {
        let flag = Flag()
        let route = OnDeviceEditRoute(providerID: "local.llamacpp.shared", isReady: { true },
                                      onModelMissing: { flag.hit() })
        let r = RoutingTableProviderRouting(table: RoutingTable(providers: [], logger: InMemoryNetworkLogger()),
                                            settings: InMemorySettingsStore(), onDevice: route)
        #expect(r.isProviderEnabled(for: .transform, context: StageContext()))
        #expect(flag.count == 0)
    }

    @Test func offerPostsOncePerLaunchAndOnlyWhilePolicyAllows() async throws {
        let policy = ModelOfferPolicy(store: .inMemory())
        policy.recordOnboardingSkipped()
        let center = NotificationCenter()
        let flag = Flag()
        let token = center.addObserver(forName: EditModels.notchOfferNotification, object: nil, queue: nil) { n in
            #expect(n.userInfo?["recommendedModelID"] as? String == "qwen-x")
            flag.hit()
        }
        defer { center.removeObserver(token) }
        let latch = EditModels.OfferLatch()
        func ask(ready: Bool = false) -> Bool {
            EditModels.requestNotchOfferIfNeeded(policy: policy, hasReadyModel: { ready }, recommendedID: { "qwen-x" },
                                                 center: center, latch: latch)
        }
        #expect(!ask(ready: true))          // a model is ready: no offer
        #expect(ask())                      // first rewrite with no model
        #expect(!ask())                     // same launch: not again
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(flag.count == 1)

        // The notch showed it → Settings only, even after a relaunch (fresh latch).
        policy.recordNotchOfferShown()
        #expect(!EditModels.requestNotchOfferIfNeeded(policy: policy, hasReadyModel: { false }, recommendedID: { "x" },
                                                      center: center, latch: EditModels.OfferLatch()))
        // Chosen in onboarding → never offered in the notch.
        let chosen = ModelOfferPolicy(store: .inMemory()); chosen.recordOnboardingChoice()
        #expect(!EditModels.requestNotchOfferIfNeeded(policy: chosen, hasReadyModel: { false }, recommendedID: { "x" },
                                                      center: center, latch: EditModels.OfferLatch()))
    }
}
