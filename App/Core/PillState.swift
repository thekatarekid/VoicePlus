import Foundation
import Shared

/// The five pill states from the Build doc (T2) plus `hidden` for "retracted".
public enum PillState: Equatable, Sendable {
    case hidden
    case idle
    case listening(level: Float)
    case preview(text: String)
    case landing
    case warning(MicQuality)

    public var isVisible: Bool { self != .hidden }

    public var caseName: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case .listening: return "listening"
        case .preview: return "preview"
        case .landing: return "landing"
        case .warning: return "warning"
        }
    }
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
            state = .preview(text: "⚠︎ \(message)")
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
