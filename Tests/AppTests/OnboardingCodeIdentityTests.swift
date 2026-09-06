import Foundation
import Testing
@testable import VoicePlusApp

/// 1.6.4 — Input Monitoring and Accessibility read "off" while System Settings shows both switches
/// ON. Measured on the reporting machine (macOS 26.6.2): the switches really are on, but each row's
/// stored code requirement is `cdhash H"…"` of a *different, older* build, tccd re-evaluates it on
/// every query, fails it (`errSecCSReqFailed`, -67050) and answers "not granted". Two consequences
/// the old screen got wrong:
///
/// 1. **Re-check can never succeed.** The status is not stale; it is a correct answer to a question
///    whose answer will not change. Keeping Return on that button was a promise the app cannot keep.
/// 2. **Relaunching is not the cure either.** A brand-new process of the installed app still read
///    `AXIsProcessTrusted() == false` and `CGPreflightListenEventAccess() == false`, so there is no
///    per-process cache to defeat. "Quit & Reopen" stays as a secondary action, never the headline.
///
/// The one thing that does fix it is removing the row and re-adding it — and that only has to be
/// done once if the build's designated requirement stops naming a single binary. All of that is a
/// factual claim about the signature, so the copy derives from `AppCodeIdentity` rather than guessing.
@Suite("Code identity → what the recovery screen may claim")
struct AppCodeIdentityTests {
    static let adHoc = AppCodeIdentity(
        designatedRequirement: #"cdhash H"cb56c554cba441f6fef195efaa7ea5ac8a0715e2""#,
        bundlePath: "/Applications/VoicePlus.app")
    static let stableAdHoc = AppCodeIdentity(
        designatedRequirement: #"identifier "in.adityakatare.voiceplus""#,
        bundlePath: "/Applications/VoicePlus.app")
    static let developerID = AppCodeIdentity(
        designatedRequirement: #"identifier "in.adityakatare.voiceplus" and anchor apple generic and certificate leaf H"abcd""#,
        bundlePath: "/Applications/VoicePlus.app")
    static let translocated = AppCodeIdentity(
        designatedRequirement: #"cdhash H"cb56c554""#,
        bundlePath: "/private/var/folders/qx/T/AppTranslocation/1E2F/d/VoicePlus.app")

    @Test func aBareCdhashRequirementNamesOneBuildAndNothingElse() {
        #expect(Self.adHoc.pinsThisBuild)
        #expect(!Self.adHoc.isStable)
        // Anything that survives a rebuild is a property of the identity, not of the bytes.
        #expect(Self.stableAdHoc.isStable)
        #expect(Self.developerID.isStable)
        // Unreadable must count as pinned: never promise durability we cannot see.
        #expect(AppCodeIdentity(designatedRequirement: nil, bundlePath: "/Applications/VoicePlus.app").pinsThisBuild)
    }

    /// The requirement string is case-insensitive in practice (`cdhash` vs `CDHash` depending on who
    /// printed it), and a mixed requirement that still contains a cdhash clause is still pinned.
    @Test func cdhashIsDetectedWhateverTheCase() {
        #expect(AppCodeIdentity(designatedRequirement: #"CDHash H"AB""#, bundlePath: "/x").pinsThisBuild)
        #expect(AppCodeIdentity(designatedRequirement: #"identifier "x" and cdhash H"ab""#, bundlePath: "/x").pinsThisBuild)
    }

    @Test func translocationIsRecognisedFromThePath() {
        #expect(Self.translocated.isTranslocated)
        #expect(!Self.adHoc.isTranslocated)
    }

    /// Relaunching a translocated copy only produces another translocated copy, so the decision has
    /// to refuse rather than run and appear to have done something.
    @Test func relaunchRefusesFromATranslocatedCopy() {
        #expect(Self.adHoc.relaunchOutcome == .relaunch(bundlePath: "/Applications/VoicePlus.app"))
        #expect(Self.translocated.relaunchOutcome == .translocated)
    }
}

@Suite("Non-promptable recovery copy (Input Monitoring / Accessibility)")
struct NonPromptableRecoveryCopyTests {
    typealias I = AppCodeIdentityTests

    /// The first pass is unchanged: nothing has been tried yet, so "go turn it on" is honest and the
    /// screen must not open with an accusation about older builds.
    @Test func firstPassStillJustAsksTheUserToTurnItOn() {
        for p in OnboardingPermission.allCases where !p.isPromptable {
            let copy = p.recoveryCopy(status: .awaitingUserAction, attempts: 0, identity: I.adHoc)
            #expect(copy.headline.contains(p.settingsListName))
            #expect(copy.detail == nil)
            #expect(copy.steps.isEmpty, "no remove-and-re-add dance before anything has failed")
            #expect(copy.retryTitle == nil, "no API can prompt for \(p.rawValue)")
            #expect(copy.relaunchTitle == nil, "nothing has failed yet; do not offer a restart")
            #expect(!copy.showsResetCommand)
            #expect(!copy.showsRowReset)
        }
    }

    /// THE detector fix. The 1.6.4 copy asserted "that switch belongs to an older build of VoicePlus"
    /// from `attempts >= 1 && !isTranslocated` and nothing else — it never established that an entry
    /// exists, that its switch is on, or that its stored requirement mismatches, none of which the app
    /// can read (TCC.db is SIP-protected). On the reporting machine it happened to be true. On a clean
    /// Mac with no VoicePlus entry at all, one press of Re-check made every clause of it false.
    ///
    /// The cure is the same for "stale entry" and "no entry", so the copy leads with the cure and
    /// keeps the cause conditional.
    @Test func escalatedCopyStatesTheCureAndNeverAssertsAnEntryItCannotSee() throws {
        for p in OnboardingPermission.allCases where !p.isPromptable {
            let copy = p.recoveryCopy(status: .awaitingUserAction, attempts: 1, identity: I.adHoc)
            let prose = copy.headline + " " + copy.steps.joined(separator: " ") + " " + (copy.detail ?? "")

            // Unconditional claims about the user's TCC state are the bug. Every mention of an
            // existing entry has to be guarded by an "if".
            #expect(!copy.headline.contains("belongs to an older build"))
            #expect(!copy.headline.contains("macOS shows VoicePlus switched on"))
            for sentence in copy.steps where sentence.contains("already in that list") {
                #expect(sentence.hasPrefix("If "), "the entry's existence is a conditional, not a fact")
            }
            #expect(!copy.headline.lowercased().contains("probably"), "conditional, not hedged")

            // The cure, in order, as its own steps — this is what the 1.6.5 user never reached when
            // it was one long sentence of grey caption text under an orange headline.
            #expect(copy.steps.count == 3)
            #expect(copy.steps[0].contains(p.settingsListName))
            #expect(copy.steps[1].contains("“–”"))
            #expect(copy.steps[2].contains("“+”"))
            #expect(prose.contains("Turning its switch off and on again is not the same thing and will not fix it"))
            #expect(prose.contains("re-adding the entry is the only thing that rewrites that"))
            #expect(copy.showsResetCommand)
            #expect(copy.showsRowReset, "and the app offers to do the fiddly step itself")
        }
    }

    /// The one corroborating fact the app *can* observe: another non-promptable service granted right
    /// now, under this same signature. It proves TCC accepts this build's requirement — so it may be
    /// stated — but it still does not prove that an entry for *this* service exists, so it may not
    /// upgrade the conditional into an assertion.
    @Test func corroborationIsMentionedOnlyWhenItExistsAndNeverBecomesAnAssertion() throws {
        let p = OnboardingPermission.accessibility
        let bare = try #require(p.recoveryCopy(status: .awaitingUserAction, attempts: 1,
                                               identity: I.stableAdHoc).detail)
        #expect(!bare.contains("already honouring"))

        let corroborated = try #require(p.recoveryCopy(
            status: .awaitingUserAction, attempts: 1, identity: I.stableAdHoc,
            evidence: .init(corroboratingGrants: [.inputMonitoring])).detail)
        #expect(corroborated.contains("already honouring Input Monitoring for this exact build"))
        #expect(corroborated.contains("the signature is fine"))
        // The steps — the actual instructions — are identical either way.
        #expect(p.recoveryCopy(status: .awaitingUserAction, attempts: 1, identity: I.stableAdHoc).steps
                == p.recoveryCopy(status: .awaitingUserAction, attempts: 1, identity: I.stableAdHoc,
                                  evidence: .init(corroboratingGrants: [.inputMonitoring])).steps)
    }

    /// Corrected in 1.6.7. The 1.6.6 answer — "the status APIs are live for all three, a restart is
    /// never required" — was measured on processes that already held the grant at launch, and macOS'
    /// own alerts said the opposite for two of the three. Accessibility stays exactly as it was (no
    /// quit string in the Privacy pane, and a toggle picked up in ~1 s inside a running process);
    /// Microphone and Input Monitoring now offer the restart, because that is what macOS does.
    @Test func restartIsOfferedOnlyWhereMacOSActuallyRequiresIt() throws {
        let accessibility = OnboardingPermission.accessibility.recoveryCopy(
            status: .awaitingUserAction, attempts: 2, identity: I.stableAdHoc)
        #expect(accessibility.relaunchTitle == nil, "measured live; a restart button here teaches a false model")
        let note = try #require(accessibility.restartNote)
        #expect(note.contains("don't need to quit"))
        #expect(!note.contains("until it is quit"), "macOS ships no quit string for Accessibility")

        let inputMonitoring = OnboardingPermission.inputMonitoring.recoveryCopy(
            status: .awaitingUserAction, attempts: 2, identity: I.stableAdHoc)
        #expect(inputMonitoring.relaunchTitle == "Quit & Reopen")
        let imNote = try #require(inputMonitoring.restartNote)
        // The copy has to agree with the alert the user just dismissed, not contradict it.
        #expect(imNote.contains("will not be able to monitor input from your keyboard until it is quit"))
        #expect(!imNote.contains("you don't need to quit"))
        // `retryTitle` is what the view renders as the prominent, Return-bound button. A
        // non-promptable service must never get one: no API can re-ask for it.
        #expect(inputMonitoring.retryTitle == nil)
    }

    @Test func everyServiceAnswersTheRestartQuestionInWords() throws {
        for p in OnboardingPermission.allCases {
            for attempts in [0, 1, 3] {
                let copy = p.recoveryCopy(status: .awaitingUserAction, attempts: attempts, identity: I.stableAdHoc)
                #expect(copy.restartNote != nil, "\(p.rawValue) @\(attempts) must say whether a restart is needed")
            }
        }
        // The per-service verdict, which the onboarding enum delegates to `Permission` so the two
        // can never drift apart.
        #expect(OnboardingPermission.microphone.relaunchNeededForMidSessionGrant)
        #expect(OnboardingPermission.inputMonitoring.relaunchNeededForMidSessionGrant)
        #expect(!OnboardingPermission.accessibility.relaunchNeededForMidSessionGrant)
        #expect(!OnboardingPermission.microphone.grantReachesRunningApp)
        #expect(OnboardingPermission.accessibility.grantReachesRunningApp)
    }

    /// The first pass may not promise live pickup for a service that does not have it. Before 1.6.7
    /// it told Input Monitoring users "come back — this screen notices on its own", which is a lie
    /// the screen then acts out for as long as the user is willing to wait.
    @Test func theFirstPassOnlyPromisesLivePickupWhereItHappens() {
        let accessibility = OnboardingPermission.accessibility.recoveryCopy(
            status: .awaitingUserAction, attempts: 0, identity: I.stableAdHoc)
        #expect(accessibility.headline.contains("notices on its own"))

        let inputMonitoring = OnboardingPermission.inputMonitoring.recoveryCopy(
            status: .awaitingUserAction, attempts: 0, identity: I.stableAdHoc)
        #expect(!inputMonitoring.headline.contains("notices on its own"))
        #expect(inputMonitoring.headline.contains("Quit & Reopen"))
    }

    /// A hard "Don't Allow" is the one microphone state a mid-session Settings grant arrives from,
    /// and macOS withholds that grant from the running process. Once a re-check has come back off,
    /// the restart offer is the honest next step — but not before the user has tried anything.
    @Test func microphoneOffersTheRestartOnlyAfterARecheckHasFailed() {
        let firstLook = OnboardingPermission.microphone.recoveryCopy(status: .denied, attempts: 0,
                                                                    identity: I.stableAdHoc)
        #expect(firstLook.relaunchTitle == nil, "nothing has failed yet")
        let afterRecheck = OnboardingPermission.microphone.recoveryCopy(status: .denied, attempts: 1,
                                                                       identity: I.stableAdHoc)
        #expect(afterRecheck.relaunchTitle == "Quit & Reopen")
        // Except from a translocated copy, where relaunching only translocates again.
        #expect(OnboardingPermission.microphone
            .recoveryCopy(status: .denied, attempts: 1, identity: I.translocated).relaunchTitle == nil)
    }

    /// Whether the −/+ dance has to be repeated after every update is a fact about the signature, so
    /// the sentence that promises "only once" may only appear when the requirement really is stable.
    @Test func durabilityPromiseFollowsTheSignature() throws {
        let p = OnboardingPermission.accessibility
        let adHoc = try #require(p.recoveryCopy(status: .awaitingUserAction, attempts: 2, identity: I.adHoc).detail)
        #expect(adHoc.contains("repeat this after each one"))
        #expect(!adHoc.contains("only have to do this once"))

        for stable in [I.stableAdHoc, I.developerID] {
            let text = try #require(p.recoveryCopy(status: .awaitingUserAction, attempts: 2, identity: stable).detail)
            #expect(text.contains("only have to do this once"))
            #expect(!text.contains("repeat this after each one"))
        }
    }

    /// A translocated copy is the one case where the System Settings advice is actively wrong: the
    /// grant would attach to a path that does not survive the launch. Different cause, different
    /// cure, and no relaunch button — relaunching makes another temporary copy.
    @Test func translocatedCopyStopsSendingTheUserToTheWrongList() throws {
        let p = OnboardingPermission.inputMonitoring
        let copy = p.recoveryCopy(status: .awaitingUserAction, attempts: 1, identity: I.translocated)
        #expect(copy.headline.contains("temporary copy"))
        #expect(!copy.headline.contains("older build"), "that is a different diagnosis")
        #expect(copy.relaunchTitle == nil, "a translocated relaunch only translocates again")
        #expect(copy.showsDequarantineCommand)
        #expect(!copy.showsResetCommand, "resetting TCC cannot help a path that vanishes")
        #expect(!copy.showsRowReset, "nor can removing an entry that was never the problem")
        let steps = copy.steps.joined(separator: " ")
        #expect(steps.contains("xattr -dr com.apple.quarantine"))
        #expect(steps.contains("Applications"))
    }

    /// The promptable service is untouched by any of this: its copy is chosen by status alone, and
    /// the microphone must keep the button that reaches `AVCaptureDevice.requestAccess`.
    @Test func microphoneCopyIsUnaffectedByTheCodeIdentity() {
        for identity in [I.adHoc, I.stableAdHoc, I.translocated] {
            let copy = OnboardingPermission.microphone.recoveryCopy(status: .notDetermined, attempts: 2,
                                                                    identity: identity)
            #expect(copy.retryTitle == "Ask macOS again")
            #expect(copy.relaunchTitle == nil)
            #expect(!copy.showsDequarantineCommand)
            #expect(!copy.showsRowReset, "the mic pane has no rows to remove and no + to re-add with")
        }
    }
}

/// The exact escalation path the 1.6.4 detector got wrong, walked through the real state machine:
/// a clean Mac with no VoicePlus entry anywhere, and one impatient press of Re-check.
@Suite("First run + one Re-check must not accuse the user's TCC state")
struct FirstRunEscalationTests {
    @Test func aSingleRecheckOnACleanMacProducesNoOlderBuildClaim() throws {
        var machine = OnboardingStateMachine(initialStatuses: [.microphone: .granted, .inputMonitoring: .granted])
        machine.handle(.next)
        #expect(machine.currentPermission == .accessibility)
        #expect(machine.permissionPhase == .explain)

        // "Allow Accessibility" → AXIsProcessTrustedWithOptions returns synchronously, ungranted.
        machine.handle(.allow(.accessibility))
        machine.handle(.permissionResult(.accessibility, .awaitingUserAction))
        #expect(machine.permissionPhase == .needsSystemSettings(recheckAttempts: 0))

        // One press of "Re-check" — the only thing needed to reach the escalated copy.
        machine.handle(.verify(.accessibility))
        machine.handle(.permissionResult(.accessibility, .awaitingUserAction))
        #expect(machine.permissionPhase == .needsSystemSettings(recheckAttempts: 1))

        // Nothing is switched on, no entry exists, no older build is involved. The copy may not say
        // otherwise — and it may not offer a restart for a service macOS re-reads live.
        let copy = OnboardingPermission.accessibility.recoveryCopy(
            status: .awaitingUserAction, attempts: 1,
            identity: AppCodeIdentityTests.stableAdHoc,
            evidence: .init(corroboratingGrants: [.inputMonitoring]))
        #expect(!copy.headline.contains("belongs to an older build"))
        #expect(!copy.headline.contains("switched on in"))
        #expect(copy.relaunchTitle == nil)
        // What it says instead is the cure, which is right in both worlds.
        #expect(copy.steps.contains { $0.contains("“+”") && $0.contains("Applications folder") })
    }
}

@Suite("Quit & Reopen")
@MainActor
struct RelaunchActionTests {
    @Test func relaunchOpensTheBundleForANormalInstall() {
        let vm = OnboardingViewModel(dependencies: .mock())
        let relauncher = MockRelauncher()
        let outcome = vm.relaunchApp(identity: AppCodeIdentityTests.adHoc, relauncher: relauncher)
        #expect(outcome == .relaunch(bundlePath: "/Applications/VoicePlus.app"))
        #expect(relauncher.relaunched == ["/Applications/VoicePlus.app"])
    }

    @Test func relaunchIsRefusedRatherThanLoopingATranslocatedCopy() {
        let vm = OnboardingViewModel(dependencies: .mock())
        let relauncher = MockRelauncher()
        let outcome = vm.relaunchApp(identity: AppCodeIdentityTests.translocated, relauncher: relauncher)
        #expect(outcome == .translocated)
        #expect(relauncher.relaunched.isEmpty, "nothing may be launched from a translocated path")
    }
}

/// The report is the thing a stuck user pastes, and the thing a release is verified against on real
/// hardware. Its value is that it states the two API answers in words instead of leaving them to be
/// inferred from an onboarding phase label, so the names of those APIs are part of the contract.
@Suite("Permission report")
struct PermissionReportTests {
    @Test func reportStatesTheIdentityAndBothNonPromptableAPIsByName() {
        let lines = PermissionDiagnostics.report()
        let text = lines.joined(separator: "\n")
        #expect(text.contains("designatedRequirement="))
        #expect(text.contains("AXIsProcessTrusted()="))
        #expect(text.contains("CGPreflightListenEventAccess()="))
        #expect(text.contains("identityStable="))
        #expect(text.contains("translocated="))
        for p in Permission.allCases {
            #expect(text.contains("permission report: \(p.rawValue)="))
        }
        #expect(lines.allSatisfy { $0.hasPrefix("permission report: ") })
    }

    /// `summary()` is rendered next to the claim "that switch belongs to an older build", so it has
    /// to carry the requirement that claim is about — a cdhash alone does not show what TCC stored.
    @Test func summaryCarriesTheRequirementTheClaimRestsOn() {
        let summary = PermissionDiagnostics.summary()
        #expect(summary.contains("cdhash="))
        #expect(summary.contains("dr="))
    }
}
