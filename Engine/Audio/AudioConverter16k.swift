import AVFoundation
import Foundation

/// Converts any PCM input (rate/channels/format) to 16 kHz mono Float32 via `AVAudioConverter`.
/// One instance per input format; `AudioPipeline` rebuilds it when the format changes.
public final class AudioConverter16k: @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        self.outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate, channels: 1, interleaved: false)!
        if inputFormat.sampleRate == Self.targetSampleRate, inputFormat.channelCount == 1, inputFormat.commonFormat == .pcmFormatFloat32 {
            converter = nil
        } else {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        }
    }

    public convenience init(sampleRate: Double, channels: Int) {
        self.init(inputFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!)
    }

    /// Convert a buffer in `inputFormat` to 16k mono samples. Streaming: the resampler keeps a
    /// few ms of history between calls (`flush: false`). `flush: true` drains it (one-shot use)
    /// and resets the converter.
    public func convert(_ buffer: AVAudioPCMBuffer, flush: Bool = false) -> [Float] {
        guard let converter else { return Self.floats(buffer) }
        let ratio = Self.targetSampleRate / inputFormat.sampleRate
        var result: [Float] = []
        var consumed = false
        var error: NSError?
        while true {
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 4096
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { break }
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = flush ? .endOfStream : .noDataNow; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .error { break }
            result.append(contentsOf: Self.floats(out))
            if status != .haveData || out.frameLength == 0 || !flush { break }
        }
        if flush { converter.reset() }
        return result
    }

    /// Convenience for non-interleaved mono/stereo Float input at `inputFormat`.
    public func convert(samples: [Float]) -> [Float] {
        let channels = Int(inputFormat.channelCount)
        let frames = samples.count / channels
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        buf.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            let dst = buf.floatChannelData![c]
            if inputFormat.isInterleaved {
                for i in 0..<frames { dst[i] = samples[i * channels + c] }
            } else {
                for i in 0..<frames { dst[i] = samples[i * channels + c] }
            }
        }
        return convert(buf, flush: true)
    }

    private static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
