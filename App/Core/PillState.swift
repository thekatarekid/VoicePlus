import Foundation
import Shared

/// The five pill states from the Build doc (T2) plus `hidden` for "retracted".
public enum PillState: Equatable, Sendable {
    case hidden
    case idle
    case listening(level: Float)
    case preview(text: String)
    case landing
    /// R2.4 — the delivery actually happened: the pill drops the preview and shows the *committed*
    /// text for a beat (V3 §4.1, §14.1). `verified: false` draws the "Landed · not confirmed"
    /// variant instead of claiming a success readback could not confirm (V3 §6).
    case landed(LandedPillInfo)
    /// R2.4 — committed text with no safe destination: the destination is named and the row offers
    /// Insert here / Copy / Discard. The only other state in which the pill accepts clicks.
    case held(HeldPillInfo)
    case warning(MicQuality)
    /// Nothing on this machine can recognise speech. Its own case so the honest "no recognizer"
    /// notice can never be confused with — or substituted for — transcript text in `.preview`.
    case unavailable(reason: String)
    /// S5b — something went wrong in this turn. Its own case rather than `.preview("⚠︎ …")`: a
    /// notice the user must read is not transcript text, it must be *sized* like a notice, and
    /// `PillDwell` has to be able to tell the two apart to keep it on screen long enough to read.
    case error(message: String)
    /// P2.3 — "talk to your text": tinted pill, "editing N words", then the 5 s ghost / 8 s warm window.
    case transform(TransformPillInfo)

    public var isVisible: Bool { self != .hidden }

    public var caseName: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case .listening: return "listening"
        case .preview: return "preview"
        case .landing: return "landing"
        case .landed(let info): return info.verified ? "landed" : "landedUnverified"
        case .held: return "held"
        case .warning: return "warning"
        case .unavailable: return "unavailable"
        case .error: return "error"
        case .transform: return "transform"
        }
    }

    /// The fixed sentences this state draws, longest-first is not required — `NotchGeometry` sizes
    /// the pill to the widest of them so a notice is never clipped into a dangling ellipsis.
    /// `.preview` is deliberately absent: live transcript text is head-truncated on purpose (you
    /// want the newest words), and sizing the pill to it would make it twitch on every syllable.
    public var messageLines: [String] {
        switch self {
        case .hidden, .listening, .preview, .transform: return []
        case .idle: return ["Warming up…"]
        case .landing: return ["Landing…"]
        // The committed text is deliberately absent for the same reason `.preview` is: it is
        // variable-length and head-truncated at two lines, so sizing the panel to it buys nothing.
        // The fixed strings a landed/held row can draw *are* listed, so neither can be clipped.
        case .landed(let info): return info.verified ? [] : [DeliveryCopy.landedUnverified]
        case .held(let info): return [info.headline, info.subtitle, HeldPillInfo.actionsLine]
        case .unavailable(let reason): return [reason, PillState.unavailableSubtitle]
        case .error(let message): return [message, PillState.errorSubtitle]
        case .warning(let quality): return [PillState.warningHeadline(quality), PillState.warningSubtitle]
        }
    }

    public static let unavailableSubtitle = "Dictation is off until a speech model is installed"
    public static let errorSubtitle = "Nothing was typed — press the key again to try that turn"
    public static let warningSubtitle = "Check your input device before you speak"

    /// Single source of truth for the mic-quality headline: `PillView` renders it and
    /// `NotchGeometry` measures it, so the pill can never be narrower than its own sentence.
    public static func warningHeadline(_ q: MicQuality) -> String {
        if q.lowLevel { return "Mic level is very low" }
        if q.clipping > 0.05 { return "Mic is clipping" }
        return "Noisy mic — \(Int(q.snr)) dB SNR"
    }
}

/// What the transform-tinted pill shows (P2.3). Additive; the engine reducer never produces it.
public struct TransformPillInfo: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        /// Model is rewriting; "editing N words".
        case editing
        /// Rewrite landed; ghost row offers "↩ / try again" for `TransformGhost.lifetime`.
        case done(changed: Int)
        /// Selection still warm for a chained turn; `remaining` seconds.
        case warm(remaining: Int)
        /// No change / failed; short notice then warm.
        case notice(String)
    }
    public var editingWords: Int
    public var stage: Stage
    public init(editingWords: Int, stage: Stage) { self.editingWords = editingWords; self.stage = stage }

    public var headline: String {
        switch stage {
        case .editing: return "editing \(editingWords) word\(editingWords == 1 ? "" : "s")"
        case .done(let n): return n == 0 ? "no change" : "changed \(n) word\(n == 1 ? "" : "s")"
        case .warm(let r): return "say more… (\(r)s)"
        case .notice(let s): return s
        }
    }
    public var showsGhost: Bool { if case .done(let n) = stage { return n > 0 }; return false }
}

/// Pure reducer: engine state → pill state. Warning is sticky for the utterance so the bad-mic
/// notice renders *before* speech starts and is not blown away by the first `listening` tick.
public struct PillStateReducer: Equatable, Sendable {
    public private(set) var state: PillState = .hidden
    public private(set) var stickyWarning: MicQuality?

    public init() {}

    @discardableResult
    public mutating func reduce(_ engine: EngineState) -> PillState {
        switch engine {
        case .idle:
            state = .hidden
            stickyWarning = nil
        case .prewarming:
            state = .idle
        case .warning(let quality):
            stickyWarning = quality
            state = .warning(quality)
        case .listening(let level):
            if let q = stickyWarning { state = .warning(q) } else { state = .listening(level: level) }
        case .previewing(let text):
            stickyWarning = nil
            state = .preview(text: text)
        case .finalizing, .landed:
            stickyWarning = nil
            state = .landing
        case .error(let message):
            stickyWarning = nil
            state = .error(message: message)
        case .unavailable(let reason):
            stickyWarning = nil
            state = .unavailable(reason: reason)
        }
        return state
    }

    /// Dismisses a warning while capture continues (user keeps talking anyway).
    public mutating func clearWarning(level: Float) {
        stickyWarning = nil
        if case .warning = state { state = .listening(level: level) }
    }

    public mutating func hide() {
        state = .hidden
        stickyWarning = nil
    }
}

/// Rolling audio-level history for the waveform view. Pure; driven by a level publisher.
public struct WaveformModel: Equatable, Sendable {
    public let barCount: Int
    public private(set) var bars: [Float]
    public var smoothing: Float

    public init(barCount: Int = 24, smoothing: Float = 0.35) {
        self.barCount = max(1, barCount)
        self.bars = Array(repeating: 0, count: max(1, barCount))
        self.smoothing = smoothing
    }

    /// Push the newest level (0…1); the oldest bar falls off the left.
    public mutating func push(level: Float) {
        let clamped = min(1, max(0, level))
        let previous = bars.last ?? 0
        let smoothed = previous + (clamped - previous) * (1 - smoothing)
        bars.removeFirst()
        bars.append(smoothed)
    }

    public mutating func reset() { bars = Array(repeating: 0, count: barCount) }

    public var peak: Float { bars.max() ?? 0 }
}
