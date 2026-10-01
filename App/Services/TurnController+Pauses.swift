import Foundation

/// V5 Q8 — what the pill really is right now, read from AppKit (not from cached callbacks).
public struct PauseLiveState: Equatable, Sendable {
    /// Pointer hit-test against the pill panel.
    public var pointerInside: Bool
    /// Tab/VoiceOver focus, with the pill window key and a pill control as first responder.
    public var keyboardFocus: Bool
    /// The in-notch editor is open.
    public var editing: Bool
    /// The editor holds marked (IME) text.
    public var composing: Bool

    public init(pointerInside: Bool = false, keyboardFocus: Bool = false, editing: Bool = false, composing: Bool = false) {
        self.pointerInside = pointerInside
        self.keyboardFocus = keyboardFocus
        self.editing = editing
        self.composing = composing
    }

    /// Whether `reason` has a live cause. `.review` / `.selection` are explicit user intents with no
    /// sensed cause: they stay until resumed and are never rebuilt.
    func hasCause(_ reason: DwellPause) -> Bool? {
        switch reason {
        case .hover: return pointerInside
        case .focus: return keyboardFocus
        case .editing: return editing
        case .composition: return composing
        case .review, .selection: return nil
        }
    }
}

/// V5 Q8 — self-healing dwell pauses. Pure, so the 2 s rule is testable with a manual clock.
public struct PauseSet: Equatable, Sendable {
    /// A sensed pause with no live cause for longer than this is dropped (and logged as a fault).
    public static let grace: TimeInterval = 2
    /// Rebuild cadence while paused.
    public static let tick: TimeInterval = 0.1
    /// The reasons rebuilt from live state.
    public static let sensed: [DwellPause] = [.hover, .focus, .editing, .composition]

    public var reasons: Set<DwellPause>
    public var causelessSince: [DwellPause: Date]

    public init(reasons: Set<DwellPause> = [], causelessSince: [DwellPause: Date] = [:]) {
        self.reasons = reasons
        self.causelessSince = causelessSince
    }

    /// Applies every sensed reason that has a live cause, and drops any that has had none for more
    /// than `grace`. Returns the dropped reasons.
    @discardableResult
    public mutating func rebuild(from live: PauseLiveState, now: Date, grace: TimeInterval = PauseSet.grace) -> [DwellPause] {
        var dropped: [DwellPause] = []
        for reason in Self.sensed {
            guard let cause = live.hasCause(reason) else { continue }
            if cause {
                reasons.insert(reason)
                causelessSince[reason] = nil
            } else if reasons.contains(reason) {
                let since = causelessSince[reason] ?? now
                causelessSince[reason] = since
                if now.timeIntervalSince(since) > grace {
                    reasons.remove(reason)
                    causelessSince[reason] = nil
                    dropped.append(reason)
                }
            } else {
                causelessSince[reason] = nil
            }
        }
        return dropped
    }
}
