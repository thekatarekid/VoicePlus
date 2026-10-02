import Foundation
import Testing
import Shared
@testable import Injection

/// N5 — line breaks never send or run in apps no list names: web content (an `AXWebArea`
/// ancestor, or an Electron/Chromium runtime sniffed from the bundle) types ⇧↩; any terminal
/// surface gets bracketed paste; Return is never pressed.
@Suite struct WritePlanN5Tests {
    static let twoParagraphs = "Hello there.\n\nSecond paragraph"

    @Test func unknownAppInWebAreaTypesShiftReturnNotAX() {
        // Safari / Gemini-like: WebKit, no list entry, field inside an AXWebArea.
        let (injector, mock, _) = makeStack("com.apple.Safari") { $0.inWebArea = true }
        let outcome = injector.inject(InjectionRequest(text: Self.twoParagraphs, expectedFocus: mock.frontmost))
        guard case let .injected(method, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .keystroke)
        #expect(!mock.journal.contains("ax.setValue"))
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
        #expect(NewlineSafetyTests.combos(mock.journal) == ["36+shift", "36+shift"])
    }

    @Test(arguments: [SurfaceRuntime.electron, .chromium])
    func unlistedWebRuntimeTypesShiftReturn(runtime: SurfaceRuntime) {
        let (injector, mock, _) = makeStack("com.example.unnamed-wrapper") { $0.runtimeByPID[100] = runtime }
        _ = injector.inject(InjectionRequest(text: "a\nb", expectedFocus: mock.frontmost))
        #expect(!mock.journal.contains("ax.setValue"))
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
        #expect(NewlineSafetyTests.combos(mock.journal) == ["36+shift"])
    }

    @Test func defaultKeystrokeFallbackNeverPostsBareReturn() {
        // Native app whose AX write is not applicable: the keystroke fallback still uses ⇧↩.
        let (injector, mock, _) = makeStack("com.example.native") { $0.axWriteWorks = false }
        _ = injector.inject(InjectionRequest(text: "x\r\ny", expectedFocus: mock.frontmost))
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
    }

    @Test func nativeAppStillUsesAXFirst() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let outcome = injector.inject(InjectionRequest(text: "a\nb", expectedFocus: mock.frontmost))
        guard case let .injected(method, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .ax)
    }

    @Test(arguments: ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                      "com.github.wez.wezterm", "net.kovidgoyal.kitty", "io.alacritty"])
    func everyTerminalIdGetsBracketedPaste(bundleID: String) {
        let (injector, mock, _) = makeStack(bundleID)
        _ = injector.inject(InjectionRequest(text: "echo one\necho two", expectedFocus: mock.frontmost))
        #expect(mock.journal.contains { $0.hasPrefix("key.unicode") && $0.hasSuffix("\u{1B}[200~echo one\necho two\u{1B}[201~") }, "\(mock.journal)")
        #expect(!mock.journal.contains { $0.hasPrefix("key.combo") })
    }

    @Test func ptyBackedFieldInAnElectronAppGetsTerminalAdapter() {
        // VS Code integrated terminal: AXTextArea described "Terminal input", same bundle as the editor.
        let plan = WritePlanner.adapter(base: ElectronAdapter(),
                                        context: SurfaceWriteContext(runtime: .electron, hints: ["Terminal input"]))
        #expect(plan is TerminalAdapter)
        let editor = WritePlanner.adapter(base: ElectronAdapter(),
                                          context: SurfaceWriteContext(runtime: .electron, hints: ["Monaco editor"]))
        #expect(editor is ElectronAdapter)
    }

    @Test func resolverTerminalKindGetsBracketedPasteInAnyApp() {
        let (injector, mock, _) = makeStack("com.example.someterm")
        _ = injector.inject(InjectionRequest(text: "ls\npwd", expectedFocus: mock.frontmost, surfaceKind: .terminal))
        #expect(mock.journal.contains { $0.hasSuffix("\u{1B}[200~ls\npwd\u{1B}[201~") }, "\(mock.journal)")
        #expect(!mock.journal.contains("ax.setValue"))
    }

    @Test func chatComposerKindIsWebContent() {
        #expect(WritePlanner.adapter(base: DefaultAdapter(), context: SurfaceWriteContext(kind: .chatComposer)) is WebContentAdapter)
        #expect(WritePlanner.adapter(base: DefaultAdapter(), context: SurfaceWriteContext()) is DefaultAdapter)
        let cell = WritePlanner.adapter(base: DefaultAdapter(), context: SurfaceWriteContext(kind: .spreadsheetCell))
        #expect((cell as? WebContentAdapter)?.newlineCombo(focused: nil) == .optionReturn)
    }

    @Test func figmaLineBreaksAreShiftReturn() {
        let (injector, mock, _) = makeStack("com.figma.Desktop")
        _ = injector.inject(InjectionRequest(text: "comment\nline", expectedFocus: mock.frontmost))
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
    }

    // MARK: Runtime sniffing by bundle structure (fake layouts)

    static func fakeBundle(_ name: String, _ paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("n5-\(UUID().uuidString)/\(name).app")
        for p in paths {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(p), withIntermediateDirectories: true)
        }
        return root
    }

    @Test func sniffsRuntimeFromBundleLayout() throws {
        let electron = try Self.fakeBundle("Claude", ["Contents/Frameworks/Electron Framework.framework",
                                                      "Contents/Frameworks/Claude Helper (Renderer).app"])
        let chatGPT = try Self.fakeBundle("ChatGPT", ["Contents/Frameworks/OwlBridge.framework/Versions/A/Helpers/ChatGPT Helper (Renderer).app"])
        let dia = try Self.fakeBundle("Dia", ["Contents/Frameworks/ArcCore.framework/Versions/A/Helpers/Browser Helper (Renderer).app"])
        let comet = try Self.fakeBundle("Comet", ["Contents/Frameworks/Comet Framework.framework/Versions/1.0/Helpers/Comet Helper (Renderer).app"])
        let native = try Self.fakeBundle("Notes", ["Contents/Frameworks/Some.framework/Versions/A"])
        #expect(AppRuntimeSniffer.classify(bundleURL: electron) == .electron)
        #expect(AppRuntimeSniffer.classify(bundleURL: chatGPT) == .chromium)
        #expect(AppRuntimeSniffer.classify(bundleURL: dia) == .chromium)
        #expect(AppRuntimeSniffer.classify(bundleURL: comet) == .chromium)
        #expect(AppRuntimeSniffer.classify(bundleURL: native) == .native)
    }

    @Test func sniffIsCachedPerBundle() throws {
        let sniffer = AppRuntimeSniffer()
        let app = try Self.fakeBundle("X", ["Contents/Frameworks/X Helper (Renderer).app"])
        #expect(sniffer.runtime(bundleURL: app) == .chromium)
        #expect(sniffer.runtime(bundleURL: app) == .chromium)
        #expect(sniffer.scans == 1)
        #expect(sniffer.runtime(bundleURL: nil) == .unknown)
    }
}
