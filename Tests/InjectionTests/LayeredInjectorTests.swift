import Foundation
import Testing
import Shared
@testable import Injection

// MARK: - Layered fallback (T1)

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

    @Test func fallsBackToPasteWhenKeystrokesSwallowed() {
        let (injector, mock, store) = makeStack(value: "") { $0.axWriteWorks = false; $0.keystrokesWork = false }
        let outcome = injector.inject(InjectionRequest(text: "hi"))
        #expect(outcome == .injected(method: .paste, verified: true))
        #expect(mock.field.value == "hi")
        #expect(store.records.map { ($0.method, $0.succeeded) }.elementsEqual([("keystroke", false), ("paste", true)], by: ==))
    }

    @Test func readbackDetectsAXWriteThatSilentlyNoops() {
        // AX claims settable but the app ignores the write (Electron-style), readback catches it.
        final class LyingMock: MockSystemAccess {
            override func setFocusedValue(_ value: String) throws {}
            override func setFocusedSelectedText(_ text: String) throws {}
        }
        let mock = LyingMock(frontmost: focus("com.example.Liar"))
        let store = InMemoryOutcomeStore()
        let injector = TextInjector(system: mock, store: store)
        let outcome = injector.inject(InjectionRequest(text: "x"))
        #expect(outcome == .injected(method: .keystroke, verified: true))
        #expect(store.records.first?.method == "ax")
        #expect(store.records.first?.succeeded == false)
        #expect(store.records.first?.detail == "readback unchanged")
    }

    @Test func allMethodsFailingReportsFailure() {
        let (injector, mock, _) = makeStack { $0.axWriteWorks = false; $0.keystrokesWork = false; $0.pasteWorks = false }
        let outcome = injector.inject(InjectionRequest(text: "zzz"))
        #expect(outcome == .failed(attempts: [.keystroke, .paste]))
        #expect(mock.field.value == "")
    }

    @Test func unreadableElementCountsAsUnverifiedSuccess() {
        let (injector, _, store) = makeStack { $0.axReadable = false; $0.axWriteWorks = false }
        let outcome = injector.inject(InjectionRequest(text: "hey"))
        #expect(outcome == .injected(method: .keystroke, verified: false))
        #expect(store.records.first?.detail == "unverified")
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
