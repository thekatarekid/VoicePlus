import Foundation

/// Mic quality measured in the first ~300ms of capture (P1.2 T3). Drives the pill's warning state.
public struct MicQuality: Codable, Equatable, Hashable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        case good, poor, bad
    }

    /// Estimated signal-to-noise ratio in dB.
    public var snr: Float
    /// Fraction of samples at full scale, 0…1.
    public var clipping: Float
    /// True when input level is too low to be useful.
    public var lowLevel: Bool
    public var verdict: Verdict

    public init(snr: Float, clipping: Float, lowLevel: Bool, verdict: Verdict) {
        self.snr = snr
        self.clipping = clipping
        self.lowLevel = lowLevel
        self.verdict = verdict
    }

    public static let unknownGood = MicQuality(snr: 30, clipping: 0, lowLevel: false, verdict: .good)
}

/// State machine the pill renders. Mirrors PRODUCT-SPEC pill states.
public enum EngineState: Codable, Equatable, Sendable {
    case idle
    case prewarming
    case listening(level: Float)
    case previewing(text: String)
    case finalizing
    case landed
    case warning(MicQuality)
    case error(String)
    /// No recognizer exists on this machine (no ASR model on disk and no OS speech fallback).
    /// The engine is honestly dead: it never emits partials, previews, or spans. The associated
    /// value is a short user-facing reason ("No speech model installed").
    case unavailable(String)

    // MARK: V4 turn lifecycle (G0.4, design_v1 §5–§6). Additive: every case above keeps its meaning.

    /// C0 — the key is down and capture is being opened. "Listening" is not claimed until the
    /// microphone is actually open, so this precedes `listening` in every turn.
    case starting
    /// F0 — the microphone is closed and the final pass is running. Nothing has been written yet.
    case finishing
    /// C4 — the turn was cancelled before any write began (Escape, a too-short tap). Nothing was
    /// inserted; terminal for the turn.
    case cancelled

    public var isActive: Bool {
        switch self {
        case .idle, .landed, .error, .unavailable, .cancelled: return false
        default: return true
        }
    }

    /// Stable name without associated values, for logging and tests.
    public var caseName: String {
        switch self {
        case .idle: return "idle"
        case .prewarming: return "prewarming"
        case .listening: return "listening"
        case .previewing: return "previewing"
        case .finalizing: return "finalizing"
        case .landed: return "landed"
        case .warning: return "warning"
        case .error: return "error"
        case .unavailable: return "unavailable"
        case .starting: return "starting"
        case .finishing: return "finishing"
        case .cancelled: return "cancelled"
        }
    }
}
