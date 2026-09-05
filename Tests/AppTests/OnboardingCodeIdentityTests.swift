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
            #expect(copy.retryTitle == nil, "no API can prompt for \(p.rawValue)")
            #expect(copy.relaunchTitle == nil, "nothing has failed yet; do not offer a restart")
            #expect(!copy.showsResetCommand)
        }
    }

    /// THE fix for the report: after a re-check comes back off while the switch is visibly on, the
    /// copy names that exact contradiction and states the cause outright. The old text hedged
    /// ("probably remembering an older copy"), which is what let the user read the app as wrong and
    /// System Settings as right.
    @Test func escalatedCopyNamesTheContradictionWithoutHedging() throws {
        for p in OnboardingPermission.allCases where !p.isPromptable {
            let copy = p.recoveryCopy(status: .awaitingUserAction, attempts: 1, identity: I.adHoc)
            #expect(copy.headline.contains("switched on in \(p.settingsListName)"),
                    "the headline must describe what the user is looking at")
            #expect(copy.headline.contains("older build"))
            #expect(!copy.headline.lowercased().contains("probably"), "measured, not guessed")
            #expect(!copy.headline.contains("Still off."), "the old hedged headline is gone")
            // The only cure, spelled out, and the explicit denial of the thing users try first.
            let detail = try #require(copy.detail)
            #expect(detail.contains("Turning it off and on again will not fix it"))
            #expect(detail.contains("“–”") && detail.contains("“+”"))
            #expect(copy.showsResetCommand)
        }
    }

    /// Restart is offered, but only as a secondary action and only after a failed re-check —
    /// a fresh process was measured to read exactly the same `false`.
    @Test func relaunchIsOfferedOnlyAfterAFailedRecheckAndNeverAsThePrimaryAction() {
        let p = OnboardingPermission.inputMonitoring
        #expect(p.recoveryCopy(status: .awaitingUserAction, attempts: 0, identity: I.adHoc).relaunchTitle == nil)
        let escalated = p.recoveryCopy(status: .awaitingUserAction, attempts: 1, identity: I.adHoc)
        #expect(escalated.relaunchTitle == "Quit & Reopen")
        // `retryTitle` is what the view renders as the prominent, Return-bound button. A
        // non-promptable service must never get one: no API can re-ask for it.
        #expect(escalated.retryTitle == nil)
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
        let detail = try #require(copy.detail)
        #expect(detail.contains("xattr -dr com.apple.quarantine"))
        #expect(detail.contains("Applications"))
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
        }
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
