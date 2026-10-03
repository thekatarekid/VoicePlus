import Foundation
import Providers
import Testing
@testable import VoicePlusApp

/// X5 notch wiring — the rewrite-model download is offered once on the notch (onboarding skipped →
/// first rewrite command), Download starts the recommended model through the manager seam (no
/// network in tests), and afterwards the offer is Settings only.
@MainActor
@Suite("X5 — rewrite model offer on the notch")
struct MenuRewriteModelNotchOfferTests {
    private func rig(stage: (ModelOfferPolicy) -> Void = { $0.recordOnboardingSkipped() })
        -> (PillViewModel, TransformPillDriver, ModelOfferPolicy, RewriteModelNotchOffer, Box) {
        let pill = PillViewModel()
        let driver = TransformPillDriver(pill: pill)
        let policy = ModelOfferPolicy(store: .inMemory())
        stage(policy)
        let box = Box()
        let offer = RewriteModelNotchOffer(pill: pill, driver: driver, policy: policy,
                                           hasReadyModel: { false }, recommendedID: { "qwen-2b" },
                                           startDownload: { box.started.append($0) })
        return (pill, driver, policy, offer, box)
    }

    final class Box { var started: [String] = [] }

    @Test func landingOfferDrawsDownloadAndStartsTheModel() {
        let (pill, driver, _, offer, box) = rig()
        driver.handle(.needsModel(line: "Needs the on-device model · Saved to Notes", offerDownload: true))
        offer.sync()
        let button = pill.content().buttons.first { $0.action == .models }
        #expect(button?.label == "Download")
        pill.perform(.models)
        #expect(box.started == ["qwen-2b"])
        #expect(!pill.transformOffersDownload, "the row closes after Download")
    }

    @Test func noOfferMeansNoButton() {
        let (pill, driver, _, offer, box) = rig()
        driver.handle(.needsModel(line: "Needs the on-device model · Saved to Notes", offerDownload: false))
        offer.sync()
        #expect(!pill.content().buttons.contains { $0.action == .models })
        pill.perform(.models)
        #expect(box.started.isEmpty)
    }

    @Test func notificationOffersOnceThenSettingsOnly() {
        let (pill, _, policy, offer, box) = rig()
        #expect(offer.offerFromNotification(recommendedID: "qwen-4b"))
        #expect(policy.stage == .settingsOnly)
        #expect(pill.content().buttons.contains { $0.action == .models })
        pill.perform(.models)
        #expect(box.started == ["qwen-4b"])
        #expect(!offer.offerFromNotification(recommendedID: "qwen-4b"), "never twice")
    }

    @Test func choiceInOnboardingOrABusyNotchSkips() {
        let (_, _, _, chosen, _) = rig(stage: { $0.recordOnboardingChoice() })
        #expect(!chosen.offerFromNotification(recommendedID: nil))
        let (pill, _, policy, offer, _) = rig()
        pill.present(.listening(level: 0.2))
        #expect(!offer.offerFromNotification(recommendedID: nil))
        #expect(policy.stage == .skippedInOnboarding, "a skipped offer is not recorded")
    }
}
