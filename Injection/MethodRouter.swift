import Foundation
import Shared

/// T3: orders an adapter's allowed methods using local success history for that bundle ID.
/// Rules: a method with ≥ `minimumSamples` recent outcomes and success rate ≥ `promoteAt` is moved to the
/// front (best rate first); a method with ≥ `minimumSamples` and rate ≤ `demoteAt` is moved to the back.
/// Methods are never removed — a demoted method is still the last line of defence.
public final class MethodRouter {
    public struct Stats: Equatable, Sendable {
        public var samples: Int
        public var successes: Int
        public var rate: Double { samples == 0 ? 0 : Double(successes) / Double(samples) }
    }

    public let store: InjectionOutcomeStore
    public var minimumSamples = 3
    public var promoteAt = 0.8
    public var demoteAt = 0.3
    public var historyLimit = 50

    public init(store: InjectionOutcomeStore) { self.store = store }

    public func stats(for bundleID: String) -> [InjectionMethod: Stats] {
        var result: [InjectionMethod: Stats] = [:]
        for record in store.outcomes(appBundleID: bundleID, limit: historyLimit) {
            guard let method = InjectionMethod(rawValue: record.method) else { continue }
            // N16 — "posted, readback unchanged" is no evidence either way (Chromium's stale
            // AXValue made Brave learn paste-first): neutral, not a failure.
            if Self.isNeutral(record) { continue }
            var s = result[method] ?? Stats(samples: 0, successes: 0)
            s.samples += 1
            if record.succeeded { s.successes += 1 }
            result[method] = s
        }
        return result
    }

    /// N16 — an outcome whose readback ran and showed nothing (`ReadbackVerdict.unconfirmed`).
    public static func isNeutral(_ record: InjectionOutcomeRecord) -> Bool {
        !record.succeeded && (record.detail?.contains(ReadbackVerdict.unconfirmed.detail) ?? false)
    }

    /// N16 — `keepKeystrokeBeforePaste`: in a newline-safe plan keystrokes carry the ⇧↩ / ⌥↩
    /// line breaks and paste does not, so history may reorder anything else but never lift paste
    /// above keystrokes. History stays a tie-break only.
    public func order(_ allowed: [InjectionMethod], for bundleID: String, keepKeystrokeBeforePaste: Bool) -> [InjectionMethod] {
        var result = order(allowed, for: bundleID)
        guard keepKeystrokeBeforePaste, let p = result.firstIndex(of: .paste),
              let k = result.firstIndex(of: .keystroke), p < k else { return result }
        result.remove(at: k)
        result.insert(.keystroke, at: p)
        return result
    }

    public func order(_ allowed: [InjectionMethod], for bundleID: String) -> [InjectionMethod] {
        let stats = stats(for: bundleID)
        var promoted: [(InjectionMethod, Double)] = []
        var neutral: [InjectionMethod] = []
        var demoted: [InjectionMethod] = []
        for method in allowed {
            guard let s = stats[method], s.samples >= minimumSamples else { neutral.append(method); continue }
            if s.rate >= promoteAt { promoted.append((method, s.rate)) }
            else if s.rate <= demoteAt { demoted.append(method) }
            else { neutral.append(method) }
        }
        // Stable: ties keep the adapter's preference.
        let promotedSorted = promoted.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map(\.element.0)
        return promotedSorted + neutral + demoted
    }
}
