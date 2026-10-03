import Engine
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// X7 / H30 (owner Q7, round 3 "Hands-free destination") — session target = the field focused when
/// hands-free started; a piece goes to a new app only when an editable non-secure field is focused
/// there; otherwise a background write to the stored element (no activation); if impossible and
/// the old box is still there, switch back, insert, return; neither → Notes. Spy delivery, no live
/// apps.
@Suite("Hands-free destination (X7 / H30)")
struct HandsFreeDestinationTests {
    static let notesApp = FocusSnapshot(pid: 10, bundleID: "com.apple.Notes", appName: "Notes", elementToken: "n1")
    static let slack = FocusSnapshot(pid: 20, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", elementToken: "s1")
    static let finder = FocusSnapshot(pid: 30, bundleID: "com.apple.finder", appName: "Finder", elementToken: nil)

    // MARK: The pure rule

    @Test("the rule table")
    func table() {
        typealias R = HandsFreeRoute
        let n = Self.notesApp, s = Self.slack
        #expect(R.decide(target: n, now: n, field: .editable) == .target(n))
        #expect(R.decide(target: n, now: n, field: .none) == .target(n), "same app: insert as usual")
        #expect(R.decide(target: n, now: s, field: .editable) == .switchTarget(s))
        #expect(R.decide(target: n, now: s, field: .secure) == .background(n), "a password field never becomes the target")
        #expect(R.decide(target: n, now: Self.finder, field: .none) == .background(n))
        #expect(R.decide(target: n, now: nil, field: .none) == .background(n))
        #expect(R.decide(target: nil, now: s, field: .editable) == .switchTarget(s))
        #expect(R.decide(target: nil, now: s, field: .secure) == .target(s), "the injector refuses it there")
        #expect(R.decide(target: nil, now: nil, field: .none) == .notes)
    }

    private func info(_ role: String) -> FocusedElementInfo {
        FocusedElementInfo(role: role, value: "", selectedRange: nil, isValueSettable: false, isSelectedTextSettable: false)
    }

    @Test("the focused field: secure first, then editable text, else none")
    func fieldOf() {
        #expect(HandsFreeField.of(nil) == .none)
        #expect(HandsFreeField.of(info("AXTextArea")) == .editable)
        #expect(HandsFreeField.of(info("AXSecureTextField")) == .secure)
        #expect(HandsFreeField.of(info("AXButton")) == .none)
    }

    // MARK: The runtime

    final class Spy: LatchDelivering, @unchecked Sendable {
        let lock = NSLock()
        var focus: FocusSnapshot?
        var field: HandsFreeField = .editable
        var backgroundWorks = false
        var alive = false
        var switchBackWorks = false
        var log: [String] = []

        var routesHandsFree: Bool { true }
        func currentFocus() -> FocusSnapshot? { lock.withLock { focus } }
        func focusedField() -> HandsFreeField { lock.withLock { field } }
        func deliver(_ spans: [TranscriptSpan], segment: SegmentID) async -> Bool { true }
        func deliver(_ spans: [TranscriptSpan], segment: SegmentID, focus: FocusSnapshot?) async -> LatchDeliveryResult {
            lock.withLock { log.append("deliver \(focus?.appName ?? "-")") }
            return .delivered
        }
        func hold(_ spans: [TranscriptSpan], segment: SegmentID, reason: String) -> String { "" }
        func insertHeld(into target: String) -> Int { 0 }
        func backgroundWrite(_ spans: [TranscriptSpan], segment: SegmentID, to target: FocusSnapshot) async -> LatchDeliveryResult? {
            lock.withLock { log.append("background \(target.appName)") }
            return lock.withLock { backgroundWorks } ? .delivered : nil
        }
        func targetAlive(_ target: FocusSnapshot) -> Bool { lock.withLock { alive } }
        func switchBackInsertReturn(_ spans: [TranscriptSpan], segment: SegmentID, to target: FocusSnapshot,
                                    returnTo: FocusSnapshot?) async -> LatchDeliveryResult? {
            lock.withLock { log.append("switchBack \(target.appName) return \(returnTo?.appName ?? "-")") }
            return lock.withLock { switchBackWorks } ? .delivered : nil
        }
    }

    final class Notes: @unchecked Sendable { var texts: [String] = [] }

    private func run(_ spy: Spy, startIn start: FocusSnapshot?, closeIn close: FocusSnapshot?,
                     field: HandsFreeField) async -> (LatchRuntime, Notes) {
        let runtime = LatchRuntime(delivery: spy)
        let notes = Notes()
        runtime.notesRoute = { text, _ in notes.texts.append(text); return true }
        spy.focus = start
        runtime.enterLatch(feed: nil)
        spy.focus = close
        spy.field = field
        runtime.handle(.closed(segment: SegmentID(sessionID: UUID(), index: 0),
                               spans: [TranscriptSpan(text: "hello there", confidence: 0.9, audioRange: 0...1,
                                                      provenance: [.asr], stability: .final)],
                               stability: .final, reason: .endpoint))
        await runtime.settle()
        return (runtime, notes)
    }

    @Test("start in Notes, stay in Notes: the piece lands in Notes' field")
    func sameApp() async {
        let spy = Spy()
        let (runtime, notes) = await run(spy, startIn: Self.notesApp, closeIn: Self.notesApp, field: .editable)
        #expect(spy.log == ["deliver Notes"])
        #expect(notes.texts.isEmpty)
        #expect(runtime.latchTarget == Self.notesApp)
    }

    @Test("clicked into Slack's message box: Slack becomes the target (badge bounce hook)")
    func switchToNewField() async {
        let spy = Spy()
        let runtime = LatchRuntime(delivery: spy)
        var changed: [String] = []
        runtime.onTargetChanged = { changed.append($0.appName) }
        spy.focus = Self.notesApp
        runtime.enterLatch(feed: nil)
        spy.focus = Self.slack
        spy.field = .editable
        runtime.handle(.closed(segment: SegmentID(sessionID: UUID(), index: 0),
                               spans: [TranscriptSpan(text: "hi", confidence: 0.9, audioRange: 0...1,
                                                      provenance: [.asr], stability: .final)],
                               stability: .final, reason: .endpoint))
        await runtime.settle()
        #expect(spy.log == ["deliver Slack"])
        #expect(changed == ["Slack"])
        #expect(runtime.latchTarget == Self.slack)
    }

    @Test("switched to Finder with no box: background write to the Notes box, no activation")
    func backgroundWrite() async {
        let spy = Spy()
        spy.backgroundWorks = true
        let (_, notes) = await run(spy, startIn: Self.notesApp, closeIn: Self.finder, field: .none)
        #expect(spy.log == ["background Notes"])
        #expect(notes.texts.isEmpty)
    }

    @Test("background write impossible, Notes still open: switch back, insert, return to Finder")
    func switchBack() async {
        let spy = Spy()
        spy.alive = true
        spy.switchBackWorks = true
        let (_, notes) = await run(spy, startIn: Self.notesApp, closeIn: Self.finder, field: .none)
        #expect(spy.log == ["background Notes", "switchBack Notes return Finder"])
        #expect(notes.texts.isEmpty)
    }

    @Test("neither the old box nor a new box: the piece goes to Notes (the app)")
    func toNotes() async {
        let spy = Spy()
        let (_, notes) = await run(spy, startIn: Self.notesApp, closeIn: Self.finder, field: .none)
        #expect(spy.log == ["background Notes"])
        #expect(notes.texts == ["hello there"])
    }

    @Test("a password field in another app is never the target")
    func secureNeverTarget() async {
        let spy = Spy()
        spy.backgroundWorks = true
        let (runtime, _) = await run(spy, startIn: Self.notesApp, closeIn: Self.slack, field: .secure)
        #expect(spy.log == ["background Notes"])
        #expect(runtime.latchTarget == Self.notesApp)
    }

    @Test("leaving hands-free forgets the target")
    func leaveForgets() async {
        let spy = Spy()
        let (runtime, _) = await run(spy, startIn: Self.notesApp, closeIn: Self.notesApp, field: .editable)
        runtime.leaveLatch()
        #expect(runtime.latchTarget == nil)
    }

    @Test("a delivery that does not opt in keeps B1 (no session target)")
    func legacyDelivery() async {
        let spy = LatchFocusSpy()
        spy.focus = Self.notesApp
        let runtime = LatchRuntime(delivery: spy)
        runtime.enterLatch(feed: nil)
        #expect(runtime.latchTarget == nil)
    }

    // MARK: Never Return at the end of a piece

    @Test("the background writer never receives a trailing newline")
    func noReturn() {
        var written: [String] = []
        let injector = BackgroundWriteInjector(target: Self.notesApp) { text, _ in written.append(text); return true }
        let outcome = injector.inject(InjectionRequest(text: "send this\n", utteranceID: nil, expectedFocus: nil))
        #expect(outcome.succeeded)
        #expect(written == ["send this"])
        #expect(injector.wrote)
    }

    @Test("a failed background write reports nothing written")
    func failedWrite() {
        let injector = BackgroundWriteInjector(target: Self.notesApp) { _, _ in false }
        #expect(!injector.inject(InjectionRequest(text: "x", utteranceID: nil, expectedFocus: nil)).succeeded)
        #expect(!injector.wrote)
    }
}

/// X3-handsfree (owner round 3, "Tap during hands-free") and H23 — the stop tap's last piece: a
/// focused text box takes it; nothing focused → Notes. A password field keeps nothing.
@Suite("Hands-free stop and H23 secure refusal")
struct HandsFreeStopTests {
    @Test("nothing focused: no text box")
    func noFocus() {
        #expect(!TurnController.textBoxFocused(TargetRevision(focus: nil)))
    }

    @Test("roles")
    func roles() {
        func rev(_ role: String?, secure: Bool = false) -> TargetRevision {
            TargetRevision(focus: HandsFreeDestinationTests.notesApp, role: role, isSecure: secure)
        }
        #expect(TurnController.textBoxFocused(rev("AXTextArea")))
        #expect(TurnController.textBoxFocused(rev("AXTextField")))
        #expect(!TurnController.textBoxFocused(rev("AXButton")))
        #expect(!TurnController.textBoxFocused(rev("AXList")))
        #expect(TurnController.textBoxFocused(rev(nil)), "unreadable: the injector decides")
        #expect(TurnController.textBoxFocused(rev("AXSecureTextField", secure: true)), "refused by the secure rule, not Notes")
    }

    @Test("H23 — Escape after words: the words so far stay on the cancelled turn for Notes")
    func escapeKeepsWords() async throws {
        let h = TurnControllerTests.Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.notePartial("meet me at three")
        _ = h.controller.escape()
        h.store.flush()
        let entry = try #require(h.store.entry(id))
        #expect(entry.stage == .cancelled)
        #expect(entry.record.finalText == "meet me at three")
    }
}
