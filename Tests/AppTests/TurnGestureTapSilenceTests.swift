import Engine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// H1 — a silent hold: < 0.6 s vanishes; ≥ 0.6 s shows A06 "Didn’t hear anything", gone 1.5 s after
/// key-up, never X08. H2 — tap rules: a tap over a visible non-capture notch dismisses it and
/// schedules nothing new; a double tap still latches. Tap to talk replaced the old tap hint.
@Suite("Turn gestures: silent holds and taps (H1, H2)")
struct TurnGestureTapSilenceTests {
    typealias H = TurnControllerTests.Harness
    final class Count: @unchecked Sendable { var value = 0 }
    final class Fades: @unchecked Sendable { var value: [TimeInterval] = [] }

    // MARK: H1

    static func silentHold(_ h: H, held: TimeInterval, finalPassTakes: TimeInterval = 0) async -> TurnID? {
        guard case .began(let id) = h.controller.keyDown() else { return nil }
        h.controller.captureOpened(id)
        h.clock.advance(held)
        guard h.controller.keyUp(id) else { return nil }
        h.clock.advance(finalPassTakes)
        await h.controller.finalize(id, spans: [])
        return id
    }

    @Test("a silent hold under 0.6 s just vanishes: no row, the turn row is retracted")
    func shortSilentHoldVanishes() async throws {
        let h = H()
        let fades = Fades()
        h.controller.onQuietNotice = { _, fade in fades.value.append(fade) }
        let id = try #require(await Self.silentHold(h, held: 0.4))
        #expect(h.events.notices.isEmpty)
        #expect(fades.value.isEmpty)
        #expect(h.events.events.last == .retract)
        #expect(h.store.entry(id)?.stage == .empty)
    }

    @Test("a silent hold of 0.6 s or more shows A06, timed to go 1.5 s after key-up")
    func longSilentHoldShowsA06() async throws {
        let h = H()
        let fades = Fades()
        let entries = TurnControllerTests.Box<[RecoveryID]>([])
        h.controller.onQuietNotice = { entry, fade in entries.value.append(entry.id); fades.value.append(fade) }
        _ = try #require(await Self.silentHold(h, held: 0.9, finalPassTakes: 0.3))
        #expect(entries.value == [.A06])
        let fade = try #require(fades.value.first)
        #expect(abs(fade - 1.2) < 0.001, "shown 0.3 s after key-up → gone 1.2 s later (1.5 s after key-up)")
    }

    @Test("without a quiet-notice sink the A06 still reaches onNotice; exactly 0.6 s shows the row")
    func boundaryAndFallback() async throws {
        let h = H()
        _ = try #require(await Self.silentHold(h, held: 0.6))
        #expect(h.events.notices == [.A06])
    }

    @Test("fade arithmetic: remainder of 1.5 s, floored; 0.6 s threshold")
    func fadeArithmetic() {
        #expect(PillDwell.silentHoldFade(sinceKeyUp: 0) == 1.5)
        #expect(abs(PillDwell.silentHoldFade(sinceKeyUp: 1.0) - 0.5) < 0.0001)
        #expect(PillDwell.silentHoldFade(sinceKeyUp: 3) == PillDwell.silentHoldMinimumShown)
        #expect(!PillDwell.silentHoldShowsRow(held: 0.59))
        #expect(PillDwell.silentHoldShowsRow(held: 0.6))
    }

    @Test("rendered row: “Didn’t hear anything” is the quiet A06 row — fades (.minimum), never X08",
          arguments: ["", "stray words"])
    func renderedRow(liveText: String) {
        let state = PillState.error(message: PillDeck.didntHearAnything)
        let ctx = PillTurnContext(keyLabel: "Right Option", destination: "Mail",
                                  now: Date(timeIntervalSince1970: 1_000), liveText: liveText)
        let row = PillContent.make(state, context: ctx)
        #expect(row.designKey == "error")
        #expect(row.status == "Didn’t hear anything")
        #expect(row.status != RecoveryCatalog.entry(.X08).headline)
        #expect(row.helper == RecoveryCatalog.entry(.A06).consequence)
        #expect(row.buttons.isEmpty && !row.notice)
        #expect(PillNotice.entry(forMessage: PillDeck.didntHearAnything)?.id == .A06)
        #expect(PillNotice.entry(forMessage: "Didn't hear anything")?.id == .A06)
        #expect(PillDwell.rule(for: state) == .minimum(PillDwell.silentHoldMinimumShown))
        #expect(!PillDwell.staysUntilAction(state))
    }

    // MARK: H2

    @Test("tap with nothing showing → no hint (tap to talk replaced it), no record, no dismiss")
    func tapShowsNoHint() {
        let h = H()
        let dismissed = Count()
        h.controller.surfaceShowing = { false }
        h.controller.onTapDismiss = { dismissed.value += 1 }
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureTapped(id)
        h.clock.advance(5)
        #expect(dismissed.value == 0)
        #expect(h.store.entry(id) == nil, "no cancelled row")
        #expect(!h.events.stateNames.contains("preview"))
    }

    @Test("tap while a notice shows → dismissed, nothing new, no stray cancelled row")
    func tapOverNoticeDismisses() {
        let h = H()
        let dismissed = Count()
        let showing = TurnControllerTests.Box(true)
        h.controller.surfaceShowing = { showing.value }
        h.controller.onTapDismiss = { dismissed.value += 1; showing.value = false }
        guard case .began(let tap) = h.controller.keyDown() else { Issue.record("no turn"); return }
        h.controller.captureTapped(tap)
        #expect(dismissed.value == 1)
        h.clock.advance(5)
        #expect(h.store.entry(tap) == nil, "no cancelled row")
        #expect(!h.events.stateNames.contains("cancelled"))
        #expect(h.events.notices.isEmpty)
    }

    @Test("double tap still latches; no hint flashes")
    func doubleTapStillLatches() {
        var m = HotkeyStateMachine()
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.keyUp(at: 0.1) == [.cancelCapture])
        #expect(m.keyDown(at: 0.25, surfaceShowing: true) == [.startCapture])
        #expect(m.keyUp(at: 0.3) == [.enterLatch])
        #expect(m.phase == .latched)
    }

    @Test("pill surface classifier: hint, notices and outcome rows are surfaces; capture rows are not")
    func surfaceClassifier() {
        typealias V = PillSurfaceVisibility
        #expect(V.isNonCaptureSurface(.preview(text: "Saved to Notes · no text field"), captureOpen: false))
        #expect(!V.isNonCaptureSurface(.preview(text: "live words"), captureOpen: true))
        #expect(V.isNonCaptureSurface(.error(message: PillDeck.didntHearAnything), captureOpen: false))
        #expect(V.isNonCaptureSurface(.cancelled, captureOpen: false))
        for state in [PillState.hidden, .idle, .starting, .listening(level: 0), .listeningQuiet, .latched(elapsed: 1)] {
            #expect(!V.isNonCaptureSurface(state, captureOpen: false), "\(state.caseName)")
        }
    }
}
