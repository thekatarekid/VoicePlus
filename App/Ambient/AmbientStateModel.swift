import Foundation

/// The three-and-only-three honest ambient states (PRODUCT-SPEC Part 5: "no hidden hot mic, ever").
public enum AmbientState: String, Codable, CaseIterable, Sendable {
    case listening, muted, processing

    /// SF Symbol for the menu bar status item.
    public var menuBarSymbol: String {
        switch self {
        case .listening: return "waveform.circle"
        case .muted: return "mic.slash.circle.fill"
        case .processing: return "waveform.circle.fill"
        }
    }
    /// SF Symbol for the notch glyph (filled variants read better on the black notch).
    public var notchSymbol: String {
        switch self {
        case .listening: return "waveform"
        case .muted: return "mic.slash.fill"
        case .processing: return "ellipsis.circle.fill"
        }
    }
    public var label: String {
        switch self {
        case .listening: return "Listening"
        case .muted: return "Muted"
        case .processing: return "Processing"
        }
    }
    public var accessibilityDescription: String { "VoicePlus is \(label.lowercased())" }
}

/// Pure state model for the ambient glyph. Mute is a hard latch: it wins over everything and is
/// only ever released by an explicit `unmute()` gesture — never by a timer, a dictation ending,
/// relaunch, or a new session.
public struct AmbientStateModel: Equatable, Codable, Sendable {
    public private(set) var muted: Bool
    public private(set) var processing: Bool
    /// Directed-speech acknowledgment: the glyph "warms" for a beat. Purely visual.
    public private(set) var warmUntil: Date?
    public static let warmDuration: TimeInterval = 0.6

    public init(muted: Bool = false, processing: Bool = false) {
        self.muted = muted; self.processing = processing
    }

    public var state: AmbientState {
        if muted { return .muted }
        return processing ? .processing : .listening
    }

    /// Badge text shown persistently while muted (menu bar + notch); nil otherwise.
    public var badge: String? { muted ? "MUTED" : nil }
    public var menuBarSymbol: String { state.menuBarSymbol }
    public var notchSymbol: String { state.notchSymbol }
    public func isWarm(at now: Date = Date()) -> Bool { !muted && (warmUntil.map { $0 > now } ?? false) }

    // MARK: gestures (all one action each)

    /// One gesture toggles mute. Returns the new state.
    @discardableResult
    public mutating func toggleMute() -> AmbientState { muted ? unmute() : mute() }

    @discardableResult
    public mutating func mute() -> AmbientState { muted = true; warmUntil = nil; return state }

    /// The only way out of muted. Must be invoked from a user gesture.
    @discardableResult
    public mutating func unmute() -> AmbientState { muted = false; return state }

    // MARK: engine signals (never affect the mute latch)

    public mutating func setProcessing(_ on: Bool) { processing = on }

    /// Called when the directed-speech classifier decides the user meant it.
    public mutating func acknowledgeDirected(at now: Date = Date()) {
        guard !muted else { return }
        warmUntil = now.addingTimeInterval(Self.warmDuration)
    }

    /// Audio should only be fed to the ambient classifier/engine when this is true.
    public var micOpen: Bool { !muted }
}
