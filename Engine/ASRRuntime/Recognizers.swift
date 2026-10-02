import AVFoundation
import FluidAudio
import Foundation
import Shared

/// Streaming preview: fed incrementally, yields cumulative text (no per-token confidence upstream).
public protocol PreviewRecognizer: AnyObject, Sendable {
    /// Feed 16 kHz samples; returns the cumulative partial text so far (may be unchanged).
    func feed(_ samples: [Float]) async throws -> String
    func reset() async
}

/// Final pass over the whole utterance → word spans with confidence + timestamps.
public protocol FinalRecognizer: AnyObject, Sendable {
    var name: String { get }
    func recognize(_ samples: [Float]) async throws -> [TranscriptSpan]
}

/// TDT final pass through the frozen `Decoder` interface (so P1.5 biasing and P1.6 beam plug in).
public final class DecoderFinalRecognizer: FinalRecognizer, FinalPassTimingReporting, @unchecked Sendable {
    public let name: String
    public let decoder: Decoder

    public init(decoder: Decoder, name: String? = nil) {
        self.decoder = decoder
        self.name = name ?? decoder.name
    }

    public func recognize(_ samples: [Float]) async throws -> [TranscriptSpan] {
        await decoder.reset()
        let result = try await decoder.decode(encoderFrames: FluidAudioTDTDecoder.frames(fromSamples: samples))
        return WordConfidence.spans(from: result.tokens)
    }

    /// N6 — the decoder's last final-pass stages (nil for decoders that do not report them).
    public var lastFinalPassTiming: FinalPassTiming? { (decoder as? FinalPassTimingReporting)?.lastFinalPassTiming }
}

/// V5 B1 — a final recognizer with a separate, never-boosted preview pass (the decoder's streaming
/// `AsrManager`). `PollingPreviewRecognizer` uses it so preview polls neither pay for CTC boosting
/// nor disturb the final pass's decoder state.
public protocol PreviewPassRecognizer: FinalRecognizer {
    func recognizePreview(_ samples: [Float]) async throws -> [TranscriptSpan]
}

extension DecoderFinalRecognizer: PreviewPassRecognizer {
    public func recognizePreview(_ samples: [Float]) async throws -> [TranscriptSpan] {
        guard let preview = decoder as? PreviewDecoding else { return try await recognize(samples) }
        let result = try await preview.decodePreview(encoderFrames: FluidAudioTDTDecoder.frames(fromSamples: samples))
        return WordConfidence.spans(from: result.tokens)
    }

    /// Installs (nil clears) the final-pass booster when the decoder supports one. Returns whether
    /// it was installed.
    @discardableResult
    public func installBooster(_ booster: VocabularyBooster?) -> Bool {
        guard let boostable = decoder as? VocabularyBoostable else { return false }
        boostable.booster = booster
        (booster as? BoostReporting)?.prepare()   // N6: stable rescorer built while the user speaks
        return booster != nil
    }
}

/// Parakeet Realtime EOU 120M streaming preview. Upstream chunks internally (160 ms, 50 %
/// overlap) and exposes the running transcript via `getPartialTranscript()`; per-token
/// confidence is not available on this path. `finish()` is never called here: the TDT final
/// pass replaces the preview, so the EOU manager is simply `reset()` per utterance.
public final class EOUPreviewRecognizer: PreviewRecognizer, @unchecked Sendable {
    private let manager: StreamingEouAsrManager
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    public init(manager: StreamingEouAsrManager) { self.manager = manager }

    public func feed(_ samples: [Float]) async throws -> String {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return await manager.getPartialTranscript()
        }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        _ = try await manager.process(audioBuffer: buf)
        return await manager.getPartialTranscript()
    }

    public func reset() async { await manager.reset() }
}

/// Preview that echoes the final recognizer over the accumulated buffer every `interval` seconds
/// of new audio. Used when no EOU model is on disk (e.g. tiny-model-only first launch).
public final class PollingPreviewRecognizer: PreviewRecognizer, @unchecked Sendable {
    private let recognizer: FinalRecognizer
    private let intervalSamples: Int
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var sinceLast = 0
    private var latest = ""

    public init(recognizer: FinalRecognizer, interval: TimeInterval = 1.0) {
        self.recognizer = recognizer
        self.intervalSamples = Int(interval * 16_000)
    }

    public func feed(_ samples: [Float]) async throws -> String {
        let (run, snapshot): (Bool, [Float]) = lock.withLock {
            buffer.append(contentsOf: samples); sinceLast += samples.count
            let r = sinceLast >= intervalSamples; if r { sinceLast = 0 }
            return (r, buffer)
        }
        if run {
            let spans: [TranscriptSpan]
            if let pass = recognizer as? PreviewPassRecognizer {
                spans = try await pass.recognizePreview(snapshot)
            } else {
                spans = try await recognizer.recognize(snapshot)
            }
            let text = spans.joinedText
            lock.withLock { latest = text }
        }
        return lock.withLock { latest }
    }

    public func reset() async { lock.withLock { buffer.removeAll(); sinceLast = 0; latest = "" } }
}
