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
public final class DecoderFinalRecognizer: FinalRecognizer, @unchecked Sendable {
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
}

/// Parakeet Realtime EOU 120M streaming preview. Confidence is not exposed upstream.
public final class EOUPreviewRecognizer: PreviewRecognizer, @unchecked Sendable {
    private let manager: StreamingEouAsrManager
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var pending: [Float] = []
    private var latest = ""
    private let chunkSamples: Int

    public init(manager: StreamingEouAsrManager, chunkSize: StreamingChunkSize = .ms160) {
        self.manager = manager
        self.chunkSamples = chunkSize.chunkSamples
    }

    public func feed(_ samples: [Float]) async throws -> String {
        lock.withLock { pending.append(contentsOf: samples) }
        while true {
            let next: [Float]? = lock.withLock {
                guard pending.count >= chunkSamples else { return nil }
                let c = Array(pending.prefix(chunkSamples)); pending.removeFirst(chunkSamples); return c
            }
            guard let chunk = next else { break }
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else { continue }
            buf.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            let text = try await manager.process(audioBuffer: buf)
            lock.withLock { latest = text }
        }
        return lock.withLock { latest }
    }

    public func reset() async {
        lock.withLock { pending.removeAll(); latest = "" }
        await manager.reset()
    }
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
            let text = try await recognizer.recognize(snapshot).joinedText
            lock.withLock { latest = text }
        }
        return lock.withLock { latest }
    }

    public func reset() async { lock.withLock { buffer.removeAll(); sinceLast = 0; latest = "" } }
}
