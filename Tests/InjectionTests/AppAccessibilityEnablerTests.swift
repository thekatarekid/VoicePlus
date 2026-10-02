import Foundation
import Testing
import Shared
@testable import Injection

/// Q2 / N10 — accessibility is turned on by trying, not by recognising the app: the harmless
/// manual switch on any app, a probe, and the enhanced switch only after a failed probe in a
/// bundle that ships a `… (Renderer).app` helper. Set at key-down, before the caret read.
@Suite struct AppAccessibilityEnablerTests {

    // MARK: Fake bundle layouts (structural check, no name lists)

    /// Builds `<tmp>/<name>.app` with the given relative directories.
    static func fakeBundle(_ name: String, dirs: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("n10-\(UUID().uuidString)").appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        for d in dirs {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        return root
    }

    /// ChatGPT (Owl runtime): the renderer helper sits inside a framework's Helpers folder.
    static func chatGPT() throws -> URL {
        try fakeBundle("ChatGPT", dirs: ["Contents/Frameworks/OwlBridge.framework/Versions/A/Helpers/ChatGPT Helper (Renderer).app/Contents/MacOS"])
    }
    /// Dia: ArcCore.framework carries the helpers.
    static func dia() throws -> URL {
        try fakeBundle("Dia", dirs: ["Contents/Frameworks/ArcCore.framework/Versions/A/Helpers/Browser Helper (Renderer).app"])
    }
    /// Comet: Chromium layout under its own framework name.
    static func comet() throws -> URL {
        try fakeBundle("Comet", dirs: ["Contents/Frameworks/Comet Framework.framework/Versions/140.0/Helpers/Comet Helper (Renderer).app"])
    }
    static func native() throws -> URL {
        try fakeBundle("Notes", dirs: ["Contents/Frameworks/Something.framework/Versions/A"])
    }
    static func electron() throws -> URL {
        try fakeBundle("Wrapper", dirs: ["Contents/Frameworks/Electron Framework.framework",
                                         "Contents/Frameworks/Wrapper Helper (Renderer).app"])
    }

    @Test func rendererHelperFoundInEveryChromiumLayout() throws {
        for url in [try Self.chatGPT(), try Self.dia(), try Self.comet()] {
            #expect(AppRuntimeSniffer.hasRendererHelper(under: url.appendingPathComponent("Contents/Frameworks"), maxDepth: 5),
                    "\(url.lastPathComponent)")
            #expect(AppAccessibilityKind.classify(bundleURL: url) == .chromium)
        }
        #expect(AppAccessibilityKind.classify(bundleURL: try Self.native()) == .native)
        #expect(AppAccessibilityKind.classify(bundleURL: try Self.electron()) == .electron)
        #expect(AppAccessibilityKind.classify(bundleURL: nil) == .native)
    }

    // MARK: The enabler

    final class World: @unchecked Sendable {
        var sets: [(Int32, String)] = []
        /// Whether the app answers the manual set (native apps refuse it).
        var manualAccepted = false
        /// The tree becomes editable after which attribute (nil = already editable, "never" = never).
        var editableAfter: String? = "never"
        var webArea = false
        var probes = 0
        var setOK: Bool = true

        func probe() -> AppAccessibilityProbe {
            probes += 1
            let names = Set(sets.map(\.1))
            let editable: Bool
            switch editableAfter {
            case nil: editable = true
            case "never": editable = false
            case let attr?: editable = names.contains(attr)
            }
            return AppAccessibilityProbe(editable: editable, inWebArea: editable && webArea)
        }
    }

    static func enabler(_ w: World, apps: [Int32: AppAccessibilityEnabler.App], chromium: Bool = true,
                        off: Set<String> = []) -> AppAccessibilityEnabler {
        AppAccessibilityEnabler(
            lookup: { apps[$0] },
            setAttribute: { pid, attr in
                w.sets.append((pid, attr))
                return attr == AppAccessibilityKind.electronAttribute ? w.manualAccepted : w.setOK
            },
            probe: { _ in w.probe() },
            chromiumEnabled: { chromium },
            appDisabled: { off.contains($0 ?? "") })
    }

    @Test func chatGPTGetsEnhancedOnlyAfterAFailedProbe() throws {
        let w = World()
        w.manualAccepted = false
        w.editableAfter = AppAccessibilityKind.chromiumAttribute
        w.webArea = true
        let e = Self.enabler(w, apps: [10: .init(bundleID: "com.openai.chat", bundleURL: try Self.chatGPT(), version: "1.0")])
        #expect(e.enable(pid: 10))
        #expect(w.sets.map(\.1) == ["AXManualAccessibility", "AXEnhancedUserInterface"], "manual first, enhanced after the failed probe")
        #expect(w.probes == 2)
        let o = try #require(e.outcome(pid: 10))
        #expect(o.switchUsed == .enhanced)
        #expect(o.inWebArea, "web content from the AXWebArea ancestor")
        // Cached: the next key-down sets nothing and probes nothing.
        #expect(e.enable(pid: 10))
        #expect(w.sets.count == 2)
        #expect(w.probes == 2)
    }

    @Test func diaAndCometAreRecognisedStructurally() throws {
        for (pid, url) in [(Int32(20), try Self.dia()), (21, try Self.comet())] {
            let w = World()
            w.editableAfter = AppAccessibilityKind.chromiumAttribute
            let e = Self.enabler(w, apps: [pid: .init(bundleID: "com.unlisted.\(pid)", bundleURL: url)])
            #expect(e.enable(pid: pid))
            #expect(e.outcome(pid: pid)?.switchUsed == .enhanced)
        }
    }

    @Test func electronIsReadableWithTheManualSwitchAlone() throws {
        let w = World()
        w.manualAccepted = true
        w.editableAfter = AppAccessibilityKind.electronAttribute
        w.webArea = true
        let e = Self.enabler(w, apps: [30: .init(bundleID: "com.example.wrapper", bundleURL: try Self.electron())])
        #expect(e.enable(pid: 30))
        #expect(w.sets.map(\.1) == ["AXManualAccessibility"], "no enhanced: the probe succeeded")
        #expect(e.outcome(pid: 30)?.switchUsed == .manual)
    }

    @Test func aNativeAppNeverGetsTheEnhancedAttribute() throws {
        let w = World()
        w.editableAfter = "never"   // e.g. focus on a button, or a canvas
        let e = Self.enabler(w, apps: [40: .init(bundleID: "com.apple.Notes", bundleURL: try Self.native())])
        #expect(!e.enable(pid: 40))
        #expect(!e.enable(pid: 40))
        #expect(w.sets.map(\.1) == ["AXManualAccessibility"], "manual tried once per process+version, enhanced never")
        #expect(e.outcome(pid: 40)?.switchUsed == .unresolved)
        #expect(e.rendererScans == 1, "structural check cached")
    }

    @Test func aReadableNativeFieldLogsNoSwitch() throws {
        let w = World()
        w.editableAfter = nil
        let e = Self.enabler(w, apps: [41: .init(bundleID: "com.apple.TextEdit", bundleURL: try Self.native())])
        #expect(e.enable(pid: 41))
        #expect(e.outcome(pid: 41)?.switchUsed == AppAccessibilitySwitch.none)
        #expect(e.outcome(pid: 41)?.inWebArea == false)
    }

    @Test func chromiumSettingOffKeepsOnlyTheHarmlessSwitch() throws {
        let w = World()
        w.editableAfter = AppAccessibilityKind.chromiumAttribute
        let e = Self.enabler(w, apps: [50: .init(bundleID: "com.google.Chrome", bundleURL: try Self.comet())], chromium: false)
        #expect(!e.enable(pid: 50))
        #expect(!w.sets.contains { $0.1 == "AXEnhancedUserInterface" })
        #expect(e.outcome(pid: 50)?.switchUsed == .unresolved)
    }

    @Test func perAppOffSwitchSetsNothing() throws {
        let w = World()
        w.editableAfter = nil
        let e = Self.enabler(w, apps: [60: .init(bundleID: "com.openai.chat", bundleURL: try Self.chatGPT())],
                             off: ["com.openai.chat"])
        #expect(!e.enable(pid: 60))
        #expect(w.sets.isEmpty)
        #expect(w.probes == 0)
        #expect(e.outcome(pid: 60)?.switchUsed == .off)
    }

    @Test func enhancedIsNeverSetTwiceAndAnUnresolvedTreeIsReprobed() throws {
        let w = World()
        w.editableAfter = "never"
        let e = Self.enabler(w, apps: [70: .init(bundleID: "x", bundleURL: try Self.comet())])
        #expect(!e.enable(pid: 70))
        #expect(!e.enable(pid: 70))
        #expect(w.sets.filter { $0.1 == "AXEnhancedUserInterface" }.count == 1)
        #expect(w.probes == 3, "two probes the first time, one after")
        // The user clicks into the composer: the next key-down finds it.
        w.editableAfter = nil
        #expect(e.enable(pid: 70))
    }

    @Test func manualIsRetriedForANewVersionOrProcess() throws {
        let w = World()
        w.editableAfter = "never"
        var apps: [Int32: AppAccessibilityEnabler.App] = [80: .init(bundleID: "a", bundleURL: try Self.native(), version: "1")]
        let e = Self.enabler(w, apps: apps)
        e.enable(pid: 80); e.enable(pid: 80)
        #expect(w.sets.count == 1)
        apps[81] = .init(bundleID: "a", bundleURL: nil, version: "2")
        e.lookup = { apps[$0] }
        e.enable(pid: 81)
        #expect(w.sets.count == 2)
    }

    @Test func ourOwnProcessIsNeverTouched() {
        let w = World()
        let e = Self.enabler(w, apps: [OwnProcess.pid: .init(bundleID: "self", bundleURL: nil)])
        #expect(!e.enable(pid: OwnProcess.pid))
        #expect(w.sets.isEmpty)
    }

    @Test func switchesDefault() {
        let defaults = UserDefaults(suiteName: "q2-\(UUID().uuidString)")!
        #expect(InjectionSettingsKeys.exposeChromiumText(defaults))
        defaults.set(false, forKey: InjectionSettingsKeys.exposeChromiumText)
        #expect(!InjectionSettingsKeys.exposeChromiumText(defaults))
        #expect(!InjectionSettingsKeys.accessibilityOff(bundleID: "com.x", defaults))
        defaults.set(["com.x"], forKey: InjectionSettingsKeys.accessibilityOffApps)
        #expect(InjectionSettingsKeys.accessibilityOff(bundleID: "com.x", defaults))
    }

    @Test func webAreaDrivesShiftReturn() {
        // (4) the web-content flag from the probe feeds the write plan: ⇧↩, never a bare Return.
        let plan = SurfaceWriteContext(isInWebArea: true, runtime: .native)
        #expect(plan.isWebContent)
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
