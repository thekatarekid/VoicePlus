import Foundation

/// V5 C1 — how long the capture's automatic gain control took to settle after `start()`.
///
/// Apple's voice-processing I/O runs an AGC that ramps the gain over the first few hundred ms, so
/// level readings there describe the AGC, not the room (hence `CaptureGraphPlan.levelWarmup`). This
/// measures the ramp so the warm-up is a number, not a guess: fed one RMS per block (stream order),
/// it reports the start of the first `window`-long run of audible blocks whose level stays within
/// `toleranceDB`. Digital silence is skipped (no level to settle). Deterministic; worker-only.
public struct AGCAdaptationTracker: Sendable {
    public var window: TimeInterval = 0.2
    public var toleranceDB: Float = 3
    /// Give up after this much audio: "not settled" is itself worth logging.
    public var horizon: TimeInterval = 3

    public enum Outcome: Equatable, Sendable {
        case settled(after: TimeInterval)
        case notSettled(within: TimeInterval)
    }

    public private(set) var outcome: Outcome?
    private var elapsed: TimeInterval = 0
    private var run: [(start: TimeInterval, db: Float, duration: TimeInterval)] = []

    public init(window: TimeInterval = 0.2, toleranceDB: Float = 3, horizon: TimeInterval = 3) {
        self.window = window; self.toleranceDB = toleranceDB; self.horizon = horizon
    }

    public mutating func reset() { outcome = nil; elapsed = 0; run.removeAll() }

    /// Returns the outcome once, at the block that decides it.
    @discardableResult
    public mutating func feed(rms: Float, duration: TimeInterval) -> Outcome? {
        guard outcome == nil, duration > 0 else { return nil }
        let start = elapsed
        elapsed += duration
        if rms > 1e-5 {
            let db = 20 * log10(rms)
            run.append((start, db, duration))
            // Keep the longest suffix whose spread is within tolerance.
            while let lo = run.map(\.db).min(), let hi = run.map(\.db).max(), hi - lo > toleranceDB { run.removeFirst() }
            let span = run.reduce(0) { $0 + $1.duration }
            if span >= window - 1e-9, let first = run.first {
                outcome = .settled(after: first.start)
                return outcome
            }
        }
        if elapsed >= horizon {
            outcome = .notSettled(within: horizon)
            return outcome
        }
        return nil
    }

    public var logLine: String? {
        switch outcome {
        case .settled(let t)?: return "audio: AGC settled after \(Int((t * 1000).rounded())) ms"
        case .notSettled(let h)?: return "audio: AGC did not settle within \(Int(h * 1000)) ms"
        case nil: return nil
        }
    }
}
