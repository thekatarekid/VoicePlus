import Foundation

/// S1 — the prototype's 26 visible states (design §6), in the prototype's order (`poses` in the Spool
/// module; `spool_spec.json` › `statePoses`). The raw values are the prototype's keys.
enum SpoolStateKey: String, CaseIterable, Sendable {
    case idle, ready, starting, listening, quiet, latched, finishing, preview, uncertain, correcting
    case inserting, inserted, held, unconfirmed, partial, warning, cancelled, muted, unavailable, blocked
    case editing, undo, meeting, paused, notes, error
}

/// The seven expressions the rig can draw (design §3.1, build doc S1.3).
enum SpoolPose: String, CaseIterable, Sendable {
    case ready, listen, finish, preview, review, insert, error
}

/// What `art()` adds on top of a pose (build doc S1.2).
enum SpoolOverlay: String, CaseIterable, Sendable {
    /// `warning`: two concerned brow strokes.
    case concernedBrows
    /// `muted` / `blocked` / `unavailable`: shutter plate, closed-eye lines and the padlock latch.
    case shutterLatch
    /// `paused`: two pause bars.
    case pauseBars
    /// `quiet`: tape amplitude forced to 0.
    case flatTape
    /// `cancelled`: the pill tape retracts under a clip over 0.32 s.
    case retractTape
    /// `editing` / `notes`: an 18 × 6 progress marker moving 40 pt/s along the tape lane.
    case progressMarker
}

enum SpoolPoseTable {
    /// `poses[key]`.
    static func pose(for key: SpoolStateKey) -> SpoolPose {
        switch key {
        case .idle, .ready, .starting, .quiet, .cancelled, .muted, .unavailable, .blocked, .paused, .notes:
            return .ready
        case .listening, .latched, .warning, .meeting:
            return .listen
        case .finishing, .editing:
            return .finish
        case .preview, .inserted, .undo:
            return .preview
        case .uncertain, .correcting:
            return .review
        case .inserting:
            return .insert
        case .held, .unconfirmed, .partial, .error:
            return .error
        }
    }

    /// `live`: states whose reels and tape follow open capture.
    static let liveStates: Set<SpoolStateKey> = [.listening, .latched, .warning, .meeting]

    static func isLive(_ key: SpoolStateKey) -> Bool { liveStates.contains(key) }

    static func overlays(for key: SpoolStateKey) -> [SpoolOverlay] {
        switch key {
        case .warning: return [.concernedBrows]
        case .muted, .blocked, .unavailable: return [.shutterLatch]
        case .paused: return [.pauseBars]
        case .quiet: return [.flatTape]
        case .cancelled: return [.retractTape]
        case .editing, .notes: return [.progressMarker]
        default: return []
        }
    }

    // MARK: Still frames (cameos, Reduce Motion)

    /// `scene(…, still: true)`: t = 1.4 except finishing 0.55, inserting 0.4, cancelled 0.8.
    static let defaultStillTime = 1.4
    static let stillTimes: [SpoolStateKey: Double] = [.finishing: 0.55, .inserting: 0.4, .cancelled: 0.8]

    static func stillTime(for key: SpoolStateKey) -> Double { stillTimes[key] ?? defaultStillTime }

    /// `cameo()` draws every state at t = 1.4 (the prototype passes 1.4 regardless of the still table).
    static let cameoTime = 1.4

    // MARK: Time remap (`art()`)

    /// finishing `min(t·1.5/0.55, 1.5)`, inserting `min(t, 1.2)`, editing fixed 1.5, otherwise `t`.
    static func remappedTime(_ key: SpoolStateKey, _ t: Double) -> Double {
        switch key {
        case .finishing: return SpoolMath.min(t * 1.5 / 0.55, 1.5)
        case .inserting: return SpoolMath.min(t, 1.2)
        case .editing: return 1.5
        default: return t
        }
    }

    // MARK: Frame loop (`animate()`)

    /// Seconds after a state change during which the loop keeps running for every state.
    static let settleWindow = 0.8
    /// Inserting animates until 1.1 s (the feed is finite).
    static let insertingWindow = 1.1

    /// The frame loop runs while live, editing or notes, inserting before 1.1 s, or within 0.8 s of a
    /// state change; never when hidden or under Reduce Motion (build doc S1.5).
    static func animates(_ key: SpoolStateKey, t: Double, hidden: Bool = false, reduceMotion: Bool = false) -> Bool {
        if hidden || reduceMotion { return false }
        if isLive(key) || key == .editing || key == .notes { return true }
        if key == .inserting && t < insertingWindow { return true }
        return t < settleWindow
    }

    /// When the loop for a state entered at `start` stops by itself: `nil` if it never runs,
    /// `.distantFuture` if it runs until the state changes.
    static func loopEnd(_ key: SpoolStateKey, start: Date, hidden: Bool = false, reduceMotion: Bool = false) -> Date? {
        if hidden || reduceMotion { return nil }
        if isLive(key) || key == .editing || key == .notes { return .distantFuture }
        let window = key == .inserting ? Swift.max(insertingWindow, settleWindow) : settleWindow
        return start.addingTimeInterval(window)
    }
}
