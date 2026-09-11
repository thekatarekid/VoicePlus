import Foundation
import Testing
@testable import VoicePlusApp

/// 1.6.8 — Input Monitoring stops being a requirement.
///
/// The permission was never about hold-to-talk or about the bare modifier; it was about one API.
/// These tests pin the consequence: with the shipped backends nothing consults
/// `kTCCServiceListenEvent`, so the hotkey capability cannot be blocked by it, the onboarding walk
/// does not contain it, and the forced quit-and-relaunch that is a property of that service alone
/// has nothing to attach to.
@Suite("A missing ListenEvent grant no longer blocks the hotkey")
struct HotkeyCapabilityGateTests {
    /// The exact state the reporting user was in for four rounds: everything else granted, Input
    /// Monitoring not. Before 1.6.8 that produced `hotkey=false` and the menu-bar fallback.
    @Test func noListenEventGrantAtAllStillGivesAWorkingHotkey() {
        let matrix: PermissionMatrix = [.microphone: .granted, .accessibility: .granted,
                                        .inputMonitoring: .notDetermined]
        let caps = PermissionPlanner.capabilities(matrix, hotkeyRequires: nil)
        #expect(caps.canUseGlobalHotkey)
        #expect(!caps.needsMenuFallback)
        // Even an outright denial cannot take it away, because nothing asks.
        var denied = matrix
        denied[.inputMonitoring] = .denied
        #expect(PermissionPlanner.capabilities(denied, hotkeyRequires: nil).canUseGlobalHotkey)
    }

    /// The requirement is derived from the binding, not hard-coded — a chord and a bare modifier both
    /// answer "nothing".
    @Test func theRequirementComesFromTheBinding() {
        let matrix: PermissionMatrix = [.microphone: .granted, .accessibility: .granted]
        for kind in HotkeyBinding.Kind.allCases {
            let requires = HotkeyBackendSelector.requiredPermission(for: HotkeyBinding(kind: kind))
            #expect(requires == nil)
            #expect(PermissionPlanner.capabilities(matrix, hotkeyRequires: requires).canUseGlobalHotkey)
        }
    }

    /// The escape hatch keeps the old gate exactly as it was — including the fallback copy.
    @Test func theForcedEventTapKeepsTheOldGate() {
        let matrix: PermissionMatrix = [.microphone: .granted, .inputMonitoring: .denied]
        let caps = PermissionPlanner.capabilities(matrix, hotkeyRequires: .inputMonitoring)
        #expect(!caps.canUseGlobalHotkey)
        #expect(caps.needsMenuFallback)
        var granted = matrix
        granted[.inputMonitoring] = .granted
        #expect(PermissionPlanner.capabilities(granted, hotkeyRequires: .inputMonitoring).canUseGlobalHotkey)
    }

    @Test func theWalkAndTheMissingListSkipItByDefault() {
        #expect(PermissionPlanner.order() == [.microphone, .accessibility])
        #expect(PermissionPlanner.order(hotkeyRequires: .inputMonitoring)
                == [.microphone, .inputMonitoring, .accessibility])
        // A backend that needed something already in the baseline must not duplicate the step.
        #expect(PermissionPlanner.order(hotkeyRequires: .accessibility) == [.microphone, .accessibility])

        let mostlyGranted: PermissionMatrix = [.microphone: .granted, .accessibility: .granted]
        #expect(PermissionPlanner.nextStep(mostlyGranted) == .allGranted,
                "an install with no Input Monitoring row is fully set up")
        #expect(PermissionPlanner.nextStep(mostlyGranted, hotkeyRequires: .inputMonitoring)
                == .prePrompt(.inputMonitoring))
        #expect(PermissionPlanner.missing(mostlyGranted).isEmpty)
        #expect(PermissionPlanner.missing(mostlyGranted, hotkeyRequires: .inputMonitoring) == [.inputMonitoring])
    }
}

@Suite("Onboarding skips the Input Monitoring step when nothing needs it")
struct OnboardingSkipsInputMonitoringTests {
    typealias M = OnboardingStateMachine

    @Test func theDefaultWalkIsMicrophoneThenAccessibility() {
        #expect(OnboardingPermission.order(hotkeyRequires: nil) == [.microphone, .accessibility])
        #expect(M().permissionOrder == [.microphone, .accessibility])
    }

    /// Walking it end to end: the step the user used to get stuck on is simply not visited.
    @Test func theWalkNeverStopsOnInputMonitoring() {
        var m = M()
        m.handle(.next)
        #expect(m.currentPermission == .microphone)
        m.handle(.allow(.microphone)); m.handle(.permissionResult(.microphone, .granted))
        // R6.2 — the microphone's ask and its meter now share one screen (DESIGN §11.2); a grant
        // reveals the meter there before Continue moves on.
        m.handle(.next)
        #expect(m.currentPermission == .accessibility, "Input Monitoring must not be between them")
        m.handle(.allow(.accessibility)); m.handle(.permissionResult(.accessibility, .granted))
        #expect(m.currentPermission == nil)
        #expect(m.allPermissionsGranted, "an ungranted Input Monitoring cannot hold onboarding back")
    }

    /// A user who never touches Input Monitoring is "done" even with no TCC row for it at all.
    @Test func allPermissionsGrantedIgnoresAnUngrantedInputMonitoring() {
        let m = M(initialStatuses: [.microphone: .granted, .accessibility: .granted,
                                    .inputMonitoring: .denied])
        #expect(m.allPermissionsGranted)
        #expect(m.currentPermission == nil)
    }

    /// The escape hatch puts the step back, in the same place it used to be.
    @Test func theEscapeHatchRestoresTheStep() {
        let order = OnboardingPermission.order(hotkeyRequires: .inputMonitoring)
        #expect(order == [.microphone, .inputMonitoring, .accessibility])
        var m = M(permissionOrder: order)
        m.handle(.next)
        m.handle(.allow(.microphone)); m.handle(.permissionResult(.microphone, .granted))
        m.handle(.next)   // past the meter
        #expect(m.currentPermission == .inputMonitoring)
    }

    /// The dependency the app actually reads, so the wiring — not just the helper — is covered.
    @Test func liveDependenciesReportNoHotkeyPermissionForADefaultInstall() {
        let d = UserDefaults(suiteName: "AppTests.onboardreq.\(UUID())")!
        #expect(HotkeyService.currentRequiredPermission(defaults: d) == nil)
        d.set(true, forKey: HotkeyService.forceEventTapDefaultsKey)
        #expect(HotkeyService.currentRequiredPermission(defaults: d) == .inputMonitoring)
    }
}

@Suite("The watcher arms with no Input Monitoring grant in play")
@MainActor
struct HotkeyArmingWithoutInputMonitoringTests {
    /// The end-to-end shape of the fix: a checker that says Input Monitoring is *denied*, a hotkey
    /// that needs no permission, and a tap that arms anyway on the first tick.
    @Test func aDeniedListenEventDoesNotStopArming() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted, .accessibility: .granted,
                                                       .inputMonitoring: .denied])
        let hotkey = MockHotkeyArming()          // requiredPermission defaults to nil
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [hotkey])
        #expect(watcher.hotkeyRequirement == nil)
        watcher.refresh()
        #expect(hotkey.isRunning)
        #expect(hotkey.startCount == 1)
        #expect(watcher.capabilities?.canUseGlobalHotkey == true)
        // And a second tick does not stack a second source.
        watcher.refresh()
        #expect(hotkey.startCount == 1)
        #expect(hotkey.stopCount == 0, "nothing may tear the hotkey down over a permission it does not use")
    }

    /// The forced-tap service keeps the pre-1.6.8 behaviour: it waits for the grant, then arms.
    @Test func aForcedEventTapStillWaitsForTheGrant() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .denied])
        let hotkey = MockHotkeyArming()
        hotkey.requiredPermission = .inputMonitoring
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [hotkey])
        #expect(watcher.hotkeyRequirement == .inputMonitoring)
        watcher.refresh()
        #expect(!hotkey.isRunning)
        checker.statuses[.inputMonitoring] = .granted
        watcher.refresh()
        #expect(hotkey.isRunning)
        #expect(hotkey.startCount == 1)
    }

    /// A real `HotkeyService` on the default binding, driven by the real watcher with a stub source:
    /// nothing in the matrix mentions Input Monitoring, and it arms.
    @Test func aRealServiceOnTheDefaultBindingArmsFromAnEmptyMatrix() {
        let stub = StubEventTap()
        stub.kind = .globalMonitor
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.arm.\(UUID())")!)
        service.installer = stub.installer
        #expect(service.requiredPermission == nil)
        let watcher = CapabilityWatcher(checker: MockPermissionChecker(statuses: [:]), hotkeys: [service])
        #expect(watcher.hotkeyRequirement == nil)
        watcher.refresh()
        #expect(service.isRunning)
        #expect(service.backendKind == .globalMonitor)
        #expect(stub.liveTaps.count == 1)
        service.stop()
    }
}

@Suite("The picker says what a key costs")
struct HotkeyPickerCopyTests {
    /// Requirement: the trade-off has to be legible where the choice is made. It is derived from
    /// `HotkeyBackendSelector`, so the copy cannot drift from the rule.
    @Test func everyShippedChoiceAdvertisesNoExtraPermission() {
        for kind in HotkeyBinding.Kind.allCases {
            let note = StatusItemController.permissionNote(for: kind, forcingEventTap: false)
            #expect(note.contains("no extra permission"), "\(kind.displayName): \(note)")
            #expect(!note.contains("Input Monitoring"))
        }
        #expect(StatusItemController.permissionNote(for: .rightOption, forcingEventTap: false)
                .contains("Global key monitor"))
        #expect(StatusItemController.permissionNote(for: .controlOptionD, forcingEventTap: false)
                .contains("System hotkey"))
    }

    /// The escape hatch names both costs — the pane *and* the relaunch — because a user who turns it
    /// on is signing up for exactly the loop this release removed.
    @Test func theEscapeHatchNamesThePaneAndTheRelaunch() {
        let note = StatusItemController.permissionNote(for: .rightOption, forcingEventTap: true)
        #expect(note.contains("Input Monitoring"))
        #expect(note.lowercased().contains("quit"))
        // A chord is unaffected by the hatch, so its copy must not inherit the warning.
        #expect(!StatusItemController.permissionNote(for: .controlOptionD, forcingEventTap: true)
            .contains("Input Monitoring"))
    }
}

@Suite("The Settings picker drives the real binding")
@MainActor
struct HotkeySettingsPickerTests {
    /// It did not, before 1.6.8: the picker wrote its own key and offered an `f5` the binding could
    /// not express, so choosing in Settings changed nothing at all.
    @Test func everyChoiceMapsOntoARealBindingAndBack() {
        #expect(HotkeyChoice.allCases.count == HotkeyBinding.Kind.allCases.count)
        for kind in HotkeyBinding.Kind.allCases {
            #expect(HotkeyChoice(binding: kind).binding == kind)
        }
    }

    @Test func choosingWritesTheKeyTheServiceReads() {
        let store = InMemorySettingsStore()
        let vm = GeneralSettingsViewModel(store: store)
        vm.hotkey = .controlOptionD
        #expect(store.string(HotkeyService.bindingDefaultsKey) == "controlOptionD")
        #expect(store.string(SettingsKeys.hotkey) == "controlOptionD")
        // And a service reading those defaults picks the chord up.
        let d = UserDefaults(suiteName: "AppTests.picker.\(UUID())")!
        d.set("controlOptionD", forKey: HotkeyService.bindingDefaultsKey)
        #expect(HotkeyService(defaults: d).backendKind == .carbon)
    }

    @Test func theNoteSaysNothingIsOwedUntilTheHatchIsOn() {
        let store = InMemorySettingsStore()
        let vm = GeneralSettingsViewModel(store: store)
        #expect(!vm.forceEventTap)
        #expect(vm.hotkeyPermissionNote.contains("no extra permission"))
        vm.forceEventTap = true
        #expect(vm.hotkeyPermissionNote.contains("Input Monitoring"))
        #expect(store.bool(HotkeyService.forceEventTapDefaultsKey) == true)
    }
}
