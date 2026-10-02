import Foundation
import Shared

/// N22 (round-1 P2-1, investigation §4) — the turn-facing pill has five faces, down from the
/// thirteen turn-time variants. Every `PillState` a dictation turn can produce collapses onto one
/// of them; states that are not about a turn (ready, muted, unavailable, blocked, meeting, editing)
/// have no face and keep their own rows.
///
/// | Face      | Absorbs                                                                   |
/// |-----------|---------------------------------------------------------------------------|
/// | listening | starting, idle (warming up), listening, live preview, quiet, latched, warning (a badge) |
/// | inserting | landing, finishing (incl. slow), auto final preview, inserting             |
/// | done      | landed (verified / unreadable / unconfirmed ⚠), partial ⚠, undo            |
/// | needsYou  | held (every reason, incl. "not typed"), Manual / paused preview, error with recovered words |
/// | nothing   | cancelled, empty, error with no words                                      |
public enum PillTurnFace: String, CaseIterable, Equatable, Sendable {
    case listening
    case inserting
    case done
    case needsYou
    case nothing

    /// Whether the face carries choices. Only `needsYou` asks the user anything; `inserting` may
    /// show one Cancel the controller raised (it skips optional work and never drops recognised
    /// text, N2); `listening` keeps its capture controls (latched Finish, mic check).
    public var asksUser: Bool { self == .needsYou }
}

public extension PillState {
    /// N22 — the face this state collapses onto; nil for a state that is not about a turn.
    /// `recoveredWords` decides an `.error`: with words the user can still use it it needs them,
    /// without it there is nothing to act on.
    func turnFace(recoveredWords: Bool = false) -> PillTurnFace? {
        switch self {
        case .idle, .starting, .listening, .preview, .listeningQuiet, .latched, .warning:
            return .listening
        case .landing, .finishing, .inserting:
            return .inserting
        case .finalPreview(let info):
            // No dwell (owner decision 2): an automatic preview is the text on its way in. Manual
            // review, or a preview the user froze, waits for them.
            return info.manual || info.paused ? .needsYou : .inserting
        case .landed, .landedPartial, .undoAvailable:
            return .done
        case .held:
            return .needsYou
        case .cancelled:
            return .nothing
        case .error:
            return recoveredWords ? .needsYou : .nothing
        case .hidden, .ready, .muted, .unavailable, .transform, .correcting, .editing, .meeting:
            return nil
        }
    }
}

public extension PillContent {
    /// N22 — the face `state` is drawn as under `context` (an error's recovered words are the
    /// turn's live text).
    static func face(_ state: PillState, context: PillTurnContext) -> PillTurnFace? {
        state.turnFace(recoveredWords: !context.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
