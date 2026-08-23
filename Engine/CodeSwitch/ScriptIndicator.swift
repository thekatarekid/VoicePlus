import Foundation

/// Model for the small script indicator in the pill: shows what the engine heard (EN / हि / both).
/// Pure value type so the App can render it in SwiftUI without importing detection internals.
public struct ScriptIndicatorModel: Equatable, Sendable {
    public enum State: Equatable, Sendable { case none, latin, devanagari, mixed }

    public private(set) var state: State = .none
    /// Detections below this confidence do not change the indicator (avoids flicker mid-word).
    public var minimumConfidence: Float

    public init(minimumConfidence: Float = 0.55) { self.minimumConfidence = minimumConfidence }

    public var label: String {
        switch state {
        case .none: return ""
        case .latin: return "EN"
        case .devanagari: return "हि"
        case .mixed: return "EN·हि"
        }
    }
    public var accessibilityLabel: String {
        switch state {
        case .none: return "No language detected"
        case .latin: return "English"
        case .devanagari: return "Hindi"
        case .mixed: return "Hindi and English"
        }
    }

    public mutating func update(with detection: LanguageDetector.Detection) {
        guard detection.confidence >= minimumConfidence || detection.language == .mixed else { return }
        let scripts = detection.scripts
        if scripts.contains(.devanagari) && scripts.contains(.latin) { state = .mixed }
        else if scripts.contains(.devanagari) { state = .devanagari }
        else if scripts.contains(.latin) { state = detection.language == .mixed ? .mixed : .latin }
        else { state = .none }
    }

    public mutating func update(with segments: ScriptSegments) {
        let s = segments.scripts
        if s.contains(.devanagari) && s.contains(.latin) { state = .mixed }
        else if s.contains(.devanagari) { state = .devanagari }
        else if s.contains(.latin) { state = .latin }
    }

    public mutating func reset() { state = .none }
}
