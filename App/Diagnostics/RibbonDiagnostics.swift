import Foundation
import Shared

// N19 (F18) — the ribbon's one geometry-only Q13 event per insertion: which rung aimed it (or why it was
// suppressed / invalidated), whether its aim point was on a display, how long locating took, and which
// better rungs were skipped because their geometry was off every display. No dictated text, no
// coordinates. Rides the existing `.decision` event (owner "ribbon") so the Q13 schema is unchanged:
// `band` = rung, `reason` = outcome, `questionProbabilities` = numeric facts.

/// One ribbon outcome, as the flight controller saw it.
struct RibbonReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The ribbon flew (or finished at once because locating ran past its flight time).
        case flew
        /// Suppressed before it flew.
        case suppressed(TapeFlightSuppression)
        /// Taken down after it flew.
        case invalidated(TapeFlightSuppression)
    }

    var outcome: Outcome
    var rung: TapeFlightRung?
    /// `nil` when no rect was measured.
    var onDisplay: Bool?
    var locateMs: Int?
    var skippedOffDisplay: [TapeFlightRung] = []
    /// Fix notch — whether the overlay window was on the active Space when the ribbon flew; nil when
    /// the surface cannot tell (tests) or nothing was drawn (the flight was already over).
    var surfaceVisible: Bool? = nil
}

enum RibbonDiagnostics {
    static let owner = "ribbon"

    static func event(_ report: RibbonReport) -> TurnDiagnosticsEvent {
        let reason: String
        switch report.outcome {
        // Fix notch — "flewHidden": the ribbon ran but its window was on no Space, so nobody saw it.
        case .flew: reason = report.surfaceVisible == false ? "flewHidden" : "flew"
        case .suppressed(let why): reason = "suppressed: \(why.rawValue)"
        case .invalidated(let why): reason = "invalidated: \(why.rawValue)"
        }
        let skipped = report.skippedOffDisplay.map { "\($0)" }.joined(separator: ",")
        var facts: [String: Double] = ["offDisplaySkipped": Double(report.skippedOffDisplay.count)]
        if let ms = report.locateMs { facts["locateMs"] = Double(max(0, ms)) }
        if let on = report.onDisplay { facts["onDisplay"] = on ? 1 : 0 }
        if let visible = report.surfaceVisible { facts["surfaceVisible"] = visible ? 1 : 0 }
        let seen = report.outcome == .flew && report.surfaceVisible != false
        return .decision(.init(owner: owner, confidence: seen ? 1 : 0,
                               band: report.rung.map { "\($0)" },
                               reason: skipped.isEmpty ? reason : "\(reason); skipped off-display: \(skipped)",
                               questionProbabilities: facts))
    }

    /// Live sink: the current turn's Q13 rows (nothing outside a turn). Notice-level log as well.
    static func record(_ report: RibbonReport) {
        let event = event(report)
        if case let .decision(d) = event {
            Log.app.notice("ribbon \(d.reason) rung=\(d.band ?? "none") locateMs=\(report.locateMs ?? -1)")
        }
        guard let turn = PillDiagnostics.turnID() else { return }
        TurnEventDiagnostics.record(event, turn: turn)
    }
}
