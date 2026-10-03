import CoreGraphics
import Foundation

/// Fix notch (RC3/RC4) — the pill (`PillPanelController`) and the presence chin
/// (`PresenceIndicatorController`) are two windows at one anchor. These are the pure rules that make
/// them read as one notch: the pill grows out of the chin and shrinks back into it, a hide and a show
/// inside one animation never close-then-reopen, and the chin does not widen for a key press the pill
/// is about to answer (taps, double-taps, the hold's 300 ms presentation delay).
public enum NotchHandoff {
    /// The pill's layout with its retracted frame (the frame it opens from and closes into) set to the
    /// chin's frame, when there is a chin on the same display hanging from the same top edge. Without
    /// one, the centred line (`NotchGeometry.pillLayout`) is kept.
    public static func layout(_ layout: NotchGeometry.Layout, chin: CGRect?) -> NotchGeometry.Layout {
        guard let chin, chin.width > 1, chin.height > 1,
              abs(chin.maxY - layout.shown.maxY) < 0.5,           // same top edge (same display, same band)
              abs(chin.midX - layout.shown.midX) < 0.5,           // centred on the same notch
              chin.width <= layout.shown.width, chin.height <= layout.shown.height else { return layout }
        var result = layout
        result.retracted = chin
        return result
    }

    /// A show that arrives while the pill is still rolling up (ordered in, retraction in flight) grows
    /// it back from where it is instead of snapping it to the line and ordering it in again.
    public static func resumesRetraction(retracting: Bool, panelOrderedIn: Bool) -> Bool {
        retracting && panelOrderedIn
    }
}

/// Fix notch (RC4) — the chin goes from rest to a live face (listening / processing) only once that
/// face has lasted `delay`. A dictation key press opens the microphone at key-down, but the pill is
/// what answers it: after 300 ms for a hold, at once for a double-tap, and not at all for a tap that
/// is cancelled. Widening the chin at key-down made every tap and every double-tap read as "opens
/// slightly, closes, opens fully". A live face the pill does not take over (a meeting, ambient, a
/// pill that failed to show) still appears, `delay` later. Leaving a live face, and every other
/// change (muted, paused, blocked, off, ready), is immediate; a live face that follows the pill
/// (`shown == .off`) is immediate too, so the notch is never empty after the pill hands back.
public struct PresenceRevealGate: Equatable, Sendable {
    public static let defaultDelay: TimeInterval = 0.75
    public var delay: TimeInterval
    /// When the pending live face was first asked for.
    public private(set) var pendingSince: Date?

    public init(delay: TimeInterval = PresenceRevealGate.defaultDelay) { self.delay = delay }

    public struct Verdict: Equatable, Sendable {
        /// The face to draw now.
        public var state: PresenceState
        /// Ask again after this long (the pending face's reveal is due); nil = nothing pending.
        public var recheckAfter: TimeInterval?
    }

    public mutating func admit(_ next: PresenceState, shown: PresenceState, now: Date) -> Verdict {
        guard Self.isLive(next), shown == .ready else {
            pendingSince = nil
            return Verdict(state: next, recheckAfter: nil)
        }
        let since = pendingSince ?? now
        pendingSince = since
        let waited = now.timeIntervalSince(since)
        if waited >= delay {
            pendingSince = nil
            return Verdict(state: next, recheckAfter: nil)
        }
        return Verdict(state: shown, recheckAfter: delay - waited)
    }

    static func isLive(_ state: PresenceState) -> Bool {
        switch state {
        case .listening, .processing: return true
        default: return false
        }
    }
}
