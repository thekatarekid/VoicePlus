import AVFoundation
import Foundation

/// Converts any PCM input (rate/channels/format) to 16 kHz mono Float32 via `AVAudioConverter`.
/// One instance per input format; `AudioPipeline` rebuilds it when the format changes.
public final class AudioConverter16k: @unchecked Sendable {
    public static let targetSampleRate: Double = 16_000
    /// The format callers hand us — i.e. what the tap produces.
    public let inputFormat: AVAudioFormat
    public let outputFormat: AVAudioFormat
    /// True when the input carries more than two channels. Apple's voice-processing tap hands back
    /// a *discrete* multi-channel layout (5 ch on Apple silicon, layout tag 9633797) and
    /// `AVAudioConverter` maps that to digital silence — measured on this hardware: raw channel 0
    /// rms 0.000482 in, 0.000000 out. Channel 0 is therefore taken explicitly instead.
    public let extractsChannelZero: Bool
    /// The format actually fed to `AVAudioConverter` (mono at `inputFormat.sampleRate` when
    /// `extractsChannelZero`, otherwise `inputFormat`).
    public let converterInputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    public init(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        self.outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate, channels: 1, interleaved: false)!
        let mono = inputFormat.channelCount > 2
            ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)
            : nil
        self.converterInputFormat = mono ?? inputFormat
        self.extractsChannelZero = mono != nil
        let source = mono ?? inputFormat
        if source.sampleRate == Self.targetSampleRate, source.channelCount == 1, source.commonFormat == .pcmFormatFloat32 {
            converter = nil
        } else {
            converter = AVAudioConverter(from: source, to: outputFormat)
        }
    }

    public convenience init(sampleRate: Double, channels: Int) {
        self.init(inputFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!)
    }

    /// Convert a buffer in `inputFormat` to 16k mono samples. Streaming: the resampler keeps a
    /// few ms of history between calls (`flush: false`). `flush: true` drains it (one-shot use)
    /// and resets the converter.
    public func convert(_ buffer: AVAudioPCMBuffer, flush: Bool = false) -> [Float] {
        guard let buffer = extractsChannelZero ? Self.channelZero(of: buffer, as: converterInputFormat) : buffer else { return [] }
        guard let converter else { return Self.floats(buffer) }
        let ratio = Self.targetSampleRate / converterInputFormat.sampleRate
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

    /// Copies channel 0 of a multi-channel buffer into a mono buffer. Handles interleaved and
    /// deinterleaved input via `AVAudioPCMBuffer.stride`.
    static func channelZero(of buffer: AVAudioPCMBuffer, as format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData, buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        let step = buffer.stride
        let source = src[0]
        let target = dst[0]
        for i in 0..<Int(buffer.frameLength) { target[i] = source[i * step] }
        return out
    }

    private static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}
