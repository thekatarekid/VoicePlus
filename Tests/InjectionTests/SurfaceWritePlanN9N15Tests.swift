import Foundation
import Testing
import Shared
@testable import Injection

/// N9-integrate — the write plan comes from the resolver's surface kind; the bundle id only names
/// the starting adapter, and the adapters' bundle lists are the one seed table (no private lists).
/// N15 — a canvas with nothing editable focused is held ("Click into a text box first"), by role.
@Suite struct SurfaceWritePlanN9N15Tests {
    static func res(_ kind: SurfaceKind, web: Bool = false) -> SurfaceResolution {
        SurfaceResolution(kind: kind, confidence: 0.9, isWebArea: web, signals: ["test"])
    }

    struct Row: CustomStringConvertible, Sendable {
        var bundle: String
        var surface: SurfaceResolution?
        var adapter: String
        var description: String { "\(bundle) \(surface?.recordValue ?? "nil") → \(adapter)" }
    }

    static let table: [Row] = [
        // Known apps keep their adapter when the surface agrees.
        Row(bundle: "com.apple.Terminal", surface: res(.terminal), adapter: "terminal"),
        Row(bundle: "com.google.Chrome", surface: res(.chatComposer, web: true), adapter: "chromium"),
        Row(bundle: "com.microsoft.Excel", surface: res(.spreadsheetCell), adapter: "spreadsheet"),
        Row(bundle: "com.apple.TextEdit", surface: res(.prose), adapter: "default"),
        // The surface decides, not the app: an IDE's terminal pane, an unlisted emulator.
        Row(bundle: "com.microsoft.VSCode", surface: res(.terminal, web: true), adapter: "terminal"),
        Row(bundle: "com.unknown.TermApp", surface: res(.terminal), adapter: "terminal"),
        // Unknown apps: web content / empty tree → ⇧↩ keystroke plan; Safari's Gemini too.
        Row(bundle: "com.openai.chat", surface: res(.chatComposer, web: true), adapter: "webContent"),
        Row(bundle: "com.unknown.Wrapper", surface: res(.prose, web: true), adapter: "webContent"),
        Row(bundle: "com.apple.Safari", surface: res(.chatComposer, web: true), adapter: "webContent"),
        Row(bundle: "com.unknown.Wrapper", surface: res(.spreadsheetCell, web: true), adapter: "webContent"),
        // Unknown native prose keeps the default plan; nil surface keeps the bundle adapter.
        Row(bundle: "com.unknown.NativeApp", surface: res(.prose), adapter: "default"),
        Row(bundle: "com.google.Chrome", surface: nil, adapter: "chromium"),
    ]

    @Test(arguments: table)
    func planBySurface(_ row: Row) {
        #expect(AdapterRegistry.standard().adapter(for: row.bundle, surface: row.surface).id == row.adapter)
    }

    @Test func webPlanNeverPostsBareReturn() {
        let a = AdapterRegistry.standard().adapter(for: "com.unknown.Wrapper", surface: Self.res(.prose, web: true))
        #expect(a is NewlineSafeAdapter)
        #expect(!a.methodOrder.contains(.ax))
        #expect(WritePlanner.newlineCombo(adapter: a, focused: nil) == .shiftReturn)
    }

    // MARK: no private lists

    @Test func adapterListsAreTheSeedTable() {
        #expect(TerminalAdapter.bundleIDs == SeedHints.bundleIDs(.terminal))
        #expect(SpreadsheetAdapter.bundleIDs == SeedHints.bundleIDs(.spreadsheet))
        #expect(ChromiumAdapter.bundleIDs.allSatisfy { SeedHints.hint(for: $0)?.runtime == .chromium })
        #expect(ElectronAdapter.bundleIDs.allSatisfy { SeedHints.hint(for: $0)?.runtime == .electron })
        #expect(ElectronAdapter.bundleIDs.contains(ElectronAdapter.claudeDesktopBundleID))
        // Release-channel siblings still match through the seed's browser prefix rule.
        #expect(ChromiumAdapter().matches(bundleID: "com.google.Chrome.canary"))
        // An unlisted app matches no named adapter: it is resolved from structure alone.
        #expect(AdapterRegistry.standard().adapter(for: "com.example.unlisted").id == "default")
    }

    @Test func cursorMatchIsWordLevel() {
        #expect(CursorAdapter().matches(bundleID: "com.anysphere.cursor"))
        #expect(CursorAdapter().matches(bundleID: CursorAdapter.toDesktopBundleID))
        #expect(!CursorAdapter().matches(bundleID: "com.example.cursorpaint"))
    }

    // MARK: injector uses the request's surface

    @Test func injectorPicksPlanFromRequestSurface() {
        // A native-looking unlisted app whose key-down surface was web content: keystrokes with ⇧↩.
        let (injector, mock, _) = makeStack("com.unknown.Wrapper", value: "") { $0.axWriteWorks = true }
        let outcome = injector.inject(InjectionRequest(text: "one\ntwo", surface: Self.res(.chatComposer, web: true)))
        #expect(outcome.succeeded)
        #expect(!mock.journal.contains { $0.hasPrefix("ax.") })
        #expect(!mock.journal.contains { $0.hasPrefix("key.combo") && $0.hasSuffix(":36") })
        #expect(!mock.journal.contains { $0.hasPrefix("key.unicode") && $0.contains("\n") })
        #expect(mock.journal.contains { $0.hasPrefix("key.combo") && $0.hasSuffix(":36+shift") })
    }

    @Test func requestSurfaceFillsKind() {
        let r = InjectionRequest(text: "x", surface: Self.res(.terminal))
        #expect(r.surfaceKind == .terminal)
        #expect(InjectionRequest(text: "x", surfaceKind: .prose, surface: Self.res(.terminal)).surfaceKind == .prose)
    }

    // MARK: N15 — role-based canvas hold

    static func info(_ role: String, subrole: String? = nil, settable: Bool = false, hints: [String] = []) -> FocusedElementInfo {
        FocusedElementInfo(role: role, value: nil, selectedRange: nil, isValueSettable: settable,
                           isSelectedTextSettable: false, subrole: subrole, hints: hints)
    }

    @Test func canvasFocusIsStructural() {
        #expect(CanvasFocus.isCanvasLike(Self.info("AXCanvas")))
        #expect(CanvasFocus.isCanvasLike(Self.info("AXGroup", subrole: "AXCanvas")))
        #expect(CanvasFocus.isCanvasLike(Self.info("AXGroup", hints: ["canvas"])))
        #expect(CanvasFocus.isCanvasLike(Self.info("AXLayoutArea")))
        // Editable text is never held, even inside a canvas.
        #expect(!CanvasFocus.isCanvasLike(Self.info("AXCanvas", settable: true)))
        #expect(!CanvasFocus.isCanvasLike(Self.info("AXTextArea", hints: ["canvas"])))
        // Unfamiliar roles and words that merely mention a canvas are not refused.
        #expect(!CanvasFocus.isCanvasLike(Self.info("AXGroup")))
        #expect(!CanvasFocus.isCanvasLike(Self.info("AXButton", hints: ["Canvas settings"])))
        #expect(!CanvasFocus.isCanvasLike(nil))
        #expect(CanvasFocus.editable(Self.info("AXTextArea")) == nil)   // unreadable: not proved
        #expect(CanvasFocus.editable(FocusedElementInfo(role: "AXTextArea", value: "", selectedRange: nil,
                                                        isValueSettable: false, isSelectedTextSettable: false)) == true)
        #expect(CanvasFocus.editable(Self.info("AXCanvas")) == false)
        #expect(CanvasFocus.editable(Self.info("AXGroup")) == nil)
    }

    @Test func canvasWithNothingEditableIsHeldNothingTyped() {
        let (injector, mock, _) = makeStack("com.figma.Desktop") {
            $0.field = MockSystemAccess.Field(role: "AXGroup", hints: ["canvas"]); $0.axWriteWorks = false
        }
        let outcome = injector.inject(InjectionRequest(text: "hello world"))
        #expect(!outcome.succeeded)
        #expect(injector.lastLadderDecision == .hold(.notEditable))
        #expect(mock.postCount == 0)
        #expect(injector.focusGuard.held.last?.reason == "Click into a text box first")
    }

    @Test func unknownAppCanvasIsHeldToo() {
        let (injector, mock, _) = makeStack("com.example.whiteboard") {
            $0.field = MockSystemAccess.Field(role: "AXCanvas"); $0.axWriteWorks = false
        }
        _ = injector.inject(InjectionRequest(text: "rectangle"))
        #expect(injector.lastLadderDecision == .hold(.notEditable))
        #expect(mock.postCount == 0)
    }

    @Test func textBoxInCanvasAppLands() {
        let (injector, _, _) = makeStack("com.figma.Desktop") {
            $0.field = MockSystemAccess.Field(role: "AXTextArea"); $0.axWriteWorks = false
        }
        let outcome = injector.inject(InjectionRequest(text: "label", surfaceKind: .canvas))
        #expect(outcome.succeeded)
    }

    @Test func keyDownCanvasWithUnprovedTextFieldStaysHeld() {
        // A hidden, unreadable keyboard-capture field does not lift a key-down canvas.
        let (injector, mock, _) = makeStack("com.example.slides") { $0.axReadable = false }
        _ = injector.inject(InjectionRequest(text: "title", surface: Self.res(.canvas)))
        #expect(injector.lastLadderDecision == .hold(.notEditable))
        #expect(mock.postCount == 0)
    }

    @Test func keyDownCanvasButNowATextBoxLands() {
        // The resolver said canvas at key-down; the user then clicked into a text layer.
        let (injector, _, _) = makeStack("com.example.slides") { $0.field = MockSystemAccess.Field(role: "AXTextArea") }
        #expect(injector.inject(InjectionRequest(text: "title", surface: Self.res(.canvas))).succeeded)
    }
}
