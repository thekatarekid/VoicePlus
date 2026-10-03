import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// N17 — a tap under the hold threshold is a hint, not a failed turn (no turn record); no speech
/// reads "Didn’t hear anything". N23 — a new press is allowed once the previous text is final; the
/// two land in start order and the older turn never takes the pill from the newer capture.
@Suite("Taps, silence and overlapping presses (N17, N23)")
struct TurnTapOverlapN17N23Tests {
    typealias H = TurnControllerTests.Harness
    static func words(_ t: String) -> [TranscriptSpan] { TurnControllerTests.words(t) }

    final class Count: @unchecked Sendable { var value = 0 }

    // MARK: N17

    @Test("a tap: no turn record, no notice, and the hint once the double-tap window has passed")
    func tapIsAHint() {
        let h = H()
        let hints = Count()
        h.controller.onTapHint = { hints.value += 1 }
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.captureTapped(id)
        #expect(h.store.entry(id) == nil, "a tap is not stored as a cancelled turn")
        #expect(h.events.notices.isEmpty)
        #expect(hints.value == 0, "not before the double-tap window")
        h.clock.advance(h.controller.tapHintDelay)
        #expect(hints.value == 1)
    }

    @Test("the first tap of a double-tap never flashes the hint")
    func doubleTapNoHint() {
        let h = H()
        let hints = Count()
        h.controller.onTapHint = { hints.value += 1 }
        guard case .began(let first) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureTapped(first)
        guard case .began(let second) = h.controller.keyDown(latched: true) else { Issue.record("no 2nd"); return }
        h.clock.advance(h.controller.tapHintDelay)
        #expect(hints.value == 0)
        #expect(h.store.entry(first) == nil)
        #expect(h.store.entry(second) != nil, "the latched press is a real turn")
    }

    @Test("a cancel after the turn left capture is not a tap (the turn is kept)")
    func tapAfterKeyUpIgnored() async throws {
        let h = H(dwell: .immediate)
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))
        h.controller.captureTapped(id)
        #expect(h.store.entry(id)?.stage == .finishing)
    }

    @Test("copy: no speech reads “Didn’t hear anything”; the tap hint names the latch only when it is on")
    func copy() {
        #expect(TurnWiring.noticeHeadline(for: RecoveryCatalog.entry(.A06)) == "Didn’t hear anything")
        #expect(TurnWiring.noticeHeadline(for: RecoveryCatalog.entry(.K04)) == RecoveryCatalog.entry(.K04).headline)
        #expect(TurnWiring.tapHint(latchEnabled: true) == "Hold to talk · double-tap to lock")
        #expect(TurnWiring.tapHint(latchEnabled: false) == "Hold to talk")
    }

    @Test("no speech still ends the turn as empty with A06 (drawn as “Didn’t hear anything”)")
    func noSpeech() async throws {
        let h = H()
        let id = try #require(await h.holdToPreview([], held: 0.7))
        #expect(h.events.notices == [.A06])
        #expect(h.store.entry(id)?.stage == .empty)
    }

    // MARK: N23

    @Test("a press while the previous text is being typed begins a turn; both land in start order")
    func pressDuringInsertLands() async throws {
        let h = H(dwell: .immediate)
        let second = TurnControllerTests.Box<TurnKeyDown?>(nil)
        let phase = TurnControllerTests.Box<EscapePhaseBox?>(nil)
        h.system.beforeSideEffect = { [controller = h.controller] in
            guard second.value == nil else { return }
            second.value = controller.keyDown()
            phase.value = EscapePhaseBox(controller.escapePhase)
        }
        guard case .began(let a) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(a)
        #expect(h.controller.keyUp(a))
        await h.controller.finalize(a, spans: Self.words("first words"))
        #expect(await h.wait { h.events.landed.count == 1 })
        guard case .began(let b)? = second.value else { Issue.record("the press was refused: \(String(describing: second.value))"); return }
        #expect(phase.value?.phase == .beforeWrite, "Escape cancels the new capture, not the write")
        h.controller.captureOpened(b)
        #expect(h.controller.keyUp(b))
        await h.controller.finalize(b, spans: Self.words("second words"))
        #expect(await h.wait { h.events.landed.count == 2 })
        let field = h.field
        let i1 = try #require(field.range(of: "first words")), i2 = try #require(field.range(of: "second words"))
        #expect(i1.lowerBound < i2.lowerBound, "start order")
        #expect(h.store.entry(a)?.stage == .landed)
        #expect(h.store.entry(b)?.stage == .landed)
    }

    @Test("an older turn's quiet end never retracts a newer open capture; its inserting row is not drawn over it")
    func olderTurnLeavesThePillAlone() async throws {
        let h = H(dwell: .immediate)
        guard case .began(let a) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(a)
        #expect(h.controller.keyUp(a))
        // Turn A reaches "being typed" only after B's key-down: its inserting row must not show.
        let began = TurnControllerTests.Box<Bool>(false)
        h.system.beforeSideEffect = { [controller = h.controller] in
            guard !began.value else { return }
            began.value = true
            if case .began(let b) = controller.keyDown() { controller.captureOpened(b) }
        }
        await h.controller.finalize(a, spans: Self.words("first words"))
        #expect(await h.wait { h.events.landed.count == 1 })
        #expect(h.controller.hasOpenCapture)
        let names = h.events.stateNames
        let lastStarting = try #require(names.lastIndex(of: "starting"))
        #expect(!names[lastStarting...].contains("inserting"), "\(names)")
        #expect(!h.events.events.contains(.retract))
    }

    @Test("still refused (K04) while the previous final pass runs or a Manual preview waits")
    func stillRefused() async throws {
        let h = H(dwell: .manual)
        let id = try #require(await h.holdToPreview(Self.words("hello")))
        #expect(h.controller.stage(of: id) == .finalPreview)
        #expect(h.controller.keyDown() == .busy(id))
        #expect(h.events.notices == [.K04])
    }

    @Test("pill: an older turn's outcome under a newer open capture keeps the live row, notes a hold")
    func pillKeepsLiveRow() {
        let pill = PillViewModel()
        pill.present(.listening(level: 0.3))
        pill.present(delivery: .delivered(verified: true, method: "ax"), text: "first", destination: "TextEdit")
        #expect(pill.state == .listening(level: 0.3))
        #expect(pill.laneNote == nil)
        pill.present(delivery: .held(reason: "destination changed"), text: "first", destination: "TextEdit")
        #expect(pill.state == .listening(level: 0.3))
        #expect(pill.laneNote == PillDeck.previousTextHeld)
    }
}

/// Sendable wrapper for the escape phase read inside the mock's hook.
struct EscapePhaseBox: Equatable {
    let phase: EscapeTurnPhase
    init(_ phase: EscapeTurnPhase) { self.phase = phase }
}
