import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Focus safety (T4) under the R2.3 rule: focus loss *holds*, it never re-delivers

@Suite struct FocusGuardTests {
    @Test func abortsWhenFrontmostAppChangedBeforeInjection() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.tinyspeck.slackmacgap", pid: 200)
        var notified: HeldText?
        injector.focusGuard.onHeld = { notified = $0 }
        let outcome = injector.inject(InjectionRequest(text: "secret", expectedFocus: snapshot))
        #expect(outcome == .abortedFocusChanged(expected: snapshot, actual: mock.frontmost))
        #expect(mock.field.value == "")
        #expect(mock.journal.isEmpty)
        #expect(notified?.text == "secret")
        #expect(notified?.reason == DeliveryReason.destinationChanged)
        #expect(notified?.destinationName == "com.apple.TextEdit")   // named, so the pill can say where
        #expect(injector.focusGuard.held.count == 1)
        #expect(outcome.delivery == .held(reason: DeliveryReason.destinationChanged))
        #expect(!outcome.delivery.isTerminal)                        // held waits for the user
    }

    /// Was `abortsIfFocusChangesMidFallbackChain`. Under the readback rule there is no chain left to
    /// abort in the middle of: the first method that posts is the last one to run. The property the
    /// old test cared about — nothing is ever typed into the app the user switched to — still holds,
    /// and now holds for a stronger reason.
    @Test func focusFlipDuringAPostedMethodNeverStartsASecondMethod() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit") { $0.axWriteWorks = false; $0.keystrokesWork = false }
        let snapshot = mock.frontmost
        mock.beforeSideEffect = { [weak mock] in mock?.frontmost = focus("com.apple.Safari", pid: 300) }
        let outcome = injector.inject(InjectionRequest(text: "x", expectedFocus: snapshot))
        #expect(outcome == .injected(method: .keystroke, verified: false))
        #expect(!mock.journal.contains { $0.hasPrefix("key.combo") })   // paste never reached
        #expect(!mock.journal.contains { $0.contains("(300)") })         // nothing addressed to Safari
        #expect(mock.field.value == "")
    }

    @Test func focusReturningAloneNeverInsertsHeldText() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.apple.Safari", pid: 300)
        let outcome = injector.inject(InjectionRequest(text: "later", expectedFocus: snapshot))
        guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(injector.focusGuard.held.count == 1)

        // The user comes back to TextEdit. Nothing may appear there on its own.
        mock.frontmost = snapshot
        #expect(mock.field.value == "")
        #expect(mock.journal.isEmpty)
        #expect(injector.focusGuard.held.count == 1)

        // Only the user's choice delivers it.
        let delivered = injector.focusGuard.insertHere()
        #expect(delivered == .injected(method: .ax, verified: true))
        #expect(mock.field.value == "later")
        #expect(injector.focusGuard.held.isEmpty)
    }

    @Test func insertHereTargetsWhateverHasFocusNowNotTheOldDestination() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.apple.Notes", pid: 400)
        _ = injector.inject(InjectionRequest(text: "wherever", expectedFocus: snapshot))
        // Still in Notes; "Insert here" means here.
        #expect(injector.focusGuard.insertHere()?.succeeded == true)
        #expect(mock.field.value == "wherever")
    }

    @Test func copyPutsHeldTextOnThePasteboardAndClearsIt() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.apple.Safari", pid: 300)
        _ = injector.inject(InjectionRequest(text: "to the clipboard", expectedFocus: snapshot))
        #expect(injector.focusGuard.copy())
        #expect(mock.pasteboardString == "to the clipboard")
        #expect(injector.focusGuard.held.isEmpty)
        #expect(mock.field.value == "")
    }

    @Test func discardRemovesHeldTextWithoutTypingIt() {
        let (injector, mock, _) = makeStack("com.apple.TextEdit")
        let snapshot = mock.frontmost
        mock.frontmost = focus("com.apple.Safari", pid: 300)
        _ = injector.inject(InjectionRequest(text: "gone", expectedFocus: snapshot))
        #expect(injector.focusGuard.discard())
        #expect(injector.focusGuard.held.isEmpty)
        #expect(mock.journal.isEmpty)
        #expect(mock.pasteboardString == nil)
    }

    @Test func heldListIsBoundedAndDropsTheOldest() {
        let guardian = FocusGuard(system: MockSystemAccess())
        guardian.maxHeld = 3
        for i in 0..<5 { guardian.hold(InjectionRequest(text: "t\(i)"), reason: DeliveryReason.destinationChanged) }
        #expect(guardian.held.count == 3)
        #expect(guardian.held.map(\.text) == ["t2", "t3", "t4"])
    }

    @Test func heldItemsAreAddressableByIDAndCarryTheirSegment() {
        let guardian = FocusGuard(system: MockSystemAccess())
        let seg = SegmentID.first(in: UUID())
        let item = guardian.hold(InjectionRequest(text: "s"), reason: DeliveryReason.neverInject, segmentID: seg)
        #expect(guardian.heldText(id: item.id)?.segmentID == seg)
        #expect(guardian.hasHeldText)
        guardian.discardAll()
        #expect(!guardian.hasHeldText)
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
        // Nothing is ever addressed to the wrong pid, and a flip we noticed before posting holds.
        #expect(!mock.journal.contains { $0.contains("(999)") })
        if flipped && !outcome.succeeded {
            guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
            #expect(injector.focusGuard.held.count == 1)
        }
        // Whatever happened, at most one method ever posted.
        #expect(mock.postCount <= 1)
    }
}
