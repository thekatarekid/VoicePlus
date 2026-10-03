import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// X1 (owner round 4) — Option (left or right) is the dictation key. Hold = hold-to-talk, double
/// tap = hands-free, every fn tap/hold rule carries over, Option + another key / click / scroll
/// cancels silently, and the per-side device bits (0x20 / 0x40) decide which Option is down.
/// Synthetic flag words and timestamps only — no live tap.
@Suite("X1 — Option key gestures", .serialized)
struct HotkeyOptionX1Tests {
    private static let alt = CGEventFlags.maskAlternate.rawValue
    private static let left = alt | HotkeyBinding.Kind.deviceLeftAltMask
    private static let right = alt | HotkeyBinding.Kind.deviceRightAltMask
    private static let both = left | right

    private func service(_ kind: HotkeyBinding.Kind = .option) -> (HotkeyService, Box) {
        let d = UserDefaults(suiteName: "AppTests.optionX1.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(kind)
        s.otherInputWithin = { _ in false }
        s.surfaceShowing = { false }
        let box = Box()
        s.onAction = { box.actions.append($0) }
        return (s, box)
    }

    final class Box { var actions: [HotkeyStateMachine.Action] = [] }

    // MARK: Per-side bits

    @Test("either Option alone holds to talk")
    func eitherSideHolds() {
        for (code, flags) in [(Int64(58), Self.left), (61, Self.right)] {
            let (s, box) = service()
            s.handle(keyCode: code, flags: flags, timestamp: 0)
            s.handle(keyCode: code, flags: 0, timestamp: 0.6)
            #expect(box.actions == [.startCapture, .finalize])
        }
    }

    @Test("both Options: the press ends only when the last side comes up")
    func bothSidesOnePress() {
        let (s, box) = service()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.handle(keyCode: 61, flags: Self.both, timestamp: 0.1)
        s.handle(keyCode: 58, flags: Self.right, timestamp: 0.3)
        #expect(box.actions == [.startCapture])
        s.handle(keyCode: 61, flags: 0, timestamp: 0.7)
        #expect(box.actions == [.startCapture, .finalize])
    }

    @Test("Right Option binding sees its release while Left Option is still held (the per-side bug)")
    func rightReleaseWithLeftHeld() {
        let (s, box) = service(.rightOption)
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)            // left down: not ours
        s.handle(keyCode: 61, flags: Self.both, timestamp: 0.1)          // right down
        s.handle(keyCode: 61, flags: Self.left, timestamp: 0.6)          // right up, left still down
        #expect(box.actions == [.startCapture, .finalize])
    }

    @Test("Left Option binding ignores a right-side press")
    func leftIgnoresRight() {
        #expect(HotkeyBinding(kind: .leftOption).edge(keyCode: 61, flags: Self.right) == nil)
        #expect(HotkeyBinding(kind: .leftOption).edge(keyCode: 58, flags: Self.right) == .up)
        #expect(HotkeyBinding(kind: .leftOption).edge(keyCode: 58, flags: Self.left) == .down)
        // A synthetic word with only the shared bit still reads as down.
        #expect(HotkeyBinding(kind: .option).edge(keyCode: 61, flags: Self.alt) == .down)
    }

    // MARK: Tap / hold rules carry over

    @Test("double tap of Option (left then right) latches hands-free")
    func doubleTapLatches() {
        let (s, box) = service()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.handle(keyCode: 58, flags: 0, timestamp: 0.08)
        s.handle(keyCode: 61, flags: Self.right, timestamp: 0.2)
        s.handle(keyCode: 61, flags: 0, timestamp: 0.28)
        #expect(box.actions == [.startCapture, .cancelCapture, .startCapture, .enterLatch])
    }

    @Test("tap < 250 ms is a tap; over a visible notch up to 0.8 s is a tap")
    func tapRules() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0)
        #expect(m.keyUp(at: 0.2) == [.cancelCapture])
        #expect(m.lastCancel == .tap)
        m.keyDown(at: 5, surfaceShowing: true)
        #expect(m.keyUp(at: 5.75) == [.cancelCapture])
    }

    // MARK: Option + anything → silent cancel

    @Test("Option + key while held: silent cancel, key-up does nothing, no double tap armed")
    func chordCancelsSilently() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0)
        #expect(m.otherInput(at: 0.1) == [.cancelCapture])
        #expect(m.lastCancel == .chord)
        #expect(m.phase == .chorded)
        #expect(!m.isCapturing)
        #expect(m.keyUp(at: 0.15) == [])
        #expect(m.phase == .idle)
        // A tap right after the chord is a first tap, not the second of a double tap.
        m.keyDown(at: 0.2)
        #expect(m.keyUp(at: 0.25) == [.cancelCapture])
        #expect(m.lastCancel == .tap)
    }

    @Test("input between two taps breaks the double tap")
    func inputBetweenTaps() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0); m.keyUp(at: 0.05)
        m.otherInput(at: 0.1)
        m.keyDown(at: 0.2)
        #expect(m.keyUp(at: 0.25) == [.cancelCapture], "not enterLatch")
    }

    @Test("during hands-free, a clean Option press stops at key-up; Option + key keeps the session")
    func latchedStopAndChord() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0); m.keyUp(at: 0.05); m.keyDown(at: 0.15)
        #expect(m.keyUp(at: 0.2) == [.enterLatch])
        #expect(m.keyDown(at: 3) == [])
        #expect(m.otherInput(at: 3.1) == [])
        #expect(m.keyUp(at: 3.2) == [])
        #expect(m.phase == .latched)
        #expect(m.keyDown(at: 5) == [])
        #expect(m.keyUp(at: 5.1) == [.finalize])
        #expect(m.phase == .idle)
    }

    @Test("service: Option + key marks a chord cancel the session takes once")
    func serviceMarksChord() {
        let (s, box) = service()
        _ = HotkeyGestureContext.takeChordCancel()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.noteOtherInput(at: 0.05)
        #expect(box.actions == [.startCapture, .cancelCapture])
        #expect(HotkeyGestureContext.takeChordCancel())
        #expect(!HotkeyGestureContext.takeChordCancel())
        s.handle(keyCode: 58, flags: 0, timestamp: 0.4)
        #expect(box.actions == [.startCapture, .cancelCapture], "the chorded key-up adds nothing")
    }

    @Test("service: passive check at key-up — a click during the hold cancels silently")
    func passiveCheckAtKeyUp() {
        let (s, box) = service()
        var now: TimeInterval = 10
        s.uptime = { now }
        var asked: TimeInterval?
        s.otherInputWithin = { asked = $0; return true }
        s.handle(keyCode: 61, flags: Self.right, timestamp: 10)
        now = 10.7
        s.handle(keyCode: 61, flags: 0, timestamp: 10.7)
        #expect(box.actions == [.startCapture, .cancelCapture])
        #expect(abs((asked ?? 0) - 0.7) < 0.001)
        #expect(HotkeyGestureContext.takeChordCancel())
    }

    @Test("service: a plain tap is not a chord cancel")
    func tapIsNotChord() {
        let (s, box) = service()
        _ = HotkeyGestureContext.takeChordCancel()
        s.handle(keyCode: 58, flags: Self.left, timestamp: 0)
        s.handle(keyCode: 58, flags: 0, timestamp: 0.1)
        #expect(box.actions == [.startCapture, .cancelCapture])
        #expect(!HotkeyGestureContext.takeChordCancel())
    }

    @Test("the act key never marks a dictation chord cancel")
    func actKeyDoesNotMark() {
        let d = UserDefaults(suiteName: "AppTests.optionX1.act.\(UUID())")!
        let act = HotkeyService(defaults: d, bindingKey: HotkeyService.actBindingDefaultsKey,
                                defaultBinding: HotkeyBinding(kind: .rightCommand))
        _ = HotkeyGestureContext.takeChordCancel()
        act.handle(keyCode: 54, flags: CGEventFlags.maskCommand.rawValue, timestamp: 0)
        act.noteOtherInput(at: 0.1)
        #expect(!HotkeyGestureContext.takeChordCancel())
    }
}
