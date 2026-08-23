import Foundation

/// Minimal RIFF/WAVE reader + writer (PCM 8/16/24/32-bit and IEEE float32), no AVFoundation.
/// Used by the fixture replayer and by tests; output is always mono Float in -1…1.
public struct WAVFile: Sendable, Equatable {
    public var sampleRate: Int
    public var channels: Int
    /// Interleaved samples, Float -1…1.
    public var samples: [Float]

    public init(sampleRate: Int, channels: Int = 1, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = max(1, channels)
        self.samples = samples
    }

    public var frameCount: Int { samples.count / channels }
    public var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }

    /// Channels averaged down to one.
    public var mono: [Float] {
        guard channels > 1 else { return samples }
        var out = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channels)
        for i in 0..<frameCount {
            var acc: Float = 0
            for c in 0..<channels { acc += samples[i * channels + c] }
            out[i] = acc * scale
        }
        return out
    }

    public enum WAVError: Error, Equatable {
        case notRIFF, missingFormat, missingData, unsupportedFormat(Int), unsupportedBits(Int), truncated
    }

    // MARK: Reading

    public static func read(url: URL) throws -> WAVFile {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> WAVFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, tag(bytes, 0) == "RIFF", tag(bytes, 8) == "WAVE" else { throw WAVError.notRIFF }
        var offset = 12
        var format: (tag: Int, channels: Int, rate: Int, bits: Int)?
        var payload: ArraySlice<UInt8>?
        while offset + 8 <= bytes.count {
            let id = tag(bytes, offset)
            let size = Int(u32(bytes, offset + 4))
            let body = offset + 8
            switch id {
            case "fmt ":
                guard body + 16 <= bytes.count else { throw WAVError.truncated }
                var fmtTag = Int(u16(bytes, body))
                let channels = Int(u16(bytes, body + 2))
                let rate = Int(u32(bytes, body + 4))
                let bits = Int(u16(bytes, body + 14))
                if fmtTag == 0xFFFE, body + 26 <= bytes.count { fmtTag = Int(u16(bytes, body + 24)) } // WAVE_FORMAT_EXTENSIBLE
                format = (fmtTag, channels, rate, bits)
            case "data":
                let end = min(body + size, bytes.count)
                payload = bytes[body..<end]
            default: break
            }
            offset = body + size + (size & 1)
        }
        guard let fmt = format else { throw WAVError.missingFormat }
        guard let raw = payload else { throw WAVError.missingData }
        let bytesPerSample = fmt.bits / 8
        let count = raw.count / max(1, bytesPerSample)
        var samples = [Float](repeating: 0, count: count)
        let base = raw.startIndex
        switch (fmt.tag, fmt.bits) {
        case (1, 8):
            for i in 0..<count { samples[i] = (Float(raw[base + i]) - 128) / 128 }
        case (1, 16):
            for i in 0..<count {
                let v = Int16(bitPattern: UInt16(raw[base + 2 * i]) | UInt16(raw[base + 2 * i + 1]) << 8)
                samples[i] = Float(v) / 32768
            }
        case (1, 24):
            for i in 0..<count {
                let b = base + 3 * i
                var v = Int32(raw[b]) | Int32(raw[b + 1]) << 8 | Int32(raw[b + 2]) << 16
                if v & 0x800000 != 0 { v |= ~0xFFFFFF }
                samples[i] = Float(v) / 8_388_608
            }
        case (1, 32):
            for i in 0..<count {
                let b = base + 4 * i
                let v = Int32(bitPattern: UInt32(raw[b]) | UInt32(raw[b + 1]) << 8 | UInt32(raw[b + 2]) << 16 | UInt32(raw[b + 3]) << 24)
                samples[i] = Float(v) / 2_147_483_648
            }
        case (3, 32):
            for i in 0..<count {
                let b = base + 4 * i
                let bits = UInt32(raw[b]) | UInt32(raw[b + 1]) << 8 | UInt32(raw[b + 2]) << 16 | UInt32(raw[b + 3]) << 24
                samples[i] = Float(bitPattern: bits)
            }
        case (1, _), (3, _): throw WAVError.unsupportedBits(fmt.bits)
        default: throw WAVError.unsupportedFormat(fmt.tag)
        }
        return WAVFile(sampleRate: fmt.rate, channels: fmt.channels, samples: samples)
    }

    // MARK: Writing (16-bit PCM)

    public func pcm16Data() -> Data {
        var out = Data()
        let dataBytes = samples.count * 2
        func put16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        func put32(_ v: UInt32) { put16(UInt16(v & 0xFFFF)); put16(UInt16(v >> 16)) }
        out.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + dataBytes)); out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(UInt16(channels))
        put32(UInt32(sampleRate)); put32(UInt32(sampleRate * channels * 2)); put16(UInt16(channels * 2)); put16(16)
        out.append(contentsOf: Array("data".utf8)); put32(UInt32(dataBytes))
        for s in samples {
            let clamped = max(-1, min(1, s))
            let v = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
            put16(UInt16(bitPattern: v))
        }
        return out
    }

    public func write(to url: URL) throws {
        try pcm16Data().write(to: url)
    }

    // MARK: helpers
    private static func tag(_ b: [UInt8], _ o: Int) -> String {
        guard o + 4 <= b.count else { return "" }
        return String(decoding: b[o..<o + 4], as: UTF8.self)
    }
    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
}

/// Locates audio fixtures under `Fixtures/audio/<suite>/`.
public enum AudioFixtures {
    public static func url(_ suite: String, _ file: String) -> URL? {
        AppPathsBridge.fixtures?.appendingPathComponent("audio/\(suite)/\(file)")
    }
    public static func list(_ suite: String) -> [URL] {
        guard let dir = AppPathsBridge.fixtures?.appendingPathComponent("audio/\(suite)") else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".wav") }.sorted().map { dir.appendingPathComponent($0) }
    }
}
