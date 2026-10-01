import Foundation

/// V5 LR1–LR3 — what the camera is for. Off by default; the camera runs only while a mode other
/// than `.off` is on (LR5).
public enum LipMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// No camera.
    case off
    /// LR1 — face signals only (lip activity vs audio, facing, presence). No lip reading.
    case signals
    /// LR2 — signals + fused audio-visual recognition (`AVSRRecognizer`) when a face is tracked.
    case fused
    /// LR3 — silent dictation: camera only, microphone muted, `AVSRRecognizer(videoOnly: true)`.
    case lipsOnly

    public var needsCamera: Bool { self != .off }
    /// LR3 mutes the mic: nothing is captured from it while lips-only is on.
    public var capturesMicrophone: Bool { self != .lipsOnly }
    /// Whether mouth crops are kept for the current utterance (LR2/LR3 recognisers need them).
    public var collectsMouthCrops: Bool { self == .fused || self == .lipsOnly }
    /// Signals need 15 fps; Auto-AVSR is trained on 25 fps video.
    public var frameRate: Int { collectsMouthCrops ? 25 : 15 }

    public var title: String {
        switch self {
        case .off: return "Camera off"
        case .signals: return "Camera assists (who's speaking)"
        case .fused: return "Voice + lips"
        case .lipsOnly: return "Lips only (silent)"
        }
    }
}
