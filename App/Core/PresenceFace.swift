import Foundation
import Shared

/// N22 (round-1 P2-1, investigation §4) — the notch shows five visible faces: Ready, Listening,
/// Working (until the write finishes or the text is held, N20), Needs you, and Blocked. `off` is
/// the hidden state. `PresenceState` keeps its finer reasons (a muted badge, a block reason) for the
/// glyph and the row; the face is what the chin *means*.
public enum PresenceFace: String, CaseIterable, Equatable, Sendable {
    case off
    case ready
    case listening
    case working
    case needsYou
    case blocked

    /// The face of `state`, given how many held texts are waiting (Insert here / Copy). Held text
    /// only takes over a resting chin: an open microphone, work in progress or a blocker says more.
    public static func of(_ state: PresenceState, heldWaiting: Int = 0) -> PresenceFace {
        switch state {
        case .off: return .off
        case .ready, .paused: return heldWaiting > 0 ? .needsYou : .ready
        case .listening: return .listening
        case .processing: return .working
        // A muted microphone cannot take a dictation: it reads as blocked (with its MUTED badge).
        case .muted, .blocked: return .blocked
        }
    }

    // MARK: Needs you — the chin's own copy (the other faces draw `PresenceState`'s)

    public static let needsYouSymbol = "tray.full.fill"
    public static let needsYouBadge = "Needs you"
    public static func needsYouDetail(_ count: Int) -> String {
        count <= 1 ? "VoicePlus · 1 text held · Insert or Copy from the menu"
                   : "VoicePlus · \(count) texts held · Insert or Copy from the menu"
    }
}

public extension Notification.Name {
    /// N22 — the number of held texts waiting changed (`userInfo["count"]: Int`). Posted on the main
    /// queue by the turn controller; the notch shows Needs you while the count is above zero.
    static let voicePlusHeldWaitingChanged = Notification.Name("VoicePlus.heldWaitingChanged")
}
