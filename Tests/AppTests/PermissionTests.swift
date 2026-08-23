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

    @Test func systemCheckerReportsWithoutPrompting() {
        let s = SystemPermissionChecker()
        // Read-only TCC queries; values depend on the machine, only the shape is asserted.
        #expect(s.matrix().count == 3)
    }
}
