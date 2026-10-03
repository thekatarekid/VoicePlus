import Foundation
import Testing
@testable import VoicePlusApp

/// H2 + X3-taps — the gesture machine's tap rules: every press under 250 ms is a tap; while the
/// notch shows something that is not a live capture, a press up to ~0.8 s is a tap too; a longer
/// press is a hold (Q3.2: a hold always wins). Synthetic key edges, no live tap.
@Suite("Hotkey tap rules (H2, X3-taps)")
struct HotkeyTapRulesTests {
    @Test("every press under 250 ms is a tap (cancelCapture), including the 180–250 ms band")
    func underThresholdIsTap() {
        for duration in [0.05, 0.179, 0.2, 0.249] {
            var m = HotkeyStateMachine()
            m.keyDown(at: 10)
            #expect(m.keyUp(at: 10 + duration) == [.cancelCapture], "\(duration)")
        }
    }

    @Test("with nothing showing, 250 ms and longer is a hold")
    func holdWithNothingShowing() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0, surfaceShowing: false)
        #expect(m.keyUp(at: 0.5) == [.finalize])
    }

    @Test("over a visible notch a press up to 0.8 s is a tap; longer is a hold",
          arguments: [(0.3, false), (0.6, false), (0.8, false), (0.81, true), (2.0, true)])
    func visibleNotchCeiling(duration: TimeInterval, hold: Bool) {
        var m = HotkeyStateMachine()
        #expect(m.keyDown(at: 1, surfaceShowing: true) == [.startCapture])
        #expect(m.pressOverSurface)
        #expect(m.keyUp(at: 1 + duration) == (hold ? [.finalize] : [.cancelCapture]))
        #expect(m.phase == .idle)
        #expect(m.lastTapUp == nil, "a long dismissing press never arms a double tap")
    }

    @Test("the surface flag belongs to its own press")
    func flagPerPress() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0, surfaceShowing: true)
        m.keyUp(at: 0.5)
        m.keyDown(at: 5, surfaceShowing: false)
        #expect(!m.pressOverSurface)
        #expect(m.keyUp(at: 5.5) == [.finalize])
    }

    @Test("latched: a press stops the session regardless of the surface")
    func latchedStops() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0); m.keyUp(at: 0.1); m.keyDown(at: 0.2); m.keyUp(at: 0.25)
        #expect(m.phase == .latched)
        #expect(m.keyDown(at: 3, surfaceShowing: true) == [.finalize])
    }

    @Test("HotkeyService feeds the surface flag at key-down (dictation key only)")
    func serviceReadsSurface() {
        let defaults = UserDefaults(suiteName: "HotkeyTapRulesTests-\(UUID())")!
        let service = HotkeyService(defaults: defaults, defaultBinding: HotkeyBinding(kind: .rightOption))
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        service.surfaceShowing = { true }
        let key = service.binding.kind
        let mask = key.flagMask
        service.handle(keyCode: key.keyCode, flags: mask, timestamp: 1)
        service.handle(keyCode: key.keyCode, flags: 0, timestamp: 1.6)
        #expect(actions == [.startCapture, .cancelCapture])
        let act = HotkeyService(defaults: defaults, bindingKey: HotkeyService.actBindingDefaultsKey)
        #expect(act.surfaceShowing() == false)
    }
}
