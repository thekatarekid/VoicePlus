import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// K02 — lost key-up (design §5 hotkey edge cases, §13 scenario 9). A key-up the listener never
/// delivered (a secure-input switch, an event-tap timeout) must not leave the machine in `.keyDown`,
/// where every later key-down is dropped as key repeat and capture stays open with no way out but
/// Escape or the menu.
@Suite("K02 — lost key-up")
@MainActor
struct LostKeyUpK02Tests {
    typealias Machine = HotkeyStateMachine
    static let fnDown = HotkeyBinding.Kind.fn.flagMask

    // MARK: The machine

    @Test("a lost key-up after a hold finalizes; the next key-down starts a new press")
    func machineHold() {
        var m = Machine()
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.keyDown(at: 0.4) == [], "still down: a key-down is key repeat")
        #expect(m.lostKeyUp(at: 0.9) == [.finalize])
        #expect(m.phase == .idle && m.lastTapUp == nil)
        #expect(m.keyDown(at: 1.2) == [.startCapture], "not dropped as key repeat any more")
    }

    @Test("a lost key-up on a short press cancels and never arms or enters Latch")
    func machineShortPress() {
        var m = Machine()
        m.keyDown(at: 0)
        #expect(m.lostKeyUp(at: 0.1) == [.cancelCapture])
        #expect(m.lastTapUp == nil, "a synthesized release is not a tap")
        m.keyDown(at: 0.2)
        #expect(m.keyUp(at: 0.25) == [.cancelCapture], "a following real tap does not latch off it")
        #expect(m.lostKeyUp(at: 0.3) == [], "nothing outside .keyDown")
        var latched = Machine()
        latched.keyDown(at: 0); latched.keyUp(at: 0.05); latched.keyDown(at: 0.2)
        #expect(latched.keyUp(at: 0.25) == [.enterLatch])
        #expect(latched.lostKeyUp(at: 1) == [], "latched: no key is held, nothing to lose")
    }

    // MARK: The service

    private func service(flags: @escaping () -> UInt64, uptime: TimeInterval = 5) -> (HotkeyService, Box<[Machine.Action]>, Box<Int>) {
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.k02.\(UUID())")!)
        #expect(service.binding.kind == .fn)
        let actions = Box<[Machine.Action]>([]), lost = Box(0)
        service.onAction = { actions.value.append($0) }
        service.onLostKeyUp = { lost.value += 1 }
        service.modifierFlags = flags
        service.uptime = { uptime }
        return (service, actions, lost)
    }

    @Test("the poll sees fn up twice in a row: .finalize, then onLostKeyUp; a later key-down begins again")
    func servicePoll() {
        let flags = Box<UInt64>(Self.fnDown)
        let (s, actions, lost) = service(flags: { flags.value })
        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 4)
        #expect(actions.value == [.startCapture])
        #expect(!s.checkForLostKeyUp(), "fn still down in the modifier state")
        flags.value = 0
        #expect(!s.checkForLostKeyUp(), "first read: a real key-up may still be queued")
        #expect(s.checkForLostKeyUp())
        #expect(actions.value == [.startCapture, .finalize], "held 1 s: the words are kept")
        #expect(lost.value == 1)
        #expect(!s.checkForLostKeyUp() && lost.value == 1, "once")
        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 6)
        #expect(actions.value.last == .startCapture, "the next press is a new turn, not key repeat")
    }

    @Test("a real key-up between polls wins; chords and idle keys are never polled")
    func serviceRaces() {
        let (s, actions, lost) = service(flags: { 0 })
        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 4)
        #expect(!s.checkForLostKeyUp())
        s.handle(keyCode: 63, flags: 0, timestamp: 4.6)   // the queued key-up arrives
        #expect(!s.checkForLostKeyUp())
        #expect(actions.value == [.startCapture, .finalize] && lost.value == 0)

        #expect(!s.checkForLostKeyUp() && !s.checkForLostKeyUp(), "idle: nothing is down")
        #expect(!s.wantsReleasePoll)
        s.setBinding(.controlOptionD)
        s.handleChord(down: true, timestamp: 7)
        #expect(!s.checkForLostKeyUp() && !s.checkForLostKeyUp(), "a chord has no flag word to read")
        #expect(lost.value == 0)
    }

    @Test("the release poll is wanted only while a live source holds a bare modifier down")
    func pollArming() {
        let (s, _, _) = service(flags: { Self.fnDown })
        s.installer = HotkeyBackend(kind: .globalMonitor, preflight: { true },
                                    install: { _ in InstalledHotkeySource(setEnabled: { _ in }, invalidate: {}) })
        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 1)
        #expect(!s.wantsReleasePoll, "no live source")
        s.resetGesture()
        #expect(s.start())
        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 2)
        #expect(s.wantsReleasePoll)
        s.handle(keyCode: 63, flags: 0, timestamp: 3)
        #expect(!s.wantsReleasePoll)
        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 4)
        s.stop()
        #expect(!s.wantsReleasePoll)
    }

    // MARK: The turn

    @Test("key-down, then a poll with the key up: the hold finalizes into finishing, K02 is posted, and the next press is a new turn")
    func endToEnd() async throws {
        let h = TurnControllerTests.Harness()
        let flags = Box<UInt64>(Self.fnDown)
        let (s, _, _) = service(flags: { flags.value })
        var current: TurnID?
        s.onAction = { action in
            switch action {
            case .startCapture:
                if case .began(let id) = h.controller.keyDown() { current = id; h.controller.captureOpened(id) }
            case .finalize, .cancelCapture:
                if let id = current { h.controller.keyUp(id) }
            case .enterLatch:
                break
            }
        }
        TurnWiring.wireLostKeyUp(s, controller: { h.controller })

        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 4)
        let first = try #require(current)
        #expect(h.controller.stage(of: first) == .listening)
        flags.value = 0
        s.checkForLostKeyUp()
        s.checkForLostKeyUp()
        #expect(h.controller.stage(of: first) == .finishing, "capture closed; the words go on to the preview")
        #expect(h.events.notices == [.K02])
        #expect(RecoveryCatalog.entry(.K02).headline == "Dictation stopped")

        // The kept words land through the ordinary gate.
        await h.controller.finalize(first, spans: TurnControllerTests.words("hello there"))
        h.controller.finalRendered(first)
        h.clock.advance(1)
        #expect(await h.wait { h.events.landed.count == 1 })

        flags.value = Self.fnDown
        s.handle(keyCode: 63, flags: Self.fnDown, timestamp: 8)
        let second = try #require(current)
        #expect(second != first, "a new turn, not key repeat")
        #expect(h.controller.stage(of: second) == .listening)
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }
}
