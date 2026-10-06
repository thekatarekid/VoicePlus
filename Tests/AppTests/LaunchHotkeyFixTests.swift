import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// Launch fix (2026-10-06 investigation) — RC5 and the RC1 presence hint.
@Suite("Launch fix — chord input and the loading hint")
struct LaunchHotkeyFixTests {
    private static func scroll(phase: Int64, momentum: Int64) -> CGEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -12, wheel2: 0, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return event
    }

    @Test("a scroll the user makes is a chord; its momentum tail, a resting finger and its end are not")
    func scrollPhases() {
        // Mouse wheel (no phase) and a live trackpad gesture count.
        #expect(ChordInputFilter.counts(type: .scrollWheel, event: Self.scroll(phase: 0, momentum: 0)))
        #expect(ChordInputFilter.counts(type: .scrollWheel, event: Self.scroll(phase: 1, momentum: 0)))
        #expect(ChordInputFilter.counts(type: .scrollWheel, event: Self.scroll(phase: 2, momentum: 0)))
        // Momentum (begin 1, continue 2, end 3), may-begin, ended and cancelled do not.
        for momentum: Int64 in [1, 2, 3] {
            #expect(!ChordInputFilter.counts(type: .scrollWheel, event: Self.scroll(phase: 0, momentum: momentum)))
        }
        for phase: Int64 in [4, 8, 128] {
            #expect(!ChordInputFilter.counts(type: .scrollWheel, event: Self.scroll(phase: phase, momentum: 0)))
        }
    }

    @Test("keys and clicks always count")
    func keysAndClicks() {
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        #expect(ChordInputFilter.counts(type: .keyDown, event: key))
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
        #expect(ChordInputFilter.counts(type: .leftMouseDown, event: click))
        #expect(ChordInputFilter.label(for: .scrollWheel) == "scroll")
        #expect(ChordInputFilter.label(for: .leftMouseDown) == "click")
        #expect(ChordInputFilter.label(for: .keyDown) == "key")
    }

    @Test("the passive key-up check leaves scroll to the active tap when the tap feeds the service")
    func passiveTypes() {
        #expect(ChordInputFilter.passiveTypes(includeScroll: true).contains(.scrollWheel))
        #expect(!ChordInputFilter.passiveTypes(includeScroll: false).contains(.scrollWheel))
        #expect(ChordInputFilter.passiveTypes(includeScroll: false).contains(.keyDown))
        #expect(ChordInputFilter.passiveTypes(includeScroll: false).contains(.leftMouseDown))
    }

    @Test("a hold with only a momentum tail during it is dictation, not a chord (service path)")
    func momentumTailDoesNotCancel() {
        let d = UserDefaults(suiteName: "AppTests.launchChord.\(UUID())")!
        let s = HotkeyService(defaults: d)
        s.setBinding(.option)
        s.surfaceShowing = { false }
        s.otherInputWithin = { _ in false }
        var actions: [HotkeyStateMachine.Action] = []
        s.onAction = { actions.append($0) }
        let left = CGEventFlags.maskAlternate.rawValue | HotkeyBinding.Kind.deviceLeftAltMask
        s.handle(keyCode: 58, flags: left, timestamp: 0)
        // What the tap does with a momentum event: it never reaches `noteOtherInput`.
        let tail = Self.scroll(phase: 0, momentum: 2)
        if ChordInputFilter.counts(type: .scrollWheel, event: tail) { s.noteOtherInput(at: 0.05, kind: "scroll") }
        s.handle(keyCode: 58, flags: 0, timestamp: 1.5)
        #expect(actions == [.startCapture, .finalize], "a 1.5 s hold after a scroll must dictate")
    }

    @Test("while the speech model loads, the hint says so before the key hint")
    func loadingHint() {
        let hint = "Hold or Double Tap Option to dictate"
        #expect(LaunchModelHint.readyHint(hint, modelLoading: false) == hint)
        let loading = LaunchModelHint.readyHint(hint, modelLoading: true)
        #expect(loading.hasPrefix(LaunchModelHint.loadingPrefix))
        #expect(loading.hasSuffix(hint))
    }
}
