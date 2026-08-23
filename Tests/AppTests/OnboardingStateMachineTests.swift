import Foundation
import Testing
@testable import VoicePlusApp

@Suite("Onboarding state machine (P1.9 T1/T2)")
struct OnboardingStateMachineTests {
    typealias M = OnboardingStateMachine

    @Test func happyPathAllGranted() {
        var m = M()
        #expect(m.step == .welcome)
        #expect(m.handle(.next) == [])
        #expect(m.step == .permissions)
        #expect(m.currentPermission == .microphone)

        #expect(m.handle(.allow(.microphone)) == [.requestPermission(.microphone)])
        #expect(m.permissionPhase == .requesting)
        m.handle(.permissionResult(.microphone, .granted))
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        m.handle(.allow(.accessibility))
        let effects = m.handle(.permissionResult(.accessibility, .granted))
        #expect(effects == [.startMicMonitoring])
        #expect(m.step == .micCheck)
        #expect(m.allPermissionsGranted)

        m.handle(.micLevel(0.02)); #expect(m.micVerdict == .tooQuiet)
        m.handle(.micLevel(0.4)); #expect(m.micVerdict == .good)
        m.handle(.micLevel(0.99)); #expect(m.micVerdict == .clipping)
        #expect(m.handle(.next) == [.stopMicMonitoring])
        #expect(m.step == .modelChoice)

        #expect(m.handle(.choose(.balanced)) == [.selectModel(.balanced), .startDownload(.balanced)])
        m.handle(.downloadProgress(0.5)); #expect(m.download == .downloading(0.5))
        // Re-choosing while a download is in flight does not start a second one.
        #expect(m.handle(.choose(.best)) == [.selectModel(.best)])
        #expect(m.handle(.next) == [.beginGuidedDictation])
        #expect(m.step == .firstDictation)
        m.handle(.downloadFinished); #expect(m.download == .installed)  // late event after leaving the screen
        m.handle(.dictationLanded("hello"))
        #expect(m.landedText == "hello")
        #expect(m.handle(.next) == [.finish(skipped: false)])
        #expect(m.step == .done)
        #expect(m.handle(.next) == [])
    }

    @Test func deniedMicrophoneShowsSettingsThenVerifyRecovers() {
        var m = M()
        m.handle(.next)
        m.handle(.allow(.microphone))
        #expect(m.handle(.permissionResult(.microphone, .denied)) == [])
        #expect(m.permissionPhase == .denied)
        #expect(m.currentPermission == .microphone)
        #expect(m.handle(.verify(.microphone)) == [.checkPermission(.microphone)])
        // Verify comes back granted after the user flipped it in System Settings.
        m.handle(.permissionResult(.microphone, .granted))
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .explain)
    }

    @Test func deniedMicrophoneSkippedSkipsMicCheck() {
        var m = M()
        m.handle(.next)
        m.handle(.allow(.microphone)); m.handle(.permissionResult(.microphone, .denied))
        m.handle(.next)  // "Skip this one"
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        m.handle(.allow(.accessibility))
        let effects = m.handle(.permissionResult(.accessibility, .denied))
        #expect(effects == [])
        #expect(m.permissionPhase == .denied)
        // Skipping the last denied permission goes straight to model choice: mic check needs the mic.
        let skipEffects = m.handle(.next)
        #expect(m.step == .modelChoice)
        #expect(!skipEffects.contains(.startMicMonitoring))
        #expect(m.statuses[.microphone] == .denied)
    }

    @Test func skipEverythingStillFinishes() {
        var m = M()
        #expect(m.handle(.skip) == [])  // welcome skip → micCheck skipped (no mic) → modelChoice
        #expect(m.step == .modelChoice)
        #expect(m.handle(.skip) == [.beginGuidedDictation])
        #expect(m.handle(.skip) == [.finish(skipped: true)])
        #expect(m.step == .done)
        #expect(m.chosenTier == nil)  // bundled model stays active
    }

    @Test func modelChoiceNextWithoutChoiceFallsBackToFastAndNeverBlocks() {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        #expect(m.handle(.next) == [.startMicMonitoring])  // all granted → permissions step auto-skips
        #expect(m.step == .micCheck)
        m.handle(.next)
        m.handle(.downloadFailed("offline"))
        #expect(m.download == .failed("offline"))
        #expect(m.handle(.next) == [.beginGuidedDictation])
        #expect(m.chosenTier == .fast)
    }

    @Test func pregrantedPermissionsAreSkippedInOrder() {
        var m = M(initialStatuses: [.microphone: .granted])
        m.handle(.next)
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        #expect(m.currentPermission == .accessibility)
    }

    @Test func resultForNonCurrentPermissionIsRecordedButDoesNotAdvance() {
        var m = M()
        m.handle(.next)
        m.handle(.permissionResult(.accessibility, .granted))
        #expect(m.currentPermission == .microphone)
        #expect(m.statuses[.accessibility] == .granted)
        m.handle(.allow(.microphone)); m.handle(.permissionResult(.microphone, .granted))
        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        #expect(m.step == .micCheck)  // accessibility already granted → skipped
    }

    @Test func backNavigation() {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        m.handle(.next); m.handle(.next)
        #expect(m.step == .modelChoice)
        #expect(m.handle(.back) == [.startMicMonitoring])
        #expect(m.step == .micCheck)
        #expect(m.handle(.back) == [.stopMicMonitoring, .startMicMonitoring])  // permissions all granted → bounces to mic check
        var denied = M(initialStatuses: [.microphone: .denied])
        denied.handle(.skip)
        #expect(denied.step == .modelChoice)
        denied.handle(.back)
        #expect(denied.step == .permissions)
        var fresh = M()
        #expect(fresh.handle(.back) == [])
    }

    @Test func progressIsMonotonic() {
        var m = M()
        var last = m.progress
        for event in [M.Event.next, .skip, .skip, .skip] {
            m.handle(event)
            #expect(m.progress >= last)
            last = m.progress
        }
        #expect(last == 1)
    }
}

@Suite("Onboarding view model integration")
@MainActor
struct OnboardingViewModelTests {
    @Test func deniedMicThenOpenSettingsCallsChecker() async throws {
        let deps = OnboardingDependencies.mock(permissionResults: [.microphone: .denied])
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.permissionPhase == .denied }
        vm.openSettings(for: .microphone)
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        #expect(checker.openedSettings == [.microphone])
        checker.statuses[.microphone] = .granted
        vm.send(.verify(.microphone))
        #expect(vm.machine.currentPermission == .inputMonitoring)
    }

    @Test func fullRunWithMocksFinishesAndDownloads() async throws {
        let deps = OnboardingDependencies.mock()
        let vm = OnboardingViewModel(dependencies: deps)
        var finished: Bool?
        vm.onFinished = { finished = $0 }
        vm.send(.next)
        for p in OnboardingPermission.allCases {
            vm.send(.allow(p))
            try await waitUntil { vm.machine.statuses[p] == .granted }
        }
        #expect(vm.step == .micCheck)
        let mic = try #require(deps.micLevel as? OnboardingMockMicLevelPublisher)
        #expect(mic.monitoring)
        mic.subject.send(0.5)
        try await waitUntil { vm.machine.micVerdict == .good }
        vm.send(.next)
        #expect(!mic.monitoring)
        vm.send(.choose(.balanced))
        try await waitUntil { vm.machine.download == .installed }
        #expect(deps.models.selectedTier == .balanced)
        vm.send(.next)
        vm.runGuidedDictation()
        try await waitUntil { vm.machine.landedText != nil }
        #expect(vm.machine.landedText?.contains("quick brown fox") == true)
        vm.send(.next)
        #expect(finished == false)
        #expect(deps.settingsStore.bool(SettingsKeys.onboardingCompleted) == true)
        #expect(vm.showContactsOffer)
        #expect(!OnboardingWindowController.isNeeded(settings: deps.settingsStore))
    }

    @Test func downloadFailureIsNonBlocking() async throws {
        let deps = OnboardingDependencies.mock()
        (deps.models as? OnboardingMockModelManager)?.failDownload = true
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip)
        vm.send(.choose(.best))
        try await waitUntil { if case .failed = vm.machine.download { return true }; return false }
        vm.send(.next)
        #expect(vm.step == .firstDictation)
    }
}

func waitUntil(timeoutMs: Int = 2000, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while !(await condition()) {
        try #require(Date() < deadline, "timed out waiting for condition")
        try await Task.sleep(for: .milliseconds(5))
    }
}
