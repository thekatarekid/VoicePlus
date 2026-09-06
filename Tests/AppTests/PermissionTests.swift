import Foundation
import Testing
@testable import VoicePlusApp

@Suite("Permission matrix (T5)")
struct PermissionMatrixTests {
    /// The walk a default install gets since 1.6.8: microphone → accessibility. Input Monitoring is
    /// not in it, because no shipped hotkey binding consults `kTCCServiceListenEvent`.
    @Test(arguments: [
        ([:] as PermissionMatrix, PermissionPlanner.Step.prePrompt(.microphone)),
        ([.microphone: .granted], .prePrompt(.accessibility)),
        ([.microphone: .granted, .accessibility: .granted], .allGranted),
        ([.microphone: .granted, .inputMonitoring: .denied, .accessibility: .granted], .allGranted),
        ([.microphone: .denied, .accessibility: .granted], .openSettings(.microphone)),
        ([.microphone: .granted, .accessibility: .denied], .openSettings(.accessibility)),
    ])
    func nextStep(matrix: PermissionMatrix, expected: PermissionPlanner.Step) {
        #expect(PermissionPlanner.nextStep(matrix) == expected)
    }

    /// The same table for a build on the `hotkeyForceEventTap` escape hatch — the one configuration
    /// that still has to walk Input Monitoring.
    @Test(arguments: [
        ([.microphone: .granted] as PermissionMatrix, PermissionPlanner.Step.prePrompt(.inputMonitoring)),
        ([.microphone: .granted, .inputMonitoring: .granted], .prePrompt(.accessibility)),
        ([.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted], .allGranted),
        ([.microphone: .granted, .inputMonitoring: .denied], .openSettings(.inputMonitoring)),
        ([.microphone: .granted, .inputMonitoring: .notDetermined, .accessibility: .denied], .prePrompt(.inputMonitoring)),
    ])
    func nextStepOnTheEscapeHatch(matrix: PermissionMatrix, expected: PermissionPlanner.Step) {
        #expect(PermissionPlanner.nextStep(matrix, hotkeyRequires: .inputMonitoring) == expected)
    }

    @Test func capabilitiesAndFallback() {
        // The default backend needs no permission, so a denied Input Monitoring costs nothing.
        let free = PermissionPlanner.capabilities([.microphone: .granted, .inputMonitoring: .denied])
        #expect(free.canCapture && free.canUseGlobalHotkey && !free.canInjectText)
        #expect(!free.needsMenuFallback)
        // The escape hatch keeps the old gate, fallback copy included.
        let tapped = PermissionPlanner.capabilities([.microphone: .granted, .inputMonitoring: .denied],
                                                    hotkeyRequires: .inputMonitoring)
        #expect(tapped.canCapture && !tapped.canUseGlobalHotkey && !tapped.canInjectText)
        #expect(tapped.needsMenuFallback)
        #expect(PermissionPlanner.missing([.accessibility: .granted]) == [.microphone])
        #expect(PermissionPlanner.missing([.accessibility: .granted], hotkeyRequires: .inputMonitoring)
                == [.microphone, .inputMonitoring])
        #expect(Permission.inputMonitoring.settingsURL.absoluteString.contains("Privacy_ListenEvent"))
        for p in Permission.allCases { #expect(!p.rationale.isEmpty) }
    }

    /// `awaitingUserAction` is the honest answer for Input Monitoring / Accessibility (see
    /// `SystemPermissionChecker.request`); it must route to Settings, never back to a fresh prompt.
    @Test func awaitingUserActionRoutesToSettings() {
        #expect(PermissionPlanner.nextStep([.microphone: .granted, .accessibility: .awaitingUserAction])
                == .openSettings(.accessibility))
        #expect(PermissionPlanner.nextStep([.microphone: .granted, .inputMonitoring: .awaitingUserAction],
                                           hotkeyRequires: .inputMonitoring) == .openSettings(.inputMonitoring))
        let caps = PermissionPlanner.capabilities([.microphone: .granted, .inputMonitoring: .awaitingUserAction],
                                                  hotkeyRequires: .inputMonitoring)
        #expect(caps.needsMenuFallback)   // dictation still works from the menu bar
        #expect(PermissionPlanner.missing([.inputMonitoring: .awaitingUserAction], hotkeyRequires: .inputMonitoring)
                .contains(.inputMonitoring))
    }

    /// Modern pane id first, legacy `Security.prefPane` as the fallback. Anchors are the
    /// `revealElementKeyName` values macOS 26 ships in TCCServiceList.plist.
    @Test func settingsDeepLinksPreferTheModernPaneAndKeepALegacyFallback() {
        for p in Permission.allCases {
            let urls = p.settingsURLs.map(\.absoluteString)
            #expect(urls.count == 2)
            #expect(urls[0].contains("com.apple.settings.PrivacySecurity.extension"))
            #expect(urls[1].contains("com.apple.preference.security"))
            #expect(urls.allSatisfy { $0.hasSuffix("?\(p.settingsAnchor)") })
            #expect(p.settingsURL == p.settingsURLs[0])
        }
        #expect(Permission.inputMonitoring.settingsAnchor == "Privacy_ListenEvent")
        #expect(Permission.accessibility.settingsAnchor == "Privacy_Accessibility")
        // Onboarding shares the same links rather than keeping a second copy.
        #expect(OnboardingPermission.inputMonitoring.settingsURLs == Permission.inputMonitoring.settingsURLs)
    }

    @Test func diagnosticsNameTheIdentityAndTheResetCommand() {
        #expect(PermissionDiagnostics.summary().contains(PermissionDiagnostics.bundleIdentifier))
        #expect(PermissionDiagnostics.resetCommand(for: .inputMonitoring).hasPrefix("tccutil reset ListenEvent "))
        #expect(PermissionDiagnostics.resetCommand(for: .accessibility).contains("Accessibility"))
        #expect(PermissionDiagnostics.resetCommand(for: .microphone).contains("Microphone"))
    }
}

@Suite("Permission orchestrator")
struct PermissionOrchestratorTests {
    @Test func walksPrePromptVerifyForEachPermission() {
        let checker = MockPermissionChecker(grantOnRequest: Set(Permission.allCases))
        var prompted: [Permission] = []
        let o = PermissionOrchestrator(checker: checker, presentPrePrompt: { p, done in prompted.append(p); done(.proceed) },
                                       openSettings: { _ in Issue.record("should not open settings") },
                                       hotkeyRequires: nil)
        var result: PermissionMatrix?
        o.run { result = $0 }
        // Two prompts, not three: the hotkey costs nothing, so Input Monitoring is never asked for.
        #expect(prompted == [.microphone, .accessibility])
        #expect(checker.requested == prompted)
        #expect(result?[.microphone] == .granted && result?[.accessibility] == .granted)
        #expect(o.log.last == "all granted")
    }

    /// The escape hatch puts the third prompt back, in the middle where it used to be.
    @Test func theEscapeHatchWalksInputMonitoringToo() {
        let checker = MockPermissionChecker(grantOnRequest: Set(Permission.allCases))
        var prompted: [Permission] = []
        let o = PermissionOrchestrator(checker: checker, presentPrePrompt: { p, done in prompted.append(p); done(.proceed) },
                                       openSettings: { _ in Issue.record("should not open settings") },
                                       hotkeyRequires: .inputMonitoring)
        o.run { _ in }
        #expect(prompted == [.microphone, .inputMonitoring, .accessibility])
    }

    @Test func skipContinuesToNextAndDeniedOpensSettings() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted], grantOnRequest: [])
        var opened: [Permission] = []
        let o = PermissionOrchestrator(checker: checker, presentPrePrompt: { p, done in done(p == .inputMonitoring ? .skip : .proceed) },
                                       openSettings: { opened.append($0) }, hotkeyRequires: .inputMonitoring)
        var finished = false
        o.run { _ in finished = true }
        #expect(finished)
        #expect(checker.requested == [.accessibility])
        #expect(opened == [.accessibility])
        #expect(o.log.contains("skip:inputMonitoring"))
    }

    /// The orchestrator behind the menu-bar "Check permissions…" used to stop dead after opening
    /// System Settings. With a watcher installed it resumes the walk on the grant.
    @Test func watcherResumesTheWalkAfterSystemSettings() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted], grantOnRequest: [.accessibility])
        var opened: [Permission] = []
        var pending: [(Permission, () -> Void)] = []
        let o = PermissionOrchestrator(checker: checker, presentPrePrompt: { _, done in done(.proceed) },
                                       openSettings: { opened.append($0) }, hotkeyRequires: .inputMonitoring)
        o.watchUntilGranted = { p, granted in pending.append((p, granted)) }
        var matrices: [PermissionMatrix] = []
        o.run { matrices.append($0) }
        // Input Monitoring refused → Settings opened, and a watch armed rather than giving up.
        #expect(opened == [.inputMonitoring])
        #expect(pending.count == 1)
        // Two reports, not one: since 1.6.6 the walk publishes what is already granted *before* the
        // pre-prompt window goes up, so a capability the user already has is never withheld while a
        // modal sits on a different permission. That is the whole "Input Monitoring was granted and
        // the hotkey was never armed" failure.
        #expect(matrices.count == 2)
        #expect(matrices.first?[.microphone] == .granted)

        // The user grants it in System Settings; the poller fires.
        checker.statuses[.inputMonitoring] = .granted
        pending.removeFirst().1()
        #expect(checker.requested == [.inputMonitoring, .accessibility])
        #expect(o.log.contains("granted-after-settings:inputMonitoring"))
        #expect(matrices.last?[.accessibility] == .granted)
        #expect(o.log.last == "all granted")
    }

    @Test func systemCheckerReportsWithoutPrompting() {
        let s = SystemPermissionChecker()
        // Read-only TCC queries; values depend on the machine, only the shape is asserted.
        #expect(s.matrix().count == 3)
    }
}
