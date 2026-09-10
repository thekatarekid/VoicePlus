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

    /// Focus is nil off the permissions step, which is what stops the view model logging elsewhere.
    @Test func focusIsOnlyEverSetOnThePermissionsStep() {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        #expect(m.permissionFocus == nil, "welcome has no permission in focus")
        m.handle(.next)
        #expect(m.step == .micCheck, "all granted skips straight past permissions")
        #expect(m.permissionFocus == nil)
    }

    /// One line per transition: entering, requesting, and each advance are all distinct pairs, and
    /// a repeated status refresh that changes nothing produces the same pair (so nothing is logged).
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

        // Three transitions, not five: the two steady polls in the middle add nothing.
        #expect(seen == ["onboarding: microphone status=notDetermined phase=explain",
                         "onboarding: microphone status=notDetermined phase=requesting",
                         "onboarding: inputMonitoring status=notDetermined phase=explain"])
    }
}

@Suite("Onboarding state machine (P1.9 T1/T2)")
struct OnboardingStateMachineTests {
    typealias M = OnboardingStateMachine

    @Test func happyPathAllGranted() {
        var m = fullWalkM()
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
        m.handle(.micCaptureBegan(real: true))
        m.handle(.micLevel(0.02)); #expect(m.micVerdict == .waiting)
        m.handle(.micLevel(0.4)); #expect(m.micVerdict == .good)
        m.handle(.micLevel(0.99)); #expect(m.micVerdict == .clipping)
        #expect(m.handle(.next) == [.stopMicMonitoring, .checkModelPresence, .startDownload,
                                    .checkRecognizerReadiness])
        #expect(m.step == .modelInstall)

        // The install starts itself on entering the step; asking again while it runs starts nothing.
        let half = ModelDownloadProgress(fraction: 0.5, bytesReceived: 250_000_000,
                                         bytesExpected: 500_000_000, modelName: "Parakeet TDT 0.6B v3")
        m.handle(.downloadProgress(half)); #expect(m.download == .downloading(half))
        #expect(m.handle(.installModels) == [], "no second fetch while one is in flight")
        // Continue is not offered while the model is only half-downloaded.
        #expect(!m.canContinueFromModelInstall)
        #expect(m.handle(.next) == [])
        #expect(m.step == .modelInstall)
        m.handle(.downloadFinished)
        #expect(m.canContinueFromModelInstall)
        #expect(m.continueBlockedReason == nil)
        #expect(m.handle(.next) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(m.step == .firstDictation)
        #expect(m.download == .installed)
        m.handle(.dictationFinished(.landed(text: "hello", app: "Notes")))
        #expect(m.landedText == "hello")
        #expect(m.handle(.next) == [.finish(skipped: false)])
        #expect(m.step == .done)
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
        // Verify comes back granted after the user flipped it in System Settings.
        m.handle(.permissionResult(.microphone, .granted))
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .explain)
    }

    /// BUG 1, the exact shape the user hit: `CGRequestListenEventAccess()` returns false without
    /// prompting, so the request resolves to `.awaitingUserAction`. That must expose the escape
    /// hatches, not bounce back to a lone "Allow" button.
    @Test func awaitingUserActionNeverReturnsToExplain() {
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
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
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
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
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
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
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
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

    /// Every permission refused still terminates: the skips walk off the step, never loop.
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
        // No microphone → nothing to meter. The walk lands on the mic check, which says exactly
        // that, and one more skip leaves it. It must not loop, and it must not pretend to pass.
        #expect(m.step == .micCheck)
        #expect(m.micVerdict == .permissionRequired)
        #expect(m.currentPermission == nil)
        m.handle(.skip)
        #expect(m.step == .modelInstall)
    }

    /// A *non-promptable* permission macOS has already been asked for on an earlier launch skips the
    /// useless Allow button: `CGRequestListenEventAccess()` can never raise a dialog, so re-offering
    /// one would be the lie. This must NOT generalise to promptable services — see the suite below.
    @Test func alreadyRequestedPermissionStartsInSettingsPhase() {
        var m = fullWalkM(initialStatuses: [.microphone: .granted], alreadyRequested: [.inputMonitoring])
        m.handle(.next)
        #expect(m.currentPermission == .inputMonitoring)
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        m.handle(.statusRefreshed(.inputMonitoring, .granted))
        // Accessibility was never requested, so it still gets the honest first-run Allow button.
        #expect(m.currentPermission == .accessibility)
        #expect(m.permissionPhase == .explain)
    }

    @Test func deniedMicrophoneSkippedSkipsMicCheck() {
        var m = fullWalkM()
        m.handle(.next)
        m.handle(.allow(.microphone)); m.handle(.permissionResult(.microphone, .denied))
        m.handle(.next)  // "Skip this one"
        #expect(m.currentPermission == .inputMonitoring)
        m.handle(.allow(.inputMonitoring)); m.handle(.permissionResult(.inputMonitoring, .granted))
        m.handle(.allow(.accessibility))
        let effects = m.handle(.permissionResult(.accessibility, .denied))
        #expect(effects == [])
        #expect(m.permissionPhase == .needsSystemSettings(recheckAttempts: 0))
        // Skipping the last denied permission still opens the mic check — but as the blocked
        // screen, with no capture started and no way to reach a passing verdict.
        let skipEffects = m.handle(.next)
        #expect(m.step == .micCheck)
        #expect(m.micVerdict == .permissionRequired)
        #expect(!skipEffects.contains(.startMicMonitoring))
        #expect(m.statuses[.microphone] == .denied)
    }

    @Test func skipEverythingStillFinishes() {
        var m = M()
        #expect(m.handle(.skip) == [])  // welcome skip → micCheck, blocked (no mic grant)
        #expect(m.step == .micCheck)
        #expect(m.micVerdict == .permissionRequired)
        #expect(m.handle(.skip) == [.stopMicMonitoring, .checkModelPresence, .startDownload,
                                    .checkRecognizerReadiness])
        #expect(m.step == .modelInstall)
        // Entering the dictation step now asks which recogniser is available first, so the screen
        // can name it instead of presenting a test that may not be able to work.
        #expect(m.handle(.skip) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(m.handle(.skip) == [.finish(skipped: true)])
        #expect(m.step == .done)
        #expect(!m.stackInstalled)  // nothing landed, and the machine says so rather than guessing
    }

    /// A failed download blocks Continue rather than waving the user through to a dictation screen
    /// with nothing to transcribe with — but Skip is still there, and now says what it costs.
    @Test func modelInstallContinueStaysShutAfterAFailedDownloadAndSkipSaysWhy() {
        var m = M(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        #expect(m.handle(.next) == [.startMicMonitoring])  // all granted → permissions step auto-skips
        #expect(m.step == .micCheck)
        m.handle(.next)
        #expect(m.handle(.downloadFailed("offline")) == [.checkModelPresence, .checkRecognizerReadiness])
        #expect(m.download == .failed("offline"))
        #expect(!m.canContinueFromModelInstall)
        #expect(m.continueBlockedReason?.contains("offline") == true)
        #expect(m.handle(.next) == [])
        #expect(m.step == .modelInstall, "Continue must not walk the user past a model that never arrived")
        #expect(m.skipConsequence?.contains("dictation won't work") == true)
        #expect(m.handle(.skip) == [.checkRecognizerReadiness, .beginGuidedDictation])
        #expect(m.step == .firstDictation)
        #expect(m.skippedModelInstallWithoutModel)
    }

    @Test func pregrantedPermissionsAreSkippedInOrder() {
        var m = fullWalkM(initialStatuses: [.microphone: .granted])
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
        #expect(m.step == .modelInstall)
        #expect(m.handle(.back) == [.startMicMonitoring])
        #expect(m.step == .micCheck)
        #expect(m.handle(.back) == [.stopMicMonitoring, .startMicMonitoring])  // permissions all granted → bounces to mic check
        var denied = M(initialStatuses: [.microphone: .denied])
        denied.handle(.skip)
        #expect(denied.step == .micCheck)
        denied.handle(.skip)
        #expect(denied.step == .modelInstall)
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
        im.handle(.next)
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
        im.handle(.next)
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
        im.handle(.next)
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
        #expect(vm.machine.currentPermission == .inputMonitoring)
    }

    @Test func fullRunWithMocksFinishesAndDownloads() async throws {
        // Opting in explicitly: this walk is about everything *after* capture, so the synthetic
        // meter has to declare that it is standing in for a microphone.
        let deps = OnboardingDependencies.mock(pretendRealMicCapture: true)
        let vm = OnboardingViewModel(dependencies: deps)
        var finished: Bool?
        vm.onFinished = { finished = $0 }
        vm.send(.next)
        for p in vm.machine.permissionOrder {
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
        // The install runs itself; nothing is chosen and nothing is pressed.
        try await waitUntil { vm.machine.download == .installed }
        #expect(vm.machine.canContinueFromModelInstall)
        #expect(deps.models.isStackInstalled)
        vm.send(.next)
        // Two presses, because one press cannot contain an utterance (see `startGuidedDictation`).
        vm.startGuidedDictation()
        try await waitUntil { vm.isDictating }
        vm.finishGuidedDictation()
        try await waitUntil { vm.machine.dictation != nil }
        #expect(vm.machine.heardText?.contains("quick brown fox") == true)
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
        // The escape-hatch walk — this test is about the Input Monitoring step itself, which a
        // default install no longer visits (see `OnboardingSkipsInputMonitoringTests`).
        deps.hotkeyRequiresPermission = .inputMonitoring
        deps.settingsStore = store
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        vm.send(.allow(.microphone))
        try await waitUntil { vm.machine.currentPermission == .inputMonitoring }
        vm.send(.allow(.inputMonitoring))
        try await waitUntil { store.bool("onboarding.requested.inputMonitoring") == true }
        vm.teardown()

        var relaunch = OnboardingDependencies.mock(permissionResults: [.inputMonitoring: .awaitingUserAction])
        // The escape-hatch walk — this test is about the Input Monitoring step itself, which a
        // default install no longer visits (see `OnboardingSkipsInputMonitoringTests`).
        relaunch.hotkeyRequiresPermission = .inputMonitoring
        relaunch.settingsStore = store
        let second = OnboardingViewModel(dependencies: relaunch)
        second.send(.next)
        (relaunch.permissions as? OnboardingMockPermissionChecker)?.statuses[.microphone] = .granted
        second.send(.permissionResult(.microphone, .granted))
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
        vm.send(.skip)                      // welcome → mic check (blocked, no grant)
        vm.send(.back)                      // back to permissions
        for p in vm.machine.permissionOrder {
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
        let deps = OnboardingDependencies.mock(pretendRealMicCapture: true)
        let vm = OnboardingViewModel(dependencies: deps)
        vm.send(.next)
        for p in vm.machine.permissionOrder {
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
        vm.send(.skip); vm.send(.skip)   // welcome → blocked mic check → model install
        try await waitUntil { if case .failed = vm.machine.download { return true }; return false }
        // Continue is shut — the model never arrived — but Skip still gets the user off the screen.
        vm.send(.next)
        #expect(vm.step == .modelInstall)
        vm.send(.skip)
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
