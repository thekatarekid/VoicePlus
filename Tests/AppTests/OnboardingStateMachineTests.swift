import Foundation
import Testing
@testable import VoicePlusApp

/// The longest permission walk — microphone, Input Monitoring, accessibility.
///
/// That is no longer what a default install gets: since 1.6.8 the hotkey runs on an `NSEvent` global
/// monitor, which needs no TCC service, so onboarding walks microphone → accessibility and the
/// Input Monitoring screen appears only for a build on the `hotkeyForceEventTap` escape hatch (see
/// `OnboardingSkipsInputMonitoringTests`). The tests below are about the *mechanics* of walking a
/// multi-permission list — the non-promptable middle step, the recovery phase, skipping, ordering —
/// so they keep exercising the longest one rather than losing a step's worth of coverage.
private func fullWalkM(initialStatuses: [OnboardingPermission: OnboardingPermissionStatus] = [:],
                       alreadyRequested: Set<OnboardingPermission> = []) -> OnboardingStateMachine {
    OnboardingStateMachine(initialStatuses: initialStatuses, alreadyRequested: alreadyRequested,
                           permissionOrder: OnboardingPermission.order(hotkeyRequires: .inputMonitoring))
}

/// From `.welcome`, reaches whichever permission is first not yet granted — passing straight
/// through the Microphone screen's meter (R6.2) without lingering when the microphone is already
/// granted, exactly as a user pressing Continue would. Most of the tests below construct their
/// machine with the microphone pre-granted purely to exercise the *rest* of the permission walk
/// (Input Monitoring, Accessibility), so this is the one extra `.next` that used to be implicit.
private func advanceToFirstOpenPermission(_ m: inout OnboardingStateMachine) {
    m.handle(.next)
    if m.currentPermission == nil, m.step == .microphone { m.handle(.next) }
}

/// FIX B — the phase a permission step opens on is now recorded. The 1.6.2 microphone regression
/// was a *phase* choice: `initialPhase` sent a notDetermined microphone to the settings-recovery
/// screen, whose panel has no Allow button and therefore no route to
/// `AVCaptureDevice.requestAccess`. Nothing logged that choice, so the happy path and the dead end
/// were indistinguishable in the user's own logs and a verifier could not tell which one ran.
@Suite("FIX B — onboarding permission transitions are observable")
struct OnboardingTransitionLogTests {
    typealias M = OnboardingStateMachine

    @Test func lineNamesPermissionLiveStatusAndChosenPhase() {
        #expect(M.transitionLog(permission: .microphone, status: .notDetermined, phase: .explain)
                == "onboarding: microphone status=notDetermined phase=explain")
        #expect(M.transitionLog(permission: .microphone, status: .notDetermined,
                                phase: .needsSystemSettings(recheckAttempts: 0))
                == "onboarding: microphone status=notDetermined phase=needsSystemSettings(recheck=0)")
        #expect(M.transitionLog(permission: .accessibility, status: .denied,
                                phase: .needsSystemSettings(recheckAttempts: 3))
                == "onboarding: accessibility status=denied phase=needsSystemSettings(recheck=3)")
        #expect(M.transitionLog(permission: .inputMonitoring, status: .awaitingUserAction, phase: .requesting)
                == "onboarding: inputMonitoring status=awaitingUserAction phase=requesting")
    }

    /// The exact pair the two 1.6.2 outcomes differ by — identical before this line existed.
    @Test func theRegressionAndTheFixNowReadDifferently() {
        let fixed = M(initialStatuses: [.microphone: .notDetermined], alreadyRequested: [.microphone])
        var m = fixed
        m.handle(.next)
        let focus = m.permissionFocus
        #expect(focus?.permission == .microphone)
        #expect(focus?.phase == .explain, "promptable + notDetermined must open on the Allow button")
        #expect(M.transitionLog(permission: .microphone, status: .notDetermined, phase: focus!.phase)
                != M.transitionLog(permission: .microphone, status: .notDetermined,
                                   phase: .needsSystemSettings(recheckAttempts: 0)))
    }

    /// `--onboarding-selftest` reads the user's real persisted flags — a stale one *was* the 1.6.2
    /// dead end — so it must be structurally unable to write to them.
    @Test func theSelfTestsSettingsViewReadsThroughButSwallowsWrites() {
        let backing = InMemorySettingsStore()
        backing.set(true, for: "onboarding.requested.microphone")
        backing.set("fn", for: SettingsKeys.hotkey)
        let readOnly = ReadOnlySettingsStore(backing)

        #expect(readOnly.bool("onboarding.requested.microphone") == true)
        #expect(readOnly.string(SettingsKeys.hotkey) == "fn")

        readOnly.set(false, for: "onboarding.requested.microphone")
        readOnly.set("rightCommand", for: SettingsKeys.hotkey)
        #expect(backing.bool("onboarding.requested.microphone") == true, "a diagnostic must not rewrite user state")
        #expect(backing.string(SettingsKeys.hotkey) == "fn")
    }

    /// Focus is nil off a permission screen, which is what stops the view model logging elsewhere.
    @Test func focusIsOnlyEverSetOnAPermissionScreen() {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        #expect(m.permissionFocus == nil, "welcome has no permission in focus")
        m.handle(.next)
        #expect(m.step == .microphone, "all granted skips straight to the meter")
        #expect(m.permissionFocus == nil)
    }

    /// One line per transition: entering, requesting, and each advance are all distinct pairs, and
    /// a repeated status refresh that changes nothing produces the same pair (so nothing is logged).
    /// Granting the microphone drops focus to nil (the meter is what's left to show on this same
    /// screen — DESIGN §11.2); focus picks back up on Input Monitoring once Accessibility opens.
    @Test func everyAdvanceIsADistinctPairAndASteadyPollIsNot() {
        var m = fullWalkM()
        m.handle(.next)
        var seen: [String] = []
        func note() {
            guard let f = m.permissionFocus else { return }
            let line = M.transitionLog(permission: f.permission,
                                       status: m.statuses[f.permission] ?? .notDetermined, phase: f.phase)
            if line != seen.last { seen.append(line) }
        }
        note()
        m.handle(.allow(.microphone)); note()
        // Two poll ticks that learn nothing new must not add a line.
        m.handle(.statusRefreshed(.microphone, .notDetermined)); note()
        m.handle(.statusRefreshed(.microphone, .notDetermined)); note()
        m.handle(.permissionResult(.microphone, .granted)); note()
        #expect(m.permissionFocus == nil, "the meter is on screen now, not a permission")
        m.handle(.next); note()   // Continue past the meter onto Accessibility

        // Three transitions, not five: the two steady polls in the middle add nothing.
        #expect(seen == ["onboarding: microphone status=notDetermined phase=explain",
                         "onboarding: microphone status=notDetermined phase=requesting",
                         "onboarding: inputMonitoring status=notDetermined phase=explain"])
    }
}

@Suite("Onboarding state machine (P1.9 T1/T2)")
struct OnboardingStateMachineTests {
    typealias M = OnboardingStateMachine

    /// The seven steps, in order, with every permission granted and a model install running the
    /// whole time in the background (never gating anything — DESIGN §11.1).
    @Test func happyPathAllGranted() {
        var m = fullWalkM()
        #expect(m.step == .welcome)
        // The install starts the moment onboarding opens (the view model sends this from `init`);
        // it never blocks a single step below.
        #expect(m.handle(.installModels) == [.checkModelPresence, .startDownload, .checkRecognizerReadiness])
        #expect(m.handle(.next) == [])
        #expect(m.step == .microphone, "step 2 of 7")
        #expect(m.currentPermission == .microphone)

        #expect(m.handle(.allow(.microphone)) == [.requestPermission(.microphone), .rememberRequested(.microphone)])
        #expect(m.permissionPhase == .requesting)
        #expect(m.handle(.permissionResult(.microphone, .granted)) == [.startMicMonitoring])
        #expect(m.currentPermission == nil, "the meter is what's left on this screen, not a permission")
        #expect(m.step == .microphone)

        // A quiet first block is not yet a verdict — see `quietVerdictWaitsForEnoughRealAudio`.
        m.handle(.micCaptureBegan(real: true))
        m.handle(.micLevel(0.02)); #expect(m.micVerdict == .waiting)
        m.handle(.micLevel(0.4)); #expect(m.micVerdict == .good)
        m.handle(.micLevel(0.99)); #expect(m.micVerdict == .clipping)
        // A half-finished install never blocks Continue off the meter.
        let half = ModelDownloadProgress(fraction: 0.5, bytesReceived: 250_000_000,
                                         bytesExpected: 500_000_000, modelName: "Parakeet TDT 0.6B v3")
        m.handle(.downloadProgress(half)); #expect(m.download == .downloading(half))
        #expect(m.handle(.next) == [.stopMicMonitoring], "step 3 of 7")
        #expect(m.step == .accessibility)
        #expect(m.currentPermission == .inputMonitoring)

        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        #expect(m.currentPermission == .accessibility)
        m.handle(.allow(.accessibility))
        let effects = m.handle(.permissionResult(.accessibility, .granted))
        // Step 4 of 7 — the Model step, because the install is still running; it never holds
        // Continue shut.
        #expect(effects == [.checkRecognizerReadiness], "step 4 of 7, still installing")
        #expect(m.step == .model)
        #expect(m.allPermissionsGranted)
        #expect(m.download.isInFlight)
        #expect(m.modelPhase == .downloading(half))
        #expect(m.handle(.next) == [.checkRecognizerReadiness, .beginGuidedDictation], "step 5 of 7")
        #expect(m.step == .firstDictation)

        m.handle(.downloadFinished)
        #expect(m.download == .installed)
        #expect(m.needsModelLoad)
        m.handle(.modelLoadStarted); m.handle(.modelLoadFinished(.loaded(name: "Parakeet TDT 0.6B v3")))
        #expect(m.modelPhase == .ready(name: "Parakeet TDT 0.6B v3"))
        m.handle(.dictationFinished(.landed(text: "hello", app: "Notes")))
        #expect(m.landedText == "hello")
        #expect(m.handle(.next) == [], "step 6 of 7 — Voice")
        #expect(m.step == .voice)
        #expect(m.handle(.beginVoiceEnrollment) == [.startVoiceEnrollment])
        m.handle(.voiceEnrolled(filtering: true))
        #expect(m.handle(.next) == [.finish(skipped: false)], "step 7 of 7")
        #expect(m.step == .done)
        #expect(m.readyVerdict == .ready)
        #expect(m.handle(.next) == [])
    }

    @Test func deniedMicrophoneShowsSettingsThenVerifyRecovers() {
        var m = fullWalkM()
        m.handle(.next)
        m.handle(.allow(.microphone))
        #expect(m.handle(.permissionResult(.microphone, .denied)) == [])
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        #expect(m.currentPermission == .microphone)
        #expect(m.handle(.verify(.microphone)) == [.checkPermission(.microphone)])
        // Verify comes back granted after the user flipped it in System Settings — the meter is
        // what's left on this same screen now, not the next permission.
        m.handle(.permissionResult(.microphone, .granted))
        #expect(m.currentPermission == nil)
        #expect(m.step == .microphone)
        // Continuing past the meter is what reaches Input Monitoring.
        m.handle(.next)
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .explain)
    }

    /// BUG 1, the exact shape the user hit: `CGRequestListenEventAccess()` returns false without
    /// prompting, so the request resolves to `.awaitingUserAction`. That must expose the escape
    /// hatches, not bounce back to a lone "Allow" button.
    @Test func awaitingUserActionNeverReturnsToExplain() {
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
        advanceToFirstOpenPermission(&m)
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
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
        advanceToFirstOpenPermission(&m)
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
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
        advanceToFirstOpenPermission(&m)
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
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
        advanceToFirstOpenPermission(&m)
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring))
        m.handle(.permissionResult(.inputMonitoring, .awaitingUserAction))
        m.handle(.skip)
        #expect(m.step == .accessibility)
        #expect(m.currentPermission == .accessibility)   // was unreachable before the fix
        m.handle(.allow(.accessibility))
        m.handle(.permissionResult(.accessibility, .granted))
        #expect(m.step == .model)
        #expect(m.statuses[.accessibility] == .granted)
    }

    /// Every permission refused still terminates: continuing past each one never loops. With the
    /// microphone itself refused, "Continue anyway" leaves the meter screen for good (R6.2 — the
    /// ask and its denial share one screen, so once denied-and-continued there is nothing left of
    /// it to revisit) rather than looping back through it later.
    @Test func allThreeRefusedStillTerminates() {
        var m = fullWalkM()
        m.handle(.next)
        for p in m.permissionOrder {
            #expect(m.currentPermission == p)
            m.handle(.allow(p))
            m.handle(.permissionResult(p, .awaitingUserAction))
            #expect(m.permissionPhase.isNeedsSystemSettings)
            m.handle(.next)
        }
        // Every permission refused, and the walk still reached the end rather than looping.
        #expect(m.step == .model)
        #expect(m.micVerdict != .good, "nothing may pretend the refused microphone passed")
        #expect(m.statuses[.microphone] == .awaitingUserAction)
        #expect(m.currentPermission == nil)
        m.handle(.skip); m.handle(.skip); m.handle(.skip)   // Model, Try dictation, Voice
        #expect(m.step == .done)
        #expect(m.readyVerdict == .notReady([.P01, .M01]), "Ready never claims a setup that cannot dictate")
    }

    /// A *non-promptable* permission macOS has already been asked for on an earlier launch skips the
    /// useless Allow button: `CGRequestListenEventAccess()` can never raise a dialog, so re-offering
    /// one would be the lie. This must NOT generalise to promptable services — see the suite below.
    @Test func alreadyRequestedPermissionStartsInSettingsPhase() {
        var m = fullWalkM(initialStatuses: [.microphone: .granted], alreadyRequested: [.inputMonitoring])
        advanceToFirstOpenPermission(&m)
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        m.handle(.statusRefreshed(.inputMonitoring, .granted))
        // Accessibility was never requested, so it still gets the honest first-run Allow button.
        #expect(m.currentPermission == .accessibility)
        #expect(m.permissionPhase == .explain)
    }

    /// A denied microphone, continued past, never gets a second look — the ask and its denial share
    /// one screen (R6.2 / DESIGN §11.2), so "Continue anyway" there leaves the meter behind for
    /// good rather than looping back to a blocked version of it once the other permissions resolve.
    @Test func deniedMicrophoneSkippedNeverRevisitsTheMeter() {
        var m = fullWalkM()
        m.handle(.next)
        m.handle(.allow(.microphone)); m.handle(.permissionResult(.microphone, .denied))
        m.handle(.next)  // "Continue anyway"
        #expect(m.step == .accessibility)
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        m.handle(.allow(.accessibility))
        let effects = m.handle(.permissionResult(.accessibility, .denied))
        #expect(effects == [])
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        // Skipping the last denied permission reaches the Model step directly — no capture was ever
        // started, and there is no way to reach a passing verdict.
        let skipEffects = m.handle(.next)
        #expect(m.step == .model)
        #expect(m.micVerdict != .good)
        #expect(!skipEffects.contains(.startMicMonitoring))
        #expect(m.statuses[.microphone] == .denied)
    }

    /// Skip is offered on every step but Welcome and Done (DESIGN §11.1's "no Skip everything" on
    /// Welcome is a view-layer choice; the state machine still has to survive a stray one) and the
    /// walk still terminates: seven steps, six skips.
    @Test func skipEverythingStillFinishes() {
        var m = M()
        #expect(m.handle(.skip) == [])  // welcome skip → Microphone, blocked (no mic grant)
        #expect(m.step == .microphone)
        #expect(m.micVerdict == .permissionRequired)
        #expect(m.handle(.skip) == [.stopMicMonitoring])  // Microphone skip → Accessibility
        #expect(m.step == .accessibility)
        // The Model step names whatever would stand in for a missing stack.
        #expect(m.handle(.skip) == [.checkRecognizerReadiness])
        #expect(m.step == .model)
        // Entering the dictation step now asks which recogniser is available first, so the screen
        // can name it instead of presenting a test that may not be able to work.
        #expect(m.handle(.skip) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(m.step == .firstDictation)
        #expect(m.handle(.skip) == [])
        #expect(m.step == .voice)
        #expect(m.handle(.skip) == [.finish(skipped: true)])
        #expect(m.step == .done)
        #expect(!m.stackInstalled)  // nothing landed, and the machine says so rather than guessing
    }

    /// A failed download is never a reason to hold anyone on any step (DESIGN §11.1 — "never a
    /// blocking progress screen"). It just keeps being told about, honestly, wherever it appears.
    @Test func failedDownloadNeverBlocksAStepAndStaysHonestAboutWhy() {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        #expect(m.handle(.installModels) == [.checkModelPresence, .startDownload, .checkRecognizerReadiness])
        #expect(m.handle(.next) == [.startMicMonitoring])   // all granted → straight to the meter
        #expect(m.step == .microphone)
        #expect(m.handle(.downloadFailed("offline")) == [.checkModelPresence, .checkRecognizerReadiness])
        #expect(m.download == .failed("offline"))
        #expect(m.modelInstallStatusLine?.contains("offline") == true)
        // Continue works regardless — a failed background download is not this step's problem.
        // (Accessibility was already granted too, so this reaches the Model step directly, which
        // says what failed and still lets Continue through.)
        #expect(m.handle(.next) == [.stopMicMonitoring, .checkRecognizerReadiness])
        #expect(m.step == .model)
        #expect(m.modelPhase == .downloadFailed("offline"))
        #expect(m.handle(.next) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(m.step == .firstDictation)
    }

    @Test func pregrantedPermissionsAreSkippedInOrder() {
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
        advanceToFirstOpenPermission(&m)
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
        m.handle(.next)   // past the meter
        #expect(m.step == .model)   // accessibility already granted → Accessibility skipped entirely
    }

    @Test func backNavigation() {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        m.handle(.next)
        #expect(m.step == .microphone)
        m.handle(.next)
        #expect(m.step == .model, "both permissions already granted, so Accessibility is skipped too")
        #expect(m.handle(.back) == [])
        #expect(m.step == .accessibility)
        #expect(m.handle(.back) == [.startMicMonitoring])
        #expect(m.step == .microphone)
        var denied = M(initialStatuses: [.microphone: .denied])
        denied.handle(.skip)
        #expect(denied.step == .microphone)
        denied.handle(.skip)
        #expect(denied.step == .accessibility)
        denied.handle(.back)
        #expect(denied.step == .microphone)
        var fresh = M()
        #expect(fresh.handle(.back) == [])
    }

    // MARK: BUG 2 — the verdict may only speak about audio that actually arrived

    private func atMicCheck() -> M {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        m.handle(.next)
        precondition(m.step == .microphone)
        // Every one of these cases is about audio that did or did not arrive from a *real* capture
        // stack, which the view model declares before the first level.
        m.handle(.micCaptureBegan(real: true))
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

/// The 1.6.2 microphone regression: the onboarding screen opened straight on the settings-recovery
/// phase, so `AVCaptureDevice.requestAccess(for: .audio)` — reachable only from the `.explain`
/// phase's Allow button — was never called. Because that call is the ONLY way an app appears in
/// System Settings › Privacy & Security › Microphone (the pane has no "+"), the user could not
/// escape: `tccutil reset Microphone` cleared TCC but not the persisted "asked once" flag, so every
/// relaunch landed on the same dead end telling them to enable an app that was not in the list.
@Suite("Promptable vs non-promptable permissions (1.6.3 regression)")
struct PromptablePermissionTests {
    typealias M = OnboardingStateMachine

    @Test func onlyMicrophoneIsPromptable() {
        #expect(OnboardingPermission.microphone.isPromptable)
        #expect(!OnboardingPermission.inputMonitoring.isPromptable)
        #expect(!OnboardingPermission.accessibility.isPromptable)
        // Same fact, one source of truth, so the core matrix and onboarding can never disagree.
        #expect(Permission.microphone.isPromptable)
        #expect(!Permission.inputMonitoring.isPromptable)
        #expect(!Permission.accessibility.isPromptable)
    }

    /// THE regression, at the unit level: the persisted flag must never suppress a real request for a
    /// promptable service whose live status is `notDetermined`.
    @Test func askedOnceFlagDoesNotSuppressAPromptableRequest() {
        var m = M(initialStatuses: [.microphone: .notDetermined], alreadyRequested: [.microphone])
        m.handle(.next)
        #expect(m.currentPermission == .microphone)
        #expect(m.permissionPhase == .explain, "a notDetermined microphone must offer the real request")
        #expect(!m.permissionPhase.isNeedsSystemSettings)
        // …and the Allow button really does reach the API.
        #expect(m.handle(.allow(.microphone)) == [.requestPermission(.microphone), .rememberRequested(.microphone)])
    }

    /// Generalised: for every promptable service, `notDetermined` means "ask", flag or no flag; for
    /// every non-promptable one the flag still short-circuits to the recovery phase.
    @Test func initialPhaseSplitsOnPromptability() {
        for p in OnboardingPermission.allCases {
            let flagged = M.initialPhase(for: p, requested: [p], status: .notDetermined)
            #expect(flagged == (p.isPromptable ? .explain : .needsSystemSettings(recheckAttempts: 0)),
                    "\(p.rawValue) with the asked-once flag and a notDetermined status")
            #expect(M.initialPhase(for: p, requested: [], status: .notDetermined) == .explain)
            // A real denial is a real denial for everyone: the row exists, so Settings can fix it.
            #expect(M.initialPhase(for: p, requested: [p], status: .denied)
                    == .needsSystemSettings(recheckAttempts: 0))
        }
    }

    /// A dialog that was dismissed leaves TCC undecided. Retrying is the only cure, so the screen has
    /// to stay on the Allow button rather than filing it under "go to System Settings".
    @Test func dismissedPromptStaysRetryableInsteadOfBecomingASettingsProblem() {
        var m = M()
        m.handle(.next)
        m.handle(.allow(.microphone))
        #expect(m.handle(.permissionResult(.microphone, .notDetermined)) == [])
        #expect(m.permissionPhase == .explain)
        #expect(m.currentPermission == .microphone)
        #expect(m.handle(.allow(.microphone)) == [.requestPermission(.microphone), .rememberRequested(.microphone)])
        // The same answer from a non-promptable service is genuinely a Settings problem.
        var im = fullWalkM(initialStatuses: [.microphone: .granted])
        advanceToFirstOpenPermission(&im)
        im.handle(.allow(.inputMonitoring))
        im.handle(.permissionResult(.inputMonitoring, .notDetermined))
        #expect(im.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
    }

    /// "Re-check" on an undecided promptable service must re-invoke the API, not re-read a status
    /// that can never change on its own — the in-app escape hatch for anyone already stuck.
    @Test func recheckReAsksMacOSForAnUndecidedPromptableService() {
        var m = M(initialStatuses: [.microphone: .denied], alreadyRequested: [.microphone])
        m.handle(.next)
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        // Denied: the row exists, so a status read is the right question.
        #expect(m.handle(.verify(.microphone)) == [.checkPermission(.microphone)])
        // Undecided: no row exists, so a status read can only ever return the same nothing — only
        // the API can create the row. Re-check must therefore ask macOS for real.
        var undecided = M(initialStatuses: [.microphone: .awaitingUserAction], alreadyRequested: [.microphone])
        undecided.handle(.next)
        undecided.handle(.statusRefreshed(.microphone, .notDetermined))
        #expect(undecided.handle(.verify(.microphone))
                == [.requestPermission(.microphone), .rememberRequested(.microphone)])
        #expect(undecided.permissionPhase == .requesting)
        // Never for a non-promptable one: there is no API that could prompt.
        var im = fullWalkM(initialStatuses: [.microphone: .granted], alreadyRequested: [.inputMonitoring])
        advanceToFirstOpenPermission(&im)
        #expect(im.handle(.verify(.inputMonitoring)) == [.checkPermission(.inputMonitoring)])
    }

    /// `tccutil reset Microphone` drops the status back to `notDetermined` behind the app's back. The
    /// poll must notice, drop the stale flag and put the Allow button back — without any clicking.
    @Test func tccResetSelfHealsTheStalePhaseAndFlag() {
        var m = M(initialStatuses: [.microphone: .denied], alreadyRequested: [.microphone])
        m.handle(.next)
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        #expect(m.requestedPermissions.contains(.microphone))
        #expect(m.handle(.statusRefreshed(.microphone, .notDetermined)) == [.forgetRequested(.microphone)])
        #expect(m.permissionPhase == .explain)
        #expect(!m.requestedPermissions.contains(.microphone))
        #expect(m.handle(.allow(.microphone)) == [.requestPermission(.microphone), .rememberRequested(.microphone)])
        // A non-promptable service has nothing to heal into: no prompt exists for it either way.
        var im = fullWalkM(initialStatuses: [.microphone: .granted], alreadyRequested: [.inputMonitoring])
        advanceToFirstOpenPermission(&im)
        #expect(im.handle(.statusRefreshed(.inputMonitoring, .notDetermined)) == [])
        #expect(im.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
    }

    // MARK: Copy — the old text was wrong on both counts for the microphone

    @Test func promptableRecoveryCopyNeverSendsTheUserToAPaneWithNoPlusButton() {
        let undecided = OnboardingPermission.microphone.recoveryCopy(status: .notDetermined, attempts: 0)
        let text = undecided.headline + (undecided.detail ?? "")
        #expect(!text.contains("only asks once"), "false: after a tccutil reset macOS asks again")
        #expect(!text.contains("“+”") || text.contains("no “+” button"),
                "the Microphone pane has no “+”, so the user cannot add the app by hand")
        #expect(undecided.retryTitle == "Ask macOS again", "the only cure must be one button away")
        #expect(undecided.showsResetCommand)
        // Escalation must not silently reintroduce the wrong advice.
        let escalated = OnboardingPermission.microphone.recoveryCopy(status: .notDetermined, attempts: 3)
        #expect(escalated == undecided)
        #expect(!escalated.headline.contains("only asks once"))
    }

    @Test func deniedMicrophoneCopyPointsAtTheSwitchThatNowExists() {
        let denied = OnboardingPermission.microphone.recoveryCopy(status: .denied, attempts: 0)
        #expect(denied.headline.contains("Privacy & Security › Microphone"))
        #expect(denied.retryTitle == nil, "after a Don't Allow the dialog cannot be reopened")
        #expect(!denied.showsResetCommand)
        #expect(!denied.headline.contains("only asks once"))
    }

    /// The identity is pinned so the assertion is about the copy, not about however the test binary
    /// happens to be signed. The escalated wording itself is covered in OnboardingCodeIdentityTests.
    @Test func nonPromptableCopyKeepsTheSettingsFirstInstructions() {
        let installed = AppCodeIdentity(designatedRequirement: #"cdhash H"ab""#,
                                        bundlePath: "/Applications/VoicePlus.app")
        for p in OnboardingPermission.allCases where !p.isPromptable {
            let first = p.recoveryCopy(status: .awaitingUserAction, attempts: 0, identity: installed)
            #expect(first.headline.contains(p.settingsListName))
            #expect(first.retryTitle == nil, "no API can prompt for \(p.rawValue)")
            let escalated = p.recoveryCopy(status: .awaitingUserAction, attempts: 2, identity: installed)
            #expect(escalated.steps.contains { $0.contains("“+”") }, "these panes really do have +/–")
            #expect(escalated.showsResetCommand)
        }
    }
}

@Suite("Onboarding view model integration")
@MainActor
struct OnboardingViewModelTests {
    @Test func deniedMicThenOpenSettingsCallsChecker() async throws {
        var deps = OnboardingDependencies.mock(permissionResults: [.microphone: .denied])
        // The escape-hatch walk — this test is about the Input Monitoring step itself, which a
        // default install no longer visits (see `OnboardingSkipsInputMonitoringTests`).
        deps.hotkeyRequiresPermission = .inputMonitoring
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.permissionPhase.isNeedsSystemSettings }
        vm.openSettings(for: .microphone)
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        #expect(checker.openedSettings == [.microphone])
        checker.statuses[.microphone] = .granted
        vm.send(.verify(.microphone))
        // The grant reveals the meter on this same screen; Continue is what reaches Input Monitoring.
        #expect(vm.machine.currentPermission == nil)
        #expect(vm.step == .microphone)
        vm.send(.next)
        #expect(vm.machine.currentPermission == .inputMonitoring)
    }

    @Test func fullRunWithMocksFinishesAndDownloads() async throws {
        // Opting in explicitly: this walk is about everything *after* capture, so the synthetic
        // meter has to declare that it is standing in for a microphone.
        var deps = OnboardingDependencies.mock(pretendRealMicCapture: true)
        // A voice already enrolled on this Mac: the Voice step has nothing to ask (V4.48).
        deps.isVoiceEnrolled = { true }
        let vm = OnboardingViewModel(dependencies: deps)
        var finished: Bool?
        vm.onFinished = { finished = $0 }
        // The install already started the moment `vm` was created (R6.2 §11.1) — no step gates it.
        vm.send(.next)
        #expect(vm.step == .microphone)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.statuses[.microphone] == .granted }
        #expect(vm.step == .microphone, "the meter is what's left on this screen, not Accessibility")
        let mic = try #require(deps.micLevel as? OnboardingMockMicLevelPublisher)
        #expect(mic.monitoring)
        mic.send(0.5)
        try await waitUntil { vm.machine.micVerdict == .good }
        #expect(vm.micLevel == 0.5)
        vm.send(.next)
        #expect(!mic.monitoring)
        #expect(vm.step == .accessibility)
        // The install ran itself in the background the whole time; nothing was chosen or pressed.
        try await waitUntil { vm.machine.download == .installed }
        #expect(deps.models.isStackInstalled)
        vm.send(.allow(.accessibility))
        try await waitUntil { vm.machine.statuses[.accessibility] == .granted }
        // The stack is on disk, so the Model step has nothing to ask and is passed through.
        #expect(vm.step == .firstDictation)
        try await waitUntil { vm.machine.modelPhase.isReady }
        // Two presses, because one press cannot contain an utterance (see `startGuidedDictation`).
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        vm.finishGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(vm.machine.heardText?.contains("quick brown fox") == true)
        vm.send(.next)   // Try dictation → Voice (already enrolled, so straight on) → Ready
        #expect(vm.step == .done)
        #expect(finished == false)
        #expect(deps.settingsStore.bool(SettingsKeys.onboardingCompleted) == true)
        #expect(vm.showContactsOffer)
        #expect(!OnboardingWindowController.isNeeded(settings: deps.settingsStore))
    }

    /// BUG 1 end-to-end through the view model: the request resolves to `.awaitingUserAction`
    /// (what the real TCC calls do), and the 0.5 s poll picks up the grant made in System Settings
    /// with no further clicks — the checkmark flips and the step advances to Accessibility.
    @Test func pollingPicksUpAGrantMadeInSystemSettings() async throws {
        var deps = OnboardingDependencies.mock(permissionResults: [
            .microphone: .granted, .inputMonitoring: .awaitingUserAction,
        ])
        // The escape-hatch walk — this test is about the Input Monitoring step itself, which a
        // default install no longer visits (see `OnboardingSkipsInputMonitoringTests`).
        deps.hotkeyRequiresPermission = .inputMonitoring
        let vm = OnboardingViewModel(dependencies: deps)
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.statuses[.microphone] == .granted }
        vm.send(.next)   // past the meter, onto Input Monitoring
        #expect(vm.machine.currentPermission == .inputMonitoring)
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
        // The escape-hatch walk — this test is about the Input Monitoring step itself, which a
        // default install no longer visits (see `OnboardingSkipsInputMonitoringTests`).
        deps.hotkeyRequiresPermission = .inputMonitoring
        deps.settingsStore = store
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.statuses[.microphone] == .granted }
        vm.send(.next)   // past the meter, onto Input Monitoring
        #expect(vm.machine.currentPermission == .inputMonitoring)
        vm.send(.allow(.inputMonitoring))
        try await waitUntil { store.bool("onboarding.requested.inputMonitoring") == true }
        vm.teardown()

        var relaunch = OnboardingDependencies.mock(permissionResults: [.inputMonitoring: .awaitingUserAction])
        // The escape-hatch walk — this test is about the Input Monitoring step itself, which a
        // default install no longer visits (see `OnboardingSkipsInputMonitoringTests`).
        relaunch.hotkeyRequiresPermission = .inputMonitoring
        relaunch.settingsStore = store
        let second = OnboardingViewModel(dependencies: relaunch)
        // S8: the relaunch resumes on the step setup was left on (design §8.7) — Input Monitoring.
        #expect(second.step == .accessibility)
        #expect(second.machine.currentPermission == .inputMonitoring)
        #expect(second.machine.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        second.teardown()
    }

    /// The user's exact broken state, end to end: `onboarding.requested.microphone == 1` left over
    /// from an earlier build, microphone status back to `notDetermined` after `tccutil reset`. The
    /// app MUST still reach the real request API — that call is the only thing that puts VoicePlus
    /// into System Settings › Privacy & Security › Microphone. Before the fix this asserted zero
    /// requests and a `needsSystemSettings` phase with no Allow button anywhere on screen.
    @Test func staleAskedOnceFlagStillReachesTheRealMicrophoneRequest() async throws {
        let store = InMemorySettingsStore()
        store.set(true, for: "onboarding.requested.microphone")
        store.set(true, for: "onboarding.requested.inputMonitoring")
        var deps = OnboardingDependencies.mock()
        // The escape-hatch walk — this test is about the Input Monitoring step itself, which a
        // default install no longer visits (see `OnboardingSkipsInputMonitoringTests`).
        deps.hotkeyRequiresPermission = .inputMonitoring
        deps.settingsStore = store
        let vm = OnboardingViewModel(dependencies: deps)
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        #expect(checker.status(of: .microphone) == .notDetermined)

        vm.send(.next)
        #expect(vm.machine.currentPermission == .microphone)
        #expect(vm.machine.permissionPhase == .explain, "the Allow button is the only path to requestAccess")
        #expect(checker.requests.isEmpty)

        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.statuses[.microphone] == .granted }
        #expect(checker.requests == [.microphone], "AVCaptureDevice.requestAccess must actually be called")
        vm.send(.next)   // past the meter
        // Input Monitoring is non-promptable, so its flag legitimately keeps the recovery-first shape.
        #expect(vm.machine.currentPermission == .inputMonitoring)
        #expect(vm.machine.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        vm.teardown()
    }

    /// And the in-app escape hatch for a build that is already installed: a promptable service whose
    /// TCC row was deleted heals back to the Allow button on the next 0.5 s poll, clearing the stale
    /// flag from disk so the dead end cannot come back on the next launch — no Terminal required.
    @Test func resetMicrophoneHealsBackToTheAllowButtonWhileTheAppIsRunning() async throws {
        let store = InMemorySettingsStore()
        var deps = OnboardingDependencies.mock(permissionResults: [.microphone: .denied])
        deps.settingsStore = store
        let vm = OnboardingViewModel(dependencies: deps)
        let checker = try #require(deps.permissions as? OnboardingMockPermissionChecker)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.permissionPhase.isNeedsSystemSettings }
        #expect(store.bool("onboarding.requested.microphone") == true)

        // `tccutil reset Microphone in.adityakatare.voiceplus` — the row disappears.
        checker.statuses[.microphone] = .notDetermined
        try await waitUntil(timeoutMs: 4000) { vm.machine.permissionPhase == .explain }
        #expect(store.bool("onboarding.requested.microphone") == false, "the stale flag must not survive")
        vm.send(.allow(.microphone))
        try await waitUntil { checker.requests.count == 2 }
        vm.teardown()
    }

    /// BUG 2 through the view model: a capture that fails to start says why, instead of the meter
    /// sitting at zero under "Very quiet".
    @Test func micCaptureFailureReachesTheScreen() async throws {
        let deps = OnboardingDependencies.mock(pretendRealMicCapture: true)
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.skip)                      // welcome → Microphone, blocked (no grant)
        #expect(vm.step == .microphone)
        vm.send(.back)                      // back to Welcome
        vm.send(.next)                      // into Microphone again
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.statuses[.microphone] == .granted }
        #expect(vm.step == .microphone, "the meter is what's on screen once the microphone alone is granted")
        let mic = try #require(deps.micLevel as? OnboardingMockMicLevelPublisher)
        mic.fail("noInputDevice")
        try await waitUntil { vm.machine.micVerdict == .unavailable("noInputDevice") }
        #expect(vm.micLevel == 0)
        vm.teardown()
    }

    /// The watchdog fires when capture is up but silent, and says so honestly.
    @Test func noAudioWatchdogReportsSilenceNotQuietness() async throws {
        let deps = OnboardingDependencies.mock(pretendRealMicCapture: true)
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.statuses[.microphone] == .granted }
        #expect(vm.step == .microphone)
        #expect(vm.machine.micVerdict == .waiting)
        try await waitUntil(timeoutMs: 6000) { vm.machine.micVerdict == .noAudio }
        vm.teardown()
    }

    /// R6.2 — a failed background install is never a step's problem (DESIGN §11.1: "never a
    /// blocking progress screen"). It shows up as an honest line, not a wall.
    @Test func downloadFailureIsNonBlocking() async throws {
        let deps = OnboardingDependencies.mock()
        (deps.models as? OnboardingMockModelManager)?.failDownload = true
        let vm = OnboardingViewModel(dependencies: deps)   // the install started itself right here
        vm.send(.skip); vm.send(.skip)   // welcome → blocked Microphone → Accessibility
        #expect(vm.step == .accessibility)
        try await waitUntil { if case .failed = vm.machine.download { return true }; return false }
        #expect(vm.machine.modelInstallStatusLine?.contains("didn't finish installing") == true)
        // Continue just continues — a failed model install is never any step's wall.
        vm.send(.next)
        #expect(vm.step == .model)
        vm.send(.next)
        #expect(vm.step == .firstDictation)
    }
}

/// Polls an eventual condition. The deadline is a hang guard, not a latency assertion: a full
/// parallel `AppTests` run can stall the main actor for 20 s+, and a tight deadline then fails every
/// waiter at once. So `timeoutMs` is only a floor under `waitUntilHangGuardMs`.
let waitUntilHangGuardMs = 60_000

func waitUntil(timeoutMs: Int = 2000, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(max(timeoutMs, waitUntilHangGuardMs)) / 1000)
    while !(await condition()) {
        try #require(Date() < deadline, "timed out waiting for condition")
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - S8 · Onboarding (design §8.7, V4.48, I1)

/// The verified design's six steps plus the owner's Voice step, the Model step's honest phases, the
/// resume point, every skip path, and I1's fn prompt and Right ⌥ fallback — all on the pure machine.
@Suite("S8 — onboarding state machine: new steps, resume, skip paths, fn fallback")
struct OnboardingS8StateMachineTests {
    typealias M = OnboardingStateMachine
    static let granted: [OnboardingPermission: OnboardingPermissionStatus] =
        [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted]

    /// Welcome → Microphone (meter) → Model, with every permission granted and nothing installed.
    private func atModel(installed: Bool = false) -> M {
        var m = M(initialStatuses: Self.granted)
        if installed { m.handle(.modelPresenceChanged(true)) }
        m.handle(.next)   // → Microphone (granted: the meter)
        m.handle(.next)   // → Typing access, granted → Model
        return m
    }

    private func atTry() -> M {
        var m = atModel()
        m.handle(.next)
        precondition(m.step == .firstDictation)
        return m
    }

    private func atVoice(voiceEnrolled: Bool = false) -> M {
        var m = M(initialStatuses: Self.granted, voiceEnrolled: voiceEnrolled)
        m.handle(.next); m.handle(.next)   // → Microphone (the meter) → Typing access, granted → Model
        m.handle(.next)                    // → Try dictation
        m.handle(.next)                    // → Voice (or straight past it)
        precondition(m.step == (voiceEnrolled ? .done : .voice))
        return m
    }

    // MARK: The steps

    @Test func sevenStepsInTheDesignsOrderWithTheOwnersVoiceStep() {
        #expect(M.Step.allCases == [.welcome, .microphone, .accessibility, .model, .firstDictation, .voice, .done])
        #expect(M.stepCount == 7)
        var m = M()
        #expect(m.stepNumber == 1)
        #expect(abs(m.progress - 1.0 / 7) < 1e-9, "the prototype's bar already shows the first segment")
        m.handle(.skip)
        #expect(m.stepNumber == 2)
        #expect(OnboardingCopy.eyebrow(step: m.stepNumber, of: M.stepCount) == "Setup · 2 of 7")
    }

    @Test func voiceComesAfterTryDictationAndBeforeReady() {
        var m = atTry()
        #expect(m.handle(.next) == [])
        #expect(m.step == .voice)
        #expect(m.handle(.back) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(m.step == .firstDictation)
    }

    // MARK: Model — real bytes → Verifying → Loading → Ready (never Ready before the load)

    @Test func modelPhasesAreBytesThenVerifyingThenLoadingThenReady() {
        var m = atModel()
        #expect(m.step == .model)
        #expect(m.modelPhase == .notStarted)
        #expect(m.handle(.installModels) == [.checkModelPresence, .startDownload, .checkRecognizerReadiness])
        #expect(m.modelPhase == .starting)
        let partway = ModelDownloadProgress(fraction: 0.4, bytesReceived: 400, bytesExpected: 1000, modelName: "Parakeet TDT 0.6B v3")
        m.handle(.downloadProgress(partway))
        #expect(m.modelPhase == .downloading(partway))
        let allBytes = ModelDownloadProgress(fraction: 1, bytesReceived: 1000, bytesExpected: 1000, modelName: "Parakeet TDT 0.6B v3")
        m.handle(.downloadProgress(allBytes))
        #expect(m.modelPhase == .verifying, "every byte in is not a verified model")
        m.handle(.downloadFinished)
        #expect(m.modelPhase == .loading, "verified files are not a loaded model")
        #expect(!m.modelPhase.isReady)
        #expect(m.needsModelLoad)
        m.handle(.modelLoadStarted)
        #expect(m.modelPhase == .loading)
        #expect(!m.needsModelLoad, "one load at a time")
        #expect(m.handle(.modelLoadFinished(.loaded(name: "Parakeet TDT 0.6B v3"))) == [.checkRecognizerReadiness])
        #expect(m.modelPhase == .ready(name: "Parakeet TDT 0.6B v3"))
    }

    @Test func aFailedLoadSaysSoAndCanBeRetried() {
        var m = atModel()
        m.handle(.downloadFinished)
        m.handle(.modelLoadStarted)
        m.handle(.modelLoadFinished(.failed("The speech model isn’t ready")))
        #expect(m.modelPhase == .loadFailed("The speech model isn’t ready"))
        #expect(!m.needsModelLoad)
        m.handle(.retryModelLoad)
        #expect(m.needsModelLoad)
        #expect(m.modelPhase == .loading)
    }

    @Test func modelNeverHoldsContinueShut() {
        var m = atModel()
        m.handle(.installModels)
        m.handle(.downloadProgress(ModelDownloadProgress(fraction: 0.03, bytesReceived: 3, bytesExpected: 100, modelName: "x")))
        #expect(m.handle(.next) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(m.step == .firstDictation)
        var failed = atModel()
        failed.handle(.downloadFailed("offline"))
        #expect(failed.modelPhase == .downloadFailed("offline"))
        failed.handle(.readinessChanged(.fallback(name: "Apple Speech (on-device)", awaiting: nil)))
        failed.handle(.next)
        #expect(failed.step == .firstDictation, "interrupted → keep going on what is on this Mac")
    }

    @Test func anInstalledStackPassesThroughModelForwardButBackLandsOnIt() {
        var m = atModel(installed: true)
        #expect(m.step == .firstDictation, "nothing to install or decide: the forward path passes through")
        #expect(m.needsModelLoad, "…and the load still runs, so Ready stays honest")
        #expect(m.handle(.back) == [.checkRecognizerReadiness])
        #expect(m.step == .model, "Back lands on the step instead of bouncing forward")
        #expect(m.modelPhase == .loading)
    }

    @Test func theLoadWaitsForTheModelStep() {
        var m = M(initialStatuses: Self.granted)
        m.handle(.modelPresenceChanged(true))
        #expect(!m.needsModelLoad, "never on Welcome: that would race the app's own launch warm-up")
        m.handle(.next)
        #expect(!m.needsModelLoad)
        m.handle(.next)
        #expect(m.needsModelLoad)
    }

    @Test func aVanishedStackUnloads() {
        var m = atModel()
        m.handle(.downloadFinished)
        m.handle(.modelLoadStarted); m.handle(.modelLoadFinished(.loaded(name: "x")))
        m.handle(.modelPresenceChanged(false))
        #expect(m.modelLoad == .notLoaded)
        #expect(!m.modelPhase.isReady)
    }

    // MARK: Voice (V4.48) — skippable, H2 passive fallback

    @Test func skippingVoiceFinishesAsSkippedAndLeavesPassiveEnrollment() {
        var m = atVoice()
        #expect(m.step == .voice)
        #expect(m.handle(.skip) == [.finish(skipped: true)])
        #expect(m.step == .done)
        #expect(m.skippedSteps.contains(.voice))
    }

    @Test func continueWithoutEnrollingIsTheSameChoiceAsSkip() {
        var m = atVoice()
        #expect(m.handle(.next) == [.finish(skipped: true)])
        #expect(m.skippedSteps == [.voice])
    }

    @Test func enrollingFinishesWithoutASkip() {
        var m = atVoice()
        #expect(m.handle(.beginVoiceEnrollment) == [.startVoiceEnrollment])
        #expect(m.voice == .enrolling)
        #expect(m.handle(.beginVoiceEnrollment) == [], "one enrollment at a time")
        m.handle(.voiceEnrolled(filtering: true))
        #expect(m.voice == .enrolled(filtering: true))
        #expect(m.handle(.next) == [.finish(skipped: false)])
    }

    @Test func aProfileTheEmbedderCannotUseKeepsFilteringOff() {
        var m = atVoice()
        m.handle(.beginVoiceEnrollment)
        m.handle(.voiceEnrolled(filtering: false))
        #expect(m.voice == .enrolled(filtering: false), "saved, speaker filtering off (X03)")
        #expect(m.voice.isEnrolled)
    }

    @Test func leavingMidEnrollmentStopsIt() {
        var m = atVoice()
        m.handle(.beginVoiceEnrollment)
        let effects = m.handle(.back)
        #expect(effects.first == .stopVoiceEnrollment)
        #expect(m.voice == .notEnrolled)
        m.handle(.next)
        m.handle(.beginVoiceEnrollment)
        #expect(m.handle(.cancelVoiceEnrollment) == [.stopVoiceEnrollment])
        #expect(m.voice == .notEnrolled)
    }

    @Test func noRecorderIsStatedAndRetryable() {
        var m = atVoice()
        m.handle(.beginVoiceEnrollment)
        m.handle(.voiceEnrollmentUnavailable)
        #expect(m.voice == .unavailable)
        #expect(m.handle(.beginVoiceEnrollment) == [.startVoiceEnrollment])
    }

    @Test func anAlreadyEnrolledVoicePassesThroughForward() {
        let m = atVoice(voiceEnrolled: true)
        #expect(m.step == .done)
        #expect(!m.skippedSteps.contains(.voice))
    }

    // MARK: Skip paths

    @Test func everyStepAfterWelcomeCanBeSkippedAndReadyIsStillReached() {
        var m = M()
        var seen: [M.Step] = [m.step]
        while m.step != .done {
            m.handle(.skip)
            seen.append(m.step)
        }
        #expect(seen == [.welcome, .microphone, .accessibility, .model, .firstDictation, .voice, .done])
        #expect(m.skippedSteps == [.welcome, .microphone, .accessibility, .model, .firstDictation, .voice])
        #expect(m.handle(.skip) == [], "Ready is final")
        #expect(m.handle(.back) == [])
    }

    // MARK: Resume at the unfinished step (design §8.7)

    @Test func resumeReopensEachUnfinishedStepWithItsEntryEffects() {
        var mic = M()
        #expect(mic.resume(at: .microphone) == [])
        #expect(mic.step == .microphone)
        #expect(mic.currentPermission == .microphone)

        var typing = M(initialStatuses: [.microphone: .denied])
        #expect(typing.resume(at: .accessibility) == [])
        #expect(typing.step == .accessibility)
        #expect(typing.currentPermission == .accessibility, "the cursor lands on the open permission")

        var model = M()
        #expect(model.resume(at: .model) == [.checkRecognizerReadiness])
        #expect(model.step == .model)

        var tryStep = M()
        #expect(tryStep.resume(at: .firstDictation) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(tryStep.step == .firstDictation)
        #expect(tryStep.currentPermission == nil)

        var voice = M()
        #expect(voice.resume(at: .voice) == [])
        #expect(voice.step == .voice)
        #expect(voice.handle(.back) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(voice.step == .firstDictation)
    }

    @Test func resumeOntoAStepThatIsNowResolvedMovesOn() {
        var m = M(initialStatuses: Self.granted)
        m.handle(.modelPresenceChanged(true))
        m.resume(at: .accessibility)
        #expect(m.step == .firstDictation, "granted since, and installed since: nothing left on either")
    }

    @Test func resumeNeverOntoWelcomeOrReadyAndOnlyFromAFreshMachine() {
        var m = M()
        #expect(m.resume(at: .welcome) == [])
        #expect(m.resume(at: .done) == [])
        #expect(m.step == .welcome)
        m.handle(.skip)
        m.resume(at: .voice)
        #expect(m.step == .microphone, "a walk already under way is not resumed over")
    }

    // MARK: I1 — the fn prompt before the key test; Right ⌥ after three silent presses

    static let emojiConflict = FnKeyConflict(.showEmojiAndSymbols)!

    @Test func theFnSystemActionPromptComesBeforeTheKeyTest() {
        var m = atTry()
        #expect(m.keyCheck == .unknown)
        m.handle(.keyStatus(.fn, conflict: Self.emojiConflict, fnEventsSeen: 0))
        #expect(m.keyCheck == .conflict(Self.emojiConflict))
        #expect(m.handle(.checkKey) == [], "no key test while the prompt is up")
        #expect(m.handle(.fixFnConflict) == [.openKeyboardSettings])
        // Back from Keyboard settings with the setting fixed: the prompt is gone.
        m.handle(.keyStatus(.fn, conflict: nil, fnEventsSeen: 0))
        #expect(m.keyCheck == .testing(attempts: 0, prompting: false))
    }

    @Test func continueAnywayPastThePromptStartsTheKeyTest() {
        var m = atTry()
        m.handle(.keyStatus(.fn, conflict: Self.emojiConflict, fnEventsSeen: 0))
        m.handle(.dismissFnConflict)
        #expect(m.keyCheck == .testing(attempts: 0, prompting: false))
    }

    @Test func threeSilentPressesOfferRightOption() {
        var m = atTry()
        m.handle(.keyStatus(.fn, conflict: nil, fnEventsSeen: 0))
        for attempt in 1...FnKeyProbe.attemptsBeforeFallback {
            #expect(m.handle(.checkKey) == [.startKeyPromptWindow])
            #expect(m.keyCheck == .testing(attempts: attempt - 1, prompting: true))
            #expect(m.handle(.checkKey) == [], "one window at a time")
            m.handle(.keyPromptElapsed)
        }
        #expect(m.keyCheck == .offerFallback(.rightOption))
        #expect(m.handle(.useFallbackKey) == [.rebindDictationKey(.rightOption)])
        #expect(m.dictationKey == .rightOption)
        #expect(m.keyCheck == .ready(.rightOption))
    }

    @Test func tryingFnAgainForgetsTheSilentPresses() {
        var m = atTry()
        m.handle(.keyStatus(.fn, conflict: nil, fnEventsSeen: 0))
        for _ in 1...FnKeyProbe.attemptsBeforeFallback { m.handle(.checkKey); m.handle(.keyPromptElapsed) }
        m.handle(.retryFnKey)
        #expect(m.keyCheck == .testing(attempts: 0, prompting: false))
        #expect(m.handle(.useFallbackKey) == [], "nothing to fall back from any more")
    }

    @Test func oneFnEventConfirmsTheKeyForGood() {
        var m = atTry()
        m.handle(.keyStatus(.fn, conflict: nil, fnEventsSeen: 0))
        m.handle(.checkKey); m.handle(.keyPromptElapsed)
        m.handle(.checkKey); m.handle(.keyPromptElapsed)
        m.handle(.checkKey)
        m.handle(.fnKeyEvent)
        #expect(m.keyCheck == .ready(.fn))
        m.handle(.keyPromptElapsed)
        #expect(m.keyCheck == .ready(.fn), "a late window close cannot undo a real event")
    }

    @Test func fnSeenBeforeTheStepConfirmsAtOnce() {
        var m = atTry()
        m.handle(.keyStatus(.fn, conflict: nil, fnEventsSeen: 2))
        #expect(m.keyCheck == .ready(.fn))
    }

    @Test func anElapsedWindowThatWasNeverOpenedCountsNothing() {
        var m = atTry()
        m.handle(.keyStatus(.fn, conflict: nil, fnEventsSeen: 0))
        m.handle(.keyPromptElapsed)
        #expect(m.keyCheck == .testing(attempts: 0, prompting: false))
    }

    @Test func aKeyThatIsNotFnNeedsNoPromptAndNoTest() {
        var m = atTry()
        m.handle(.keyStatus(.rightOption, conflict: Self.emojiConflict, fnEventsSeen: 0))
        #expect(m.keyCheck == .ready(.rightOption))
        #expect(m.fnConflict == nil)
    }

    /// The default bare-modifier monitor costs no permission, fn included, so the walk never
    /// contains Input Monitoring for it.
    @Test func onlyTheSelectedBackendsPermissionsAreWalked() {
        for kind in [HotkeyBinding.Kind.fn, .rightOption] {
            let needs = HotkeyBackendSelector.requiredPermission(for: HotkeyBinding(kind: kind))
            #expect(needs == nil)
            #expect(OnboardingPermission.order(hotkeyRequires: needs) == [.microphone, .accessibility])
        }
    }

    // MARK: Ready — only when capture and a recogniser work; copy-only labelled

    @Test func readyNeedsCaptureAndAWorkingRecognizer() {
        var m = atModel()
        m.handle(.downloadFinished)
        m.handle(.modelLoadStarted)
        #expect(m.readyVerdict == .notReady([.M07]), "installed but not loaded is not ready")
        m.handle(.modelLoadFinished(.loaded(name: "x")))
        #expect(m.readyVerdict == .ready)

        var copyOnly = M(initialStatuses: [.microphone: .granted])
        copyOnly.handle(.readinessChanged(.fallback(name: "Apple Speech (on-device)", awaiting: "Parakeet TDT 0.6B v3")))
        #expect(copyOnly.readyVerdict == .copyOnly, "typing access off: labelled copy-only, not a failure")

        let nothing = M()
        #expect(nothing.readyVerdict == .notReady([.P01, .M01]))

        var failedDownload = M(initialStatuses: Self.granted)
        failedDownload.handle(.downloadFailed("offline"))
        #expect(failedDownload.readyVerdict == .notReady([.M02]))
    }

    @Test func aCapturePathSeenFailingIsNotReady() {
        var m = M(initialStatuses: Self.granted)
        m.handle(.readinessChanged(.fallback(name: "Apple Speech (on-device)", awaiting: nil)))
        m.handle(.next)
        m.handle(.micCaptureBegan(real: true))
        m.handle(.micNoAudio)
        #expect(m.readyVerdict == .notReady([.A05]))
    }

    @Test func aRealTranscriptionProvesTheRecognizer() {
        var m = atTry()
        m.handle(.dictationFinished(.landed(text: "hello", app: OnboardingCopy.practiceFieldName)))
        #expect(m.recognizerWorks)
        #expect(m.readyVerdict == .ready)
    }

    @Test func readyKeepsHearingBackgroundEventsButNoNavigation() {
        var m = M(initialStatuses: [.microphone: .granted])
        while m.step != .done { m.handle(.skip) }
        #expect(m.readyVerdict == .notReady([.M01]))
        m.handle(.modelPresenceChanged(true))
        m.handle(.modelLoadStarted)
        m.handle(.modelLoadFinished(.loaded(name: "x")))
        m.handle(.statusRefreshed(.accessibility, .granted))
        #expect(m.readyVerdict == .ready, "a grant or a load after reaching Ready counts")
        #expect(m.handle(.next) == [])
        #expect(m.step == .done)
    }
}
