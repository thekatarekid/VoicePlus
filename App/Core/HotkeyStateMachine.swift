import Foundation

/// Pure hotkey gesture recogniser (T3). Fed key-down/key-up timestamps, emits dictation actions.
/// Timing constants are Muesli-validated: hold threshold 250 ms, tap guard 180 ms, double-tap window 350 ms.
///
/// Gestures:
/// - Hold (≥ holdThreshold): capture starts on key-down, finalizes on key-up.
/// - Tap (< holdThreshold): capture is cancelled on key-up; a tap shorter than `tapGuard` counts toward a double-tap.
/// - Double-tap (two guarded taps within `doubleTapWindow`): hands-free mode — capture keeps running after key-up.
/// - Any key-down while hands-free: finalize and leave hands-free.
public struct HotkeyStateMachine: Equatable, Sendable {
    public struct Timing: Equatable, Sendable {
        public var holdThreshold: TimeInterval
        public var tapGuard: TimeInterval
        public var doubleTapWindow: TimeInterval
        public init(holdThreshold: TimeInterval = 0.250, tapGuard: TimeInterval = 0.180, doubleTapWindow: TimeInterval = 0.350) {
            self.holdThreshold = holdThreshold
            self.tapGuard = tapGuard
            self.doubleTapWindow = doubleTapWindow
        }
        public static let `default` = Timing()
    }

    public enum Action: Equatable, Sendable {
        /// Begin capture (key went down; pill should appear immediately).
        case startCapture
        /// Key released after a hold, or hands-free ended: finalize the utterance.
        case finalize
        /// Key released too early: abort without text.
        case cancelCapture
        /// Second quick tap detected: keep capturing until the next key-down.
        case enterHandsFree
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case keyDown(since: TimeInterval)
        case handsFree
    }

    public let timing: Timing
    public private(set) var phase: Phase = .idle
    /// Time of the last key-up that qualified as a guarded tap; `nil` once consumed or expired.
    public private(set) var lastTapUp: TimeInterval?

    public init(timing: Timing = .default) { self.timing = timing }

    public var isCapturing: Bool {
        switch phase {
        case .idle: return false
        case .keyDown, .handsFree: return true
        }
    }

    @discardableResult
    public mutating func keyDown(at t: TimeInterval) -> [Action] {
        switch phase {
        case .keyDown:
            return [] // key repeat — ignore
        case .handsFree:
            phase = .idle
            lastTapUp = nil
            return [.finalize]
        case .idle:
            phase = .keyDown(since: t)
            return [.startCapture]
        }
    }

    @discardableResult
    public mutating func keyUp(at t: TimeInterval) -> [Action] {
        guard case .keyDown(let since) = phase else { return [] }
        let duration = t - since
        if duration >= timing.holdThreshold {
            phase = .idle
            lastTapUp = nil
            return [.finalize]
        }
        if duration < timing.tapGuard {
            if let previous = lastTapUp, t - previous <= timing.doubleTapWindow {
                phase = .handsFree
                lastTapUp = nil
                return [.enterHandsFree]
            }
            lastTapUp = t
            phase = .idle
            return [.cancelCapture]
        }
        // Ambiguous press: neither a clean tap nor a hold. Cancel; does not arm a double-tap.
        phase = .idle
        lastTapUp = nil
        return [.cancelCapture]
    }

    /// External reset (e.g. engine error, permission lost).
    public mutating func reset() {
        phase = .idle
        lastTapUp = nil
    }
}

/// Which key triggers dictation. Persisted in UserDefaults by `HotkeyService`.
public struct HotkeyBinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rightOption, leftOption, rightCommand, rightControl, fn
        public var displayName: String {
            switch self {
            case .rightOption: return "Right ⌥"
            case .leftOption: return "Left ⌥"
            case .rightCommand: return "Right ⌘"
            case .rightControl: return "Right ⌃"
            case .fn: return "fn / 🌐"
            }
        }
        /// macOS virtual key code delivered by `flagsChanged` events.
        public var keyCode: Int64 {
            switch self {
            case .rightOption: return 61
            case .leftOption: return 58
            case .rightCommand: return 54
            case .rightControl: return 62
            case .fn: return 63
            }
        }
        /// Bit in `CGEventFlags` that is set while the key is held.
        public var flagMask: UInt64 {
            switch self {
            case .rightOption, .leftOption: return 0x0008_0000 // maskAlternate
            case .rightCommand: return 0x0010_0000           // maskCommand
            case .rightControl: return 0x0004_0000           // maskControl
            case .fn: return 0x0080_0000                     // maskSecondaryFn
            }
        }
    }

    public var kind: Kind
    public init(kind: Kind = .rightOption) { self.kind = kind }
    public static let `default` = HotkeyBinding()

    /// Classifies a modifier `flagsChanged` event (key code + resulting flags) as press/release of this binding.
    public func edge(keyCode: Int64, flags: UInt64) -> Edge? {
        guard keyCode == kind.keyCode else { return nil }
        return (flags & kind.flagMask) != 0 ? .down : .up
    }

    public enum Edge: Equatable, Sendable { case down, up }
}
