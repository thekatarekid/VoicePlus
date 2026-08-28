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

        #expect(m.handle(.allow(.microphone)) == [.requestPermission(.microphone), .rememberRequested(.microphone)])
        #expect(m.permissionPhase == .requesting)
        m.handle(.permissionResult(.microphone, .granted))
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        m.handle(.allow(.accessibility))
        let effects = m.handle(.permissionResult(.accessibility, .granted))
        #expect(effects == [.startMicMonitoring])
        #expect(m.step == .micCheck)
        #expect(m.allPermissionsGranted)

        // A quiet first block is not yet a verdict — see `quietVerdictWaitsForEnoughRealAudio`.
        m.handle(.micLevel(0.02)); #expect(m.micVerdict == .waiting)
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
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        #expect(m.currentPermission == .microphone)
        #expect(m.handle(.verify(.microphone)) == [.checkPermission(.microphone)])
        // Verify comes back granted after the user flipped it in System Settings.
        m.handle(.permissionResult(.microphone, .granted))
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .explain)
    }

    /// BUG 1, the exact shape the user hit: `CGRequestListenEventAccess()` returns false without
    /// prompting, so the request resolves to `.awaitingUserAction`. That must expose the escape
    /// hatches, not bounce back to a lone "Allow" button.
    @Test func awaitingUserActionNeverReturnsToExplain() {
        var m = M(initialStatuses: [.microphone: .granted])
        m.handle(.next)
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .explain)
        m.handle(.allow(.inputMonitoring))
        m.handle(.permissionResult(.inputMonitoring, .awaitingUserAction))
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        #expect(m.currentPermission == .inputMonitoring)   // still here, but with a way out
        #expect(m.statuses[.inputMonitoring] == .awaitingUserAction)
    }

    /// Repeated re-checks that keep failing escalate to the stale-TCC recovery copy instead of
    /// repeating the same advice forever.
    @Test func repeatedRecheckEscalatesToRecoveryCopy() {
        var m = M(initialStatuses: [.microphone: .granted])
        m.handle(.next)
        m.handle(.allow(.inputMonitoring))
        m.handle(.permissionResult(.inputMonitoring, .awaitingUserAction))
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        #expect(m.handle(.verify(.inputMonitoring)) == [.checkPermission(.inputMonitoring)])
        m.handle(.permissionResult(.inputMonitoring, .notDetermined))
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 1))
        m.handle(.verify(.inputMonitoring))
        m.handle(.permissionResult(.inputMonitoring, .notDetermined))
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 2))
        // …and it still recovers the moment the user actually flips it.
        m.handle(.permissionResult(.inputMonitoring, .granted))
        #expect(m.currentPermission == .accessibility)
    }

    /// The background poll flips the checkmark without any click, and never disturbs the phase.
    @Test func pollingAdvancesOnGrantAndIsOtherwiseInert() {
        var m = M(initialStatuses: [.microphone: .granted])
        m.handle(.next)
        m.handle(.allow(.inputMonitoring))
        m.handle(.permissionResult(.inputMonitoring, .awaitingUserAction))
        // Poll ticks while the user is still in System Settings: no phase churn.
        for _ in 0..<5 { m.handle(.statusRefreshed(.inputMonitoring, .notDetermined)) }
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        #expect(m.currentPermission == .inputMonitoring)
        // They flip the switch; the very next tick moves on.
        m.handle(.statusRefreshed(.inputMonitoring, .granted))
        #expect(m.currentPermission == .accessibility)
        #expect(m.statuses[.inputMonitoring] == .granted)
    }

    /// The reported dead end: Input Monitoring stalls, and the only working control skipped the whole
    /// step so Accessibility was never shown. Skip must advance exactly one permission.
    @Test func skipOnPermissionsAdvancesOneAndStillReachesAccessibility() {
        var m = M(initialStatuses: [.microphone: .granted])
        m.handle(.next)
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring))
        m.handle(.permissionResult(.inputMonitoring, .awaitingUserAction))
        m.handle(.skip)
        #expect(m.step == .permissions)
        #expect(m.currentPermission == .accessibility)   // was unreachable before the fix
        m.handle(.allow(.accessibility))
        m.handle(.permissionResult(.accessibility, .granted))
        #expect(m.step == .micCheck)
        #expect(m.statuses[.accessibility] == .granted)
    }

    /// Every permission refused still terminates: three skips walk off the step, never loop.
    @Test func allThreeRefusedStillTerminates() {
        var m = M()
        m.handle(.next)
        for p in M.permissionOrder {
            #expect(m.currentPermission == p)
            m.handle(.allow(p))
            m.handle(.permissionResult(p, .awaitingUserAction))
            #expect(m.permissionPhase.isNeedsSystemSettings)
            m.handle(.next)
        }
        // No microphone → nothing to meter, so the walk lands on model choice, not a loop.
        #expect(m.step == .modelChoice)
        #expect(m.currentPermission == nil)
    }

    /// A permission macOS has already been asked for on an earlier launch skips the useless Allow
    /// button, since no prompt can ever appear again for this code identity.
    @Test func alreadyRequestedPermissionStartsInSettingsPhase() {
        var m = M(initialStatuses: [.microphone: .granted], alreadyRequested: [.inputMonitoring])
        m.handle(.next)
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        m.handle(.statusRefreshed(.inputMonitoring, .granted))
        // Accessibility was never requested, so it still gets the honest first-run Allow button.
        #expect(m.currentPermission == .accessibility)
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
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
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

    // MARK: BUG 2 — the verdict may only speak about audio that actually arrived

    private func atMicCheck() -> M {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        m.handle(.next)
        precondition(m.step == .micCheck)
        return m
    }

    /// The regression: one synthetic `level: 0` emitted at capture start used to pin the screen to
    /// "Very quiet" forever, before a single sample existed.
    @Test func quietVerdictWaitsForEnoughRealAudio() {
        var m = atMicCheck()
        #expect(m.micVerdict == .waiting)
        #expect(m.micLevelEvents == 0)
        for _ in 0..<40 {
            m.handle(.micLevel(0.01))
            #expect(m.micVerdict == .waiting, "quiet verdict before the settle window elapsed")
        }
        m.handle(.micSettled)
        #expect(m.micVerdict == .tooQuiet)   // now it has listened long enough to mean it
        #expect(m.micLevelEvents == 40)
    }

    /// The settle timer alone must never produce a verdict — that would be the old bug in a new hat
    /// (a clock-driven "too quiet" for audio that never arrived).
    @Test func settlingWithoutAnyAudioDoesNotProduceAQuietVerdict() {
        var m = atMicCheck()
        m.handle(.micSettled)
        #expect(m.micVerdict == .waiting)
        #expect(m.micLevelEvents == 0)
        m.handle(.micNoAudio)
        #expect(m.micVerdict == .noAudio)
    }

    /// Capture "succeeded" and nothing ever arrived — a stale microphone grant, not a quiet room.
    @Test func noAudioIsReportedAsNoAudioNotAsQuiet() {
        var m = atMicCheck()
        m.handle(.micNoAudio)
        #expect(m.micVerdict == .noAudio)
        #expect(m.micLevelEvents == 0)
        // A late watchdog tick must not undo a good verdict once audio is flowing.
        m.handle(.micLevel(0.4))
        #expect(m.micVerdict == .good)
        m.handle(.micNoAudio)
        #expect(m.micVerdict == .good)
    }

    @Test func captureFailureSurfacesTheRealError() {
        var m = atMicCheck()
        m.handle(.micFailed("noInputDevice"))
        #expect(m.micVerdict == .unavailable("noInputDevice"))
        // "Try again" restarts capture from a clean slate.
        #expect(m.handle(.verify(.microphone)) == [.stopMicMonitoring, .startMicMonitoring])
        #expect(m.micVerdict == .waiting)
        #expect(m.micLevelEvents == 0)
        #expect(!m.micSettled)
        #expect(m.peakLevel == 0)
    }

    @Test func verdictTableIsHonestAboutEachInput() {
        #expect(M.verdict(for: 0.0, peak: 0.0, settled: false) == .waiting)
        #expect(M.verdict(for: 0.01, peak: 0.02, settled: true) == .tooQuiet)
        #expect(M.verdict(for: 0.2, peak: 0.2, settled: false) == .good)   // loud enough, judge at once
        #expect(M.verdict(for: 0.99, peak: 0.99, settled: true) == .clipping)
        // Peak is sticky: a momentary dip after real speech stays "good".
        #expect(M.verdict(for: 0.01, peak: 0.5, settled: true) == .good)
    }

    @Test func progressIsMonotonic() {
        var m = M()
        var last = m.progress
        // Three skips now clear the three permissions one at a time, then the remaining steps.
        for event in [M.Event.next, .skip, .skip, .skip, .skip, .skip] {
            m.handle(event)
            #expect(m.progress >= last)
            last = m.progress
        }
        #expect(m.step == .done)
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
        try await waitUntil { vm.machine.permissionPhase.isNeedsSystemSettings }
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
        mic.send(0.5)
        try await waitUntil { vm.machine.micVerdict == .good }
        #expect(vm.micLevel == 0.5)
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

    /// BUG 1 end-to-end through the view model: the request resolves to `.awaitingUserAction`
    /// (what the real TCC calls do), and the 0.5 s poll picks up the grant made in System Settings
    /// with no further clicks — the checkmark flips and the step advances to Accessibility.
    @Test func pollingPicksUpAGrantMadeInSystemSettings() async throws {
        let deps = OnboardingDependencies.mock(permissionResults: [
            .microphone: .granted, .inputMonitoring: .awaitingUserAction,
        ])
        let vm = OnboardingViewModel(dependencies: deps)
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.currentPermission == .inputMonitoring }
        vm.send(.allow(.inputMonitoring))
        try await waitUntil { vm.machine.permissionPhase.isNeedsSystemSettings }
        #expect(vm.machine.currentPermission == .inputMonitoring)   // not a dead end: still actionable

        // The user flips the switch in System Settings; nothing in the app is clicked.
        checker.statuses[.inputMonitoring] = .granted
        try await waitUntil(timeoutMs: 4000) { vm.machine.statuses[.inputMonitoring] == .granted }
        #expect(vm.machine.currentPermission == .accessibility)
    }

    /// The "asked once" flag persists, so a second launch opens straight on the Settings phase
    /// rather than an Allow button macOS will never honour again.
    @Test func requestIsRememberedAcrossLaunches() async throws {
        let store = InMemorySettingsStore()
        var deps = OnboardingDependencies.mock(permissionResults: [.inputMonitoring: .awaitingUserAction])
        deps.settingsStore = store
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.currentPermission == .inputMonitoring }
        vm.send(.allow(.inputMonitoring))
        try await waitUntil { store.bool("onboarding.requested.inputMonitoring") == true }
        vm.teardown()

        var relaunch = OnboardingDependencies.mock(permissionResults: [.inputMonitoring: .awaitingUserAction])
        relaunch.settingsStore = store
        let second = OnboardingViewModel(dependencies: relaunch)
        second.send(.next)
        (relaunch.permissions as? OnboardingMockPermissionChecker)?.statuses[.microphone] = .granted
        second.send(.permissionResult(.microphone, .granted))
        #expect(second.machine.currentPermission == .inputMonitoring)
        #expect(second.machine.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        second.teardown()
    }

    /// BUG 2 through the view model: a capture that fails to start says why, instead of the meter
    /// sitting at zero under "Very quiet".
    @Test func micCaptureFailureReachesTheScreen() async throws {
        let deps = OnboardingDependencies.mock()
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip)                      // welcome → (no mic) → modelChoice
        vm.send(.back)                      // back to permissions
        for p in OnboardingPermission.allCases {
            vm.send(.allow(p))
            try await waitUntil { vm.machine.statuses[p] == .granted }
        }
        #expect(vm.step == .micCheck)
        let mic = try #require(deps.micLevel as? OnboardingMockMicLevelPublisher)
        mic.fail("noInputDevice")
        try await waitUntil { vm.machine.micVerdict == .unavailable("noInputDevice") }
        #expect(vm.micLevel == 0)
        vm.teardown()
    }

    /// The watchdog fires when capture is up but silent, and says so honestly.
    @Test func noAudioWatchdogReportsSilenceNotQuietness() async throws {
        let deps = OnboardingDependencies.mock()
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        for p in OnboardingPermission.allCases {
            vm.send(.allow(p))
            try await waitUntil { vm.machine.statuses[p] == .granted }
        }
        #expect(vm.step == .micCheck)
        #expect(vm.machine.micVerdict == .waiting)
        try await waitUntil(timeoutMs: 6000) { vm.machine.micVerdict == .noAudio }
        vm.teardown()
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
