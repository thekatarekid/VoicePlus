import Foundation
import Testing
@testable import VoicePlusApp

@Suite("Permission matrix (T5)")
struct PermissionMatrixTests {
    @Test(arguments: [
        ([:] as PermissionMatrix, PermissionPlanner.Step.prePrompt(.microphone)),
        ([.microphone: .granted], .prePrompt(.inputMonitoring)),
        ([.microphone: .granted, .inputMonitoring: .granted], .prePrompt(.accessibility)),
        ([.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted], .allGranted),
        ([.microphone: .denied, .inputMonitoring: .granted, .accessibility: .granted], .openSettings(.microphone)),
        ([.microphone: .granted, .inputMonitoring: .denied], .openSettings(.inputMonitoring)),
        ([.microphone: .granted, .inputMonitoring: .notDetermined, .accessibility: .denied], .prePrompt(.inputMonitoring)),
    ])
    func nextStep(matrix: PermissionMatrix, expected: PermissionPlanner.Step) {
        #expect(PermissionPlanner.nextStep(matrix) == expected)
    }

    @Test func capabilitiesAndFallback() {
        let caps = PermissionPlanner.capabilities([.microphone: .granted, .inputMonitoring: .denied])
        #expect(caps.canCapture && !caps.canUseGlobalHotkey && !caps.canInjectText)
        #expect(caps.needsMenuFallback)
        #expect(PermissionPlanner.missing([.accessibility: .granted]) == [.microphone, .inputMonitoring])
        #expect(Permission.inputMonitoring.settingsURL.absoluteString.contains("Privacy_ListenEvent"))
        for p in Permission.allCases { #expect(!p.rationale.isEmpty) }
    }

    /// `awaitingUserAction` is the honest answer for Input Monitoring / Accessibility (see
    /// `SystemPermissionChecker.request`); it must route to Settings, never back to a fresh prompt.
    @Test func awaitingUserActionRoutesToSettings() {
        #expect(PermissionPlanner.nextStep([.microphone: .granted, .inputMonitoring: .awaitingUserAction])
                == .openSettings(.inputMonitoring))
        let caps = PermissionPlanner.capabilities([.microphone: .granted, .inputMonitoring: .awaitingUserAction])
        #expect(caps.needsMenuFallback)   // dictation still works from the menu bar
        #expect(PermissionPlanner.missing([.inputMonitoring: .awaitingUserAction]).contains(.inputMonitoring))
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
                                       openSettings: { _ in Issue.record("should not open settings") })
        var result: PermissionMatrix?
        o.run { result = $0 }
        #expect(prompted == [.microphone, .inputMonitoring, .accessibility])
        #expect(checker.requested == prompted)
        #expect(result == [.microphone: .granted, .inputMonitoring: .granted, .accessibility: .granted])
        #expect(o.log.last == "all granted")
    }

    @Test func skipContinuesToNextAndDeniedOpensSettings() {
        let checker = MockPermissionChecker(statuses: [.microphone: .granted], grantOnRequest: [])
        var opened: [Permission] = []
        let o = PermissionOrchestrator(checker: checker, presentPrePrompt: { p, done in done(p == .inputMonitoring ? .skip : .proceed) },
                                       openSettings: { opened.append($0) })
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
                                       openSettings: { opened.append($0) })
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
