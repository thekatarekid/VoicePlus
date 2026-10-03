import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H28 (core) — the hands-free notch stays out all session: an older turn finishing under an open
/// hands-free capture never draws its "being typed" row over it and a retract never orders the
/// hands-free row out; once the session ends, the turn row retracts as before.
@Suite("Hands-free pill stays out (H28 core)")
struct HandsFreePillStaysTests {
    typealias H = TurnControllerTests.Harness
    static func words(_ t: String) -> [TranscriptSpan] { TurnControllerTests.words(t) }

    @Test("an older turn's write under an open hands-free session: no inserting/undo row over it")
    func olderTurnUnderHandsFree() async throws {
        let h = H(dwell: .immediate)
        guard case .began(let a) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(a)
        #expect(h.controller.keyUp(a))
        let began = TurnControllerTests.Box<Bool>(false)
        h.system.beforeSideEffect = { [controller = h.controller] in
            guard !began.value else { return }
            began.value = true
            if case .began(let b) = controller.keyDown() {
                controller.captureOpened(b)
                controller.noteLatched(true)
            }
        }
        await h.controller.finalize(a, spans: Self.words("first words"))
        #expect(await h.wait { h.events.landed.count == 1 })
        let names = h.events.stateNames
        let lastStarting = try #require(names.lastIndex(of: "starting"))
        #expect(!names[lastStarting...].contains("inserting"), "\(names)")
        #expect(!names[lastStarting...].contains("undoAvailable"), "\(names)")
    }

    @Test("the hands-free session's own end (empty trailing audio) still retracts")
    func sessionEndRetracts() async throws {
        let h = H(dwell: .immediate)
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureOpened(id)
        h.controller.noteLatched(true)
        #expect(h.controller.keyUp(id))
        await h.controller.finalize(id, spans: [])
        #expect(await h.wait { h.events.events.contains(.retract) })
    }

    @Test("retract while the hands-free capture is open returns to the hands-free row, never hides it")
    func retractActionTable() {
        typealias W = TurnWiring
        // Session open: turn rows go back to the hands-free row.
        for state: PillState in [.starting, .listening(level: 0), .finishing(elapsedWarning: false),
                                 .inserting(text: "x"), .cancelled, .undoAvailable] {
            #expect(W.retractAction(state, captureOpen: true, latched: true) == .returnToLatched, "\(state)")
        }
        // The hands-free row itself, a piece's outcome row and a lane note are left alone.
        #expect(W.retractAction(.latched(elapsed: 3), captureOpen: true, latched: true) == .leave)
        #expect(W.retractAction(.preview(text: "note"), captureOpen: true, latched: true) == .leave)
        #expect(W.retractAction(.error(message: "Couldn’t save to Notes"), captureOpen: true, latched: true) == .leave)
        // Fix notch — still latched with the pill's per-piece capture flag cleared (a piece's own
        // preview clears it): the session is live, so back to the hands-free row, never hidden.
        #expect(W.retractAction(.finishing(elapsedWarning: false), captureOpen: false, latched: true) == .returnToLatched)
        // Session over (`latched` false — `endLatch` precedes the end) or a hold turn: retract as before.
        #expect(W.retractAction(.finishing(elapsedWarning: false), captureOpen: false, latched: false) == .hide)
        #expect(W.retractAction(.cancelled, captureOpen: false, latched: false) == .hide)
        #expect(W.retractAction(.listening(level: 0), captureOpen: true, latched: false) == .hide)
    }
}
