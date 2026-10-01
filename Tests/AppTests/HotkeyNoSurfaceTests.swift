import Combine
import Foundation
import Shared
import Testing
@testable import VoicePlusApp

/// BUG B — "the hotkey sometimes shows no pill at all, and the presence chin goes away with it".
///
/// The chin stands down while the pill is showing (`PresenceStateReducer`: "the pill wins"), and
/// until this suite the input to that rule was `PillViewModel.state.isVisible` — an *intent* to put a
/// pill on screen. Every way the panel could fail to place one (no host display, the pinned display
/// gone, a start refused the instant after `.starting` went up) therefore produced exactly the
/// reported symptom: the chin suppressed by a pill nobody can see, and so no surface at all, both
/// coming back on key-up when the state fell to `.hidden`.
///
/// What is tested here is the logic: the gesture the key resolves to, the suppression rule, and the
/// refusal copy. **Not** testable on this machine: the fn / 🌐 key itself, `CGEvent`-tap liveness and
/// re-enabling, and the TCC grants of the running copy — those need real hardware and a real
/// window server, and must be verified by hand.
@Suite("A hotkey press always leaves a surface (BUG B)")
struct HotkeyNoSurfaceTests {

    // MARK: - The suppression rule

    /// The chin the app would draw for a pill in `pillState` whose panel is (or is not) on screen.
    /// `panelOnScreen == nil` is a run where nothing reports a panel at all — headless, and every
    /// existing presence test.
    @MainActor
    private func chin(pillState: PillState, panelOnScreen: Bool?) -> PresenceState {
        let presence = PresenceIndicatorController()
        presence.setPillVisible(pillState.isVisible)
        if let panelOnScreen { presence.setPillOnScreen(panelOnScreen) }
        return presence.reducedState
    }

    @MainActor
    @Test("a pill state that never reaches the screen does not take the chin with it")
    func intentAloneNeverSuppressesTheChin() {
        // The reported failure: the turn put `.starting` up, the panel never placed it.
        #expect(chin(pillState: .starting, panelOnScreen: false) == .ready)
        #expect(chin(pillState: .error(message: "x"), panelOnScreen: false) == .ready)
        // And a pill genuinely on screen still wins, exactly as the design says.
        #expect(chin(pillState: .starting, panelOnScreen: true) == .off)
        #expect(chin(pillState: .hidden, panelOnScreen: true) == .ready)
    }

    @MainActor
    @Test("with no panel reporting (headless, tests) the pill's state decides as it always did")
    func noPanelReportKeepsTheOldRule() {
        #expect(chin(pillState: .starting, panelOnScreen: nil) == .off)
        #expect(chin(pillState: .hidden, panelOnScreen: nil) == .ready)
    }

    @MainActor
    @Test("the panel going out brings the chin back even while the state still says visible")
    func panelLeavingRestoresTheChin() {
        let presence = PresenceIndicatorController()
        presence.setPillVisible(true)
        presence.setPillOnScreen(true)
        #expect(presence.reducedState == .off)
        presence.setPillOnScreen(false)
        #expect(presence.reducedState == .ready, "no pill is drawn, so the chin is the only surface left")
    }

    @MainActor
    @Test("a dead event tap stays visible even while a pill state is up that never got drawn")
    func deadTapIsStillVisible() {
        // `CapabilityWatcher` re-arms a deaf source once and then calls `onTapProvenDead`, which the
        // app turns into this blocker ("Relaunch"). It is the only thing on screen telling the user
        // why the key does nothing — and a phantom pill used to hide it too.
        let presence = PresenceIndicatorController()
        presence.setTapProvenDead()
        presence.setPillVisible(true)
        presence.setPillOnScreen(false)
        #expect(presence.reducedState == .blocked(.relaunchNeeded))
    }

    // MARK: - The pill panel's own report

    @MainActor
    @Test("a fresh pill panel reports no surface on screen")
    func panelStartsOffScreen() {
        let controller = PillPanelController()
        var reported: [Bool] = []
        let token = controller.surfaceOnScreen.sink { reported.append($0) }
        #expect(reported == [false])
        token.cancel()
    }

    @MainActor
    @Test("`bind` carries the panel's report through to the suppression rule")
    func bindForwardsThePanelReport() async {
        let presence = PresenceIndicatorController()
        let panel = CurrentValueSubject<Bool, Never>(false)
        presence.bind(pill: PillViewModel(), engineStates: Empty().eraseToAnyPublisher(), mute: nil,
                      pillOnScreen: panel.eraseToAnyPublisher())
        await settle()                       // let the bound publishers' first values land
        presence.setPillVisible(true)        // a turn put a row up…
        #expect(presence.reducedState == .ready, "the panel says nothing is on screen")
        panel.send(true)
        await settle()
        #expect(presence.reducedState == .off, "a pill that is really drawn still wins")
    }

    /// `bind` delivers on the main queue, which is always one hop away even from the main thread.
    @MainActor
    private func settle() async {
        for _ in 0..<50 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    // MARK: - Gesture resolution (the fn / 🌐 edges, as the recogniser sees them)

    @Test("hold, tap, double-tap and a lost key-up resolve to the actions the turn expects")
    func gestureResolution() {
        var m = HotkeyStateMachine()
        // A hold: capture starts on key-down and finalizes on key-up.
        #expect(m.keyDown(at: 0) == [.startCapture])
        #expect(m.keyDown(at: 0.1) == [], "key repeat is not a second turn")
        #expect(m.keyUp(at: 0.4) == [.finalize])

        // Two guarded taps inside the window latch; the first cancels, as nothing was said.
        var l = HotkeyStateMachine()
        _ = l.keyDown(at: 0)
        #expect(l.keyUp(at: 0.1) == [.cancelCapture])
        _ = l.keyDown(at: 0.2)
        #expect(l.keyUp(at: 0.3) == [.enterLatch])
        #expect(l.isCapturing, "latched capture continues with no key held")
        #expect(l.keyDown(at: 1.0) == [.finalize], "a tap while latched stops and finalizes")

        // K02: the key is up but its key-up never arrived. Without this the machine stays in
        // `.keyDown` and drops every later key-down as key repeat — the key goes dead.
        var k = HotkeyStateMachine()
        _ = k.keyDown(at: 0)
        #expect(k.lostKeyUp(at: 0.5) == [.finalize])
        #expect(!k.isCapturing)
        #expect(k.keyDown(at: 1) == [.startCapture], "the next press starts a turn, not a repeat")
    }

    // MARK: - A start that cannot happen says so, in the catalogue's words

    @Test("a turn whose capture never opened leaves a recovery row, not an empty screen")
    func captureFailureIsSurfaced() {
        let h = TurnControllerTests.Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn began"); return }
        #expect(h.events.stateNames == ["starting"], "the row that suppresses the chin went up")
        h.controller.captureFailed(id)
        #expect(h.events.notices == [.A03], "“Couldn’t start this microphone · Nothing was recorded.”")
        #expect(h.controller.stage(of: id) == nil || h.controller.stage(of: id) == .failed)
    }

    @Test("the refusal names what refused, when the starter knows it")
    func captureFailureKeepsTheMappedEntry() {
        let h = TurnControllerTests.Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn began"); return }
        h.controller.captureFailed(id, reason: .A01)
        #expect(h.events.notices == [.A01], "“No microphone found”, not a generic start failure")
    }

    @Test("a press while the previous turn is still in flight is refused out loud (K04)")
    func secondPressIsRefusedOutLoud() {
        let h = TurnControllerTests.Harness()
        guard case .began(let id) = h.controller.keyDown() else { Issue.record("no turn began"); return }
        h.controller.captureOpened(id)
        #expect(h.controller.keyUp(id))      // the turn is now finishing
        guard case .busy = h.controller.keyDown() else {
            Issue.record("a press during the previous turn must be refused, not swallowed")
            return
        }
        #expect(h.events.notices == [.K04], "“Finishing your previous dictation · A second session has not started.”")
    }
}
