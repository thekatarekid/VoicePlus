import Foundation

/// S5b — how long a pill state must stay on screen before it is allowed to be taken away.
///
/// The bug this exists for: `RealEngine.stop()` emits `.landed` and `.idle` back to back (and
/// `.error(...)` immediately before a `cancel()`/next turn that resets to `.idle`). The pill
/// reducer turns that into `landing` → `hidden` in the same run-loop pass, so the panel slid *in*
/// and straight back *out* — the "broken animation of the notch state appeared and disappeared
/// quickly" the owner saw on key release. Worse, the same race applies to the error notice: the
/// message flashed for a couple of frames and could not be read, let alone screenshotted.
///
/// The rule is deliberately narrow, so it can never leave a stale pill in front of a live turn:
/// **only a retraction is ever delayed.** Any *visible* state replaces whatever is showing at once
/// (a new utterance, a preview, a warning, a transform all take over immediately). `.hidden` waits
/// until the current state has had its legible minimum.
public enum PillDwell {
    /// Long enough to read a sentence and decide whether to screenshot it.
    public static let notice: TimeInterval = 4.0
    /// A tick of acknowledgement — enough for the slide-in to complete and register.
    public static let acknowledgement: TimeInterval = 0.6
    /// R2.4 — long enough to *read* the committed text the field received (V3 §4.1: "for a beat").
    /// An acknowledgement-class minimum raised to the 1.2 s the item specifies; it is a legibility
    /// minimum, so reduced motion does not shorten it (DESIGN §8.4 (1)).
    public static let landedText: TimeInterval = 1.2

    /// Minimum time `state` must remain visible once shown.
    public static func minimum(for state: PillState) -> TimeInterval {
        switch state {
        case .hidden, .idle, .listening, .preview, .transform: return 0
        case .landing: return acknowledgement
        case .landed: return landedText
        // A held row is a notice the user has to act on; it gets the notice minimum, and the same
        // three actions stay reachable in the menu after it retracts.
        case .error, .warning, .unavailable, .held: return notice
        // G0.4 — the V4 states, slotted into the existing classes until S2 owns this table: live and
        // in-flight states have no floor, "Cancelled" is an acknowledgement, "Updated · Undo" reads
        // like a landed row, and a partial insertion is a notice the user has to act on.
        case .ready, .muted, .starting, .listeningQuiet, .latched, .finishing, .finalPreview, .inserting,
             .correcting, .editing, .meeting: return 0
        case .cancelled: return acknowledgement
        case .undoAvailable: return landedText
        case .landedPartial: return notice
        }
    }

    /// Is this a state the user is meant to *read* (as opposed to watch)? Used only for logging and
    /// tests; the dwell table above is the behaviour.
    public static func isNotice(_ state: PillState) -> Bool { minimum(for: state) >= notice }
}

/// Pure gate between "what the reducer says" and "what the panel draws". Owns no timers: the caller
/// asks, gets a decision, and schedules `flush` when told to hold.
public struct PillPresenter: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Draw this state now.
        case show(PillState)
        /// Keep drawing the current state until this instant, then call `flush`.
        case hold(until: Date)
        /// Nothing to do.
        case unchanged
    }

    public private(set) var displayed: PillState = .hidden
    /// When `displayed` went up. `nil` before the first `request`.
    public private(set) var shownAt: Date?
    /// The retraction that is waiting for `displayed` to finish its dwell.
    public private(set) var pending: PillState?

    public init() {}

    /// The instant `displayed` may be replaced by a retraction.
    public func releaseTime() -> Date? {
        guard let shownAt else { return nil }
        return shownAt.addingTimeInterval(PillDwell.minimum(for: displayed))
    }

    /// True while the current state is inside its guaranteed-legible window.
    public func isDwelling(now: Date) -> Bool {
        guard let release = releaseTime() else { return false }
        return now < release
    }

    public mutating func request(_ next: PillState, now: Date) -> Decision {
        // A visible state is always news — it never waits behind an older one.
        if next.isVisible { return commit(next, now: now) }
        if displayed == .hidden { pending = nil; return .unchanged }
        if let release = releaseTime(), now < release {
            pending = next
            return .hold(until: release)
        }
        return commit(next, now: now)
    }

    /// R2.4 — take the current row down *now*, ignoring its dwell. The dwell exists so a notice
    /// cannot flash past before it is read; it is not there to hold a row in front of the user who
    /// has just acted on it (clicked Insert here / Copy / Discard).
    public mutating func dismiss(now: Date) -> Decision {
        pending = nil
        return commit(.hidden, now: now)
    }

    /// Apply a held retraction once its deadline has passed. Safe to call early or spuriously.
    public mutating func flush(now: Date) -> Decision {
        guard let pending else { return .unchanged }
        if let release = releaseTime(), now < release { return .hold(until: release) }
        return commit(pending, now: now)
    }

    private mutating func commit(_ state: PillState, now: Date) -> Decision {
        pending = nil
        guard state != displayed else { return .unchanged }
        displayed = state
        shownAt = now
        return .show(state)
    }
}
