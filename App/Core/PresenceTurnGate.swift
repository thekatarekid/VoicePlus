import Foundation
import Shared

/// N20 — the notch says Working until the turn's write finishes or its text is held.
///
/// The engine reports `.landed` (and then `.idle`) the moment recognition ends, long before the
/// text is formatted, previewed and typed. Fed straight to the chin, that read as "done" while
/// nothing had been typed. This gate sits on the chin's engine feed: from the moment capture closes
/// (`.finishing` / `.finalizing`) until the turn controller ends the turn, a resting engine state is
/// reported as `.finalizing` (Working…). The turn's end (`turnEnded()`) opens the gate again, and
/// the chin's own turn-end handling brings it back to rest.
public final class PresenceTurnGate: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = false
    private var attached = false

    /// A turn controller is attached (set by the coordinator). Without one (the direct landing path,
    /// headless tools) every state passes through untouched.
    public var turnsAttached: Bool {
        get { lock.withLock { attached } }
        set { lock.withLock { attached = newValue; if !newValue { inFlight = false } } }
    }

    public init() {}

    /// Whether a turn is between key-up and its final outcome.
    public var isTurnInFlight: Bool { lock.withLock { inFlight } }

    /// The state the chin should hear for `engine`.
    public func map(_ engine: EngineState) -> EngineState {
        lock.withLock {
            guard attached else { return engine }
            switch engine {
            case .finishing, .finalizing:
                inFlight = true
                return engine
            case .landed, .idle:
                return inFlight ? .finalizing : engine
            case .starting, .listening, .previewing, .prewarming:
                // A new capture (or a latched session's next segment) speaks for itself.
                return engine
            case .cancelled, .error, .unavailable, .warning:
                if case .cancelled = engine { inFlight = false }
                return engine
            }
        }
    }

    /// The turn controller ended a turn (landed, held, failed, cancelled, empty…).
    public func turnEnded() { lock.withLock { inFlight = false } }
}
