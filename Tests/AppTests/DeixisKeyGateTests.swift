import Actions
import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// G1 — the dictation key as the deixis trigger: overlay visibility and tap arming per hotkey
/// action, and a press inside latch that overlaps a drag points instead of stopping.
@Suite("G1 dictation key → deixis overlay")
struct DeixisKeyGateTests {
    typealias A = HotkeyStateMachine.Action

    final class Recorder: DeixisCaptureControlling {
        enum Call: Equatable { case begin(newTurn: Bool), end(finishingDrag: Bool), cancel }
        var calls: [Call] = []
        func beginCapture(at instant: TimelineInstant?, newTurn: Bool) { calls.append(.begin(newTurn: newTurn)) }
        func endCapture(finishingDrag: Bool) { calls.append(.end(finishingDrag: finishingDrag)) }
        func cancelTurn() { calls.append(.cancel) }
    }

    /// A controller over fakes: the overlay's front/back state, what reached the coordinator, and a
    /// session whose latched flag follows what it was sent (as `SessionCoordinator` does).
    final class Rig {
        let capture = Recorder()
        var overlayFront = false
        var overlayLog: [DeixisKeyArbiter.Overlay] = []
        var forwarded: [A] = []
        var latched = false
        var keyDown = false
        var drawWithoutKey = false
        lazy var controller: DeixisKeyController = {
            let c = DeixisKeyController(
                capture: capture,
                overlay: { [unowned self] o in
                    self.overlayLog.append(o)
                    if case .show = o { self.overlayFront = true } else { self.overlayFront = false }
                },
                forward: { [unowned self] a in
                    self.forwarded.append(a)
                    switch a {
                    case .enterLatch: self.latched = true
                    case .finalize: self.latched = false
                    case .startCapture, .cancelCapture: break
                    }
                },
                keyProbe: { [unowned self] in self.keyDown },
                sessionLatched: { [unowned self] in self.latched },
                drawWithoutKey: { [unowned self] in self.drawWithoutKey })
            c.autoPoll = false
            return c
        }()
    }

    @Test func holdShowsTheOverlayOnlyWhileTheKeyIsDown() {
        let rig = Rig()
        rig.controller.handle(.startCapture)
        #expect(rig.overlayFront && rig.capture.calls == [.begin(newTurn: true)] && rig.forwarded == [.startCapture])
        rig.controller.handle(.finalize)
        #expect(!rig.overlayFront && rig.overlayLog.last == .hide(fading: true))      // boxes fade 1.5 s
        #expect(rig.capture.calls.last == .end(finishingDrag: true) && rig.forwarded == [.startCapture, .finalize])
    }

    @Test func tooShortPressCancelsAndClearsAtOnce() {
        let rig = Rig()
        rig.controller.handle(.startCapture)
        rig.controller.handle(.cancelCapture)
        #expect(!rig.overlayFront && rig.overlayLog.last == .hide(fading: false))
        #expect(rig.capture.calls.last == .cancel && rig.forwarded == [.startCapture, .cancelCapture])
    }

    @Test func enterLatchEndsCaptureAndHidesTheOverlay() {
        let rig = Rig()
        rig.controller.handle(.startCapture); rig.controller.handle(.cancelCapture)   // first tap
        rig.controller.handle(.startCapture); rig.controller.handle(.enterLatch)      // second tap
        #expect(!rig.overlayFront && rig.overlayLog.last == .hide(fading: false))
        #expect(rig.capture.calls.last == .end(finishingDrag: true))
        #expect(rig.forwarded == [.startCapture, .cancelCapture, .startCapture, .enterLatch])
        #expect(rig.controller.arbiter.mode == .latched)
    }

    @Test func drawWithoutKeyKeepsTheTapInLatch() {
        let rig = Rig()
        rig.drawWithoutKey = true
        rig.controller.handle(.startCapture)
        rig.controller.handle(.enterLatch)
        #expect(!rig.overlayFront)                                       // the overlay still goes
        #expect(rig.capture.calls == [.begin(newTurn: true)])            // but the tap stays armed
        #expect(rig.controller.checkLatch())                             // still latched: keep watching
        #expect(rig.capture.calls == [.begin(newTurn: true)])
        rig.latched = false                                              // latch stopped from the menu
        #expect(!rig.controller.checkLatch())
        #expect(rig.capture.calls.last == .end(finishingDrag: true) && rig.controller.arbiter.mode == .idle)
        #expect(rig.overlayLog.last == .hide(fading: true))
    }

    @Test func onlyAKeptTapIsWatched() {
        for keep in [false, true] {
            var arbiter = DeixisKeyArbiter()
            _ = arbiter.handle(.startCapture, sessionLatched: false, drawWithoutKey: keep)
            let entered = arbiter.handle(.enterLatch, sessionLatched: false, drawWithoutKey: keep)
            #expect(entered.watchLatch == keep && (entered.capture == nil) == keep)
        }
    }

    @Test func pressInsideLatchThatDrawsPointsInsteadOfStopping() {
        let rig = Rig()
        rig.controller.handle(.startCapture); rig.controller.handle(.enterLatch)
        // Key-down in latch: the recogniser emits .finalize at once; it is held, not forwarded.
        rig.keyDown = true
        rig.controller.handle(.finalize)
        #expect(rig.overlayFront && rig.capture.calls.last == .begin(newTurn: false))   // re-armed for the drag
        #expect(rig.forwarded == [.startCapture, .enterLatch] && rig.latched)
        rig.controller.regionStarted()                                    // a box is dragged
        #expect(!rig.controller.pollRelease())                           // key still down: nothing yet
        rig.keyDown = false
        #expect(rig.controller.pollRelease())
        #expect(rig.latched && rig.forwarded == [.startCapture, .enterLatch])   // latch keeps listening
        #expect(!rig.overlayFront && rig.overlayLog.last == .hide(fading: true))
        #expect(rig.capture.calls.last == .end(finishingDrag: true))
        #expect(rig.controller.arbiter.mode == .latched)

        // The recogniser is now idle, so the next press arrives as .startCapture: a plain tap stops.
        rig.keyDown = true
        rig.controller.handle(.startCapture)
        #expect(rig.overlayFront && rig.forwarded.count == 2)
        rig.keyDown = false
        rig.controller.handle(.cancelCapture)                            // the tap's release
        #expect(rig.forwarded == [.startCapture, .enterLatch, .finalize] && !rig.latched)
        #expect(!rig.overlayFront && rig.controller.arbiter.mode == .idle)
    }

    @Test func plainPressInsideLatchStillStopsIt() {
        let rig = Rig()
        rig.controller.handle(.startCapture); rig.controller.handle(.enterLatch)
        rig.keyDown = true
        rig.controller.handle(.finalize)
        rig.keyDown = false
        rig.controller.pollRelease()
        #expect(rig.forwarded == [.startCapture, .enterLatch, .finalize] && !rig.latched)
        #expect(!rig.overlayFront && rig.controller.arbiter.mode == .idle)
    }

    @Test func latchEndedElsewhereResetsTheArbiter() {
        let rig = Rig()
        rig.controller.handle(.startCapture); rig.controller.handle(.enterLatch)
        rig.latched = false                                              // stopped from the menu
        rig.controller.handle(.startCapture)                             // a fresh hold
        #expect(rig.forwarded.last == .startCapture && rig.controller.arbiter.mode == .holding)
        #expect(rig.capture.calls.last == .begin(newTurn: true))
    }

    @Test func stuckKeyProbeTimesOut() {
        let rig = Rig()
        rig.controller.handle(.startCapture); rig.controller.handle(.enterLatch)
        rig.keyDown = true
        rig.controller.handle(.finalize)
        #expect(!rig.controller.pollRelease(now: Date()))
        #expect(rig.controller.pollRelease(now: Date().addingTimeInterval(rig.controller.releaseTimeout + 1)))
        #expect(!rig.latched)
    }

    /// Overlay visibility for every action from every mode the key can be in.
    @Test(arguments: [
        (setup: [A](), action: A.startCapture, front: true),
        (setup: [A.startCapture], action: A.finalize, front: false),
        (setup: [A.startCapture], action: A.cancelCapture, front: false),
        (setup: [A.startCapture], action: A.enterLatch, front: false),
        (setup: [A.startCapture, A.enterLatch], action: A.finalize, front: true),       // key-down in latch
        (setup: [A.startCapture, A.enterLatch], action: A.startCapture, front: true),
    ])
    func overlayVisibilityPerAction(row: (setup: [A], action: A, front: Bool)) {
        let rig = Rig()
        row.setup.forEach(rig.controller.handle)
        rig.controller.handle(row.action)
        #expect(rig.overlayFront == row.front)
    }

    @Test func hotkeyReportsTheKeyDownBetweenPressAndRelease() {
        let saved = HotkeyService.physicalKeyProbe
        defer { HotkeyService.physicalKeyProbe = saved }
        var physical = false
        HotkeyService.physicalKeyProbe = { _ in physical }
        let defaults = UserDefaults(suiteName: "g1.keydown.\(UUID().uuidString)")!
        let hotkey = HotkeyService(defaults: defaults, defaultBinding: HotkeyBinding(kind: .fn))
        #expect(!hotkey.isDictationKeyDown)
        hotkey.handle(keyCode: 63, flags: 0x0080_0000, timestamp: 1)       // fn down
        #expect(hotkey.isDictationKeyDown)
        hotkey.handle(keyCode: 63, flags: 0, timestamp: 1.5)               // fn up after a hold
        #expect(!hotkey.isDictationKeyDown)
        physical = true                                                     // held while latched
        #expect(hotkey.isDictationKeyDown)
    }
}
