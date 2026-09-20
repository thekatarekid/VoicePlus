import Foundation

/// Menu-started dictation is explicitly stopped, even though its engine mode is hold.
/// Keep its normal capture artwork and the hotkey/latch routes; only supply the missing control.
enum MenuCapturePillWiring {
    static func canFinish(_ state: PillState, captureOpen: Bool) -> Bool {
        switch state {
        case .starting, .listening, .listeningQuiet, .latched, .warning: return true
        case .preview: return captureOpen
        default: return false
        }
    }

    static func attach(_ session: SessionCoordinator, pill: PillViewModel) {
        pill.requiresExplicitCaptureFinish = { [weak session] in session?.activeRequester == .menu }
        let previousAction = pill.onAction
        pill.onAction = { [weak session, weak pill] action, shown in
            if action == .finish, let session, let requester = session.activeRequester, requester == .menu,
               canFinish(shown, captureOpen: pill?.turn.captureOpen == true) {
                session.stop(requester, reason: .userStopped)
                return
            }
            previousAction?(action, shown)
        }
    }
}
