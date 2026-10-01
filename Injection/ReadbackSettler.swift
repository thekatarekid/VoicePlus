import Foundation
import Shared

// MARK: - Q3 · Settle before judging

/// Q3 — a system that can block briefly until the focused element of `pid` reports a value or
/// selection change (`AXObserver` `kAXValueChangedNotification` / `kAXSelectedTextChangedNotification`).
///
/// Additive: `system as? ReadbackChangeWaiting`. Returns `true` when a change was observed,
/// `false` on timeout, and `nil` when observing is not possible (no observer, untrusted, no
/// focused element) — the settler then falls back to sleeping `settle(milliseconds:)`.
public protocol ReadbackChangeWaiting: AnyObject {
    func waitForFocusedChange(pid: Int32, timeoutMilliseconds: Int) -> Bool?
}

/// Q3 — what a settled readback concluded, and how long it took to get there (for Q13 diagnostics).
public struct SettledReadback: Equatable, Sendable {
    public var verdict: ReadbackVerdict
    /// Wall time from the first "after" read to the verdict, in milliseconds.
    public var settleMilliseconds: Int
    /// How many "after" reads were taken (1 = confirmed immediately).
    public var reads: Int
    /// An `AXObserver` (rather than plain polling) paced the waits.
    public var observed: Bool

    public init(verdict: ReadbackVerdict, settleMilliseconds: Int, reads: Int, observed: Bool) {
        self.verdict = verdict
        self.settleMilliseconds = settleMilliseconds
        self.reads = reads
        self.observed = observed
    }

    /// `injection_outcomes.detail` suffix.
    public var detail: String {
        "\(verdict.detail) (settled \(settleMilliseconds) ms, \(reads) read\(reads == 1 ? "" : "s")\(observed ? ", observed" : ""))"
    }
}

/// Q3 — readback used to be judged by one read taken the instant the method returned. Apps apply
/// synthesised keystrokes asynchronously (Electron, Chromium, anything with its own text model),
/// so a write that was about to land was judged "unconfirmed" and surfaced as the sticky D06 warning.
///
/// The settler re-reads until the adapter's verdict is `.confirmed` or the budget runs out:
/// every `pollIntervalMilliseconds` (default 30 ms) up to `timeoutMilliseconds` (default 400 ms),
/// with each wait cut short by an `AXObserver` change notification when the system can provide one.
///
/// Rules:
/// - The first `.confirmed` ends it — no extra latency for a field that answers at once.
/// - A field with nothing to compare (`before` exposes neither value nor caret) is judged once:
///   waiting cannot make an unreadable field readable, and Q4's neutral row should not be delayed.
/// - Timeout after a readback that *ran* is `.unconfirmed`, never `.unavailable` (an unreadable
///   intermediate read does not erase evidence that the field was readable and unchanged).
public struct ReadbackSettler {
    public var pollIntervalMilliseconds: Int
    public var timeoutMilliseconds: Int

    public init(pollIntervalMilliseconds: Int = 30, timeoutMilliseconds: Int = 400) {
        self.pollIntervalMilliseconds = max(1, pollIntervalMilliseconds)
        self.timeoutMilliseconds = max(0, timeoutMilliseconds)
    }

    public static let standard = ReadbackSettler()

    /// - Parameters:
    ///   - before: the element as read before the method posted.
    ///   - read: one "after" read of the focused element.
    ///   - judge: the adapter's verdict for (before, after).
    ///   - wait: blocks up to the given milliseconds; returns `true` if a change was observed,
    ///     `false` on timeout, `nil` if it could not observe (it must then still have waited).
    ///   - clock: wall clock, for the reported settle duration.
    public func settle(before: FocusedElementInfo?,
                       read: () -> FocusedElementInfo?,
                       judge: (FocusedElementInfo?) -> ReadbackVerdict,
                       wait: (Int) -> Bool?,
                       clock: () -> Date = Date.init) -> SettledReadback {
        let started = clock()
        func elapsed() -> Int { max(0, Int((clock().timeIntervalSince(started) * 1000).rounded())) }

        var reads = 1
        var verdict = judge(read())
        if verdict == .confirmed || !Self.isComparable(before) {
            return SettledReadback(verdict: verdict, settleMilliseconds: elapsed(), reads: reads, observed: false)
        }
        var ran = verdict == .unconfirmed
        var observed = false
        // Budget in nominal wait time, so a mock whose waits return instantly still terminates.
        var budget = timeoutMilliseconds
        while budget > 0 {
            let step = min(pollIntervalMilliseconds, budget)
            if wait(step) != nil { observed = true }
            budget -= step
            reads += 1
            verdict = judge(read())
            if verdict == .confirmed {
                return SettledReadback(verdict: .confirmed, settleMilliseconds: elapsed(), reads: reads, observed: observed)
            }
            if verdict == .unconfirmed { ran = true }
        }
        return SettledReadback(verdict: ran ? .unconfirmed : verdict, settleMilliseconds: elapsed(),
                               reads: reads, observed: observed)
    }

    /// The pre-write element exposes something a later read could be compared with.
    static func isComparable(_ before: FocusedElementInfo?) -> Bool {
        guard let before else { return false }
        return before.value != nil || before.selectedRange != nil
    }

    /// The settler wired to a `SystemAccess`: `AXObserver` waits when the system offers them,
    /// `settle(milliseconds:)` sleeps otherwise.
    public func settle(system: SystemAccess, pid: Int32?, before: FocusedElementInfo?,
                       read: () -> FocusedElementInfo?,
                       judge: (FocusedElementInfo?) -> ReadbackVerdict,
                       clock: () -> Date = Date.init) -> SettledReadback {
        let waiter = system as? ReadbackChangeWaiting
        return settle(before: before, read: read, judge: judge, wait: { ms in
            if let waiter, let pid, let changed = waiter.waitForFocusedChange(pid: pid, timeoutMilliseconds: ms) {
                return changed
            }
            system.settle(milliseconds: ms)
            return nil
        }, clock: clock)
    }
}
