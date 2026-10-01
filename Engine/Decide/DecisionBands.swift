import Foundation
import Shared

// V5 O4 · §O-b rubric 5 — the ambient confidence bands.
//
// A Layer 1 score (P(addressed to the computer)) falls in one of four bands:
//   ≥ act (0.85) → act · ask (0.65)…act → ask/confirm · note (0.40)…ask → Note · < note → ignore.
// Thresholds are data, persisted by the app (`DecisionBandsSettings`), and nudged per app by "Not for
// you" corrections: each one raises that app's thresholds a little, so an app where the user talks to
// people a lot (a call app) needs more certainty before anything acts there.

public struct DecisionBands: Codable, Equatable, Sendable {
    public var act: Double
    public var ask: Double
    public var note: Double
    /// Per-app upward offsets (bundle id or app name → added to every threshold).
    public var perAppOffset: [String: Double]

    public static let defaults = DecisionBands(act: 0.85, ask: 0.65, note: 0.40)
    /// How much one "Not for you" raises that app's thresholds, and the most it may add in total.
    public static let nudgeStep = 0.03
    public static let maxOffset = 0.12

    public init(act: Double, ask: Double, note: Double, perAppOffset: [String: Double] = [:]) {
        self.act = act; self.ask = ask; self.note = note; self.perAppOffset = perAppOffset
    }

    /// The thresholds in effect for `app` (offset applied, act capped at 0.99, ordering kept).
    public func thresholds(for app: String?) -> (act: Double, ask: Double, note: Double) {
        let off = app.flatMap { perAppOffset[$0] } ?? 0
        let a = min(0.99, act + off), k = min(a, ask + off), n = min(k, note + off)
        return (a, k, n)
    }

    public func band(for score: Double, app: String? = nil) -> UtteranceBand {
        let t = thresholds(for: app)
        if score >= t.act { return .act }
        if score >= t.ask { return .ask }
        if score >= t.note { return .note }
        return .ignore
    }

    /// "Not for you" in `app`: raise that app's thresholds one step (bounded).
    public mutating func nudgeNotForYou(app: String) {
        perAppOffset[app] = min(Self.maxOffset, (perAppOffset[app] ?? 0) + Self.nudgeStep)
    }

    /// True when the bands are ordered and in 0…1.
    public var isValid: Bool {
        (0...1).contains(note) && (0...1).contains(act) && note <= ask && ask <= act
    }
}
