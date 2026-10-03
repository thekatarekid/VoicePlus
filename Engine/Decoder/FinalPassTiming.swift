import Foundation

/// N6 — one final pass, stage by stage, plus the text from before boosting. L3 persists these into
/// `turn_records` (per-stage ms, pre-boost raw text) so every slow or wrong turn can be read back.
public struct FinalPassTiming: Sendable, Equatable, Codable {
    /// TDT recognition (preprocessor + encoder + decoder).
    public var recogniseMs: Double
    /// V5 B3 N-best replay (0 when skipped).
    public var alternativesMs: Double
    /// Getting the resident booster model. A final pass never loads one, so this stays ~0.
    public var modelWaitMs: Double
    /// CTC spotting + rescoring (capped by the deadline).
    public var rescoreMs: Double
    /// The whole final pass.
    public var totalMs: Double
    public var boostStatus: BoostReport.Status
    /// The recogniser's text before vocabulary boosting.
    public var rawPreBoostText: String
    /// The text the final pass returned.
    public var finalText: String
    /// H20 — how many terms the installed booster carried (0: no booster / empty list).
    public var boostTermCount: Int

    public init(recogniseMs: Double, alternativesMs: Double = 0, modelWaitMs: Double = 0, rescoreMs: Double = 0,
                totalMs: Double, boostStatus: BoostReport.Status, rawPreBoostText: String, finalText: String,
                boostTermCount: Int = 0) {
        self.recogniseMs = recogniseMs
        self.alternativesMs = alternativesMs
        self.modelWaitMs = modelWaitMs
        self.rescoreMs = rescoreMs
        self.totalMs = totalMs
        self.boostStatus = boostStatus
        self.rawPreBoostText = rawPreBoostText
        self.finalText = finalText
        self.boostTermCount = boostTermCount
    }

    /// Whether boosting changed the text.
    public var wasBoosted: Bool { rawPreBoostText != finalText }

    /// Log line without any transcript text (text stays in the local database only).
    public var logLine: String {
        String(format: "recognise %.0f ms, alternatives %.0f ms, model wait %.0f ms, rescore %.0f ms, total %.0f ms, boost %@ (%d terms)",
               recogniseMs, alternativesMs, modelWaitMs, rescoreMs, totalMs, boostStatus.rawValue, boostTermCount)
    }

    static func ms(since t: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000
    }
}

/// A recogniser/decoder that can say how its last final pass went (N6).
public protocol FinalPassTimingReporting: AnyObject {
    var lastFinalPassTiming: FinalPassTiming? { get }
}

/// Runs `operation` against a deadline. Returns nil when the deadline wins; the operation is left
/// to finish on its own (an actor-held rescoring cannot be interrupted), so the caller never waits
/// past `seconds`.
enum BoostDeadlineRace {
    static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        return await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let once = BoostOnce<T>(c)
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if !Task.isCancelled { once.resume(nil) }
            }
            Task {
                let v = await operation()
                once.resume(v)
                timer.cancel()
            }
        }
    }
}

/// Resumes a continuation exactly once (deadline vs. result).
final class BoostOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ c: CheckedContinuation<T?, Never>) { continuation = c }
    func resume(_ v: T?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: v)
    }
}
