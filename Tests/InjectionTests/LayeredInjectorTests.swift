import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Layered fallback (T1) as narrowed by the R2.3 readback rule

@Suite struct LayeredInjectorTests {
    @Test func axInsertsAtCaretAndVerifies() {
        let (injector, mock, store) = makeStack(value: "Hello world")
        mock.field.selection = 5..<5
        let outcome = injector.inject(InjectionRequest(text: ",", expectedFocus: mock.frontmost))
        #expect(outcome == .injected(method: .ax, verified: true))
        #expect(mock.field.value == "Hello, world")
        #expect(mock.journal == ["ax.setSelectedText"])
        #expect(store.records.map(\.method) == ["ax"])
        #expect(store.records.first?.succeeded == true)
        #expect(store.records.first?.detail == "verified")
    }

    @Test func axReplacesSelection() {
        let (injector, mock, _) = makeStack(value: "foo bar baz")
        mock.field.selection = 4..<7
        _ = injector.inject(InjectionRequest(text: "qux"))
        #expect(mock.field.value == "foo qux baz")
        #expect(mock.field.selection == 7..<7)
    }

    @Test func fallsBackToKeystrokesWhenAXNotSettable() {
        let (injector, mock, store) = makeStack(value: "a") { $0.axWriteWorks = false }
        let outcome = injector.inject(InjectionRequest(text: "b"))
        #expect(outcome == .injected(method: .keystroke, verified: true))
        #expect(mock.field.value == "ab")
        #expect(store.records.map(\.method) == ["keystroke"])  // AX skipped (not settable), not recorded as failure
    }

    /// The only fall-through the readback rule allows. `throwsBeforePosting` is what a real
    /// `CGEvent` / AX failure looks like: nothing reached the OS, so nothing can have landed.
    @Test func fallsBackToPasteOnlyWhenKeystrokesThrowBeforePosting() {
        let (injector, mock, store) = makeStack(value: "") {
            $0.axWriteWorks = false
            $0.throwsBeforePosting = [.keystrokes]
        }
        let outcome = injector.inject(InjectionRequest(text: "hi"))
        #expect(outcome == .injected(method: .paste, verified: true))
        #expect(mock.field.value == "hi")
        #expect(store.records.map { ($0.method, $0.succeeded) }.elementsEqual([("keystroke", false), ("paste", true)], by: ==))
        #expect(store.records.first?.detail?.hasPrefix("threw before posting") == true)
    }

    /// Was `readbackDetectsAXWriteThatSilentlyNoops`, which then fell through to keystrokes. R2.3
    /// forbids exactly that: an AX write that returned without throwing may have landed, and
    /// readback cannot prove otherwise (V3 §14.4).
    @Test func axWriteThatReadbackCannotConfirmEndsTheAttemptUnverified() {
        final class LyingMock: MockSystemAccess {
            override func setFocusedValue(_ value: String) throws {}
            override func setFocusedSelectedText(_ text: String) throws {}
        }
        let mock = LyingMock(frontmost: focus("com.example.Liar"))
        let store = InMemoryOutcomeStore()
        let injector = TextInjector(system: mock, store: store)
        let outcome = injector.inject(InjectionRequest(text: "x"))
        #expect(outcome == .injected(method: .ax, verified: false))
        #expect(store.records.map(\.method) == ["ax"])
        #expect(store.records.first?.detail == "unverified: readback unchanged")
        #expect(!mock.journal.contains { $0.hasPrefix("key.") })   // no second method
    }

    @Test func everyMethodThrowingBeforePostingReportsFailure() {
        let (injector, mock, _) = makeStack { $0.throwsBeforePosting = Set(MockSystemAccess.PostSite.allCases) }
        let outcome = injector.inject(InjectionRequest(text: "zzz"))
        #expect(outcome == .failed(attempts: [.ax, .keystroke, .paste]))
        #expect(mock.field.value == "")
        #expect(mock.postCount == 0)
        #expect(outcome.delivery == .failed(reason: DeliveryReason.everyMethodThrew))
    }

    /// A swallowed keystroke is *not* a failure. This is the Brave case: the OS took the event and
    /// the app's AX value did not move. The safe answer is delivered-unverified, and nothing else runs.
    @Test func swallowedKeystrokesEndTheAttemptUnverified() {
        let (injector, mock, store) = makeStack { $0.axWriteWorks = false; $0.keystrokesWork = false; $0.pasteWorks = false }
        let outcome = injector.inject(InjectionRequest(text: "zzz"))
        #expect(outcome == .injected(method: .keystroke, verified: false))
        #expect(store.records.map(\.method) == ["keystroke"])
        #expect(!mock.journal.contains { $0.hasPrefix("key.combo") })
        #expect(mock.postCount == 1)
    }

    @Test func unreadableElementCountsAsUnverifiedSuccess() {
        let (injector, _, store) = makeStack { $0.axReadable = false; $0.axWriteWorks = false }
        let outcome = injector.inject(InjectionRequest(text: "hey"))
        #expect(outcome == .injected(method: .keystroke, verified: false))
        #expect(store.records.first?.detail == "unverified: readback unavailable")
        // Nothing to read back is not evidence against the method, so the router keeps trusting it.
        #expect(store.records.first?.succeeded == true)
    }

    @Test func withoutAccessibilityTrustOnlyPasteRuns() {
        let (injector, mock, _) = makeStack { $0.isAccessibilityTrusted = false }
        let outcome = injector.inject(InjectionRequest(text: "p"))
        #expect(outcome == .injected(method: .paste, verified: false))
        #expect(mock.field.value == "p")
        #expect(!mock.journal.contains { $0.hasPrefix("key.unicode") || $0.hasPrefix("ax.") })
    }

    @Test func noFrontmostAppFailsWithoutSideEffects() {
        let (injector, mock, _) = makeStack { $0.frontmost = nil }
        #expect(injector.inject(InjectionRequest(text: "x")) == .failed(attempts: []))
        #expect(mock.journal.isEmpty)
        #expect(injector.inject(InjectionRequest(text: "x")).delivery == .failed(reason: DeliveryReason.noDestination))
    }

    @Test func unicodeAndEmojiRoundTripThroughAX() {
        let (injector, mock, _) = makeStack(value: "日本")
        _ = injector.inject(InjectionRequest(text: "語 🎉 café"))
        #expect(mock.field.value == "日本語 🎉 café")
    }

    @Test func latencyIsRecorded() {
        let (injector, _, store) = makeStack()
        var t = Date(timeIntervalSince1970: 1000)
        injector.clock = { defer { t.addTimeInterval(0.025) }; return t }
        _ = injector.inject(InjectionRequest(text: "x", utteranceID: "u1"))
        #expect(store.records.first?.latencyMs == 25)
        #expect(store.records.first?.utteranceID == "u1")
    }
}
