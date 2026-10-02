import Foundation
import Shared

/// V5 K19 — "pill up ~27 s after landing". A timed outcome row (verified / unreadable landing,
/// Cancelled, Undo) is retracted by a one-shot timer armed only on some paths
/// (`PillViewModel.present(delivery:)` → `scheduleRetractionIfTimed`). A row that reached the
/// pill any other way, or whose timer was replaced before it fired, had nothing left to take it
/// down: it stayed until the next turn replaced it. This backstop gives every timed outcome row a
/// hard deadline — its own release time plus `slack` — so it can never outlive its dwell, and it
/// records why in the Q13 diagnostics store.
public enum PillRetention {
    /// How long past its release a timed outcome row may linger before the backstop takes it down.
    public static let slack: TimeInterval = 1.5

    /// Whether the backstop owns `state`. Only outcome rows whose dwell is timed: in-progress rows
    /// (`.landing`, `.finishing`, …) and rows that stay until the user acts are never touched.
    public static func applies(to state: PillState) -> Bool {
        switch state {
        // N22 — every Done row is timed now, the ⚠ ones included.
        case .landed, .landedPartial, .cancelled, .undoAvailable: return true
        default: return false
        }
    }

    /// The latest instant `state`, shown at `shownAt`, may still be up. `release` is the
    /// presenter's own release time (it includes a finite flight hold); nil → shown + dwell.
    public static func deadline(for state: PillState, shownAt: Date, release: Date?) -> Date? {
        guard applies(to: state), case .minimum(let dwell) = PillDwell.rule(for: state) else { return nil }
        let base = max(shownAt.addingTimeInterval(dwell), release ?? shownAt)
        guard base != .distantFuture else { return nil }
        return base.addingTimeInterval(slack)
    }
}

/// V5 K19 — instrumentation into the Q13 store (`TurnDiagnostics`): panel order-in / order-out
/// with reasons, and the backstop's forced retractions. No dictated text: reason codes only.
public enum PillDiagnostics {
    /// The store (set by the composition root when a database exists).
    nonisolated(unsafe) public static var store: TurnDiagnostics?
    /// The live turn's id, when one is live (TurnController.currentTurn).
    nonisolated(unsafe) public static var turnID: () -> String? = { nil }
    /// Test seam: every event recorded here as well.
    nonisolated(unsafe) public static var observer: ((TurnDiagnosticsEvent) -> Void)?

    public static func record(_ event: TurnDiagnosticsEvent) {
        observer?(event)
        store?.record(event, turn: turnID() ?? "none")
    }
}
