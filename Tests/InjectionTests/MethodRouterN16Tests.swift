import Foundation
import Testing
import Shared
@testable import Injection

/// N16 — Brave learned "paste first" for every tab because Chromium's stale AXValue made each
/// keystroke write read back "unchanged". Unconfirmed is neutral, and in newline-safe plans paste
/// is never promoted above keystrokes.
@Suite struct MethodRouterN16Tests {
    static let unchanged = ReadbackVerdict.unconfirmed.detail

    func store(_ rows: [(InjectionMethod, Bool, String?)], app: String = "com.brave.Browser") -> InMemoryOutcomeStore {
        let s = InMemoryOutcomeStore()
        for (m, ok, detail) in rows {
            s.record(InjectionOutcomeRecord(utteranceID: nil, appBundleID: app, method: m.rawValue,
                                            succeeded: ok, latencyMs: 1, detail: detail))
        }
        return s
    }

    @Test func unconfirmedIsNeutralNotAFailure() {
        let router = MethodRouter(store: store(Array(repeating: (.keystroke, false, Self.unchanged), count: 6)))
        #expect(router.stats(for: "com.brave.Browser")[.keystroke] == nil)
        #expect(router.order([.keystroke, .paste], for: "com.brave.Browser") == [.keystroke, .paste])
        // "posted, then threw … — unverified: readback unchanged" is neutral too.
        let threw = MethodRouter(store: store(Array(repeating: (.keystroke, false, "posted, then threw: x — \(Self.unchanged)"), count: 4)))
        #expect(threw.order([.keystroke, .paste], for: "com.brave.Browser") == [.keystroke, .paste])
    }

    @Test func realFailuresStillCount() {
        let router = MethodRouter(store: store(Array(repeating: (.ax, false, "threw before posting: x"), count: 3)))
        #expect(router.order([.ax, .keystroke], for: "com.brave.Browser") == [.keystroke, .ax])
    }

    @Test func pasteNeverJumpsKeystrokesInNewlineSafePlan() {
        let rows: [(InjectionMethod, Bool, String?)] = Array(repeating: (.paste, true, "verified"), count: 5)
            + Array(repeating: (.keystroke, false, "threw before posting: x"), count: 5)
        let router = MethodRouter(store: store(rows))
        #expect(router.order([.keystroke, .paste], for: "com.brave.Browser") == [.paste, .keystroke])
        #expect(router.order([.keystroke, .paste], for: "com.brave.Browser", keepKeystrokeBeforePaste: true) == [.keystroke, .paste])
    }

    @Test func injectorKeepsKeystrokesFirstInBraveDespitePasteHistory() {
        let (injector, mock, store) = makeStack("com.brave.Browser")
        for _ in 0..<5 {
            store.record(InjectionOutcomeRecord(utteranceID: nil, appBundleID: "com.brave.Browser", method: "paste",
                                                succeeded: true, latencyMs: 1, detail: "verified"))
        }
        let outcome = injector.inject(InjectionRequest(text: "hi\nthere", expectedFocus: mock.frontmost))
        guard case let .injected(method, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(method == .keystroke)
        #expect(NewlineSafetyTests.bareReturns(mock.journal).isEmpty)
    }
}
