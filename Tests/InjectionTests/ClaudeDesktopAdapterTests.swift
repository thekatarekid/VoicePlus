import Foundation
import Testing
import Shared
@testable import Injection

/// J2 (V4.40) — the Claude desktop app is Electron (its bundle ships `Electron Framework`), so its
/// composer must be routed to `ElectronAdapter`: keystrokes, then paste, never an `AXValue` write.
@Suite struct ClaudeDesktopAdapterTests {
    /// Verified on the build machine with `osascript -e 'id of app "Claude"'` (Claude 2.110.0).
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    @Test func theClaudeBundleIDIsInTheElectronSet() {
        #expect(ElectronAdapter.claudeDesktopBundleID == Self.claudeBundleID)
        #expect(ElectronAdapter.bundleIDs.contains(Self.claudeBundleID))
        #expect(ElectronAdapter().matches(bundleID: Self.claudeBundleID))
    }

    @Test func theStandardRegistryRoutesClaudeToElectronNotDefault() {
        let adapter = AdapterRegistry.standard().adapter(for: Self.claudeBundleID)
        #expect(adapter.id == "electron")
        #expect(adapter.methodOrder == [.keystroke, .paste])
        #expect(!adapter.methodOrder.contains(.ax))
    }

    /// The match is exact: nothing else Anthropic ships (or a lookalike id) is swept in by accident.
    @Test func onlyTheExactIDMatches() {
        let electron = ElectronAdapter()
        for id in ["com.anthropic.claudefordesktop.helper", "com.anthropic.claude", "com.anthropic", "claudefordesktop"] {
            #expect(!electron.matches(bundleID: id), "\(id)")
        }
    }

    /// End to end through the injector: an AX-writable, readable field in Claude still receives the
    /// text by keystrokes — the AX write that desyncs ProseMirror is never attempted.
    @Test func dictationIntoClaudeLandsByKeystrokesAndNeverWritesAX() {
        let (injector, mock, _) = makeStack(Self.claudeBundleID, value: "Hi ") {
            $0.axReadable = true; $0.axWriteWorks = true; $0.keystrokesWork = true
        }
        let outcome = injector.inject(InjectionRequest(text: "there", expectedFocus: mock.frontmost))
        guard case let .injected(method, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .keystroke)
        #expect(mock.field.value == "Hi there")
        #expect(!mock.journal.contains { $0.hasPrefix("ax.") })
    }

    // MARK: V4.41 — the false "Couldn't confirm insertion"

    /// The real Claude composer: ProseMirror owns the text, so `AXValue` is absent (or stale) while
    /// the caret is live. The default `Readback.byValue` could then never confirm a write that had
    /// landed, and the pill drew D06 "⚠ Couldn't confirm insertion · Check destination" on every
    /// successful dictation. The caret is what this app can answer.
    @Test func aLandedKeystrokeIntoClaudeIsVerifiedByTheCaretWhenAXValueIsUnreadable() {
        let (injector, mock, store) = makeStack(Self.claudeBundleID) {
            $0.axReadable = false          // ProseMirror exposes no AXValue for the composer
            $0.axCaretReadable = true      // the caret and AXSelectedText are live
            $0.keystrokesWork = true
        }
        let outcome = injector.inject(InjectionRequest(text: "there", expectedFocus: mock.frontmost))
        guard case let .injected(method, verified) = outcome else { Issue.record("\(outcome)"); return }
        // N3 + N9 verify — the injector now resolves Claude's composer as a chat composer (web
        // content): with no readable value the ladder pastes (one event, no Return), as it already
        // did live where the bundle sniff says Electron. The caret still confirms the write.
        #expect(method == .paste)
        #expect(verified, "the caret moved by exactly the text: delivered *and* verified")
        #expect(outcome.delivery == .delivered(verified: true, method: "paste"))
        #expect(store.outcomes(appBundleID: Self.claudeBundleID, limit: 5).first?.detail == "verified")
    }

    /// A stale `AXValue` (the value reads back unchanged) with a caret that moved is the same case.
    @Test func aStaleAXValueWithAnAdvancedCaretStillConfirms() {
        let before = FocusedElementInfo(role: "AXTextArea", value: "Hi ", selectedRange: 3 ..< 3, isValueSettable: false, isSelectedTextSettable: false)
        let after = FocusedElementInfo(role: "AXTextArea", value: "Hi ", selectedRange: 8 ..< 8, isValueSettable: false, isSelectedTextSettable: false)
        #expect(Readback.byValue(text: "there", before: before, after: after) == .unconfirmed)
        #expect(ElectronAdapter().verifyReadback(text: "there", before: before, after: after) == .confirmed)
        #expect(CursorAdapter().verifyReadback(text: "there", before: before, after: after) == .confirmed)
        #expect(FigmaAdapter().verifyReadback(text: "there", before: before, after: after) == .confirmed)
    }

    /// The honesty half: a readback that ran on both sides and showed no movement at all is still
    /// unconfirmed. The fix must not turn "possibly landed" into a claim of success.
    @Test func aReadbackThatShowsNothingIsStillUnconfirmed() {
        let before = FocusedElementInfo(role: "AXTextArea", value: "Hi ", selectedRange: 3 ..< 3, isValueSettable: false, isSelectedTextSettable: false)
        let after = FocusedElementInfo(role: "AXTextArea", value: "Hi ", selectedRange: 3 ..< 3, isValueSettable: false, isSelectedTextSettable: false)
        #expect(ElectronAdapter().verifyReadback(text: "there", before: before, after: after) == .unconfirmed)
        // Nothing readable on either side: verification is skipped, never reported as a failure.
        let blind = FocusedElementInfo(role: "AXTextArea", value: nil, selectedRange: nil, isValueSettable: false, isSelectedTextSettable: false)
        #expect(ElectronAdapter().verifyReadback(text: "there", before: blind, after: blind) == .unavailable)
    }

    // MARK: rq (2026-10-04) — "Is the dictation working properly?" landed as "r?"

    /// Claude desktop: the focused element was a non-text `AXGroup` (value "", caret 0). The
    /// 20-unit keystroke chunks kept one character each and focus moved into the composer, which
    /// then read "r?" with the caret at 2. "Any forward move" called that confirmed.
    @Test func aFocusMoveDuringTheWriteIsNotConfirmed() {
        let text = "Is the dictation working properly?"
        let before = FocusedElementInfo(role: "AXGroup", value: "", selectedRange: 0 ..< 0,
                                        isValueSettable: false, isSelectedTextSettable: false)
        let after = FocusedElementInfo(role: "AXTextArea", value: "r?", selectedRange: 2 ..< 2,
                                       isValueSettable: true, isSelectedTextSettable: true)
        #expect(ElectronAdapter().verifyReadback(text: text, before: before, after: after) == .unconfirmed)
        #expect(Readback.byCaretOrSelection(text: text, before: before, after: after) == .unconfirmed)
        // Another element by identity (same role) is not proof either, even with the exact caret.
        var a = FocusedElementInfo(role: "AXTextArea", value: "", selectedRange: 0 ..< 0,
                                   isValueSettable: true, isSelectedTextSettable: true, elementID: 1)
        var b = a; b.elementID = 2; b.selectedRange = 34 ..< 34; b.value = text
        #expect(ElectronAdapter().verifyReadback(text: text, before: a, after: b) == .unconfirmed)
        a.elementID = nil
        #expect(ElectronAdapter().verifyReadback(text: text, before: a, after: b) == .confirmed,
                "one side without identity: the role is compared, and it matches")
    }

    /// Same element, but the caret moved 2 for a 34-character write: characters were dropped.
    @Test func aCaretThatMovedFarLessThanTheTextIsNotConfirmed() {
        let text = "Is the dictation working properly?"
        let before = FocusedElementInfo(role: "AXTextArea", value: "\n", selectedRange: 0 ..< 0,
                                        isValueSettable: false, isSelectedTextSettable: false, elementID: 7)
        let after = FocusedElementInfo(role: "AXTextArea", value: "r?\n", selectedRange: 2 ..< 2,
                                       isValueSettable: false, isSelectedTextSettable: false, elementID: 7)
        #expect(ElectronAdapter().verifyReadback(text: text, before: before, after: after) == .unconfirmed)
        #expect(CursorAdapter().verifyReadback(text: text, before: before, after: after) == .unconfirmed)
        // Within tolerance (an app that trims a trailing space, a rich paste that renders shorter).
        var near = after; near.value = nil; near.selectedRange = 33 ..< 33
        #expect(ElectronAdapter().verifyReadback(text: text, before: before, after: near) == .confirmed)
    }

    /// End to end: Claude with a focused AXButton (value "") never receives keystrokes; the text is
    /// held with "no text field", which the app's Notes sink files as "Saved to Notes · no text field".
    @Test("no text field focused in Claude: nothing typed, held as 'no text field'",
          arguments: ["AXButton", "AXGroup"])
    func noTextFieldInClaudeIsNeverTyped(role: String) {
        let (injector, mock, _) = makeStack(Self.claudeBundleID) {
            $0.field = MockSystemAccess.Field(role: role, value: "")
            $0.axWriteWorks = false        // not settable: no value, no selected text to write
            $0.runtimeByPID[$0.frontmost!.pid] = .electron
        }
        let outcome = injector.inject(InjectionRequest(text: "Is the dictation working properly?",
                                                       expectedFocus: mock.frontmost))
        guard case .abortedFocusChanged = outcome else { Issue.record("\(outcome)"); return }
        #expect(mock.postCount == 0, "nothing posted")
        #expect(injector.lastLadderDecision == .notes(.noField))
        #expect(injector.focusGuard.held.last?.reason == "no text field")
    }

    /// The composer itself (AXTextArea) is still typed into, verified.
    @Test func theComposerItselfIsStillTyped() {
        let (injector, mock, _) = makeStack(Self.claudeBundleID, value: "") {
            $0.runtimeByPID[$0.frontmost!.pid] = .electron
        }
        let outcome = injector.inject(InjectionRequest(text: "Is the dictation working properly?",
                                                       expectedFocus: mock.frontmost))
        #expect(outcome == .injected(method: .keystroke, verified: true))
        #expect(mock.field.value == "Is the dictation working properly?")
    }
}
