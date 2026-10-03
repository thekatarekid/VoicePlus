import CoreGraphics
import Testing
@testable import VoicePlusApp

/// H36 — one placement attempt and at most one "no display" log line per press.
struct NotchGeometryPillPlacementH36Tests {
    let laptop = ScreenMetrics(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), menuBarHeight: 38, displayID: 1)
    let external = ScreenMetrics(frame: CGRect(x: 1800, y: 89, width: 1920, height: 1080), menuBarHeight: 30, displayID: 2)

    @Test func chooserNilFallsBackToMainThenFirstDisplay() {
        #expect(PillPlacementGate.resolve(chosen: external, screens: [laptop, external], main: laptop) == external)
        #expect(PillPlacementGate.resolve(chosen: nil, screens: [laptop, external], main: external) == external)
        #expect(PillPlacementGate.resolve(chosen: nil, screens: [laptop, external], main: nil) == laptop)
        #expect(PillPlacementGate.resolve(chosen: nil, screens: [], main: nil) == nil)
    }

    @Test func eightRendersOfOneFailedPressLogOnceAndProbeOnce() {
        var gate = PillPlacementGate()
        var attempts = 0, logs = 0
        let renders: [PillState] = [.starting, .starting, .listening(level: 0.2), .listening(level: 0.3), .listening(level: 0.4), .listening(level: 0.5), .listening(level: 0.6), .listening(level: 0.7)]
        var previous: PillState? = .hidden
        for state in renders {
            if gate.mayAttempt(force: false, previous: previous, next: state) { attempts += 1 }
            if gate.noteNoDisplay() { logs += 1 }   // no display found on every render
            previous = state
        }
        #expect(attempts == 1)
        #expect(logs == 1)
    }

    @Test func forcedRenderOrNewTurnRetriesAndPlacementOrHideResets() {
        var gate = PillPlacementGate()
        _ = gate.noteNoDisplay()
        #expect(!gate.mayAttempt(force: false, previous: .listening(level: 0), next: .listening(level: 0)))
        #expect(gate.mayAttempt(force: true, previous: .listening(level: 0), next: .listening(level: 0)))
        #expect(gate.mayAttempt(force: false, previous: .listening(level: 0), next: .starting))
        gate.notePlaced()
        #expect(gate.mayAttempt(force: false, previous: .listening(level: 0), next: .listening(level: 0)))
        _ = gate.noteNoDisplay()
        gate.reset()
        let logsAgain = gate.noteNoDisplay()
        #expect(logsAgain)   // a new press logs its own (single) line
    }
}
