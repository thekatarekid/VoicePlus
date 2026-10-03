import Foundation
import Shared

/// Bet 5: dictate-vs-transform is decided by one free, deterministic signal — does a selection
/// exist? Phrasing only picks the pipeline *inside* the text key; it never promotes a
/// selection-less utterance into a rewrite of text the user did not select.
public struct TransformRouteDecision: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case noSelection, selectionTransform, selectionQuestion, emptyUtterance
    }
    public var route: Utterance.Route
    public var selection: SelectionSnapshot?
    public var reason: Reason
    public var gatekeeper: GatekeeperDecision
}

public enum TransformRouter {
    public static func decide(gatekeeper: GatekeeperDecision, selection: SelectionSnapshot?) -> TransformRouteDecision {
        if gatekeeper.route == .none {
            return TransformRouteDecision(route: .none, selection: nil, reason: .emptyUtterance, gatekeeper: gatekeeper)
        }
        guard let sel = selection, sel.isMeaningful else {
            // No selection: transform/question phrasing is dictation (typing "make this shorter" is
            // the reversible failure; rewriting unselected text is not).
            let route: Utterance.Route = gatekeeper.route == .repairCommand ? .repairCommand : .dictate
            return TransformRouteDecision(route: route, selection: nil, reason: .noSelection, gatekeeper: gatekeeper)
        }
        switch gatekeeper.route {
        case .question:
            return TransformRouteDecision(route: .question, selection: sel, reason: .selectionQuestion, gatekeeper: gatekeeper)
        default:
            // H6 (Q4) — selection = edit mode: the edit parser owns the utterance before repair
            // routing. "capitalize this", "uppercase", "scratch that" over a selection are edits of
            // the selection, never a repair of the last dictation.
            return TransformRouteDecision(route: .transform, selection: sel, reason: .selectionTransform, gatekeeper: gatekeeper)
        }
    }

    /// Convenience: read the selection now and decide.
    public static func decide(gatekeeper: GatekeeperDecision, detector: any SelectionDetecting) -> TransformRouteDecision {
        decide(gatekeeper: gatekeeper, selection: detector.currentSelection())
    }
}
