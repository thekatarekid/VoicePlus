import CoreGraphics
import Foundation
import Testing
@testable import VoicePlusApp

/// 1.6.6 — "the app crashes when I press the dictation key."
///
/// The trap itself was in the overlay window, not here, but the investigation found a second bug on
/// the same path with no test and no symptom yet: the tap's `userInfo` was
/// `Unmanaged.passUnretained(self).toOpaque()`, a raw pointer to an object the tap does not own, in
/// a class with no `deinit`. Nothing but the fact that `AppDelegate` holds both services for the
/// whole process kept the run loop from calling into freed memory on the next keypress.
///
/// These tests pin the structural properties that make that impossible rather than merely unlikely:
/// one live tap per service at all times, teardown that leaves nothing callable, and a callback path
/// that lands on the main thread whatever thread it was delivered on.
@Suite("Hotkey tap lifecycle — one tap, no dangling context")
struct HotkeyTapLifecycleTests {
    private func service(_ stub: StubEventTap) -> HotkeyService {
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.taplife.\(UUID())")!)
        service.installer = stub.installer
        return service
    }

    @Test func armReArmStopLeavesNoLiveTapAndNoResolvableToken() throws {
        let stub = StubEventTap()
        let service = service(stub)

        #expect(service.start())
        let first = try #require(service.tapToken)
        #expect(stub.liveTaps == [first])
        #expect(HotkeyTapRegistry.isLive(first))

        // Re-arm: the old tap must be gone *before* the new one exists, never two at once.
        #expect(service.rearm())
        let second = try #require(service.tapToken)
        #expect(second != first)
        #expect(stub.liveTaps == [second], "a re-arm must not stack a second tap on the run loop")
        #expect(!HotkeyTapRegistry.isLive(first), "the old token must stop resolving the moment its tap dies")
        #expect(HotkeyTapRegistry.isLive(second))

        service.stop()
        #expect(stub.liveTaps.isEmpty)
        #expect(service.tapToken == nil)
        #expect(!HotkeyTapRegistry.isLive(second))
        #expect(!service.isRunning)
    }

    /// The exact shape `CapabilityWatcher` produces on a 1 Hz poll across a grant, a revoke and a
    /// re-grant. Ten ticks must never leave ten taps.
    @Test func repeatedArmingUnderTheWatcherNeverStacksTaps() {
        let stub = StubEventTap()
        let service = service(stub)
        for _ in 0..<10 { service.start() }
        #expect(stub.liveTaps.count == 1)
        #expect(service.armCount == 1, "start() on a running service is a no-op, not a second tap")
        for _ in 0..<10 { service.stop() }
        #expect(stub.liveTaps.isEmpty)
        service.start()
        #expect(stub.liveTaps.count == 1)
        service.stop()
        #expect(stub.liveTaps.isEmpty)
    }

    /// The bug that had no symptom yet. A service released while armed used to leave its tap on the
    /// run loop holding a pointer to freed memory; now the token stops resolving and the tap is
    /// invalidated by `deinit`.
    @Test func releasingAnArmedServiceInvalidatesItsTapAndRetiresItsToken() {
        let stub = StubEventTap()
        var token: Int?
        do {
            let service = service(stub)
            #expect(service.start())
            token = service.tapToken
            #expect(HotkeyTapRegistry.isLive(token!))
        }
        #expect(stub.liveTaps.isEmpty, "deinit must tear the tap down; the run loop outlives the owner")
        #expect(!HotkeyTapRegistry.isLive(token!))
        // And an event that was already in flight for that tap reaches nothing — no crash, no action.
        HotkeyService.deliver(token: token!, keyCode: 61,
                              flags: CGEventFlags.maskAlternate.rawValue, timestamp: 0)
    }

    /// A retired token is not a dangling pointer: resolving it is a dictionary miss, which is why
    /// this can be asserted at all instead of being a hope about timing.
    /// `@MainActor` on purpose: `deliver` applies the event synchronously only when it is already
    /// on the main thread, and hops otherwise. Running the assertions on main is what makes the
    /// before/after comparison exact rather than a race with the main queue.
    @MainActor
    @Test func aCallbackForATornDownTapDoesNothing() throws {
        let stub = StubEventTap()
        let service = service(stub)
        var actions: [HotkeyStateMachine.Action] = []
        service.onAction = { actions.append($0) }
        #expect(service.start())
        let token = try #require(service.tapToken)

        HotkeyService.deliver(token: token, keyCode: 61,
                              flags: CGEventFlags.maskAlternate.rawValue, timestamp: 0)
        #expect(actions == [.startCapture])
        #expect(service.eventsReceived == 1)

        service.stop()
        HotkeyService.deliver(token: token, keyCode: 61,
                              flags: CGEventFlags.maskAlternate.rawValue, timestamp: 1)
        HotkeyService.deliver(token: token, keyCode: 61, flags: 0, timestamp: 2)
        #expect(actions == [.startCapture], "a dead tap must produce no further actions")
        #expect(service.eventsReceived == 0)
        // A token that was never issued is equally inert.
        HotkeyService.deliver(token: 999_999, keyCode: 61,
                              flags: CGEventFlags.maskAlternate.rawValue, timestamp: 3)
        #expect(actions == [.startCapture])
    }

    @Test func aRefusedTapLeavesNothingRegistered() {
        let stub = StubEventTap()
        stub.installSucceeds = false
        let service = service(stub)
        #expect(!service.start())
        #expect(service.tapToken == nil)
        #expect(!service.isRunning)
        #expect(service.armCount == 0)
        // ...and preflight refusing never even reaches the installer.
        stub.installSucceeds = true
        stub.preflightResult = false
        #expect(!service.start())
        #expect(stub.installed.isEmpty)
    }

    /// macOS disables a tap that timed out; the documented recovery is to re-enable it. It used to be
    /// done by reaching through the raw `userInfo` pointer inside the C callback.
    @MainActor
    @Test func aSystemDisabledTapIsReEnabledThroughTheToken() throws {
        let stub = StubEventTap()
        let service = service(stub)
        #expect(service.start())
        let token = try #require(service.tapToken)
        HotkeyService.reenable(token: token)
        #expect(stub.enableCalls.contains { $0.token == token && $0.enabled })
        // After teardown the same call is a no-op rather than a message to a freed object.
        service.stop()
        let before = stub.enableCalls.count
        HotkeyService.reenable(token: token)
        #expect(stub.enableCalls.count == before)
    }
}

/// Everything downstream of `onAction` is main-actor UI — the pill, the ink overlay, the dictation
/// coordinator. The run-loop source is added to `CFRunLoopGetMain()`, so today the callback already
/// arrives on the main thread; this pins that a delivery from any other thread is still applied on
/// the main one instead of mutating the state machine underneath AppKit.
@Suite("Hotkey events delivered off the main thread")
struct HotkeyOffMainDeliveryTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [(HotkeyStateMachine.Action, Bool)] = []
        func record(_ action: HotkeyStateMachine.Action, onMain: Bool) {
            lock.lock(); defer { lock.unlock() }
            actions.append((action, onMain))
        }
        var snapshot: [(HotkeyStateMachine.Action, Bool)] {
            lock.lock(); defer { lock.unlock() }
            return actions
        }
    }

    @Test func aBackgroundThreadDeliveryIsAppliedOnTheMainThread() async throws {
        let stub = StubEventTap()
        let service = HotkeyService(defaults: UserDefaults(suiteName: "AppTests.offmain.\(UUID())")!)
        service.installer = stub.installer
        let recorder = Recorder()
        service.onAction = { recorder.record($0, onMain: Thread.isMainThread) }
        #expect(service.start())
        let token = try #require(service.tapToken)

        DispatchQueue.global(qos: .userInitiated).async {
            HotkeyService.deliver(token: token, keyCode: 61,
                                  flags: CGEventFlags.maskAlternate.rawValue, timestamp: 0)
            HotkeyService.deliver(token: token, keyCode: 61, flags: 0, timestamp: 0.6)
        }

        let deadline = Date().addingTimeInterval(5)
        while recorder.snapshot.count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let seen = recorder.snapshot
        #expect(seen.map(\.0) == [.startCapture, .finalize])
        let allOnMain = seen.allSatisfy { $0.1 }
        #expect(allOnMain, "the gesture must never be advanced off the main thread")
        service.stop()
    }
}
