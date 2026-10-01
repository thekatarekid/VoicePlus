import Actions
import Foundation
import Shared
import SwiftUI
import Testing
@testable import VoicePlusApp

/// V5 CU1 — Settings › Computer use: one page for enable, act key, planner provider/model, timeout,
/// consent defaults and plan chips; every value persists and reaches the live act stack.
@Suite("CU1 Settings › Computer use")
@MainActor
struct ComputerUseSettingsTests {
    static func model(_ store: InMemorySettingsStore = InMemorySettingsStore(),
                      providers: [String] = []) -> ComputerUseSettingsModel {
        ComputerUseSettingsModel(store: store, general: GeneralSettingsViewModel(store: store),
                                 models: ModelsSettingsViewModel(store: store, models: OnboardingMockModelManager(),
                                                                 connectedProviders: providers))
    }

    @Test("indexed: a Settings subpage of its own, reachable by route")
    func indexed() {
        #expect(SettingsSubpage.allCases.contains(.computerUse))
        #expect(SettingsSubpage.computerUse.title == "Computer use")
        #expect(SettingsSubpage.computerUse.pageTitle == "Computer use")
        #expect(WindowRoute.settings(.computerUse).isValid)
        #expect(SettingsReachability.allItems.contains { $0.subpage == .computerUse && $0.marker == "ComputerUseSettingsPage(" })
    }

    @Test("fresh install: off, Right ⌘ suggested, auto provider, 60 s, default consent, chips on")
    func defaults() {
        let m = Self.model()
        #expect(!m.isEnabled)
        #expect(m.key == ActKeyChoice.suggestedKey)
        #expect(m.provider == .auto)
        #expect(m.plannerModel == .automatic)
        #expect(m.timeout == 60)
        #expect(m.policy == .default)
        #expect(m.showPlanChips)
    }

    @Test("enable is ActKeySettings, and the key is the act binding Shortcuts shows")
    func enableAndKey() {
        let store = InMemorySettingsStore()
        let m = Self.model(store)
        m.isEnabled = true
        #expect(ActKeySettings.isEnabled(store))
        #expect(m.general.actKey == .key(.rightCommand))
        m.key = .rightOption
        #expect(store.string(HotkeyService.actBindingDefaultsKey) == HotkeyChoice.rightOption.binding.rawValue)
        #expect(GeneralSettingsViewModel(store: store).actKey == .key(.rightOption))
        m.isEnabled = false
        #expect(!ActKeySettings.isEnabled(store))
        // Re-enabling returns to the key the user picked, not the default.
        m.isEnabled = true
        #expect(m.general.actKey == .key(.rightOption))
    }

    @Test("provider row writes routing.act.planner and offers connected providers")
    func provider() {
        let store = InMemorySettingsStore()
        let m = Self.model(store, providers: ["ollama"])
        #expect(m.providerOptions.contains(.provider("ollama")))
        m.provider = .provider("ollama")
        #expect(store.string("routing.act.planner") == "provider:ollama")
    }

    @Test("timeout, consent and chips persist and survive a reload; timeout is clamped")
    func persistence() {
        let store = InMemorySettingsStore()
        let m = Self.model(store)
        m.timeout = 120
        m.reversible = .undoToast
        m.semi = .confirm
        m.showPlanChips = false
        m.plannerModel = .qwen4B
        let again = Self.model(store)
        #expect(again.timeout == 120)
        #expect(again.policy == ConsentPolicy(reversible: .undoToast, semi: .confirm))
        #expect(!again.showPlanChips)
        #expect(again.plannerModel == .qwen4B)
        ComputerUseSettings.setTimeout(9_999, store: store)
        #expect(ComputerUseSettings.timeout(store) == 300)
        store.set("nonsense", for: ComputerUseSettings.timeoutKey)
        #expect(ComputerUseSettings.timeout(store) == 60)
    }

    @Test("apply hands the values to the consent engine and the agent")
    func applyReachesTheStack() {
        let store = InMemorySettingsStore()
        ComputerUseSettings.setTimeout(30, store: store)
        ComputerUseSettings.setConsentPolicy(ConsentPolicy(reversible: .confirm), store: store)
        ComputerUseSettings.setShowsPlanChips(false, store: store)
        let consent = ConsentEngine()
        let agent = NativeAgentBackend(planner: ScriptedPlanner([]), executor: ActionExecutor(system: MockActionSystem()),
                                       consent: consent)
        ComputerUseSettings.apply(store, consent: consent, agent: agent)
        #expect(agent.config.timeout == 30)
        #expect(consent.policy.reversible == .confirm)
        #expect(!agent.showsPlanChips)
    }

    @Test("the page renders")
    func renders() {
        let m = Self.model()
        let view = ComputerUseSettingsPage(model: m, general: m.general, hotkey: "⌥")
            .frame(width: 760, height: 900)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        #expect(renderer.cgImage != nil)
    }
}
