import Foundation

/// What the hold-to-talk pill renders. Derived from `KeyboardSession.State`; no UIKit.
public struct KeyboardPillModel: Equatable, Sendable {
    public enum Tint: Equatable, Sendable { case neutral, listening, proxying, landed, error }
    public var label: String
    public var tint: Tint
    public var level: Float
    public var showsFanout: Bool

    public init(state: KeyboardSession.State, level: Float = 0) {
        self.level = min(1, max(0, level))
        switch state {
        case .idle: label = "Hold to talk"; tint = .neutral; showsFanout = false
        case .listening(let p): label = p.isEmpty ? "Listening…" : p; tint = .listening; showsFanout = false
        case .proxying: label = "Polishing…"; tint = .proxying; showsFanout = false
        case .landed(_, let fan): label = fan.map { "\($0.word)? say a number" } ?? "Landed"; tint = .landed; showsFanout = fan != nil
        case .error(let m): label = "⚠︎ \(m)"; tint = .error; showsFanout = false
        }
    }

    /// Waveform bars from a level; pure so the UIView just draws rectangles.
    public static func bars(level: Float, count: Int = 12) -> [Float] {
        (0..<count).map { i in
            let phase = Float(i) / Float(max(1, count - 1))
            return max(0.08, min(1, level * (0.6 + 0.4 * sin(phase * .pi))))
        }
    }
}
