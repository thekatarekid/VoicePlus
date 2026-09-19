import AppKit
import Engine
import Foundation
import Injection
import Pipeline
import Shared
import SwiftUI
import Testing
@testable import VoicePlusApp

/// FX1 — the onboarding "Try your first sentence" freeze, end to end. A real hold turn goes through
/// the production `TurnController` → `UtteranceLander` → `TextInjector` → `LiveSystemAccess` into a
/// TextKit 2 text view in an off-screen window of *this* process — the shape of the practice field.
///
/// Before the fix the write was `AXUIElementSetAttributeValue(kAXSelectedText)` from the gate's
/// background task, which macOS runs in-process on that thread: AppKit edited the view off the main
/// thread and deadlocked against the main thread's layout. Here the turn must complete, the text must
/// be in the view, the one insert must have run on the main thread, and no AX setter may have run.
/// The system under test is the real `LiveSystemAccess` behind a recorder that refuses anything that
/// would touch the real machine (AX setters, CGEvents, the pasteboard).
@Suite("FX1 — a hold turn into VoicePlus's own text view completes")
struct OwnProcessTurnTests {
    static func words(_ text: String, confidence: Float = 0.95) -> [TranscriptSpan] {
        [TranscriptSpan(text: text, confidence: confidence, audioRange: 0...1, provenance: [.asr], stability: .final)]
    }

    /// `LiveSystemAccess` pointed at our own window, with a thread log.
    final class OwnWindowSystem: SystemAccess, InProcessTextDelivering, @unchecked Sendable {
        let live: LiveSystemAccess
        private let lock = NSLock()
        private var _calls: [(name: String, onMain: Bool)] = []
        private var pasteboard = 0

        init(live: LiveSystemAccess) { self.live = live }

        var calls: [(name: String, onMain: Bool)] { lock.withLock { _calls } }
        /// Anything that would have gone through AX or posted events: must stay empty.
        var refused: [String] { calls.map(\.name).filter { $0.hasPrefix("ax.set") || $0.hasPrefix("post") } }
        var inserts: [Bool] { calls.filter { $0.name == "own.insert" }.map(\.onMain) }
        private func log(_ name: String) { lock.withLock { _calls.append((name, Thread.isMainThread)) } }

        var isAccessibilityTrusted: Bool { live.isAccessibilityTrusted }
        var postCount: Int { live.postCount }
        func frontmostApp() -> FocusSnapshot? { live.frontmostApp() }
        func focusedElement() throws -> FocusedElementInfo { log("focusedElement"); return try live.focusedElement() }
        func setFocusedValue(_ value: String) throws { log("ax.setValue"); throw SystemAccessError.attributeNotSettable("AXValue") }
        func setFocusedSelectedRange(_ range: Range<Int>) throws { log("ax.setSelectedRange"); throw SystemAccessError.attributeNotSettable("AXSelectedTextRange") }
        func setFocusedSelectedText(_ text: String) throws { log("ax.setSelectedText"); throw SystemAccessError.attributeNotSettable("AXSelectedText") }
        func postUnicodeKeystrokes(_ text: String, toPID pid: Int32) throws { log("postKeystrokes"); throw SystemAccessError.eventPostFailed }
        func postKeyCombo(_ combo: KeyCombo, toPID pid: Int32) throws { log("postKeyCombo"); throw SystemAccessError.eventPostFailed }
        func readPasteboard() -> PasteboardSnapshot { PasteboardSnapshot(items: [], changeCount: pasteboard) }
        func writePasteboard(string: String) -> Int { log("postPaste"); pasteboard += 1; return pasteboard }
        func restorePasteboard(_ snapshot: PasteboardSnapshot) {}
        var pasteboardChangeCount: Int { pasteboard }
        func settle(milliseconds: Int) {}

        func ownFocusedText() -> FocusedElementInfo? { live.ownFocusedText() }
        func insertIntoOwnFocusedText(_ text: String) throws -> Bool {
            log("own.insert")
            return try live.insertIntoOwnFocusedText(text)
        }
    }

    /// The production turn stack over `system`, on a manual commit clock.
    struct Rig {
        let system: OwnWindowSystem
        let injector: TextInjector
        let lander: UtteranceLander
        let store: TurnStore
        let clock = TurnControllerTests.ManualClock()
        let events = TurnControllerTests.Events()
        let controller: TurnController

        init(system: OwnWindowSystem) {
            self.system = system
            injector = TextInjector(system: system)
            injector.mainThreadWriteTimeout = 30
            lander = UtteranceLander(pipeline: PipelineRunner(stages: []), injector: injector, system: system,
                                     repair: nil, flags: .inMemory(), database: nil)
            let reader = FieldContextReader(system: system)
            lander.fieldContextProvider = { reader.fieldContext(bundleID: $0) }
            store = TurnStore(database: nil)
            controller = TurnController(lander: lander, focusGuard: injector.focusGuard, store: store, clock: clock,
                                        targets: FocusGuardTargetReader(focusGuard: injector.focusGuard, display: { 7 }),
                                        dwell: { .standard })
            controller.ui = { $0() }
            controller.snapshotQueue = { $0() }
            lander.gate = controller
            events.attach(to: controller)
        }

        /// Key down → capture → key up → final pass: the payload is in the preview.
        func hold(_ spans: [TranscriptSpan]) async -> TurnID? {
            guard case .began(let id) = controller.keyDown() else { return nil }
            controller.captureOpened(id)
            guard controller.keyUp(id) else { return nil }
            await controller.finalize(id, spans: spans)
            return id
        }

        /// Real-time poll, bounded: a hang fails the test instead of stalling the run.
        func wait(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return condition()
        }
    }

    /// An off-screen window holding a TextKit 2 text view.
    final class OwnWindow: @unchecked Sendable {
        let window: NSWindow
        let textView: NSTextView

        @MainActor init(text: String) {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 360, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 140))
            window.contentView = textView
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        @MainActor var text: String { textView.string }
    }

    @MainActor static func live(pointingAt view: NSText) -> LiveSystemAccess {
        let live = LiveSystemAccess()
        live.frontmostApplication = { NSRunningApplication.current }
        live.ownTextResponder = { view }
        // A parallel test run can keep the main thread busy longer than the live timeouts.
        live.mainThreadReadTimeout = 30
        live.mainThreadWriteTimeout = 30
        return live
    }

    // MARK: - The turn

    @Test("a hold turn into our own TextKit 2 text view completes: text in the view, one insert on main, no AX write")
    func holdTurnIntoOwnTextView() async throws {
        let target = await MainActor.run { OwnWindow(text: "Dear Mira, ") }
        let system = await MainActor.run { OwnWindowSystem(live: Self.live(pointingAt: target.textView)) }
        #expect(await MainActor.run { target.textView.textLayoutManager != nil }, "TextKit 2, as the practice field")
        let rig = Rig(system: system)

        // This test runs off the main thread, so the key-down snapshot, the land-time field read and
        // the end-of-dwell revalidation all read our own view from a background thread: each must hop.
        let id = try #require(await rig.hold(Self.words("see you on Friday")))
        #expect(rig.controller.stage(of: id) == .finalPreview)
        let info = try #require(rig.controller.previewInfo)
        rig.controller.finalRendered(id)
        rig.clock.advance(info.dwellRemaining + 0.01)

        #expect(await rig.wait { rig.events.landed.count == 1 }, "the turn completes — no hang")
        #expect(await MainActor.run { target.text } == "Dear Mira, " + info.text, "the previewed text is in the view")
        #expect(rig.events.landed.first?.delivery == .delivered(verified: true, method: "adapter"))
        #expect(rig.system.inserts == [true], "exactly one insert, on the main thread")
        #expect(rig.system.refused.isEmpty, "no AX setter, no synthetic event: \(rig.system.refused)")
        #expect(rig.store.entry(id)?.stage == .landed)
        #expect(MainThreadWatchdog.shared.breadcrumb != nil, "the write path leaves the watchdog a breadcrumb")
        #expect(rig.system.calls.contains { $0.name == "focusedElement" && !$0.onMain },
                "reads were requested off the main thread (and the guard took them to main)")
    }

    // MARK: - The onboarding practice field

    /// The Try step's field: a SwiftUI `TextEditor` bound to the view model's `practiceText`.
    struct PracticeField: View {
        @ObservedObject var model: OnboardingViewModel
        var body: some View { TextEditor(text: $model.practiceText) }
    }

    @MainActor static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }

    @Test("the onboarding practice step: the turn lands in its TextEditor and the step reads it as inserted")
    @MainActor func practiceStepLandsInItsField() async throws {
        let vm = OnboardingViewModel(dependencies: OnboardingS8ViewModelTests.deps(resumeAt: .firstDictation))
        defer { vm.teardown() }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 420, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PracticeField(model: vm))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 160)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try #require(Self.textView(in: host), "SwiftUI's TextEditor is an NSTextView")
        let rig = Rig(system: OwnWindowSystem(live: Self.live(pointingAt: field)))

        // The step sees the same turn through the engine's events: released, final in the preview.
        let spans = Self.words("Testing, testing, one, two, three.")
        vm.practiceEvent(.state(.starting))
        vm.practiceEvent(.state(.finishing))
        vm.practiceEvent(.final(spans))
        #expect(vm.practice.phase == .preview)

        let id = try #require(await rig.hold(spans))
        let info = try #require(rig.controller.previewInfo)
        rig.controller.finalRendered(id)
        rig.clock.advance(info.dwellRemaining + 0.01)
        #expect(await rig.wait { rig.events.landed.count == 1 }, "the turn completes — no hang")

        #expect(field.string == info.text)
        #expect(vm.practiceText == info.text, "the insert reached the SwiftUI binding")
        #expect(vm.practice.phase == .inserted)
        #expect(vm.machine.dictation == .landed(text: info.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                app: OnboardingCopy.practiceFieldName))
        #expect(rig.system.inserts == [true])
        #expect(rig.system.refused.isEmpty)
    }
}
