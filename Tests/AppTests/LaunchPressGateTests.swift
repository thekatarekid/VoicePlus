import Foundation
import Testing
import Shared
@testable import VoicePlusApp

/// A3 / V4.6 — the hotkey is armed before `AppContainer.build`, and a press made while the container
/// is still landing is held (one at most) and replayed once it is wired. Driven through
/// `LaunchSequence.run` with a fake container future, and fed by the real `HotkeyStateMachine`, so
/// the gestures are the ones a user actually makes.
@Suite("Hotkey armed before the container (V4.6)")
@MainActor
struct LaunchPressGateTests {

    final class PillLog {
        var shown: [PillState] = []
        var dismissed = 0
    }

    final class ActionLog {
        var actions: [HotkeyStateMachine.Action] = []
        var wired = false
    }

    /// The container build, resolved by the test.
    @MainActor
    final class ContainerFuture {
        private var waiter: CheckedContinuation<String, Never>?
        private(set) var isAwaited = false
        func value() async -> String {
            isAwaited = true
            return await withCheckedContinuation { waiter = $0 }
        }
        func land() {
            waiter?.resume(returning: "container")
            waiter = nil
        }
    }

    /// One launch: the gate is live, the container future is pending.
    struct Launch {
        let gate: LaunchPressGate
        let pill: PillLog
        let log: ActionLog
        let future: ContainerFuture
        let task: Task<String, Never>
        var machine = HotkeyStateMachine()

        mutating func down(_ t: TimeInterval) { machine.keyDown(at: t).forEach(gate.handle) }
        mutating func up(_ t: TimeInterval) { machine.keyUp(at: t).forEach(gate.handle) }
    }

    private func launch() async -> Launch {
        let pill = PillLog()
        let log = ActionLog()
        let gate = LaunchPressGate(present: { pill.shown.append($0) }, dismiss: { pill.dismissed += 1 })
        let future = ContainerFuture()
        let task = Task { @MainActor in
            await LaunchSequence.run(gate: gate,
                                     build: { await future.value() },
                                     wire: { _ in log.wired = true },
                                     forward: { log.actions.append($0) })
        }
        while !future.isAwaited { await Task.yield() }
        return Launch(gate: gate, pill: pill, log: log, future: future, task: task)
    }

    private func land(_ l: Launch) async {
        l.future.land()
        _ = await l.task.value
    }

    @Test func aPressBeforeTheContainerShowsStarting() async {
        var l = await launch()
        l.down(0)
        #expect(l.pill.shown == [.starting])
        #expect(PillState.starting.messageLines.first == "Starting microphone…")
        #expect(l.log.actions.isEmpty, "nothing may reach the session before the container exists")
        await land(l)
    }

    @Test func aKeyStillHeldWhenTheContainerLandsStartsCapture() async {
        var l = await launch()
        l.down(0)
        await land(l)
        #expect(l.log.wired)
        #expect(l.log.actions == [.startCapture])
        #expect(l.pill.dismissed == 0)
        #expect(l.gate.isReady)
        // The release now belongs to the real handler, which `wire` installed; the gate is out of it.
        l.up(1.2)
        #expect(l.log.actions == [.startCapture])
    }

    @Test func aReleasedPressLandsNothingAndGoesQuietly() async {
        var l = await launch()
        l.down(0)
        l.up(1.0)                        // a real hold, released before the container landed
        #expect(l.pill.dismissed == 1)
        await land(l)
        #expect(l.log.actions.isEmpty, "a released press must not start capture later")
        #expect(l.pill.shown == [.starting], "no error, no 'too short' — the first isolated tap is quiet (K03)")
    }

    @Test func twoPressesQueueOne() async {
        var l = await launch()
        l.down(0); l.up(0.5)             // first press, released
        l.down(1.0)                      // second press, still held
        l.gate.handle(.startCapture)     // a duplicate down edge changes nothing
        await land(l)
        #expect(l.log.actions == [.startCapture], "exactly one capture for two presses")
        #expect(l.pill.shown.filter { $0 == .starting }.count == 2, "each press says Starting microphone…")
    }

    @Test func twoReleasedPressesLandNothing() async {
        var l = await launch()
        l.down(0); l.up(0.4)
        l.down(1.0); l.up(1.5)
        await land(l)
        #expect(l.log.actions.isEmpty)
        #expect(l.pill.dismissed == 2)
    }

    @Test func aDoubleTapLatchIsReplayedAsALatch() async {
        var l = await launch()
        l.down(0); l.up(0.1)             // guarded tap
        l.down(0.2); l.up(0.3)           // second guarded tap inside the window → latch
        #expect(l.gate.pending == .latched)
        await land(l)
        #expect(l.log.actions == [.startCapture, .enterLatch])
    }

    @Test func aTapOutOfALatchBeforeTheContainerLandsNothing() async {
        var l = await launch()
        l.down(0); l.up(0.1)
        l.down(0.2); l.up(0.3)           // latched
        l.down(2.0)                      // a tap while latched stops it (.finalize)
        await land(l)
        #expect(l.log.actions.isEmpty)
    }

    @Test func noPressMeansNothingIsReplayed() async {
        let l = await launch()
        await land(l)
        #expect(l.log.wired)
        #expect(l.log.actions.isEmpty)
        #expect(l.pill.shown.isEmpty)
    }

    @Test func pressesAfterTheContainerAreNotIntercepted() async {
        var l = await launch()
        await land(l)
        l.down(0)
        #expect(l.pill.shown.isEmpty, "after wiring, the real handler owns every press")
        #expect(l.log.actions.isEmpty)
        l.gate.containerReady { l.log.actions.append($0) }    // idempotent: nothing replayed twice
        #expect(l.log.actions.isEmpty)
    }
}
