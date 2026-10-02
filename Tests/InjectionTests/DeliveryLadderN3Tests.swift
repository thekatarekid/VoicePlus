import Foundation
import Testing
import Shared
@testable import Injection

/// N3 — the delivery ladder: write without a readable field when the key-up app and window are
/// still focused and secure input is off; refuse only when certain; never Return.
@Suite struct DeliveryLadderN3Tests {
    typealias L = DeliveryLadder

    struct Row: CustomStringConvertible, Sendable {
        var name: String
        var focusSame = true
        var window = L.WindowState.same
        var secureInput = false
        var readable = true
        var surface: SurfaceKind? = nil
        var multiline = false
        var web = false
        var password = false
        var editable: Bool? = nil
        var expected: L.Decision
        var description: String { name }
    }

    static let table: [Row] = [
        Row(name: "native readable → ax, verified", expected: .deliver(method: .ax, verify: true)),
        Row(name: "web readable → keystrokes (⇧↩), verified", web: true, expected: .deliver(method: .keystrokes, verify: true)),
        Row(name: "chat composer readable → keystrokes", surface: .chatComposer, expected: .deliver(method: .keystrokes, verify: true)),
        Row(name: "unreadable single-line native → keystrokes, unverified", readable: false, expected: .deliver(method: .keystrokes, verify: false)),
        Row(name: "unreadable multi-line → paste, unverified", readable: false, multiline: true, expected: .deliver(method: .paste, verify: false)),
        Row(name: "unreadable web (ChatGPT) → paste, unverified", readable: false, web: true, expected: .deliver(method: .paste, verify: false)),
        Row(name: "terminal → paste (bracketed)", surface: .terminal, expected: .deliver(method: .paste, verify: true)),
        Row(name: "unreadable terminal → paste, unverified", readable: false, surface: .terminal, expected: .deliver(method: .paste, verify: false)),
        Row(name: "unknown window evidence → deliver", window: .unknown, readable: false, expected: .deliver(method: .keystrokes, verify: false)),
        Row(name: "secure input on, readable field → deliver", secureInput: true, expected: .deliver(method: .ax, verify: true)),
        Row(name: "secure input on, unreadable → hold", secureInput: true, readable: false, expected: .hold(.secureInputBlind)),
        Row(name: "password field → hold", password: true, expected: .hold(.passwordField)),
        Row(name: "secure surface → hold", surface: .secure, expected: .hold(.passwordField)),
        Row(name: "focus moved → hold (pull back is the caller's)", focusSame: false, expected: .hold(.focusMoved)),
        Row(name: "focus moved beats unreadable", focusSame: false, readable: false, expected: .hold(.focusMoved)),
        Row(name: "window changed → hold", window: .changed, expected: .hold(.windowChanged)),
        Row(name: "window gone → hold", window: .gone, expected: .hold(.windowGone)),
        Row(name: "no window ever → Notes", window: .none, readable: false, expected: .notes(.noWindow)),
        Row(name: "canvas, nothing editable → hold", surface: .canvas, editable: false, expected: .hold(.notEditable)),
        Row(name: "canvas, unknown editable → hold", readable: false, surface: .canvas, expected: .hold(.notEditable)),
        Row(name: "canvas with a text edit active → deliver", surface: .canvas, editable: true, expected: .deliver(method: .ax, verify: true)),
        Row(name: "unfamiliar role is never refused", readable: false, surface: .prose, editable: nil, expected: .deliver(method: .keystrokes, verify: false)),
    ]

    @Test(arguments: table)
    func routingTable(_ row: Row) {
        let got = L.decide(focusSame: row.focusSame, window: row.window, secureInput: row.secureInput,
                           fieldReadable: row.readable, surface: row.surface, multiline: row.multiline,
                           webContent: row.web, passwordField: row.password, editable: row.editable)
        #expect(got == row.expected, "\(row.name)")
    }

    @Test func windowStateFromTokens() {
        #expect(L.windowState(expected: nil, current: "w1", expectedStillExists: true) == .unknown)
        #expect(L.windowState(expected: "w1", current: "w1", expectedStillExists: true) == .same)
        #expect(L.windowState(expected: "w1", current: "w2", expectedStillExists: true) == .changed)
        #expect(L.windowState(expected: "w1", current: nil, expectedStillExists: false) == .gone)
    }

    @Test func orderPutsLadderMethodFirstOnlyWhenUnreadable() {
        let web = WebContentAdapter()
        #expect(L.order([.keystroke, .paste], ladder: .paste, fieldReadable: false, adapter: web) == [.paste, .keystroke])
        #expect(L.order([.keystroke, .paste], ladder: .paste, fieldReadable: true, adapter: web) == [.keystroke, .paste])
        #expect(L.order([.adapter, .paste], ladder: .paste, fieldReadable: false, adapter: TerminalAdapter()) == [.adapter, .paste])
        #expect(L.order([.ax, .keystroke, .paste], ladder: .keystrokes, fieldReadable: false, adapter: DefaultAdapter())
                == [.keystroke, .ax, .paste])
    }

    // MARK: Through the injector

    /// The ChatGPT case: an unlisted Chromium app whose tree exposes nothing. Before N3 the text
    /// went to Notes; now it is written (paste), marked unverified, and never as a bare Return.
    @Test func fakeUnreadableChromiumAppGetsAWrite() {
        let (injector, mock, _) = makeStack("com.example.unlisted-chromium") {
            $0.runtimeByPID[100] = .chromium
            $0.axReadable = false
            $0.focusedWindow = "w1"
        }
        let outcome = injector.inject(InjectionRequest(text: "Hello there.\nSecond line", expectedFocus: mock.frontmost,
                                                       expectedWindowToken: "w1"))
        guard case let .injected(method, verified) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .paste)
        #expect(!verified)
        #expect(injector.lastLadderDecision == .deliver(method: .paste, verify: false))
        #expect(!mock.journal.contains("ax.setValue"))
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty, "\(mock.journal)")
        #expect(injector.focusGuard.held.isEmpty)
    }

    @Test func unreadableNoElementChromiumStillGetsAWrite() {
        // No focused element at all (tree off): still the same app and window → write.
        let (injector, mock, _) = makeStack("com.example.unlisted-chromium") {
            $0.runtimeByPID[100] = .chromium
            $0.hasFocusedElement = false
        }
        let outcome = injector.inject(InjectionRequest(text: "hi", expectedFocus: mock.frontmost))
        #expect(outcome.succeeded, "\(outcome)")
        #expect(mock.postCount > 0)
    }

    @Test func unreadableNativeSingleLineTypesKeystrokes() {
        let (injector, mock, _) = makeStack("com.example.native") { $0.axReadable = false }
        let outcome = injector.inject(InjectionRequest(text: "hello", expectedFocus: mock.frontmost))
        guard case let .injected(method, verified) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .keystroke)
        #expect(!verified)
    }

    @Test func secureInputBlindWriteIsRefused() {
        let (injector, mock, _) = makeStack("com.example.unlisted-chromium") {
            $0.axReadable = false
            $0.secureEventInput = true
        }
        let outcome = injector.inject(InjectionRequest(text: "hi", expectedFocus: mock.frontmost))
        #expect(outcome == .refused(.secureField))
        #expect(mock.postCount == 0)
    }

    @Test func windowChangedHoldsAndWritesNothing() {
        let (injector, mock, _) = makeStack("com.example.app") {
            $0.focusedWindow = "w2"
            $0.openWindows = ["w1"]
        }
        let outcome = injector.inject(InjectionRequest(text: "hi", expectedFocus: mock.frontmost, expectedWindowToken: "w1"))
        guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(injector.lastLadderDecision == .hold(.windowChanged))
        #expect(mock.postCount == 0)
        #expect(injector.focusGuard.held.count == 1)
    }

    @Test func windowGoneHolds() {
        let (injector, mock, _) = makeStack("com.example.app") { $0.focusedWindow = nil }
        let outcome = injector.inject(InjectionRequest(text: "hi", expectedFocus: mock.frontmost, expectedWindowToken: "w1"))
        guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(injector.lastLadderDecision == .hold(.windowGone))
        #expect(mock.postCount == 0)
    }

    @Test func canvasSurfaceHoldsWithClickIntoTextBox() {
        let (injector, mock, _) = makeStack("com.example.design") { $0.axReadable = false }
        let outcome = injector.inject(InjectionRequest(text: "hi", expectedFocus: mock.frontmost, surfaceKind: .canvas))
        guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(mock.postCount == 0)
        #expect(injector.focusGuard.held.first?.reason == DeliveryLadder.Reason.notEditable.rawValue)
    }

    @Test func focusMovedStillHoldsBeforeLadder() {
        let (injector, mock, _) = makeStack("com.example.app")
        let expected = FocusSnapshot(pid: 999, bundleID: "com.other", appName: "Other")
        let outcome = injector.inject(InjectionRequest(text: "hi", expectedFocus: expected))
        guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(mock.postCount == 0)
    }
}
