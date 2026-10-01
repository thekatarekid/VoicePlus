import AVFoundation
import Foundation
import Testing
@testable import VoicePlusApp

/// V5 Q10 — the microphone status is re-read live, and a fresh capture outranks a stale status API.
@Suite("Q10 live microphone status")
struct MicrophoneStatusProbeTests {
    @Test func everyProbeRereadsTheStatusAPI() {
        let reader = MockMicrophoneAuthorizationReader(.authorized)
        let probe = MicrophoneStatusProbe(reader: reader, trial: MockMicrophoneCaptureTrial(result: true))
        probe.probe(.tick); probe.probe(.becameActive); probe.probe(.beforeRefusal)
        #expect(reader.reads == 3)
    }

    @Test func staleDeniedFreshGrantedCaptures() {
        // The status API is frozen at `.denied` after a mid-process grant; the capture works.
        let reader = MockMicrophoneAuthorizationReader(.denied)
        let trial = MockMicrophoneCaptureTrial(result: true)
        let probe = MicrophoneStatusProbe(reader: reader, trial: trial)
        #expect(probe.probe(.tick) == .denied, "a plain tick never starts a capture")
        #expect(trial.attempts == 0)
        #expect(probe.probe(.becameActive) == .denied, "the trial result lands on the next read")
        #expect(trial.attempts == 1)
        #expect(probe.probe(.beforeRefusal) == .authorized)
        #expect(PipelineAudioSource.authorizationRefusal(probe: probe) == nil, "capture proceeds")
    }

    @Test func freshDeniedRefusesOnTheSameCall() {
        let reader = MockMicrophoneAuthorizationReader(.authorized)
        let probe = MicrophoneStatusProbe(reader: reader, trial: MockMicrophoneCaptureTrial(result: false))
        #expect(PipelineAudioSource.authorizationRefusal(probe: probe) == nil)
        reader.status = .denied   // revoked
        #expect(PipelineAudioSource.authorizationRefusal(probe: probe) == .notPermitted(status: "turned off"))
    }

    @Test func aFailedTrialKeepsTheRefusalAndTrialsAreSpaced() {
        let reader = MockMicrophoneAuthorizationReader(.denied)
        let trial = MockMicrophoneCaptureTrial(result: false)
        var now = Date(timeIntervalSince1970: 0)
        let probe = MicrophoneStatusProbe(reader: reader, trial: trial, clock: { now })
        #expect(probe.probe(.beforeRefusal) == .denied)
        #expect(probe.probe(.beforeRefusal) == .denied)
        #expect(trial.attempts == 1, "no trial storm on repeated presses")
        now += MicrophoneStatusProbe.trialSpacing
        probe.probe(.becameActive)
        #expect(trial.attempts == 2)
    }

    @Test func trialsNeverStack() {
        let trial = MockMicrophoneCaptureTrial(result: nil)
        var now = Date(timeIntervalSince1970: 0)
        let probe = MicrophoneStatusProbe(reader: MockMicrophoneAuthorizationReader(.denied), trial: trial, clock: { now })
        probe.probe(.tccChanged)
        now += 60
        probe.probe(.tccChanged)
        #expect(trial.attempts == 1)
        trial.finish(true)
        #expect(probe.probe(.tick) == .authorized)
    }

    @Test func aTCCChangeDropsAnEarlierCaptureVerdict() {
        let reader = MockMicrophoneAuthorizationReader(.denied)
        let trial = MockMicrophoneCaptureTrial(result: true)
        let probe = MicrophoneStatusProbe(reader: reader, trial: trial)
        probe.probe(.becameActive)
        #expect(probe.probe(.tick) == .authorized)
        trial.result = false   // revoked in System Settings
        probe.noteTCCChanged()
        #expect(probe.probe(.tick) == .denied)
        #expect(trial.attempts == 2)
    }

    @Test func notDeterminedNeverStartsATrial() {
        // A trial on `.notDetermined` would raise the system prompt behind the user's back.
        let trial = MockMicrophoneCaptureTrial(result: true)
        let probe = MicrophoneStatusProbe(reader: MockMicrophoneAuthorizationReader(.notDetermined), trial: trial)
        probe.probe(.becameActive)
        probe.probe(.tccChanged)
        #expect(trial.attempts == 0)
    }

    @Test func changesAreReportedOnce() {
        let reader = MockMicrophoneAuthorizationReader(.authorized)
        let probe = MicrophoneStatusProbe(reader: reader, trial: MockMicrophoneCaptureTrial(result: false))
        var seen: [AVAuthorizationStatus] = []
        probe.onChange = { status, _ in seen.append(status) }
        for _ in 0..<5 { probe.probe(.tick) }
        reader.status = .denied
        for _ in 0..<5 { probe.probe(.tick) }
        #expect(seen == [.authorized, .denied])
    }
}

/// V5 Q10 — `RelaunchAdvisor` advises a microphone relaunch only after a fresh capture failed.
@Suite("Q10 relaunch only on a failed fresh capture")
struct MicrophoneRelaunchTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let denied: PermissionMatrix = [.microphone: .denied, .inputMonitoring: .granted, .accessibility: .granted]

    @Test func aStaleStatusAloneNeverAdvises() {
        var advisor = RelaunchAdvisor()
        advisor.noteSentToSettings(.microphone, at: t0)
        advisor.noteBecameActive(at: t0 + 5)
        #expect(advisor.evaluate(matrix: denied, now: t0 + 60).isEmpty)
    }

    @Test func aFailedCaptureAfterTheTripAdvises() {
        var advisor = RelaunchAdvisor()
        advisor.noteFreshCapture(succeeded: false, at: t0 - 10)   // before the trip: does not count
        advisor.noteSentToSettings(.microphone, at: t0)
        advisor.noteBecameActive(at: t0 + 5)
        #expect(advisor.evaluate(matrix: denied, now: t0 + 60).isEmpty)
        advisor.noteFreshCapture(succeeded: false, at: t0 + 5)
        #expect(advisor.evaluate(matrix: denied, now: t0 + 60) == [.microphone])
    }

    @Test func aSuccessfulCaptureCancelsTheOffer() {
        var advisor = RelaunchAdvisor()
        advisor.noteSentToSettings(.microphone, at: t0)
        advisor.noteBecameActive(at: t0 + 5)
        advisor.noteFreshCapture(succeeded: true, at: t0 + 5)
        #expect(advisor.evaluate(matrix: denied, now: t0 + 60).isEmpty)
    }

    @MainActor
    @Test func theWatcherWiresTheProbeTrialIntoTheAdvisor() {
        final class Clock { var now = Date(timeIntervalSince1970: 3_000_000) }
        let clock = Clock()
        let trial = MockMicrophoneCaptureTrial(result: false)
        let probe = MicrophoneStatusProbe(reader: MockMicrophoneAuthorizationReader(.denied), trial: trial,
                                          clock: { clock.now })
        let checker = MockPermissionChecker(statuses: denied)
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [], microphoneProbe: probe)
        watcher.clock = { clock.now }
        var advised: [Permission] = []
        watcher.onRelaunchAdvised = { advised.append($0) }
        watcher.noteSentToSettings(.microphone)
        clock.now += 10
        watcher.noteBecameActive()            // re-read → `.denied` → fresh capture → fails
        #expect(trial.attempts == 1)
        clock.now += RelaunchAdvisor.grace
        watcher.refresh()
        #expect(advised == [.microphone])
    }

    @MainActor
    @Test func theWatcherStaysQuietWhenTheFreshCaptureWorks() {
        final class Clock { var now = Date(timeIntervalSince1970: 3_000_000) }
        let clock = Clock()
        let probe = MicrophoneStatusProbe(reader: MockMicrophoneAuthorizationReader(.denied),
                                          trial: MockMicrophoneCaptureTrial(result: true), clock: { clock.now })
        let watcher = CapabilityWatcher(checker: MockPermissionChecker(statuses: denied), hotkeys: [],
                                        microphoneProbe: probe)
        watcher.clock = { clock.now }
        var advised: [Permission] = []
        watcher.onRelaunchAdvised = { advised.append($0) }
        watcher.noteSentToSettings(.microphone)
        clock.now += 10
        watcher.noteBecameActive()
        clock.now += 60
        watcher.refresh()
        #expect(advised.isEmpty, "\"Later\" works: never tell a user to restart an app that already captures")
    }
}

/// V5 Q11 — a fresh Input Monitoring grant re-creates the legacy tap and confirms it with `TapLiveness`.
@Suite("Q11 Input Monitoring re-arm")
struct InputMonitoringRearmTests {
    @Test func theFirstReadIsNotAFreshGrant() {
        var machine = InputMonitoringRearm()
        #expect(machine.step(granted: true, needsInputMonitoring: true, isRunning: true, verdict: .alive) == .none)
        #expect(machine.phase == .idle)
    }

    @Test func livenessVerdictTransitions() {
        var machine = InputMonitoringRearm()
        _ = machine.step(granted: false, needsInputMonitoring: true, isRunning: true, verdict: .unknown)
        #expect(machine.step(granted: true, needsInputMonitoring: true, isRunning: true, verdict: .dead) == .recreateTap)
        #expect(machine.phase == .confirming)
        #expect(machine.step(granted: true, needsInputMonitoring: true, isRunning: true, verdict: .unknown) == .none)
        #expect(machine.phase == .confirming, "unknown keeps waiting")
        #expect(machine.step(granted: true, needsInputMonitoring: true, isRunning: true, verdict: .alive) == .announceListeningAgain)
        #expect(machine.phase == .confirmed)
        #expect(machine.step(granted: true, needsInputMonitoring: true, isRunning: true, verdict: .alive) == .none,
                "announced once")
    }

    @Test func aDeadVerdictHandsOverToTheDeafTapPath() {
        var machine = InputMonitoringRearm()
        _ = machine.step(granted: false, needsInputMonitoring: true, isRunning: false, verdict: .unknown)
        #expect(machine.step(granted: true, needsInputMonitoring: true, isRunning: false, verdict: .unknown) == .none,
                "not armed: the ordinary arm path creates the tap")
        #expect(machine.phase == .confirming)
        #expect(machine.step(granted: true, needsInputMonitoring: true, isRunning: true, verdict: .dead) == .none)
        #expect(machine.phase == .idle)
    }

    @Test func backendsWithoutInputMonitoringAreIgnored() {
        var machine = InputMonitoringRearm()
        _ = machine.step(granted: false, needsInputMonitoring: false, isRunning: true, verdict: .unknown)
        #expect(machine.step(granted: true, needsInputMonitoring: false, isRunning: true, verdict: .alive) == .none)
    }

    @MainActor
    @Test func theWatcherRecreatesTheTapAndSaysListeningAgainOnce() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .notDetermined,
                                                       .accessibility: .granted])
        let hotkey = MockHotkeyArming()
        hotkey.requiredPermission = .inputMonitoring
        hotkey.start()   // a tap created before the grant: exists, deaf
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [hotkey])
        var announced = 0
        watcher.onListeningAgain = { announced += 1 }
        watcher.refresh()
        #expect(!hotkey.isRunning, "ungranted: torn down")
        hotkey.start()   // model the stale-preflight case: still armed when the grant lands
        checker.statuses[.inputMonitoring] = .granted
        watcher.refresh()
        #expect(hotkey.rearmCount == 1, "fresh grant re-creates the tap")
        #expect(hotkey.isRunning)
        hotkey.livenessVerdict = .unknown
        watcher.refresh()
        #expect(announced == 0)
        hotkey.livenessVerdict = .alive
        watcher.refresh()
        watcher.refresh()
        #expect(announced == 1)
        #expect(hotkey.rearmCount == 1)
    }

    @MainActor
    @Test func aGrantSeenWhileDisarmedArmsThenConfirms() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .notDetermined,
                                                       .accessibility: .granted])
        let hotkey = MockHotkeyArming()
        hotkey.requiredPermission = .inputMonitoring
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [hotkey])
        var announced = 0
        watcher.onListeningAgain = { announced += 1 }
        watcher.refresh()
        checker.statuses[.inputMonitoring] = .granted
        watcher.refresh()
        #expect(hotkey.startCount == 1 && hotkey.rearmCount == 0)
        hotkey.livenessVerdict = .alive
        watcher.refresh()
        #expect(announced == 1)
    }
}
