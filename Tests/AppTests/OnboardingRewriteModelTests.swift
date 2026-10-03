import Foundation
import Testing
import Providers
@testable import VoicePlusApp

// X5 — the Rewrite-model step: after Voice, pick Qwen3.5-2B / 4B (download starts, onboarding goes
// on) or Skip (the notch offers once later). It passes through when nothing can be downloaded or
// the choice was already made. Owner decision round 4: the Try step names Option's double-tap.

private typealias M = OnboardingStateMachine

private func atVoice(resolved: Bool) -> M {
    var m = M(initialStatuses: [.microphone: .granted, .accessibility: .granted], voiceEnrolled: false,
              languagesConfirmed: true, rewriteModelResolved: resolved)
    m.resume(at: .voice)
    return m
}

@Suite struct OnboardingRewriteModelStateTests {
    @Test func voiceLeadsToTheRewriteStepWhenUnresolved() {
        var m = atVoice(resolved: false)
        #expect(m.step == .voice)
        m.handle(.skip)
        #expect(m.step == .rewriteModel)
    }

    @Test func pickingStartsTheDownloadAndContinueFinishes() {
        var m = atVoice(resolved: false)
        m.handle(.skip)
        #expect(m.handle(.pickRewriteModel(LocalLLMCatalog.qwen35_2B.id)) == [.downloadRewriteModel(LocalLLMCatalog.qwen35_2B.id)])
        #expect(m.rewriteModelPick == LocalLLMCatalog.qwen35_2B.id)
        let fx = m.handle(.next)
        #expect(m.step == .done)
        #expect(!fx.contains(.recordRewriteModelSkipped))
    }

    @Test func skipRecordsTheSkipAndDoesNotCountAsUnfinishedSetup() {
        var m = atVoice(resolved: false)
        m.handle(.skip)
        #expect(m.step == .rewriteModel)
        let fx = m.handle(.skip)
        #expect(fx.first == .recordRewriteModelSkipped)
        #expect(m.step == .done)
        #expect(!m.skippedSteps.contains(.rewriteModel))
    }

    @Test func resolvedStepPassesThroughAndBackLandsOnVoice() {
        var m = atVoice(resolved: true)
        m.handle(.skip)
        #expect(m.step == .done)
        var u = atVoice(resolved: false)
        u.handle(.skip)
        u.handle(.back)
        #expect(u.step == .voice)
    }

    @Test func tryStepNamesTheOptionDoubleTap() {
        let c = OnboardingCopy.copy(for: .firstDictation, key: "Option")
        #expect(c.body.contains("Hold Option"))
        #expect(c.body.hasSuffix("Double-tap Option for hands-free."))
        #expect(!OnboardingCopy.copy(for: .firstDictation, key: "fn / 🌐").body.contains("Double-tap"))
        #expect(!OnboardingCopy.copy(for: .firstDictation, key: "Control + Option + D").body.contains("Double-tap"))
    }
}

@MainActor @Suite struct OnboardingRewriteModelViewModelTests {
    private func deps(manager: (any LocalModelManaging)?, policy: ModelOfferPolicy) -> OnboardingDependencies {
        var d = OnboardingDependencies.mock(pretendRealMicCapture: true)
        let checker = d.permissions as? OnboardingMockPermissionChecker
        for p in OnboardingPermission.allCases { checker?.statuses[p] = .granted }
        d.settingsStore.set(OnboardingStateMachine.Step.voice.rawValue, for: SettingsKeys.onboardingResumeStep)
        d.rewriteModels = manager
        d.rewriteOffer = policy
        return d
    }

    @Test func pickDownloadsThroughTheManagerAndRecordsTheChoice() async throws {
        let mgr = ScriptedModelManager()
        let policy = ModelOfferPolicy(store: .inMemory())
        let vm = OnboardingViewModel(dependencies: deps(manager: mgr, policy: policy))
        vm.send(.skip)   // past Voice
        #expect(vm.step == .rewriteModel)
        vm.send(.pickRewriteModel(LocalLLMCatalog.qwen35_4B.id))
        for _ in 0..<50 where mgr.downloads.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(mgr.downloads == [LocalLLMCatalog.qwen35_4B.id])
        #expect(policy.stage == .chosenInOnboarding)
        #expect(policy.shouldOfferInNotch(hasReadyModel: false) == false)
        vm.teardown()
    }

    @Test func skipLeavesTheOneNotchOffer() {
        let policy = ModelOfferPolicy(store: .inMemory())
        let vm = OnboardingViewModel(dependencies: deps(manager: ScriptedModelManager(), policy: policy))
        vm.send(.skip)
        vm.send(.skip)
        #expect(vm.step == .done)
        #expect(policy.stage == .skippedInOnboarding)
        #expect(policy.shouldOfferInNotch(hasReadyModel: false))
        vm.teardown()
    }

    @Test func noManagerOrAModelOnDiskSkipsTheStep() async {
        let a = OnboardingViewModel(dependencies: deps(manager: nil, policy: ModelOfferPolicy(store: .inMemory())))
        a.send(.skip)
        #expect(a.step == .done)
        a.teardown()
        let mgr = ScriptedModelManager()
        await mgr.download(LocalLLMCatalog.qwen35_2B.id)
        let b = OnboardingViewModel(dependencies: deps(manager: mgr, policy: ModelOfferPolicy(store: .inMemory())))
        b.send(.skip)
        #expect(b.step == .done)
        b.teardown()
    }
}
