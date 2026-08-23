import Foundation
import Shared
import KeyboardCore
#if canImport(Speech) && canImport(AVFoundation)
import Speech
import AVFoundation

/// `KeyboardASR` over SFSpeechRecognizer with `requiresOnDeviceRecognition = true` (speech
/// never leaves the device; Ground rules §1). Compiled into both the keyboard and the app.
public final class SpeechRecognizerASR: NSObject, KeyboardASR, @unchecked Sendable {
    private let recognizer: SFSpeechRecognizer?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onFinal: (@Sendable (Result<[TranscriptSpan], Error>) -> Void)?
    private var latest: SFSpeechRecognitionResult?
    public var onLevel: (@Sendable (Float) -> Void)?

    public init(locale: Locale = .current) {
        recognizer = SFSpeechRecognizer(locale: locale)
        super.init()
    }

    public var isAvailable: Bool {
        guard let r = recognizer, r.isAvailable, r.supportsOnDeviceRecognition else { return false }
        return SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    public func start(onPartial: @escaping @Sendable (String) -> Void,
                      onFinal: @escaping @Sendable (Result<[TranscriptSpan], Error>) -> Void) throws {
        guard let recognizer, recognizer.isAvailable else { throw KeyboardASRError.unavailable }
        guard recognizer.supportsOnDeviceRecognition else { throw KeyboardASRError.onDeviceUnsupported }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw KeyboardASRError.notAuthorized }
        self.onFinal = onFinal; latest = nil
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        request = req
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
            req.append(buf)
            if let onLevel = self?.onLevel { onLevel(Self.rms(buf)) }
        }
        engine.prepare(); try engine.start()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result { self.latest = result; onPartial(result.bestTranscription.formattedString) }
            if result?.isFinal == true || error != nil { self.finish(error: result?.isFinal == true ? nil : error) }
        }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        request?.endAudio()
        // The final callback arrives from the task; guard against a recognizer that never finalizes.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.finish(error: nil) }
    }

    private func finish(error: Error?) {
        guard let done = onFinal else { return }
        onFinal = nil; task?.cancel(); task = nil; request = nil
        if let error, latest == nil { done(.failure(error)); return }
        done(.success(Self.spans(from: latest)))
    }

    static func spans(from result: SFSpeechRecognitionResult?) -> [TranscriptSpan] {
        guard let segs = result?.bestTranscription.segments, !segs.isEmpty else { return [] }
        return segs.map { seg in
            TranscriptSpan(text: seg.substring, confidence: seg.confidence > 0 ? seg.confidence : 0.85,
                           audioRange: seg.timestamp...(seg.timestamp + max(seg.duration, 0.01)),
                           alternates: seg.alternativeSubstrings.prefix(4).enumerated().map { Alternate(text: $1, score: 1 - Float($0) * 0.1, source: .beam) },
                           provenance: [.asr])
        }
    }

    static func rms(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
        return min(1, sqrt(sum / Float(buf.frameLength)) * 8)
    }
}
#endif
