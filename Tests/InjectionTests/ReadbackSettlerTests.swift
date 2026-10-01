import Foundation
import Testing
import Shared
@testable import Injection

/// Q3 — settle before judging. The app applies the write a few reads late (Electron/Chromium apply
/// synthesised keystrokes asynchronously); the old single immediate read called that "unconfirmed".
@Suite struct ReadbackSettlerTests {
    /// The pre-Q3 behaviour: one immediate read, no settling.
    static let immediate = ReadbackSettler(pollIntervalMilliseconds: 30, timeoutMilliseconds: 0)

    @Test func lateApplyingAppFailsTheImmediateReadButSettles() {
        // Old code: judged on the first "after" read, which still shows the pre-write field.
        let (old, oldMock, _) = makeStack(value: "Hi ") { $0.field.selection = 3..<3; $0.readbackLagReads = 3 }
        old.readbackSettler = Self.immediate
        #expect(old.inject(InjectionRequest(text: "there", expectedFocus: oldMock.frontmost))
                == .injected(method: .ax, verified: false))

        // New code: re-reads until the field shows it.
        let (injector, mock, store) = makeStack(value: "Hi ") { $0.field.selection = 3..<3; $0.readbackLagReads = 3 }
        let report = injector.commit(InjectionRequest(text: "there", expectedFocus: mock.frontmost),
                                     key: TurnCommitKey(turnID: TurnID(), revision: 0)).report
        #expect(report?.outcome == .injected(method: .ax, verified: true))
        #expect(report?.landing == .confirmed)
        #expect(report?.settleMilliseconds != nil)
        #expect(store.records.first?.detail == "verified")
        #expect(mock.postCount == 1, "settling never re-posts")
    }

    @Test("settles for any lag inside the budget", arguments: [1, 2, 5, 10])
    func settlesWithinBudget(lag: Int) {
        let (injector, mock, _) = makeStack("com.brave.Browser") { $0.readbackLagReads = lag }
        #expect(injector.inject(InjectionRequest(text: "hello", expectedFocus: mock.frontmost))
                == .injected(method: .keystroke, verified: true))
    }

    @Test func timeoutReturnsUnconfirmedNeverUnavailable() {
        // Readable field; the keystrokes go nowhere. 400 ms / 30 ms → 14 waits, then give up.
        let (injector, mock, store) = makeStack(value: "abc") { $0.keystrokesWork = false; $0.axWriteWorks = false }
        let report = injector.commit(InjectionRequest(text: "xyz", expectedFocus: mock.frontmost),
                                     key: TurnCommitKey(turnID: TurnID(), revision: 0)).report
        #expect(report?.landing == .unconfirmed)
        #expect(store.records.first?.detail == "unverified: readback unchanged")
    }

    @Test func timeoutAfterAnUnreadableIntermediateReadStaysUnconfirmed() {
        var reads = 0
        let before = info("abc", 3..<3)
        let result = ReadbackSettler().settle(
            before: before,
            read: { reads += 1; return reads % 2 == 0 ? nil : before },
            judge: { Readback.byValue(text: "x", before: before, after: $0) },
            wait: { _ in nil })
        #expect(result.verdict == .unconfirmed)
        #expect(result.reads == 1 + 400 / 30 + 1)   // 13 full steps + one 10 ms remainder
    }

    @Test func unreadableFieldIsJudgedOnceWithoutWaiting() {
        var waits = 0
        let result = ReadbackSettler().settle(
            before: info(nil, nil),
            read: { info(nil, nil) },
            judge: { Readback.byValue(text: "x", before: info(nil, nil), after: $0) },
            wait: { _ in waits += 1; return nil })
        #expect(result.verdict == .unavailable)
        #expect(waits == 0 && result.reads == 1)
    }

    @Test func confirmedOnFirstReadAddsNoWait() {
        var waits = 0
        let before = info("", 0..<0)
        let after = info("x", 1..<1)
        let result = ReadbackSettler().settle(before: before, read: { after },
                                              judge: { Readback.byValue(text: "x", before: before, after: $0) },
                                              wait: { _ in waits += 1; return nil })
        #expect(result.verdict == .confirmed && waits == 0 && result.reads == 1)
    }

    @Test func pollsEvery30msUpTo400ms() {
        var steps: [Int] = []
        let before = info("a", 1..<1)
        _ = ReadbackSettler().settle(before: before, read: { before },
                                     judge: { Readback.byValue(text: "x", before: before, after: $0) },
                                     wait: { steps.append($0); return nil })
        #expect(steps.reduce(0, +) == 400)
        #expect(steps.allSatisfy { $0 <= 30 })
    }

    @Test func observerWaitsAreUsedWhenTheSystemOffersThem() {
        final class Observing: MockSystemAccess, ReadbackChangeWaiting {
            var waits: [Int32] = []
            func waitForFocusedChange(pid: Int32, timeoutMilliseconds: Int) -> Bool? { waits.append(pid); return true }
        }
        let mock = Observing(frontmost: focus("com.brave.Browser"))
        mock.readbackLagReads = 2
        let injector = TextInjector(system: mock)
        let report = injector.commit(InjectionRequest(text: "hi", expectedFocus: mock.frontmost),
                                     key: TurnCommitKey(turnID: TurnID(), revision: 0)).report
        #expect(report?.landing == .confirmed)
        #expect(mock.waits == [mock.frontmost!.pid, mock.frontmost!.pid])
    }
}

private func info(_ value: String?, _ selection: Range<Int>?) -> FocusedElementInfo {
    FocusedElementInfo(role: value == nil ? "AXGroup" : "AXTextArea", value: value, selectedRange: selection,
                       isValueSettable: true, isSelectedTextSettable: true)
}
