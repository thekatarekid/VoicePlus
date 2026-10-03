import Foundation
import Injection
import Pipeline
import Shared

/// H12 (old H9) — what one selection edit did, for the log line and the turn's `extras_json`:
/// the route, the catalogue command, the selection's length, the outcome and the model used.
/// Never any text — not the selection, the instruction, the result or the answer.
public struct EditOutcomeRecord: Codable, Equatable, Sendable {
    /// "transform", "question", "replace", "copy", "undo".
    public var route: String
    /// `EditCommandEntry.id` ("case.upper", "tone.formal", "freeform"), when the edit named one.
    public var commandID: String?
    /// The selection's length in UTF-16 units (what the field counts).
    public var selectionLength: Int
    /// "applied", "noChange", "cancelled", "held", "failed", "needsModel", "refused", "answered",
    /// "answerNotTyped", "replacing", "awaitingText", "copied", "copyFailed", "undone",
    /// "undoFailed", "nothingToUndo".
    public var outcome: String
    /// "model" (pinned provider or on-device model), "rules" (deterministic fallback), "catalog"
    /// (a D command, no model); nil when nothing ran.
    public var model: String?

    public init(route: String, commandID: String?, selectionLength: Int, outcome: String, model: String?) {
        self.route = route; self.commandID = commandID; self.selectionLength = selectionLength
        self.outcome = outcome; self.model = model
    }

    /// The one notice line (no text).
    public var logLine: String {
        "edit: route=\(route) command=\(commandID ?? "-") selection=\(selectionLength) outcome=\(outcome) model=\(model ?? "-")"
    }

    /// The record for a landing outcome; nil when the landing did not handle the utterance.
    /// `instruction` / `selection` are used only to name the command (never stored).
    public static func make(_ outcome: TransformLanding.Outcome, selection: String?, instruction: String,
                            surface: SurfaceKind?) -> EditOutcomeRecord? {
        let length = selection?.utf16.count ?? 0
        func classify() -> String { EditCommandCatalog.classify(instruction, selection: selection ?? "", surface: surface).id }
        func model(_ r: TransformResult) -> String {
            switch r.source {
            case .provider: return "model"
            case .local: return "rules"
            case .catalog: return "catalog"
            }
        }
        switch outcome {
        case .notHandled:
            return nil
        case .transformed(let step):
            switch step {
            case .applied(let r, _):
                return .init(route: "transform", commandID: r.commandID, selectionLength: length, outcome: "applied", model: model(r))
            case .noChange(let r):
                return .init(route: "transform", commandID: r.commandID, selectionLength: length, outcome: "noChange", model: model(r))
            case .failed(let o):
                return .init(route: "transform", commandID: classify(), selectionLength: length, outcome: failure(o), model: nil)
            }
        case .answered(_, let injection):
            return .init(route: "question", commandID: "ask", selectionLength: length,
                         outcome: injection.succeeded ? "answered" : "answerNotTyped", model: "model")
        case .refused:
            return .init(route: "transform", commandID: classify(), selectionLength: length, outcome: "refused", model: nil)
        case .replaceSelection:
            return .init(route: "replace", commandID: "replace.with", selectionLength: length, outcome: "replacing", model: nil)
        case .awaitingReplacement:
            return .init(route: "replace", commandID: "replace.ask", selectionLength: length, outcome: "awaitingText", model: nil)
        case .copied(let verified):
            return .init(route: "copy", commandID: verified ? "copy" : classify(), selectionLength: length,
                         outcome: verified ? "copied" : "copyFailed", model: nil)
        case .undid(let o):
            let result: String
            switch o {
            case nil: result = "nothingToUndo"
            case .replaced?: result = "undone"
            default: result = "undoFailed"
            }
            return .init(route: "undo", commandID: "undo", selectionLength: length, outcome: result, model: nil)
        }
    }

    static func failure(_ o: TransformReplaceOutcome) -> String {
        switch o {
        case .mismatch: return "held"
        case .unavailable(let reason) where reason == "cancelled": return "cancelled"
        case .unavailable(let reason) where reason == TransformLanding.needsModelReason: return "needsModel"
        default: return "failed"
        }
    }
}
