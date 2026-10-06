import CoreGraphics
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// Adversarial verification of tap to talk + the launch fixes (2026-10-06): timing boundaries,
/// hands-free exits, a binding change or re-arm mid-dictation, a tap in the first seconds after
/// launch, and the Claude double-tap drop with tap to talk on. Synthetic edges only.
@Suite("Tap to talk — verification", .serialized)
struct TapToTalkVerifyTests {
    static func machine() -> HotkeyStateMachine {
        var m = HotkeyStateMachine()
        m.tapToTalk = true
        return m
    }

    private static let left = CGEventFlags.maskAlternate.rawValue | HotkeyBinding.Kind.deviceLeftAltMask
    final class Box { var actions: [HotkeyStateMachine.Action] = [] }

    private func service(tapToTalk: Bool = true) -> (HotkeyService, Box) {
        let d = UserDefaults(suiteName: "AppTests.tapToTalkVerify.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(.option)
        s.otherInputWithin = { _ in false }
        s.surfaceShowing = { false }
        s.secureInputProbe = { .off }
        s.tapToTalkEnabled = { tapToTalk }
        let box = Box()
        s.onAction = { box.actions.append($0) }
        return (s, box)
    }

    private func press(_ s: HotkeyService, _ down: TimeInterval, _ up: TimeInterval) {
        s.handle(keyCode: 58, flags: Self.left, timestamp: down)
        s.handle(keyCode: 58, flags: 0, timestamp: up)
    }

    // MARK: Timing boundaries

    @Test("press length boundaries: < 180 ms armed tap, 180–249 ms unarmed tap, 250 ms is a hold")
    func lengthBoundaries() {
        var a = Self.machine()
        _ = a.keyDown(at: 0)
        #expect(a.keyUp(at: 0.179) == [.tapToTalk])
        #expect(a.phase == .tapTalking(tapUp: 0.179, armed: true))

        var b = Self.machine()
        _ = b.keyDown(at: 0)
        #expect(b.keyUp(at: 0.18) == [.tapToTalk])
        #expect(b.phase == .tapTalking(tapUp: 0.18, armed: false))
        // An unarmed first tap never makes a double tap: a quick second tap just finishes.
        _ = b.keyDown(at: 0.25)
        #expect(b.keyUp(at: 0.3) == [.finalize])

        var c = Self.machine()
        _ = c.keyDown(at: 0)
        #expect(c.keyUp(at: 0.25) == [.finalize])
        #expect(c.lastGesture == .hold)
    }

    @Test("double-tap window: second key-down 340 ms after the first key-up latches, 352 ms finishes; a slow second tap finishes")
    func doubleTapWindowBoundaries() {
        var a = Self.machine()
        _ = a.keyDown(at: 0); _ = a.keyUp(at: 0.1)
        _ = a.keyDown(at: 0.44)
        #expect(a.keyUp(at: 0.5) == [.enterLatch])

        var b = Self.machine()
        _ = b.keyDown(at: 0); _ = b.keyUp(at: 0.1)
        _ = b.keyDown(at: 0.452)
        #expect(b.keyUp(at: 0.5) == [.finalize])

        var c = Self.machine()
        _ = c.keyDown(at: 0); _ = c.keyUp(at: 0.1)
        _ = c.keyDown(at: 0.2)
        #expect(c.keyUp(at: 0.38) == [.finalize], "a second press of 180 ms is not a double tap")
    }

    // MARK: Hands-free exits

    @Test("hands-free stops on a tap; a habitual double tap to stop folds its second tap, even at 300–350 ms")
    func handsFreeExitByDoubleTap() {
        let (s, box) = service()
        press(s, 0, 0.08)
        press(s, 0.2, 0.28)
        #expect(box.actions == [.startCapture, .tapToTalk, .enterLatch])
        box.actions = []
        press(s, 5, 5.08)
        #expect(box.actions == [.finalize])
        // Second tap of the stop double tap, 330 ms after the stop's key-up: Claude's drop already
        // kept it from other apps as a double tap, so it must not open a new dictation either.
        press(s, 5.41, 5.47)
        #expect(box.actions == [.finalize], "folded into the stop — no new tap-to-talk dictation")
        #expect(s.machine.phase == .idle)
        // A tap well after the stop starts a new dictation.
        press(s, 7, 7.08)
        #expect(box.actions == [.finalize, .startCapture, .tapToTalk])
    }

    @Test("tap to talk off: the H29 fold window stays 300 ms")
    func foldWindowUnchangedWithoutTapToTalk() {
        var m = HotkeyStateMachine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.08)
        _ = m.keyDown(at: 0.2); _ = m.keyUp(at: 0.28)
        #expect(m.phase == .latched)
        _ = m.keyDown(at: 5); _ = m.keyUp(at: 5.08)
        #expect(m.keyDown(at: 5.41) == [.startCapture], "outside 300 ms: a new press, as before")
    }

    @Test("a tap-to-talk dictation finishes on a tap; a quick re-press after it is folded")
    func tapTalkStopFolds() {
        let (s, box) = service()
        press(s, 0, 0.1)
        press(s, 3, 3.08)
        press(s, 3.4, 3.46)
        #expect(box.actions == [.startCapture, .tapToTalk, .finalize])
    }

    // MARK: Binding switch / re-arm mid-dictation

    @Test("rebind keeps a dictation with no key held and drops a press in flight")
    func rebindKeepsSessions() {
        var m = Self.machine()
        _ = m.keyDown(at: 0); _ = m.keyUp(at: 0.1)
        m.rebind()
        #expect(m.isTapTalking)
        _ = m.keyDown(at: 0.2)
        #expect(m.keyUp(at: 0.25) == [.finalize], "after a rebind the next tap finishes, never latches")

        var l = Self.machine()
        _ = l.keyDown(at: 0); _ = l.keyUp(at: 0.08); _ = l.keyDown(at: 0.2); _ = l.keyUp(at: 0.28)
        _ = l.keyDown(at: 3)
        l.rebind()
        #expect(l.phase == .latched, "the old key's stop press is dropped; hands-free continues")

        var h = Self.machine()
        _ = h.keyDown(at: 0)
        h.rebind()
        #expect(h.phase == .idle)
    }

    @Test("a re-arm (stop/start) does not orphan a tap-to-talk dictation")
    func stopKeepsTapTalk() {
        let (s, box) = service()
        press(s, 0, 0.1)
        s.stop()
        #expect(s.machine.isTapTalking)
        press(s, 3, 3.08)
        #expect(box.actions == [.startCapture, .tapToTalk, .finalize])
    }

    @Test("the silence timeout still finishes a dictation after a binding change")
    func silenceAfterRebind() {
        let (s, box) = service()
        press(s, 0, 0.1)
        s.setBinding(.rightCommand)
        s.finishTapToTalk(reason: "silence timeout")
        #expect(box.actions == [.startCapture, .tapToTalk, .finalize])
        #expect(s.machine.phase == .idle)
    }

    // MARK: First press after launch

    @Test("a tap in the first seconds after launch is held by the gate and replayed as tap to talk")
    func launchTapReplays() {
        let d = UserDefaults(suiteName: "AppTests.tapToTalkVerify.launch.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(.option)
        s.otherInputWithin = { _ in false }
        s.surfaceShowing = { false }
        s.secureInputProbe = { .off }
        let settings = InMemorySettingsStore()
        TapToTalkWiring.armEarly(hotkey: s, settings: settings)
        var shown: [PillState] = []
        let gate = LaunchPressGate(present: { shown.append($0) }, dismiss: {})
        s.onAction = { gate.handle($0) }
        press(s, 0, 0.1)
        #expect(gate.pending == .tapTalking)
        var replayed: [HotkeyStateMachine.Action] = []
        gate.containerReady { replayed.append($0) }
        #expect(replayed == [.startCapture, .tapToTalk])
        // The next tap (after the container) finishes it.
        var later: [HotkeyStateMachine.Action] = []
        s.onAction = { later.append($0) }
        press(s, 4, 4.08)
        #expect(later == [.finalize])
    }

    @Test("armEarly honours the switches: tap to talk off → a launch tap is a plain tap")
    func launchTapRespectsSwitch() {
        let d = UserDefaults(suiteName: "AppTests.tapToTalkVerify.launchOff.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(.option)
        s.otherInputWithin = { _ in false }
        s.surfaceShowing = { false }
        s.secureInputProbe = { .off }
        let settings = InMemorySettingsStore()
        TapToTalkSettings.setEnabled(false, store: settings)
        TapToTalkWiring.armEarly(hotkey: s, settings: settings)
        var actions: [HotkeyStateMachine.Action] = []
        s.onAction = { actions.append($0) }
        press(s, 0, 0.1)
        #expect(actions == [.startCapture, .cancelCapture])
    }

    // MARK: Claude's double tap, chords

    @Test("with tap to talk on, the Claude suppressor drops only the second tap of a double tap")
    func claudeDropStillWorks() {
        var sup = OptionDoubleTapSuppressor()
        var m = Self.machine()
        // Tap to talk start: passes to other apps.
        #expect(sup.option(.down, at: 0) == .pass); _ = m.keyDown(at: 0)
        #expect(sup.option(.up, at: 0.08) == .pass); #expect(m.keyUp(at: 0.08) == [.tapToTalk])
        // Second tap inside the window: dropped from other apps, still hands-free here.
        #expect(sup.option(.down, at: 0.25) == .drop); _ = m.keyDown(at: 0.25)
        #expect(sup.option(.up, at: 0.31) == .drop); #expect(m.keyUp(at: 0.31) == [.enterLatch])
        // A finishing tap later passes (Claude sees one tap).
        #expect(sup.option(.down, at: 5) == .pass); _ = m.keyDown(at: 5)
        #expect(sup.option(.up, at: 5.08) == .pass); #expect(m.keyUp(at: 5.08) == [.finalize])
    }

    @Test("Option + key from idle is a silent chord cancel with tap to talk on; nothing starts listening")
    func chordFromIdle() {
        let (s, box) = service()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.noteOtherInput(at: 0.05, kind: "key")
        s.handle(keyCode: 58, flags: 0, timestamp: 0.1)
        #expect(box.actions == [.startCapture, .cancelCapture])
        #expect(s.machine.phase == .idle)
        #expect(s.machine.lastCancel == .chord)
    }

    @Test("after speech, an Option chord during tap to talk passes through and listening continues")
    func chordAfterSpeechPassesThrough() {
        let (s, box) = service()
        s.speechHeard = { true }
        press(s, 0, 0.1)
        s.handle(keyCode: 58, flags: Self.left, timestamp: 2)
        s.noteOtherInput(at: 2.05, kind: "key")
        s.handle(keyCode: 58, flags: 0, timestamp: 2.1)
        s.noteOtherInput(at: 2.5, kind: "key")
        #expect(box.actions == [.startCapture, .tapToTalk])
        #expect(s.machine.isTapTalking)
        press(s, 4, 4.08)
        #expect(box.actions == [.startCapture, .tapToTalk, .finalize])
    }
}
