import AVFoundation
import Foundation
import Shared
import Speech

/// Offline fallback so first dictation works before any Parakeet model is on disk:
/// Apple's on-device `SFSpeechRecognizer` (`requiresOnDeviceRecognition = true`, so speech
/// never leaves the machine). Word confidence comes from `SFTranscriptionSegment.confidence`
/// (0 when Apple doesn't provide one — treated as unknown → 0.5 so the gatekeeper stays cautious).
/// Untested automatically: needs Speech TCC permission + the on-device language asset.
public final class AppleSpeechRecognizer: FinalRecognizer, @unchecked Sendable {
    public let name = "apple.speech.ondevice"
    private let recognizer: SFSpeechRecognizer
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init?(locale: Locale = Locale(identifier: "en-US")) {
        guard let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition else { return nil }
        self.recognizer = r
    }

    /// True when the recognizer exists, supports on-device mode, and permission is granted or undetermined.
    public static func isAvailable(locale: Locale = Locale(identifier: "en-US")) -> Bool {
        guard let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition, r.isAvailable else { return false }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized, .notDetermined: return true
        default: return false
        }
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        guard !samples.isEmpty else { return [] }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined, !(await Self.requestAuthorization()) {
            throw EngineError.modelUnavailable("speech permission denied")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        request.append(buf)
        request.endAudio()

        let segments: [SFTranscriptionSegment] = try await withCheckedThrowingContinuation { c in
            var done = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let error { done = true; c.resume(throwing: error); return }
                if let result, result.isFinal { done = true; c.resume(returning: result.bestTranscription.segments) }
            }
        }
        return segments.map { s in
            let conf = s.confidence > 0 ? s.confidence : 0.5
            let start = max(0, s.timestamp)
            return TranscriptSpan(text: s.substring, confidence: conf, audioRange: start...(start + max(0, s.duration)), provenance: [.asr])
        }
    }
}
