import Foundation
import Testing
import Shared
@testable import Injection

/// Q2 — Electron / Chromium expose their text fields only after `AXManualAccessibility` /
/// `AXEnhancedUserInterface` is set, and it must be set at key-down, before the caret read.
@Suite struct AppAccessibilityEnablerTests {
    static let claudeURL = URL(fileURLWithPath: "/Applications/Claude.app")
    static let electronFramework = "/Applications/Claude.app/Contents/Frameworks/Electron Framework.framework"

    // MARK: Classification

    @Test func electronIsDetectedByBundleContentsNotOnlyID() {
        let kind = AppAccessibilityKind.classify(bundleID: "com.example.unknown-electron-app",
                                                 bundleURL: Self.claudeURL,
                                                 fileExists: { $0 == Self.electronFramework })
        #expect(kind == .electron)
        #expect(kind.attribute == "AXManualAccessibility")
    }

    @Test func knownIDsClassifyWithoutTheFramework() {
        let none: (String) -> Bool = { _ in false }
        #expect(AppAccessibilityKind.classify(bundleID: "com.tinyspeck.slackmacgap", bundleURL: nil, fileExists: none) == .electron)
        #expect(AppAccessibilityKind.classify(bundleID: "com.google.Chrome", bundleURL: nil, fileExists: none) == .chromium)
        #expect(AppAccessibilityKind.classify(bundleID: "com.brave.Browser.beta", bundleURL: nil, fileExists: none).attribute == "AXEnhancedUserInterface")
        #expect(AppAccessibilityKind.classify(bundleID: "com.apple.TextEdit", bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), fileExists: none) == .native)
    }

    // MARK: Enabler: cache, relaunch, switch, own pid

    final class Recorder: @unchecked Sendable {
        var sets: [(Int32, String)] = []
        var succeed = true
    }

    static func enabler(_ recorder: Recorder, apps: [Int32: String], chromium: Bool = true) -> AppAccessibilityEnabler {
        AppAccessibilityEnabler(lookup: { pid in apps[pid].map { .init(bundleID: $0, bundleURL: nil) } },
                                setAttribute: { pid, attr in recorder.sets.append((pid, attr)); return recorder.succeed },
                                fileExists: { _ in false },
                                chromiumEnabled: { chromium })
    }

    @Test func setsOncePerPidAndReappliesOnRelaunch() {
        let recorder = Recorder()
        let enabler = Self.enabler(recorder, apps: [200: "com.anthropic.claudefordesktop", 201: "com.anthropic.claudefordesktop"])
        #expect(enabler.enable(pid: 200))
        #expect(enabler.enable(pid: 200))
        #expect(recorder.sets.count == 1, "cached per pid")
        // Relaunch: a new pid is a cache miss, so the attribute is set again.
        #expect(enabler.enable(pid: 201))
        #expect(recorder.sets.map(\.0) == [200, 201])
        #expect(recorder.sets.allSatisfy { $0.1 == "AXManualAccessibility" })
    }

    @Test func aFailedSetIsRetriedNextTime() {
        let recorder = Recorder()
        recorder.succeed = false
        let enabler = Self.enabler(recorder, apps: [300: "com.tinyspeck.slackmacgap"])
        #expect(!enabler.enable(pid: 300))
        recorder.succeed = true
        #expect(enabler.enable(pid: 300))
        #expect(recorder.sets.count == 2)
    }

    @Test func chromiumHonoursTheSwitch() {
        let recorder = Recorder()
        #expect(!Self.enabler(recorder, apps: [400: "com.google.Chrome"], chromium: false).enable(pid: 400))
        #expect(recorder.sets.isEmpty)
        #expect(Self.enabler(recorder, apps: [400: "com.google.Chrome"], chromium: true).enable(pid: 400))
        #expect(recorder.sets.first?.1 == "AXEnhancedUserInterface")
    }

    @Test func nativeAppsAndOurOwnProcessAreNeverTouched() {
        let recorder = Recorder()
        let enabler = Self.enabler(recorder, apps: [500: "com.apple.TextEdit", OwnProcess.pid: "com.example.self"])
        #expect(!enabler.enable(pid: 500))
        #expect(!enabler.enable(pid: OwnProcess.pid))
        #expect(recorder.sets.isEmpty)
    }

    @Test func switchDefaultsToOn() {
        let defaults = UserDefaults(suiteName: "q2-\(UUID().uuidString)")!
        #expect(InjectionSettingsKeys.exposeChromiumText(defaults))
        defaults.set(false, forKey: InjectionSettingsKeys.exposeChromiumText)
        #expect(!InjectionSettingsKeys.exposeChromiumText(defaults))
    }

    // MARK: Mock: the caret appears only after enabling, and key-down enables before reading

    static func electronMock() -> MockSystemAccess {
        let mock = MockSystemAccess(frontmost: FocusSnapshot(pid: 200, bundleID: "com.anthropic.claudefordesktop",
                                                             appName: "Claude", elementToken: "composer"))
        mock.field = MockSystemAccess.Field(value: "Hi ", selection: 3..<3)
        mock.requiresAccessibilityEnable = true
        return mock
    }

    @Test func mockExposesTheCaretOnlyAfterEnable() throws {
        let mock = Self.electronMock()
        #expect(try mock.focusedElement().selectedRange == nil)
        #expect(try mock.focusedElement().value == nil)
        mock.enableAppAccessibility(pid: 200)
        #expect(try mock.focusedElement().selectedRange == 3..<3)
        #expect(try mock.focusedElement().value == "Hi ")
    }

    @Test func keyDownEnablesBeforeTheCaretRead() {
        let mock = Self.electronMock()
        let revision = FocusGuard(system: mock).targetRevision()
        #expect(mock.accessibilityEvents.first == "enable(200)")
        #expect(mock.accessibilityEvents.dropFirst().first == "read(tree)")
        #expect(revision.selection == 3..<3, "the caret is readable at key-down")
    }

    @Test func injectorEnablesBeforeItsFirstReadSoReadbackConfirms() {
        let mock = Self.electronMock()
        let injector = TextInjector(system: mock)
        let outcome = injector.inject(InjectionRequest(text: "there", expectedFocus: mock.frontmost))
        #expect(mock.accessibilityEvents.first == "enable(200)")
        #expect(!mock.accessibilityEvents.contains("read(no tree)"))
        #expect(outcome == .injected(method: .keystroke, verified: true), "readback ran: not 'unavailable'")
    }

    @Test func withoutEnablingReadbackWouldBeUnavailable() {
        // The bug Q2 fixes, reproduced on a system that cannot enable: no tree, no verdict.
        let info = FocusedElementInfo(role: "AXTextArea", value: nil, selectedRange: nil,
                                      isValueSettable: false, isSelectedTextSettable: false)
        #expect(ElectronAdapter().verifyReadback(text: "x", before: info, after: info) == .unavailable)
    }
}
