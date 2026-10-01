import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// 1.7.11 — the two defects behind "I pressed Right ⌘ to dictate and got *Actions need a model set
/// up in Settings*".
///
/// The hotkey logic was right: Right ⌘ genuinely was the act key. What was wrong is that neither
/// half of that sentence was reachable from the UI — `act.planner` had no Settings row to set a
/// model in, and the act key had no picker to rebind or silence it.
@Suite("the act key and its planner stage are configurable from the UI")
@MainActor
struct ActKeySettingsTests {

    // MARK: Defect 1 — act.planner is a routable stage

    @Test("act.planner appears in Settings and is the stage the planner actually asks about")
    func plannerStageIsRoutable() {
        let stage = RoutableStage.all.first { $0.id == ProviderPlanner.stage }
        #expect(stage != nil, "the pill tells users to set a model for Actions in Settings; there must be a row")
        #expect(stage?.id.rawValue == "act.planner")
        #expect(stage?.acceptsProviders == true, "a pinned provider is still offered")
        // V5 CU8 flipped this: the shipped local planner (Qwen3.5 on llama.cpp) serves the stage.
        #expect(stage?.acceptsLocal == true)
    }

    @Test("the routing tests' index-addressed stages did not move")
    func existingStageOrderIsStable() {
        #expect(RoutableStage.all[0].id == .asr)
        #expect(RoutableStage.all[1].id == .formatterEmail)
        #expect(RoutableStage.all.last?.id == ProviderPlanner.stage, "act.planner is appended, never inserted")
    }

    @Test("pinning a provider for Actions persists under the key the planner reads")
    func plannerRoutingPersists() {
        let store = InMemorySettingsStore()
        let vm = ModelsSettingsViewModel(store: store, models: OnboardingMockModelManager(),
                                         connectedProviders: ["openrouter"])
        #expect(vm.choice(for: ProviderPlanner.stage) == .auto)
        let planner = RoutableStage.all.first { $0.id == ProviderPlanner.stage }!
        #expect(vm.options(for: planner) == [.auto, .local, .provider("openrouter")])   // V5 CU8

        vm.set(.provider("openrouter"), for: ProviderPlanner.stage)
        // The exact key the 1.7.9 workaround told users to `defaults write`, and the one
        // `RoutingTableProviderRouting.choice(for:)` reads.
        #expect(store.string("routing.act.planner") == "provider:openrouter")
        #expect(ModelsSettingsViewModel(store: store, models: OnboardingMockModelManager())
            .choice(for: ProviderPlanner.stage) == .provider("openrouter"))

        vm.resetToAuto()
        #expect(store.string("routing.act.planner") == nil)
    }

    // MARK: Defect 2 — the act key is off by default, rebindable, and silenceable

    @Test("a fresh install ships Actions off")
    func actionsAreOffOnAFreshInstall() {
        let store = InMemorySettingsStore()
        #expect(!ActKeySettings.isEnabled(store))
        #expect(GeneralSettingsViewModel(store: store).actKey == .off)
        #expect(ActKeyChoice.default == .off)
        #expect(!ActKeySettings.isEnabled(nil), "no store is not a reason to arm a second key")
    }

    @Test("an install that wrote actHotkeyBinding by hand keeps its opt-in")
    func manualDefaultsWriteCountsAsOptIn() {
        let store = InMemorySettingsStore()
        store.set(HotkeyBinding.Kind.controlOptionA.rawValue, for: HotkeyService.actBindingDefaultsKey)
        #expect(ActKeySettings.isEnabled(store), "that write was the only opt-in available before there was a switch")
        #expect(GeneralSettingsViewModel(store: store).actKey == .key(.controlOptionA))
        // An explicit Off still wins over the inferred opt-in.
        ActKeySettings.setEnabled(false, store: store)
        #expect(!ActKeySettings.isEnabled(store))
    }

    @Test("the picker rebinds the act key and persists both halves")
    func actKeyRebinds() {
        let store = InMemorySettingsStore()
        let vm = GeneralSettingsViewModel(store: store)
        vm.actKey = .key(.controlOptionA)
        #expect(store.string(HotkeyService.actBindingDefaultsKey) == "controlOptionA",
                "must be the key HotkeyService loads the act binding from")
        #expect(ActKeySettings.isEnabled(store))
        #expect(GeneralSettingsViewModel(store: store).actKey == .key(.controlOptionA))
    }

    @Test("switching Actions off keeps the key it would return to")
    func actKeyTurnsOff() {
        let store = InMemorySettingsStore()
        let vm = GeneralSettingsViewModel(store: store)
        vm.actKey = .key(.rightControl)
        vm.actKey = .off
        #expect(!ActKeySettings.isEnabled(store))
        #expect(store.string(HotkeyService.actBindingDefaultsKey) == "rightControl", "off is not amnesia")
        let reloaded = GeneralSettingsViewModel(store: store)
        #expect(reloaded.actKey == .off)
        reloaded.actKey = .key(.rightControl)
        #expect(ActKeySettings.isEnabled(store))
    }

    @Test("every act-key choice round-trips through its raw value")
    func actKeyChoiceRoundTrips() {
        #expect(ActKeyChoice.allCases.first == .off, "Off is the first thing the picker offers")
        #expect(ActKeyChoice.allCases.count == HotkeyChoice.allCases.count + 1)
        for choice in ActKeyChoice.allCases {
            #expect(ActKeyChoice(rawValue: choice.rawValue) == choice)
        }
        #expect(ActKeyChoice(rawValue: "f5") == nil)
    }

    // MARK: A switched-off act key fires nothing

    @Test("off means the act domain never opens, whatever the two bindings are")
    func disabledActKeyIsInert() {
        for act in HotkeyBinding.Kind.allCases {
            for dictation in HotkeyBinding.Kind.allCases {
                #expect(!ActKeyBinding.isLive(enabled: false,
                                              act: HotkeyBinding(kind: act),
                                              dictation: HotkeyBinding(kind: dictation)),
                        "a switched-off act key must fire nothing even on a key dictation does not use")
            }
        }
    }

    @Test("the 1.7.10 collision guard still holds, and now ANDs with the switch")
    func collisionGuardSurvives() {
        // Enabled + distinct is the only live combination.
        #expect(ActKeyBinding.isLive(enabled: true, act: HotkeyBinding(kind: .rightCommand),
                                     dictation: HotkeyBinding(kind: .rightOption)))
        // The reported configuration: both keys on Right ⌘. Dictation wins; the act key is inert.
        #expect(!ActKeyBinding.isLive(enabled: true, act: HotkeyBinding(kind: .rightCommand),
                                      dictation: HotkeyBinding(kind: .rightCommand)))
        for kind in HotkeyBinding.Kind.allCases {
            #expect(!ActKeyBinding.isLive(enabled: true, act: HotkeyBinding(kind: kind),
                                          dictation: HotkeyBinding(kind: kind)))
            #expect(!ActKeyBinding.isDistinct(act: HotkeyBinding(kind: kind), dictation: HotkeyBinding(kind: kind)),
                    "isDistinct is unchanged — isLive only adds a reason to stay shut")
        }
    }

    @Test("the picker says so when the chosen act key is the dictation key")
    func collisionIsVisibleInTheUI() {
        let store = InMemorySettingsStore()
        let vm = GeneralSettingsViewModel(store: store)
        vm.actKey = .key(.controlOptionA)
        #expect(!vm.actKeyCollidesWithDictation)
        #expect(!vm.actKeyNote.isEmpty)

        vm.actKey = .key(vm.hotkey)   // the default dictation key, Right ⌥
        #expect(vm.actKeyCollidesWithDictation)
        #expect(vm.actKeyNote.contains("dictation key"),
                "offering the colliding key is fine; offering it silently is not")
        #expect(vm.actKeyNote.contains(HotkeyChoice.default.binding.displayName))

        vm.actKey = .off
        #expect(!vm.actKeyCollidesWithDictation)
        #expect(vm.actKeyNote.contains("Off"))
    }

    // MARK: A switched-off key is never armed at all

    @Test("the capability watcher does not arm a key the user switched off")
    func disabledKeyIsNeverArmed() {
        let dictation = MockHotkeyArming()
        let act = MockHotkeyArming()
        act.isDisabledByUser = true
        let checker = MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .granted,
                                                       .accessibility: .granted])
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [dictation, act])
        watcher.refresh()
        #expect(dictation.isRunning, "every permission is granted — dictation must arm")
        #expect(!act.isRunning)
        #expect(act.startCount == 0, "off must mean no source is installed, not merely that events are dropped")

        // Flipping the switch on arms it on the next tick, with no relaunch.
        act.isDisabledByUser = false
        watcher.refresh()
        #expect(act.isRunning)
        #expect(act.startCount == 1)

        // And flipping it back tears the source down.
        act.isDisabledByUser = true
        watcher.refresh()
        #expect(!act.isRunning)
        #expect(act.stopCount == 1)
    }

    @Test("a HotkeyService reports the switch through HotkeyArming")
    func serviceReportsTheSwitch() {
        let defaults = UserDefaults(suiteName: "actkey.\(UUID().uuidString)")!
        let service = HotkeyService(defaults: defaults, bindingKey: HotkeyService.actBindingDefaultsKey,
                                    defaultBinding: HotkeyBinding(kind: .rightCommand))
        #expect(!service.isDisabledByUser, "unset means wanted; the act key's switch is applied by the caller")
        var enabled = false
        service.isWanted = { enabled }
        #expect(service.isDisabledByUser)
        enabled = true
        #expect(!service.isDisabledByUser)
    }

    @Test("arming re-reads a binding written while the key was switched off")
    func armingPicksUpABindingChangedWhileOff() {
        let defaults = UserDefaults(suiteName: "actkey.\(UUID().uuidString)")!
        let service = HotkeyService(defaults: defaults, bindingKey: HotkeyService.actBindingDefaultsKey,
                                    defaultBinding: HotkeyBinding(kind: .rightCommand))
        let stub = StubEventTap()
        service.installer = stub.installer
        // What the Settings picker writes while the service is disarmed and not observing defaults.
        defaults.set(HotkeyBinding.Kind.rightControl.rawValue, forKey: HotkeyService.actBindingDefaultsKey)
        #expect(service.binding.kind == .rightCommand, "a disarmed service has not seen the write yet")
        #expect(service.start())
        #expect(service.binding.kind == .rightControl, "arming must not install the stale binding")
        service.stop()
    }
}
