import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Focus safety (T4)

@Suite struct FocusGuardTests {
    @Test func abortsWhenFrontmostAppChangedBeforeInjection() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.tinyspeck.slackmacgap", pid: 200)
        var notified: InjectionRequest?
        injector.focusGuard.onQueued = { req, _ in notified = req }
        let outcome = injector.inject(InjectionRequest(text: "secret", expectedFocus: snapshot))
        #expect(outcome == .abortedFocusChanged(expected: snapshot, actual: mock.frontmost))
        #expect(mock.field.value == "")
        #expect(mock.journal.isEmpty)
        #expect(notified?.text == "secret")
        #expect(injector.focusGuard.queue.count == 1)
    }

    @Test func abortsIfFocusChangesMidFallbackChain() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit") { $0.axWriteWorks = false; $0.keystrokesWork = false }
        let snapshot = mock.frontmost
        mock.beforeSideEffect = { [weak mock] in mock?.frontmost = focus("com.apple.Safari", pid: 300) } // switch during keystroke attempt
        let outcome = injector.inject(InjectionRequest(text: "x", expectedFocus: snapshot))
        guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(!mock.journal.contains { $0.hasPrefix("key.combo") })   // paste never reached
        #expect(mock.field.value == "")
    }

    @Test func queuedTextDeliversWhenFocusReturns() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.apple.Safari", pid: 300)
        _ = injector.inject(InjectionRequest(text: "later", expectedFocus: snapshot))
        #expect(injector.flushQueue().isEmpty)          // still elsewhere
        mock.frontmost = snapshot
        let delivered = injector.flushQueue()
        #expect(delivered == [.injected(method: .ax, verified: true)])
        #expect(mock.field.value == "later")
        #expect(injector.focusGuard.queue.isEmpty)
    }

    @Test func noSnapshotMeansNoFocusCheck() {
        let (injector, mock, _) = makeStack()
        mock.frontmost = focus("com.anything", pid: 9)
        #expect(injector.inject(InjectionRequest(text: "x")).succeeded)
    }

    @Test func strictElementIdentityDetectsFieldChangeWithinApp() {
        let mock = MockSystemAccess()
        let guardian = FocusGuard(system: mock)
        guardian.strictElementIdentity = true
        let snap = guardian.snapshot()
        mock.frontmost = focus("com.apple.TextEdit", token: "el-2")
        #expect(!guardian.matches(snap))
        guardian.strictElementIdentity = false
        #expect(guardian.matches(snap))
    }

    @Test("chaos: random focus flips never spray text into the wrong app", arguments: 1...25)
    func chaos(seed: Int) {
        var rng = UInt64(seed) &* 2862933555777941757 &+ 3037000493
        func next() -> UInt64 { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return rng >> 33 }
        let mock = MockSystemAccess(frontmost: focus("com.target"))
        mock.axWriteWorks = next() % 2 == 0
        mock.keystrokesWork = next() % 2 == 0
        let injector = TextInjector(system: mock, store: InMemoryOutcomeStore())
        let snapshot = mock.frontmost
        var flipped = false
        mock.beforeSideEffect = { [weak mock] in
            if next() % 3 == 0 { mock?.frontmost = focus("com.wrong", pid: 999); flipped = true }
        }
        if next() % 4 == 0 { mock.frontmost = focus("com.wrong", pid: 999); flipped = true }
        let outcome = injector.inject(InjectionRequest(text: "payload", expectedFocus: snapshot))
        // Nothing is ever addressed to the wrong pid, and once we notice the flip the chain stops (queued).
        #expect(!mock.journal.contains { $0.contains("(999)") })
        if flipped && !outcome.succeeded {
            guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
            #expect(injector.focusGuard.queue.count == 1)
        }
    }
}
