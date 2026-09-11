import Combine
import Foundation
import Testing
@testable import VoicePlusApp

/// The 1.6.9 defect: onboarding's "Say something." step passed on a Mac with no ASR model, with the
/// user silent and no microphone ever opened.
///
/// `AppContainer` picked `PipelineMicLevelPublisher` only when a live audio pipeline existed, and
/// that pipeline only existed when a recognizer did. On a fresh install — the *only* state
/// onboarding runs in — it fell back to `EngineMicLevelPublisher`, which forwarded the mock engine's
/// fixture-derived `EngineState.listening(level:)` numbers. Those cleared the `peak >= 0.08` bar, so
/// the meter filled and the screen said "Sounds good." A caption admitted the meter was simulated
/// and the step passed anyway.
///
/// These tests pin the two halves of the fix: a level that did not come from live capture can never
/// reach a passing verdict, and a microphone macOS has not granted lands on a screen that says so
/// instead of a meter that cannot move.
@Suite("Onboarding mic check — a pass requires real audio")
struct OnboardingMicCheckHonestyTests {
    typealias M = OnboardingStateMachine

    private func atMicCheck() -> M {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        m.handle(.next)
        precondition(m.step == .microphone)
        return m
    }

    // MARK: A/B — provenance gates the verdict

    /// The exact old shape: levels arrive, nothing declared them captured, and they used to become
    /// "Sounds good." Now they are discarded — not even counted.
    @Test func levelsWithNoDeclaredCaptureCanNeverPass() {
        var m = atMicCheck()
        #expect(!m.micCaptureIsReal, "provenance is default-deny")
        for level in [Float(0.4), 0.9, 0.5, 0.12] { m.handle(.micLevel(level)) }
        #expect(m.micVerdict == .waiting)
        #expect(!m.micVerdict.isPass)
        #expect(m.micLevelEvents == 0, "an undeclared level is not evidence and must not be counted")
        #expect(m.peakLevel == 0)
        // Nor can the settle clock turn them into any verdict at all.
        m.handle(.micSettled)
        #expect(m.micVerdict == .waiting)
    }

    /// A source that admits it is not capture (the old engine-state meter's own answer) is refused
    /// outright, and stays refused however loud its numbers get.
    @Test func aSourceThatIsNotCaptureIsRefusedAndStaysRefused() {
        var m = atMicCheck()
        m.handle(.micCaptureBegan(real: false))
        #expect(m.micVerdict == .unavailable(M.simulatedCaptureReason))
        m.handle(.micLevel(0.9))
        m.handle(.micSettled)
        #expect(m.micVerdict == .unavailable(M.simulatedCaptureReason))
        #expect(!m.micVerdict.isPass)
        #expect(m.micLevelEvents == 0)
    }

    /// The control: the same levels, declared as live capture, do pass. Without this the gate could
    /// be satisfied by breaking the step outright.
    @Test func declaredRealCaptureStillPasses() {
        var m = atMicCheck()
        m.handle(.micCaptureBegan(real: true))
        m.handle(.micLevel(0.4))
        #expect(m.micVerdict == .good)
        #expect(m.micVerdict.isPass)
        #expect(m.micLevelEvents == 1)
    }

    /// "Try again" drops the provenance with the rest of the state, so a restart cannot inherit a
    /// previous run's permission to pass.
    @Test func retryClearsProvenanceToo() {
        var m = atMicCheck()
        m.handle(.micCaptureBegan(real: true))
        m.handle(.micLevel(0.4))
        #expect(m.micVerdict == .good)
        #expect(m.handle(.verify(.microphone)) == [.stopMicMonitoring, .startMicMonitoring])
        #expect(!m.micCaptureIsReal)
        m.handle(.micLevel(0.9))
        #expect(m.micVerdict == .waiting, "levels after a restart wait for the new capture to be declared")
    }

    /// Capture that cannot start is a blocked screen carrying the real reason — never a pass, and
    /// never the "very quiet" the pre-1.6.4 meter used to show for it.
    @Test func captureFailureBlocksInsteadOfPassing() {
        var m = atMicCheck()
        m.handle(.micCaptureBegan(real: true))
        m.handle(.micFailed("noInputDevice"))
        #expect(m.micVerdict == .unavailable("noInputDevice"))
        #expect(!m.micVerdict.isPass)
    }

    // MARK: C — a microphone macOS has not granted

    /// A denial that is continued past never gets a second look at a blocked meter — the ask and
    /// its denial share one screen (R6.2 / DESIGN §11.2), so "Continue anyway" there moves straight
    /// on (here, all the way to "Try the key", since Accessibility was already granted).
    @Test func deniedMicrophoneContinuedPastNeverShowsABlockedMeterScreen() {
        var m = M(initialStatuses: [.microphone: .denied, .inputMonitoring: .granted, .accessibility: .granted])
        m.handle(.next)
        #expect(m.step == .microphone)
        #expect(m.currentPermission == .microphone)
        let effects = m.handle(.next)   // "Continue anyway" past the denied microphone
        #expect(m.step == .firstDictation, "accessibility was already granted, so nothing is left to ask")
        #expect(m.micVerdict != .good, "nothing may pretend the refused microphone passed")
        #expect(!effects.contains(.startMicMonitoring), "there is nothing to meter without the grant")
    }

    /// Undetermined is the same answer: the app has never been allowed to open the microphone, so
    /// the check cannot succeed and must not pretend it might.
    @Test func undeterminedMicrophoneIsAlsoBlocked() {
        var m = M()
        m.handle(.skip)                       // welcome → Microphone
        #expect(m.step == .microphone)
        #expect(m.micVerdict == .permissionRequired)
        #expect(!m.micCaptureIsReal)
        // And nothing that arrives while blocked can dislodge it into a pass.
        m.handle(.micLevel(0.9))
        m.handle(.micSettled)
        m.handle(.micNoAudio)
        #expect(m.micVerdict == .permissionRequired)
        #expect(!m.micVerdict.isPass)
    }

    /// "Re-check" on the blocked screen asks about the *permission*, not the audio — restarting
    /// capture would only redraw the same dead bar. A grant then opens the real check.
    @Test func recheckOnTheBlockedScreenAsksAboutThePermission() {
        var m = M(initialStatuses: [.microphone: .denied])
        m.handle(.skip)
        #expect(m.micVerdict == .permissionRequired)
        #expect(m.handle(.verify(.microphone)) == [.checkPermission(.microphone)])

        // Still denied → still blocked.
        m.handle(.permissionResult(.microphone, .denied))
        #expect(m.micVerdict == .permissionRequired)

        // Granted → the step re-enters for real, and only now does capture start.
        let effects = m.handle(.permissionResult(.microphone, .granted))
        #expect(effects.contains(.startMicMonitoring))
        #expect(m.micVerdict == .waiting)
        #expect(!m.micCaptureIsReal, "capture still has to declare itself before any level counts")
    }
}

/// A level source that reports what the deleted `EngineMicLevelPublisher` reported: not capture.
private final class NotCaptureLevelPublisher: MicLevelPublishing {
    let subject = CurrentValueSubject<MicCheckSignal, Never>(.starting)
    private(set) var monitoring = false
    var isRealCapture: Bool { false }
    var signalPublisher: AnyPublisher<MicCheckSignal, Never> { subject.eraseToAnyPublisher() }
    func startMonitoring() { monitoring = true }
    func stopMonitoring() { monitoring = false }
}

@Suite("Onboarding mic check — view model refuses a non-capture source")
@MainActor
struct OnboardingMicCheckSourceTests {
    /// The view model is the only thing that turns a publisher into `.micLevel` events, and it
    /// refuses a source that is not live capture: it never subscribes, never starts it, and reports
    /// the step as un-completable. This is what makes the old bug unreachable end to end.
    @Test func aNonCaptureSourceIsNeverMeteredAndNeverPasses() async throws {
        var deps = OnboardingDependencies.mock()
        let fake = NotCaptureLevelPublisher()
        deps.micLevel = fake
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.statuses[.microphone] == .granted }
        #expect(vm.step == .microphone)
        #expect(!fake.monitoring, "a source that is not capture is not even started")
        #expect(vm.machine.micVerdict == .unavailable(OnboardingStateMachine.simulatedCaptureReason))

        // Even if it pushes levels anyway, nothing reaches the meter or the verdict.
        fake.subject.send(.level(0.9))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(vm.micLevel == 0)
        #expect(!vm.machine.micVerdict.isPass)
        #expect(vm.machine.micLevelEvents == 0)
        vm.teardown()
    }

    /// The default mock publisher is not a microphone, so the default `OnboardingDependencies.mock()`
    /// cannot pass the step either — a test has to say `pretendRealMicCapture: true` out loud.
    @Test func theMockPublisherDoesNotClaimToBeAMicrophoneByDefault() {
        #expect(!OnboardingMockMicLevelPublisher().isRealCapture)
        #expect(OnboardingMockMicLevelPublisher(pretendingRealCapture: true).isRealCapture)
        #expect(!OnboardingDependencies.mock().micLevel.isRealCapture)
    }

    /// A. The shipping meter is a capture graph built with no recognizer, no model and no engine —
    /// which is why it works on a fresh install. Constructing it opens nothing; `startMonitoring()`
    /// is what touches the HAL, and that needs real hardware.
    @Test func onboardingOwnsARealCaptureGraphThatNeedsNoModel() {
        let publisher = PipelineMicLevelPublisher.standalone()
        #expect(publisher.isRealCapture)
    }
}
