import Foundation
import Testing
@testable import VoicePlusApp

/// 1.6.6 — "after toggling it in Settings it requires the app to quit and relaunch."
///
/// It did, and it did not have to. `hotkey.start()` had exactly one caller in the whole app: the
/// completion of `PermissionOrchestrator.run`. That completion never runs while onboarding is on
/// screen, and was withheld while a pre-prompt window was up — so on the reporting machine Input
/// Monitoring had been granted for twenty minutes with no tap ever created, because the walk was
/// parked on the *Accessibility* pre-prompt, a permission the hotkey does not need. The app tried
/// once, at the wrong moment, and never again. A relaunch was the only thing that made it try again.
///
/// `CapabilityWatcher` re-reads the matrix continuously and owns the tap lifecycle. These tests pin
/// the two properties that matter: a grant arms exactly once, and nothing ever stacks a second tap.
@Suite("Capability arming — a grant picked up without a relaunch")
@MainActor
struct CapabilityArmingTests {
    private func watcher(_ checker: MockPermissionChecker, _ hotkeys: [MockHotkeyArming]) -> CapabilityWatcher {
        CapabilityWatcher(checker: checker, hotkeys: hotkeys)
    }

    @Test func decisionTableIsIdempotent() {
        #expect(CapabilityArming.decision(canUseGlobalHotkey: true, isArmed: false) == .arm)
        // The whole point: a poll that keeps seeing "granted" must not keep arming.
        #expect(CapabilityArming.decision(canUseGlobalHotkey: true, isArmed: true) == .hold)
        #expect(CapabilityArming.decision(canUseGlobalHotkey: false, isArmed: true) == .disarm)
        #expect(CapabilityArming.decision(canUseGlobalHotkey: false, isArmed: false) == .hold)
    }

    /// A hotkey on the `hotkeyForceEventTap` escape hatch — the only configuration left that waits
    /// on a permission. The default backends need none and arm on the first tick
    /// (`HotkeyArmingWithoutInputMonitoringTests`); this is the arm/disarm *mechanics*, which still
    /// have to be right for the service that does wait.
    @Test func deniedToGrantedArmsExactlyOnceAndLaterTicksDoNothing() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .denied,
                                                       .accessibility: .denied])
        let hotkey = MockHotkeyArming()
        hotkey.requiredPermission = .inputMonitoring
        let watcher = watcher(checker, [hotkey])

        watcher.refresh()
        #expect(hotkey.startCount == 0, "nothing to arm while Input Monitoring is denied")
        #expect(!hotkey.isRunning)

        // The user flips the switch in System Settings. No relaunch, no re-check press.
        checker.statuses[.inputMonitoring] = .granted
        watcher.refresh()
        #expect(hotkey.startCount == 1)
        #expect(hotkey.isRunning)

        for _ in 0..<10 { watcher.refresh() }
        #expect(hotkey.startCount == 1, "a 1 s poll must never stack a second tap")
        #expect(hotkey.stopCount == 0)
    }

    @Test func bothHotkeysAreArmedAndRevokingTearsThemDownExactlyOnce() {
        let checker = MockPermissionChecker(statuses: [.inputMonitoring: .granted])
        let dictate = MockHotkeyArming()
        let act = MockHotkeyArming()
        dictate.requiredPermission = .inputMonitoring
        act.requiredPermission = .inputMonitoring
        let watcher = watcher(checker, [dictate, act])
        watcher.refresh()
        #expect(dictate.startCount == 1 && act.startCount == 1)

        checker.statuses[.inputMonitoring] = .denied
        watcher.refresh()
        watcher.refresh()
        #expect(dictate.stopCount == 1 && act.stopCount == 1, "one teardown, not one per tick")
        #expect(!dictate.isRunning && !act.isRunning)

        // And it comes back when the permission does — still exactly one tap each.
        checker.statuses[.inputMonitoring] = .granted
        watcher.refresh()
        watcher.refresh()
        #expect(dictate.startCount == 2 && act.startCount == 2)
    }

    /// Preflight can say granted while `tapCreate` still refuses. That must be retried, not latched
    /// as "armed" — otherwise one transient failure disables the hotkey for the rest of the session.
    @Test func aRefusedTapIsRetriedOnTheNextTick() {
        let checker = MockPermissionChecker(statuses: [.inputMonitoring: .granted])
        let hotkey = MockHotkeyArming()
        hotkey.startSucceeds = false
        let watcher = watcher(checker, [hotkey])
        watcher.refresh()
        watcher.refresh()
        #expect(hotkey.startCount == 2)
        #expect(!hotkey.isRunning)
        hotkey.startSucceeds = true
        watcher.refresh()
        #expect(hotkey.isRunning)
    }

    @Test func capabilitiesAreReportedOnceOnTheFirstReadAndThenOnlyOnChange() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted])
        let watcher = watcher(checker, [])
        var reports: [PermissionPlanner.Capabilities] = []
        watcher.onCapabilitiesChanged = { caps, _ in reports.append(caps) }
        watcher.refresh()
        watcher.refresh()
        #expect(reports.count == 1)
        checker.statuses[.accessibility] = .granted
        watcher.refresh()
        #expect(reports.count == 2)
        #expect(reports.last?.canInjectText == true)
        // Accessibility flipping does not disturb the hotkey capability — they are independent, which
        // is exactly what the old "arm from the end of the walk" design got wrong. Since 1.6.8 the
        // hotkey capability is simply always available: no watched hotkey needs a permission.
        #expect(reports.allSatisfy { $0.canUseGlobalHotkey })
    }
}

/// `CGEvent.tapCreate` is not a permission test: with a throwaway bundle id that had no Input
/// Monitoring at all, six creations returned six non-NULL taps while `CGPreflightListenEventAccess()`
/// stayed false throughout (measured, macOS 26.6.2). So "armed" cannot be trusted to mean "working",
/// and the app needs a second signal before it may claim either that it recovered or that a restart
/// is genuinely required.
@Suite("Tap liveness — armed is not working")
struct TapLivenessTests {
    @Test func eventsArrivingIsAlwaysAlive() {
        #expect(TapLiveness.verdict(armedFor: 0.1, eventsSinceArmed: 1, systemModifierIdle: 999) == .alive)
        #expect(TapLiveness.verdict(armedFor: 600, eventsSinceArmed: 42, systemModifierIdle: 0.1) == .alive)
    }

    @Test func silenceIsUnknownUntilTheGraceHasPassed() {
        #expect(TapLiveness.verdict(armedFor: 5, eventsSinceArmed: 0, systemModifierIdle: 1) == .unknown)
        #expect(TapLiveness.verdict(armedFor: 19.9, eventsSinceArmed: 0, systemModifierIdle: 0.5) == .unknown)
    }

    /// The control. If the *system* has seen no modifier key since we armed, our silence proves
    /// nothing — the user simply hasn't touched one, and calling that "dead" would restart the app
    /// for nothing.
    @Test func silenceIsUnknownWhenTheSystemSawNoModifiersEither() {
        #expect(TapLiveness.verdict(armedFor: 60, eventsSinceArmed: 0, systemModifierIdle: 60) == .unknown)
        #expect(TapLiveness.verdict(armedFor: 60, eventsSinceArmed: 0, systemModifierIdle: 120) == .unknown)
    }

    @Test func deadOnlyWhenTheSystemSawModifiersAfterWeArmedAndWeGotNone() {
        #expect(TapLiveness.verdict(armedFor: 60, eventsSinceArmed: 0, systemModifierIdle: 2) == .dead)
        #expect(TapLiveness.verdict(armedFor: 21, eventsSinceArmed: 0, systemModifierIdle: 20.9) == .dead)
    }

    @Test func graceIsConfigurableForTests() {
        #expect(TapLiveness.verdict(armedFor: 1, eventsSinceArmed: 0, systemModifierIdle: 0.5, grace: 0.5) == .dead)
    }
}

@Suite("A deaf tap gets one re-arm, then the truth")
@MainActor
struct DeafTapRecoveryTests {
    @Test func oneSilentRearmThenTheRestartIsAnnounced() {
        let checker = MockPermissionChecker(statuses: [.inputMonitoring: .granted])
        let hotkey = MockHotkeyArming()
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [hotkey])
        var provenDead = 0
        watcher.onTapProvenDead = { provenDead += 1 }

        watcher.refresh()
        #expect(hotkey.startCount == 1)

        // The tap exists, the user is typing, nothing reaches us.
        hotkey.livenessVerdict = .dead
        watcher.refresh()
        #expect(hotkey.rearmCount == 1, "re-arm first — that is the fix for the common case")
        #expect(provenDead == 0, "do not tell the user to restart before trying")

        // Still deaf after the fresh tap: now, and only now, a restart is an honest recommendation.
        watcher.refresh()
        #expect(hotkey.rearmCount == 1, "one re-arm, not a loop")
        #expect(provenDead == 1)
    }

    @Test func aTapThatComesBackToLifeIsLeftAlone() {
        let checker = MockPermissionChecker(statuses: [.inputMonitoring: .granted])
        let hotkey = MockHotkeyArming()
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [hotkey])
        var provenDead = 0
        watcher.onTapProvenDead = { provenDead += 1 }
        watcher.refresh()
        hotkey.livenessVerdict = .dead
        watcher.refresh()
        hotkey.livenessVerdict = .alive
        for _ in 0..<5 { watcher.refresh() }
        #expect(hotkey.rearmCount == 1)
        #expect(provenDead == 0)
    }

    /// A real `HotkeyService` reports nothing about liveness while it is disarmed, so the watcher can
    /// never mistake "never armed" for "armed and deaf".
    @Test func aDisarmedServiceHasNoOpinion() {
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.arming.\(UUID())")!)
        #expect(!service.isRunning)
        #expect(service.armCount == 0)
        #expect(service.eventsReceived == 0)
        #expect(service.armedAt == nil)
        #expect(service.livenessVerdict == .unknown)
        // Idempotent teardown: stopping a service that was never started must not throw or latch.
        service.stop()
        #expect(!service.isRunning && service.armCount == 0)
    }
}

@Suite("tccutil row reset")
struct PermissionRowResetTests {
    @Test func serviceNamesMatchTheOnesTccutilTakes() {
        #expect(TCCUtilRowReset.serviceName(for: .accessibility) == "Accessibility")
        #expect(TCCUtilRowReset.serviceName(for: .inputMonitoring) == "ListenEvent")
        #expect(TCCUtilRowReset.serviceName(for: .microphone) == "Microphone")
    }

    /// "No such bundle identifier" (exit 64, measured) is not a failure: it means the pane's list
    /// never had VoicePlus in it, which is the same next step and rules the stale-entry story out.
    @Test func exitCodesMapToTheThreeOutcomes() {
        #expect(TCCUtilRowReset.interpret(status: 0, output: "") == .removed)
        #expect(TCCUtilRowReset.interpret(status: 64, output:
            "tccutil: No such bundle identifier \"in.adityakatare.voiceplus\": ...") == .noEntry)
        #expect(TCCUtilRowReset.interpret(status: 1, output: "boom") == .failed("boom"))
        #expect(TCCUtilRowReset.interpret(status: 1, output: "  ") == .failed("tccutil exited 1"))
        #expect(PermissionRowResetOutcome.removed.listIsNowEmptyOfUs)
        #expect(PermissionRowResetOutcome.noEntry.listIsNowEmptyOfUs)
        #expect(!PermissionRowResetOutcome.failed("x").listIsNowEmptyOfUs)
    }

    @Test func theCommandIsScopedToOneServiceOfOneBundleId() {
        var captured: [String] = []
        let reset = TCCUtilRowReset(bundleIdentifier: "in.example.app") { executable, arguments in
            captured = [executable] + arguments
            return (0, "")
        }
        #expect(reset.reset(.accessibility) == .removed)
        #expect(captured == ["/usr/bin/tccutil", "reset", "Accessibility", "in.example.app"])
    }

    @Test func theCLIParsesTheSameWayTheRequestSelfTestDoes() {
        #expect(PermissionDiagnostics.parseResetCLI(["VoicePlus", "--reset-permission", "accessibility"]) == .accessibility)
        #expect(PermissionDiagnostics.parseResetCLI(["VoicePlus", "--reset-permission"]) == nil)
        #expect(PermissionDiagnostics.parseResetCLI(["VoicePlus"]) == nil)
        let mock = MockRowReset(outcome: .noEntry)
        #expect(PermissionDiagnostics.runResetCLI(.accessibility, reset: mock) == 0)
        #expect(mock.resets == [.accessibility])
        #expect(PermissionDiagnostics.runResetCLI(.accessibility, reset: MockRowReset(outcome: .failed("no"))) == 1)
    }
}

@Suite("Onboarding: the whole checklist stays live, and the row reset is wired")
@MainActor
struct OnboardingLivePollingTests {
    /// A permission granted while a *different* one is in focus used to keep an empty dot until the
    /// walk happened to reach it — which is how "Microphone and Input Monitoring are green but
    /// Accessibility is empty" can be read as "the app is stuck" when it is merely not looking.
    @Test func everyPermissionIsRefreshedPerTickNotOnlyTheFocusedOne() throws {
        // The three-permission walk, i.e. a build on the escape hatch — this test is about the poll
        // refreshing every permission, so it wants the longest list.
        var deps = OnboardingDependencies.mock()
        deps.hotkeyRequiresPermission = .inputMonitoring
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        checker.statuses = [.microphone: .granted, .inputMonitoring: .denied, .accessibility: .denied]
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        // R6.2 — the microphone's ask and its meter now share one screen (DESIGN §11.2); with the
        // microphone already granted, the first `.next` only reaches that meter, and a second is
        // what reaches Input Monitoring.
        vm.send(.next)
        #expect(vm.machine.currentPermission == .inputMonitoring)

        // The user grants the one that is NOT in focus.
        checker.statuses[.accessibility] = .granted
        vm.pollCurrentPermission()
        #expect(vm.machine.statuses[.accessibility] == .granted)
        #expect(vm.machine.currentPermission == .inputMonitoring, "a background grant must not steal focus")

        // And the focused one still advances when it lands — accessibility was already granted
        // above, so this is the whole walk finishing.
        checker.statuses[.inputMonitoring] = .granted
        vm.pollCurrentPermission()
        #expect(vm.machine.step == .model, "the permission walk is over (S8: the Model step follows it)")
    }

    @Test func recoveryEvidenceOnlyCountsOtherNonPromptableGrants() throws {
        let deps = OnboardingDependencies.mock()
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        checker.statuses = [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .denied]
        let vm = OnboardingViewModel(dependencies: deps)
        #expect(vm.recoveryEvidence(for: .accessibility).corroboratingGrants == [.inputMonitoring])
        // The microphone is promptable and proves nothing about a "+"-list entry, so it is excluded.
        #expect(!vm.recoveryEvidence(for: .accessibility).corroboratingGrants.contains(.microphone))
        checker.statuses[.inputMonitoring] = .denied
        #expect(!vm.recoveryEvidence(for: .accessibility).signatureProvenGood)
    }

    @Test func removingTheEntryRunsExactlyOneScopedResetAndRefreshesTheStatus() throws {
        let deps = OnboardingDependencies.mock()
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        checker.statuses = [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .denied]
        let vm = OnboardingViewModel(dependencies: deps)
        let reset = MockRowReset()
        #expect(vm.resetPermissionRow(for: .accessibility, using: reset) == .removed)
        #expect(reset.resets == [.accessibility], "one service, and never a second one")
        #expect(vm.rowResetOutcome == .removed)
    }
}
