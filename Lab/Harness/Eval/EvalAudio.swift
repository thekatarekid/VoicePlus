import AVFoundation
import Foundation

/// V5 V3 — the Lab's own audio IO (the Lab target cannot link Engine): read any file AVFoundation
/// decodes (FLAC, WAV, …) as 16 kHz mono Float, write 16-bit PCM WAV.
public enum EvalAudio {
    public static let sampleRate: Double = 16_000

    public static func load16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return [] }
        try file.read(into: inBuf)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return [] }
        if inFormat.sampleRate == sampleRate, inFormat.channelCount == 1, inFormat.commonFormat == .pcmFormatFloat32,
           let ch = inBuf.floatChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(inBuf.frameLength)))
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw EvalError.stageUnsupported("cannot convert \(url.lastPathComponent)")
        }
        let capacity = AVAudioFrameCount(Double(frames) * sampleRate / inFormat.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return inBuf
        }
        if status == .error { throw error ?? EvalError.stageUnsupported("convert \(url.lastPathComponent)") }
        guard let ch = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }

    /// 16-bit PCM mono WAV at 16 kHz (half the bytes of float; the mixer clamps before writing).
    public static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Int = 16_000) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.reserveCapacity(d.count + samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32_767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try d.write(to: url)
    }
}
