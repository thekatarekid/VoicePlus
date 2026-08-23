import Foundation
import Shared

/// On-device recognizer contract used by the keyboard. Two implementations live in
/// `iOS/Shared/`: `SpeechRecognizerASR` (SFSpeechRecognizer, on-device only) and the
/// `ParakeetCoreMLASR` slot (FluidAudio Parakeet compiled for iOS). Tests use `MockKeyboardASR`.
public protocol KeyboardASR: AnyObject {
    var isAvailable: Bool { get }
    /// Start streaming; `onPartial` fires with interim text, `onFinal` once after `stop()`.
    func start(onPartial: @escaping @Sendable (String) -> Void,
               onFinal: @escaping @Sendable (Result<[TranscriptSpan], Error>) -> Void) throws
    func stop()
}

public enum KeyboardASRError: Error, Equatable { case unavailable, notAuthorized, onDeviceUnsupported }

/// Deterministic mock: emits the scripted partials then the final spans on `stop()`.
public final class MockKeyboardASR: KeyboardASR, @unchecked Sendable {
    public var isAvailable = true
    public var partials: [String]
    public var final: Result<[TranscriptSpan], Error>
    public private(set) var startCount = 0, stopCount = 0
    private var onFinal: (@Sendable (Result<[TranscriptSpan], Error>) -> Void)?

    public init(partials: [String] = [], final: Result<[TranscriptSpan], Error>) { self.partials = partials; self.final = final }

    public func start(onPartial: @escaping @Sendable (String) -> Void,
                      onFinal: @escaping @Sendable (Result<[TranscriptSpan], Error>) -> Void) throws {
        guard isAvailable else { throw KeyboardASRError.unavailable }
        startCount += 1; self.onFinal = onFinal
        partials.forEach(onPartial)
    }
    public func stop() { stopCount += 1; onFinal?(final); onFinal = nil }
}

/// Splits a plain recognizer string into spans with uniform confidence (SFSpeech gives
/// per-segment confidence only on some OS versions; the caller may override).
public enum KeyboardSpanBuilder {
    public static func spans(from text: String, confidence: Float = 0.85, duration: TimeInterval = 1) -> [TranscriptSpan] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        let step = duration / Double(words.count)
        return words.enumerated().map { i, w in
            TranscriptSpan(text: w, confidence: confidence, audioRange: (Double(i) * step)...(Double(i + 1) * step), provenance: [.asr])
        }
    }
}
