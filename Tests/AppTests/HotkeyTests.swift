import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

@Suite("Hotkey state machine (T3)")
struct HotkeyStateMachineTests {
    @Test func holdToTalkStartsOnDownAndFinalizesOnUp() {
        var m = HotkeyStateMachine()
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.isCapturing)
        #expect(m.keyUp(at: 0.6) == [.finalize])
        #expect(!m.isCapturing)
    }

    @Test func exactlyHoldThresholdCountsAsHold() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 1)
        #expect(m.keyUp(at: 1.250) == [.finalize])
    }

    @Test func shortTapCancels() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0)
        #expect(m.keyUp(at: 0.1) == [.cancelCapture])
        #expect(m.lastTapUp == 0.1)
    }

    @Test func ambiguousPressBetweenGuardAndHoldCancelsWithoutArmingDoubleTap() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0)
        #expect(m.keyUp(at: 0.2) == [.cancelCapture])
        #expect(m.lastTapUp == nil)
    }

    @Test func doubleTapWithinWindowEntersHandsFreeAndNextPressFinalizes() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0); m.keyUp(at: 0.05)
        #expect(m.keyDown(at: 0.2) == [.startCapture])
        #expect(m.keyUp(at: 0.25) == [.enterHandsFree])
        #expect(m.phase == .handsFree)
        #expect(m.isCapturing)
        #expect(m.keyDown(at: 3) == [.finalize])
        #expect(m.keyUp(at: 3.05) == [])
        #expect(m.phase == .idle)
    }

    @Test func doubleTapOutsideWindowIsJustTwoTaps() {
        var m = HotkeyStateMachine()
        m.keyDown(at: 0); m.keyUp(at: 0.05)
        m.keyDown(at: 0.5)
        #expect(m.keyUp(at: 0.55) == [.cancelCapture])
        #expect(m.phase == .idle)
    }

    @Test func keyRepeatAndStrayUpAreIgnored() {
        var m = HotkeyStateMachine()
        #expect(m.keyUp(at: 0) == [])
        m.keyDown(at: 0)
        #expect(m.keyDown(at: 0.1) == [])
        m.reset()
        #expect(m.phase == .idle)
    }

    @Test func customTiming() {
        var m = HotkeyStateMachine(timing: .init(holdThreshold: 1, tapGuard: 0.5, doubleTapWindow: 2))
        m.keyDown(at: 0)
        #expect(m.keyUp(at: 0.8) == [.cancelCapture])
    }
}

@Suite("Hotkey service with synthesized CGEvents")
struct HotkeyServiceTests {
    private func flagsChanged(keyCode: Int64, flags: CGEventFlags, seconds: Double) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.type = .flagsChanged
        event.flags = flags
        event.timestamp = CGEventTimestamp(seconds * 1_000_000_000)
        return event
    }

    @Test func rightOptionHoldProducesStartThenFinalize() {
        let defaults = UserDefaults(suiteName: "AppTests.hotkey.\(UUID())")!
        let service = HotkeyService(defaults: defaults)
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        service.handle(event: flagsChanged(keyCode: 61, flags: .maskAlternate, seconds: 10))
        service.handle(event: flagsChanged(keyCode: 61, flags: [], seconds: 10.4))
        #expect(actions == [.startCapture, .finalize])
    }

    @Test func otherModifiersAreIgnoredAndBindingPersists() {
        let defaults = UserDefaults(suiteName: "AppTests.hotkey.\(UUID())")!
        let service = HotkeyService(defaults: defaults)
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        service.handle(event: flagsChanged(keyCode: 54, flags: .maskCommand, seconds: 1))
        #expect(actions.isEmpty)
        service.setBinding(.rightCommand)
        service.handle(event: flagsChanged(keyCode: 54, flags: .maskCommand, seconds: 2))
        #expect(actions == [.startCapture])
        #expect(HotkeyService(defaults: defaults).binding.kind == .rightCommand)
    }

    @Test func pausedServiceDropsEvents() {
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.hotkey.\(UUID())")!)
        service.isPaused = true
        var fired = false
        service.onAction = { _ in fired = true }
        service.handle(keyCode: 61, flags: CGEventFlags.maskAlternate.rawValue, timestamp: 0)
        #expect(!fired)
    }

    @Test func bindingEdgeClassification() {
        let b = HotkeyBinding(kind: .fn)
        #expect(b.edge(keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue) == .down)
        #expect(b.edge(keyCode: 63, flags: 0) == .up)
        #expect(b.edge(keyCode: 61, flags: 0) == nil)
    }
}
