import Foundation
import Testing
@testable import VoicePlusApp

/// P6 — "macOS itself demands a relaunch, contradicting our last claim."
///
/// After toggling Microphone and Input Monitoring the user saw macOS' own alerts — "“VoicePlus” will
/// not have access to your microphone until it is quit." and "…will not be able to monitor input
/// from your keyboard until it is quit." — while VoicePlus' onboarding screen was telling them a
/// relaunch was never needed. One of the two was wrong, and it was us.
///
/// The corrected position is per service, and it is Apple's own: `PrivacyTCCServices.plist` carries
/// a `quitAllowTitleForAppName` string for `kTCCServiceMicrophone` and `kTCCServiceListenEvent` and
/// **none** for `kTCCServiceAccessibility`. Measured on the reporting machine against tccd's grant
/// timestamps: a Microphone grant 6 s into a process's life was still invisible to it 25 s later; an
/// Input Monitoring grant 16 s in was still invisible 18 s later; each *next* process read the new
/// value immediately; Accessibility flipped inside a running process in about a second.
@Suite("Which grants reach a running app (P6)")
struct GrantReachesRunningAppTests {
    @Test func onlyAccessibilityIsPickedUpWithoutARelaunch() {
        #expect(Permission.accessibility.grantReachesRunningApp)
        #expect(!Permission.microphone.grantReachesRunningApp)
        #expect(!Permission.inputMonitoring.grantReachesRunningApp)
    }

    /// Our copy has to be able to quote macOS rather than argue with it, so the strings are carried
    /// verbatim — and Accessibility, which has no such string, must carry none.
    @Test func macOSQuitWarningsAreCarriedVerbatimAndOnlyWhereTheyExist() throws {
        let mic = try #require(Permission.microphone.systemQuitWarning)
        #expect(mic == "“VoicePlus” will not have access to your microphone until it is quit.")
        let im = try #require(Permission.inputMonitoring.systemQuitWarning)
        #expect(im == "“VoicePlus” will not be able to monitor input from your keyboard until it is quit.")
        #expect(Permission.accessibility.systemQuitWarning == nil)
        // The two facts must never disagree: a service with a quit string is a service that needs one.
        for p in Permission.allCases {
            #expect(p.grantReachesRunningApp == (p.systemQuitWarning == nil))
        }
    }
}

/// The trigger. Offering a relaunch whenever something is ungranted would nag every fresh install;
/// 1.6.6's only trigger (`onTapProvenDead`) could never fire in the case that actually happens,
/// because it presupposes an armed tap and `HotkeyService.start()` refuses to arm while
/// `CGPreflightListenEventAccess()` reads false — which is exactly the frozen value at issue.
@Suite("When a relaunch offer is honest (P6)")
struct RelaunchAdvisorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let ungranted: PermissionMatrix = [.microphone: .denied, .inputMonitoring: .notDetermined,
                                               .accessibility: .notDetermined]

    @Test func accessibilityIsNeverAdvised() {
        var advisor = RelaunchAdvisor()
        #expect(!RelaunchAdvisor.candidates.contains(.accessibility))
        advisor.noteSentToSettings(.accessibility, at: t0)
        advisor.noteBecameActive(at: t0 + 1)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 60).isEmpty)
    }

    @Test func nothingIsAdvisedWithoutATripToSystemSettings() {
        var advisor = RelaunchAdvisor()
        advisor.noteBecameActive(at: t0)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 600).isEmpty,
                "a permission that was simply never granted is not a relaunch situation")
    }

    @Test func nothingIsAdvisedUntilTheUserComesBackAndSettles() {
        var advisor = RelaunchAdvisor()
        advisor.noteSentToSettings(.inputMonitoring, at: t0)
        // Still over in System Settings.
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 600).isEmpty)
        advisor.noteBecameActive(at: t0 + 30)
        // Back, but not yet settled: they may still be mid-toggle.
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 31).isEmpty)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 30 + RelaunchAdvisor.grace) == [.inputMonitoring])
    }

    /// Once per trip. A 1 Hz watcher must not open an alert every second.
    @Test func theOfferIsMadeOnceNotOncePerTick() {
        var advisor = RelaunchAdvisor()
        advisor.noteSentToSettings(.microphone, at: t0)
        advisor.noteBecameActive(at: t0 + 1)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 10) == [.microphone])
        for i in 11...40 { #expect(advisor.evaluate(matrix: ungranted, now: t0 + Double(i)).isEmpty) }
    }

    /// The other half of honesty: if the grant *does* land live, say nothing at all. Never tell a
    /// user to restart an app that already works.
    @Test func aGrantThatLandsLiveCancelsTheOfferEntirely() {
        var advisor = RelaunchAdvisor()
        advisor.noteSentToSettings(.microphone, at: t0)
        advisor.noteBecameActive(at: t0 + 1)
        var granted = ungranted
        granted[.microphone] = .granted
        #expect(advisor.evaluate(matrix: granted, now: t0 + 60).isEmpty)
        #expect(!advisor.advised.contains(.microphone))
        // And it stays quiet afterwards.
        #expect(advisor.evaluate(matrix: granted, now: t0 + 600).isEmpty)
    }

    /// Coming back before being sent out is not "coming back".
    @Test func anActivationThatPredatesTheTripDoesNotCount() {
        var advisor = RelaunchAdvisor()
        advisor.noteBecameActive(at: t0)
        advisor.noteSentToSettings(.inputMonitoring, at: t0 + 5)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 600).isEmpty)
        advisor.noteBecameActive(at: t0 + 20)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 30) == [.inputMonitoring])
    }

    /// A second trip through Settings earns a second offer — the user may have fixed something else,
    /// or toggled the wrong row the first time.
    @Test func aSecondTripCanAdviseAgain() {
        var advisor = RelaunchAdvisor()
        advisor.noteSentToSettings(.inputMonitoring, at: t0)
        advisor.noteBecameActive(at: t0 + 1)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 10) == [.inputMonitoring])
        advisor.noteSentToSettings(.inputMonitoring, at: t0 + 20)
        advisor.noteBecameActive(at: t0 + 25)
        #expect(advisor.evaluate(matrix: ungranted, now: t0 + 30) == [.inputMonitoring])
    }
}

/// End to end through the watcher, which is what actually runs in the app.
@Suite("CapabilityWatcher offers the relaunch (P6)")
@MainActor
struct CapabilityWatcherRelaunchTests {
    private final class Clock { var now = Date(timeIntervalSince1970: 2_000_000) }

    @Test func theInputMonitoringGapThatOnTapProvenDeadCannotCover() {
        // The exact reported state: Input Monitoring toggled on in Settings, "Later" pressed, so the
        // running process still reads it as ungranted. The tap therefore never arms — and
        // `onTapProvenDead` needs an armed tap, so it can never fire here. Before 1.6.7 that meant
        // the app had no way to say anything at all.
        let checker = MockPermissionChecker(statuses: [.microphone: .granted, .inputMonitoring: .notDetermined,
                                                       .accessibility: .granted])
        let hotkey = MockHotkeyArming()
        let clock = Clock()
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [hotkey])
        watcher.clock = { clock.now }
        var advised: [Permission] = []
        var provenDead = 0
        watcher.onRelaunchAdvised = { advised.append($0) }
        watcher.onTapProvenDead = { provenDead += 1 }

        watcher.refresh()
        #expect(hotkey.startCount == 0, "preflight is frozen at false, so nothing arms")
        #expect(advised.isEmpty)

        watcher.noteSentToSettings(.inputMonitoring)
        clock.now += 20                       // the trip through System Settings
        watcher.noteBecameActive()
        clock.now += 1
        watcher.refresh()
        #expect(advised.isEmpty, "not before the grace has passed")
        clock.now += RelaunchAdvisor.grace
        watcher.refresh()
        #expect(advised == [.inputMonitoring])
        #expect(provenDead == 0, "the tap was never armed; that trigger is structurally unreachable here")

        for _ in 0..<10 { watcher.refresh() }
        #expect(advised == [.inputMonitoring], "once, not once per tick")
    }

    @Test func aGrantThatArrivesLiveIsNeverCalledOutAsNeedingARestart() {
        let checker = MockPermissionChecker(statuses: [.inputMonitoring: .notDetermined])
        let clock = Clock()
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [MockHotkeyArming()])
        watcher.clock = { clock.now }
        var advised: [Permission] = []
        watcher.onRelaunchAdvised = { advised.append($0) }

        watcher.noteSentToSettings(.inputMonitoring)
        clock.now += 5
        watcher.noteBecameActive()
        checker.statuses[.inputMonitoring] = .granted     // it landed live after all
        clock.now += 60
        watcher.refresh()
        #expect(advised.isEmpty)
    }

    @Test func accessibilityNeverProducesAnOfferEvenAfterATripToSettings() {
        let checker = MockPermissionChecker(statuses: [.accessibility: .notDetermined])
        let clock = Clock()
        let watcher = CapabilityWatcher(checker: checker, hotkeys: [])
        watcher.clock = { clock.now }
        var advised: [Permission] = []
        watcher.onRelaunchAdvised = { advised.append($0) }
        watcher.noteSentToSettings(.accessibility)
        clock.now += 10
        watcher.noteBecameActive()
        clock.now += 60
        watcher.refresh()
        #expect(advised.isEmpty)
    }
}

/// The offer itself. Pure copy, so what the alert says is a test rather than something only a human
/// with two System Settings toggles can check.
@Suite("Relaunch prompt copy (P6)")
struct RelaunchPromptCopyTests {
    private static let installed = AppCodeIdentity(designatedRequirement: "identifier \"in.adityakatare.voiceplus\"",
                                                   bundlePath: "/Applications/VoicePlus.app")
    private static let translocated = AppCodeIdentity(designatedRequirement: nil,
                                                      bundlePath: "/private/var/folders/AppTranslocation/X/d/VoicePlus.app")

    @Test func accessibilityIsNeverOffered() {
        #expect(RelaunchPrompt.copy(for: .accessibility, identity: Self.installed) == nil)
    }

    @Test func theOfferQuotesMacOSRatherThanContradictingIt() throws {
        for permission in [Permission.microphone, .inputMonitoring] {
            let copy = try #require(RelaunchPrompt.copy(for: permission, identity: Self.installed))
            let warning = try #require(permission.systemQuitWarning)
            #expect(copy.message.contains(warning))
            #expect(copy.relaunchTitle == "Quit & Reopen")
            #expect(copy.dismissTitle == "Later")
            #expect(copy.title.contains(permission.title))
        }
    }

    /// The hotkey has a working fallback and the microphone does not; the copy has to say which.
    @Test func eachServiceNamesWhatStopsWorkingUntilTheRestart() throws {
        let mic = try #require(RelaunchPrompt.copy(for: .microphone, identity: Self.installed))
        #expect(mic.message.contains("cannot hear you"))
        let im = try #require(RelaunchPrompt.copy(for: .inputMonitoring, identity: Self.installed))
        #expect(im.message.contains("menu-bar"), "the working workaround has to be named")
    }

    @Test func aTranslocatedCopyIsToldTheTruthAndOfferedNoRelaunch() throws {
        let copy = try #require(RelaunchPrompt.copy(for: .inputMonitoring, identity: Self.translocated))
        #expect(copy.relaunchTitle == nil, "relaunching a translocated copy only translocates again")
        #expect(copy.message.contains("xattr -dr com.apple.quarantine"))
        #expect(copy.dismissTitle == "OK")
    }
}
