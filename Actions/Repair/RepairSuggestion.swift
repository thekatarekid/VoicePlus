import Foundation
import Shared

/// R2.5 — what the pill should offer when a repair could not be applied.
///
/// `Actions` never touches the pill: it produces this value and hands it to a
/// `RepairSuggestionPresenter`. The App layer (R2.4) renders `pillLine` / `detail` / `actionTitle`.
public struct RepairSuggestion: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        /// The region no longer reads what we wrote. The document was not touched.
        case regionChanged(actual: String?)
        /// AX could not read the destination. The document was not touched.
        case regionUnreadable(String)
        /// Nothing has been committed yet in this session.
        case noCommittedRegion
        /// A non-repair utterance came in between, so the repair context is gone.
        case contextExpired
        /// "put it back" with no repair on record.
        case nothingToPutBack
        /// "scratch that" with nothing left to scratch.
        case nothingToScratch
        /// The writer refused at write time (destination moved between read and write).
        case editRefused(String)

        /// True when the reason is "the text is not where we left it".
        public var isRegionMismatch: Bool {
            switch self {
            case .regionChanged, .regionUnreadable, .editRefused: return true
            case .noCommittedRegion, .contextExpired, .nothingToPutBack, .nothingToScratch: return false
            }
        }
    }

    public var id: UUID
    public var command: RepairVoiceCommand
    public var segment: SegmentID?
    public var reason: Reason
    /// The committed text the command was bound to, when there was one.
    public var was: String?
    /// What the user asked for: the replacement, or "" for a scratch.
    public var proposed: String?
    public var destination: RepairDestination?
    public var at: Date

    public init(id: UUID = UUID(), command: RepairVoiceCommand, segment: SegmentID?, reason: Reason,
                was: String? = nil, proposed: String? = nil, destination: RepairDestination? = nil, at: Date = Date()) {
        self.id = id
        self.command = command
        self.segment = segment
        self.reason = reason
        self.was = was
        self.proposed = proposed
        self.destination = destination
        self.at = at
    }

    /// Headline. Says what happened, in the app's voice: honest, and never claims an edit.
    public var pillLine: String {
        switch reason {
        case .regionChanged, .editRefused:
            switch command {
            case .scratchThat: return "Text changed — nothing scratched"
            case .replaceWith: return "Text changed — nothing replaced"
            case .putItBack: return "Text changed — nothing put back"
            }
        case .regionUnreadable:
            return "Can't read \(destination?.displayName ?? "the field") — nothing changed"
        case .noCommittedRegion:
            return "Nothing dictated yet"
        case .contextExpired:
            return "Too late to repair that"
        case .nothingToPutBack:
            return "Nothing to put back"
        case .nothingToScratch:
            return "Nothing to scratch"
        }
    }

    /// Second line: names the action the user can take (V3 §6 error copy rule).
    public var detail: String {
        switch reason {
        case .regionChanged(let actual):
            let now = (actual?.isEmpty == false) ? " It now reads “\(Self.trim(actual!))”." : ""
            return "\(suggestedFix)\(now)"
        case .editRefused, .regionUnreadable:
            return suggestedFix
        case .noCommittedRegion, .contextExpired:
            return "Say it again and it will land fresh."
        case .nothingToPutBack:
            return "No repair on record for this segment."
        case .nothingToScratch:
            return "The last thing dictated is already gone."
        }
    }

    /// What to offer instead of the edit.
    private var suggestedFix: String {
        switch command {
        case .scratchThat:
            return "Select the text and delete it yourself."
        case .replaceWith(let replacement):
            return "Suggested: “\(Self.trim(replacement))” — copy it or say it again."
        case .putItBack:
            return was.map { "Was: “\(Self.trim($0))” — copy it or say it again." } ?? "Copy the earlier text or say it again."
        }
    }

    /// Button title for the pill's one action, when the App layer offers one.
    public var actionTitle: String? {
        switch (reason, command) {
        case (.noCommittedRegion, _), (.contextExpired, _), (.nothingToPutBack, _), (.nothingToScratch, _): return nil
        case (_, .scratchThat): return nil
        case (_, .replaceWith): return "Copy replacement"
        case (_, .putItBack): return was == nil ? nil : "Copy original text"
        }
    }

    /// Text the pill's action puts on the clipboard, if any. Copy is the only escape hatch:
    /// repair never re-edits text it cannot verify.
    public var copyPayload: String? {
        switch command {
        case .scratchThat: return nil
        case .replaceWith(let replacement): return replacement
        case .putItBack: return was
        }
    }

    private static func trim(_ text: String, limit: Int = 48) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

/// R2.4 integration point: the App layer conforms and renders the suggestion in the pill. Nothing in `Actions` knows the pill exists.
public protocol RepairSuggestionPresenter: AnyObject, Sendable {
    func present(_ suggestion: RepairSuggestion)
}
