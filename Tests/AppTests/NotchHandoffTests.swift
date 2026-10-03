import CoreGraphics
import Foundation
import Injection
import Shared
import Testing
@testable import VoicePlusApp

/// Fix notch (2026-10-04, owner logs on 1.15.2) — the hands-free notch hid and reopened after every
/// piece, no ribbon flew for any hands-free landing, a tap's late engine states opened and closed the
/// pill, the chin widened for every press before the pill answered it and came back under a pill
/// that was still collapsing, a double-tap after Escape showed nothing, and the end summary reopened
/// a notch that had just closed.
@Suite("Fix notch — one notch for hands-free, taps and the chin hand-off")
struct NotchHandoffTests {
    static let t0 = Date(timeIntervalSince1970: 120_000)

    // MARK: RC1 — the hands-free notch never closes mid-session

    private func latchedModel() -> (PillViewModel, (TimeInterval) -> Void) {
        let model = PillViewModel()
        var clock = Self.t0
        model.now = { clock }
        model.latched = true
        model.present(.latched(elapsed: 3))
        model.apply(.listening(level: 0.3))
        return (model, { clock = clock.addingTimeInterval($0) })
    }

    @Test("a piece's preview, write and landing are drawn on the hands-free row; its dwell returns there, never .hidden")
    func handsFreePieceNeverRetractsThePill() {
        let (model, advance) = latchedModel()
        let latchedFace = model.content()
        var states: [PillState] = []
        let sub = model.$state.sink { states.append($0) }
        defer { sub.cancel() }
        // The piece's automatic preview clears the per-piece `captureOpen` (this is what broke H28).
        model.present(.finalPreview(FinalPreviewInfo(text: "Piece one.", dwellRemaining: 0, destination: "Claude")))
        #expect(!model.turn.captureOpen)
        var face = model.content()
        #expect(face.designKey == latchedFace.designKey, "preview drawn on the hands-free row")
        #expect(face.words == .final("Piece one."), "the piece's words show in the notch")
        #expect(face.buttons == latchedFace.buttons, "Finish dictation stays under the pointer")
        #expect(PillPanelController.surface(for: face) == PillPanelController.surface(for: latchedFace))
        model.present(.inserting(text: "Piece one."))
        face = model.content()
        #expect(face.designKey == latchedFace.designKey)
        #expect(PillPanelController.surface(for: face) == PillPanelController.surface(for: latchedFace))
        model.present(delivery: .delivered(verified: true, method: "ax"), text: "Piece one.", destination: "Claude")
        #expect(model.state.caseName == "landed", "still .landed underneath: the ribbon keys off it")
        face = model.content()
        #expect(face.designKey == latchedFace.designKey)
        #expect(face.status.contains("Claude"))
        advance(2)
        model.retractDelivery()
        #expect(model.state.caseName == "latched")
        #expect(!states.contains(.hidden), "the notch never closed between pieces: \(states.map(\.caseName))")
    }

    @Test("while latched, hide() and a stray engine idle return to the hands-free row; after the session they hide")
    func hideIsImpossibleWhileLatched() {
        let (model, advance) = latchedModel()
        model.hide()
        #expect(model.state.caseName == "latched")
        model.apply(.idle)
        #expect(model.state.caseName == "latched")
        model.latched = false
        advance(5)
        model.hide()
        #expect(model.state == .hidden, "the session's end is the way out")
    }

    @Test("a manual preview during hands-free keeps its own row (it waits for the user)")
    func manualPreviewKeepsItsRow() {
        let (model, _) = latchedModel()
        model.present(.finalPreview(FinalPreviewInfo(text: "Piece.", dwellRemaining: 0, manual: true)))
        #expect(model.content().designKey != "latched")
    }

    @Test("a notice line during a hands-free piece is a lane note, not a row of its own")
    func noticeDuringPieceIsALaneNote() {
        let (model, _) = latchedModel()
        model.present(.finalPreview(FinalPreviewInfo(text: "Piece.", dwellRemaining: 0)))
        model.present(.preview(text: "Voice learned"))
        #expect(model.state.caseName == "finalPreview")
        #expect(model.laneNote == "Voice learned")
    }

    @Test("retract during a hands-free piece (capture flag cleared by the piece) returns to the hands-free row")
    func retractActionKeysOnTheSession() {
        typealias W = TurnWiring
        for state: PillState in [.finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0)), .inserting(text: "x"),
                                 .cancelled, .undoAvailable, .finishing(elapsedWarning: false)] {
            #expect(W.retractAction(state, captureOpen: false, latched: true) == .returnToLatched, "\(state)")
        }
        #expect(W.retractAction(.preview(text: "note"), captureOpen: false, latched: true) == .leave)
        #expect(W.retractAction(.cancelled, captureOpen: false, latched: false) == .hide)
    }

    // MARK: RC7 — Finish dictation finishes whatever piece is drawn

    @Test("Finish dictation routes to the session's finish over a piece's preview, write or outcome")
    func finishRoutesOverAnyPiece() {
        let h = TurnControllerTests.Harness(dwell: .immediate)
        for shown: PillState in [.latched(elapsed: 2), .finalPreview(FinalPreviewInfo(text: "x", dwellRemaining: 0)),
                                 .inserting(text: "x"), .landed(LandedPillInfo(text: "x", verified: true))] {
            var finished = 0
            #expect(TurnWiring.route(.finish, shown: shown, to: h.controller, finishLatch: { finished += 1 }), "\(shown)")
            #expect(finished == 1, "\(shown)")
        }
        #expect(!TurnWiring.route(.finish, shown: .latched(elapsed: 2), to: h.controller, finishLatch: nil))
    }

    // MARK: RC3 — late engine states from a press that already ended

    @Test("no capture turn: a late listening / preview / starting / warning never reaches the pill; idle and errors do")
    func lateLiveCaptureStatesAreDropped() {
        let h = TurnControllerTests.Harness(dwell: .immediate)
        #expect(!h.controller.admitsEngineState(.listening(level: 0.2)))
        #expect(!h.controller.admitsEngineState(.previewing(text: "late")))
        #expect(!h.controller.admitsEngineState(.starting))
        #expect(!h.controller.admitsEngineState(.warning(.unknownGood)))
        #expect(h.controller.admitsEngineState(.idle))
        #expect(h.controller.admitsEngineState(.error("x")))
        // With a capture open the live states pass as before.
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.admitsEngineState(.listening(level: 0.2)))
    }

    // MARK: RC3/RC4 — the pill panel and the chin as one notch

    static let metrics = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), topInset: 32,
                                       notchWidth: 200, menuBarHeight: 32,
                                       visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), displayID: 1)

    @Test("the pill opens out of the chin and closes back into it (same display, same top edge)")
    func pillRetractsIntoTheChin() {
        let base = NotchGeometry.pillLayout(for: Self.metrics, size: NotchGeometry.activeSize)
        let rest = PresenceGeometry.layout(for: Self.metrics, state: .ready).frame
        let listening = PresenceGeometry.layout(for: Self.metrics, state: .listening(level: 0)).frame
        #expect(NotchHandoff.layout(base, chin: rest).retracted == rest)
        #expect(NotchHandoff.layout(base, chin: listening).retracted == listening)
        #expect(NotchHandoff.layout(base, chin: rest).shown == base.shown)
        // No chin, a chin elsewhere, or a hover row wider than the pill: the centred line.
        #expect(NotchHandoff.layout(base, chin: nil) == base)
        #expect(NotchHandoff.layout(base, chin: rest.offsetBy(dx: 0, dy: -40)) == base)
        #expect(NotchHandoff.layout(base, chin: rest.offsetBy(dx: 1600, dy: 0)) == base)
        let wide = CGRect(x: base.shown.midX - 400, y: rest.minY, width: 800, height: rest.height)
        #expect(NotchHandoff.layout(base, chin: wide) == base)
        #expect(base.retracted.height == 1)
    }

    @Test("a show during a retraction grows the pill back from where it is")
    func showMidRetractionResumes() {
        #expect(NotchHandoff.resumesRetraction(retracting: true, panelOrderedIn: true))
        #expect(!NotchHandoff.resumesRetraction(retracting: true, panelOrderedIn: false))
        #expect(!NotchHandoff.resumesRetraction(retracting: false, panelOrderedIn: true))
    }

    @Test("the chin never widens for a tap or before a hold's pill; a live face nobody else shows still appears")
    func revealGate() {
        var gate = PresenceRevealGate()
        let live = PresenceState.listening(level: 0.2)
        // A tap: the microphone is open ~0.6 s, then closes. The chin stays at rest throughout.
        #expect(gate.admit(live, shown: .ready, now: Self.t0).state == .ready)
        #expect(gate.admit(live, shown: .ready, now: Self.t0 + 0.6).state == .ready)
        #expect(gate.admit(.ready, shown: .ready, now: Self.t0 + 0.7).state == .ready)
        // A hold: the pill comes on screen at ~0.3 s and suppresses the chin (`.off`) — never widened.
        #expect(gate.admit(live, shown: .ready, now: Self.t0 + 1).state == .ready)
        #expect(gate.admit(.off, shown: .ready, now: Self.t0 + 1.3).state == .off)
        // A meeting (no pill): listening shows once it has lasted the delay.
        var meeting = PresenceRevealGate()
        let first = meeting.admit(live, shown: .ready, now: Self.t0)
        #expect(first.state == .ready && first.recheckAfter == PresenceRevealGate.defaultDelay)
        #expect(meeting.admit(live, shown: .ready, now: Self.t0 + PresenceRevealGate.defaultDelay).state == live)
        // After the pill (shown .off) a live face is immediate: the notch is never empty.
        var after = PresenceRevealGate()
        #expect(after.admit(live, shown: .off, now: Self.t0).state == live)
        // Leaving a live face, and alarms, are immediate.
        #expect(after.admit(.ready, shown: live, now: Self.t0).state == .ready)
        #expect(after.admit(.muted, shown: .ready, now: Self.t0).state == .muted)
    }

    // MARK: RC2 — every hands-free landing flies the ribbon

    @Test("a landing straight after the preview (no .inserting, as for a hands-free piece) flies the ribbon")
    func handsFreeLandingFlies() {
        let h = RibbonN19Tests.Harness(TapeFlightLadderQ5Tests.LadderCaret(element: TapeFlightLadderQ5Tests.elementRect))
        h.controller.stateChanged(.finalPreview(FinalPreviewInfo(text: TapeFlightTests.text, dwellRemaining: 0)))
        h.controller.stateChanged(.landed(LandedPillInfo(text: TapeFlightTests.text, verified: true)))
        #expect(h.surface.current != nil, "the ribbon is drawn")
        #expect(h.sink.reports.map(\.outcome) == [.flew])
        // The pill returning to the hands-free row is the landing's tail, not an interruption.
        h.controller.stateChanged(.latched(elapsed: 4))
        #expect(h.surface.current != nil)
    }

    @Test("a hold's .inserting → .landed still flies exactly once")
    func holdLandingFliesOnce() {
        let h = RibbonN19Tests.Harness(TapeFlightLadderQ5Tests.LadderCaret(element: TapeFlightLadderQ5Tests.elementRect))
        h.fly()
        h.controller.stateChanged(.landed(LandedPillInfo(text: TapeFlightTests.text, verified: true)))
        #expect(h.sink.reports.map(\.outcome) == [.flew])
        #expect(!TapeFlightController.landingStartsFlight(phase: .idle, insertedLength: 0))
        #expect(!TapeFlightController.landingStartsFlight(phase: .locating, insertedLength: 5))
        #expect(TapeFlightController.landingStartsFlight(phase: .armed, insertedLength: 0))
    }

    // MARK: RC5 — Escape (or Finish, or a timeout) leaves the gesture machine idle

    @MainActor @Test("hands-free ended elsewhere: the next double-tap starts hands-free again")
    func gestureLeavesLatchedWhenTheSessionEndsElsewhere() {
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.notchRC5.\(UUID())")!,
                                    defaultBinding: HotkeyBinding(kind: .fn))
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        let fn = HotkeyBinding.Kind.fn.flagMask
        func tap(_ t: TimeInterval) {
            service.handle(keyCode: 63, flags: fn, timestamp: t)
            service.handle(keyCode: 63, flags: 0, timestamp: t + 0.05)
        }
        tap(1); tap(1.2)
        #expect(actions.last == .enterLatch)
        #expect(service.machine.phase == .latched)
        service.endLatchedGesture()   // Escape ended the session
        #expect(service.machine.phase == .idle)
        actions = []
        tap(5); tap(5.2)
        #expect(actions.contains(.startCapture) && actions.last == .enterLatch, "\(actions)")
        // The stop tap itself already left `.latched`: nothing to reset.
        service.handle(keyCode: 63, flags: fn, timestamp: 9)
        service.endLatchedGesture()
        #expect(service.machine.phase != .idle, "a key that is down is never reset from here")
    }
}
