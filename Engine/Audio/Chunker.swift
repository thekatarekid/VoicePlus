import Foundation

/// A contiguous slice of 16 kHz audio handed to ASR.
public struct AudioChunk: Sendable, Equatable {
    public var samples: [Float]
    /// Position in the utterance, seconds.
    public var range: ClosedRange<TimeInterval>
    public var reason: Reason
    public enum Reason: String, Sendable { case speechEnd, maxDuration, flush }

    public init(samples: [Float], range: ClosedRange<TimeInterval>, reason: Reason) {
        self.samples = samples; self.range = range; self.reason = reason
    }
    public var duration: TimeInterval { range.upperBound - range.lowerBound }
}

/// Cuts the stream into ASR-sized chunks: never shorter than `minDuration` (unless flushed),
/// never longer than `maxDuration`; prefers cutting at a VAD speech-end boundary.
/// Defaults 3.0 s / 5.0 s (Muesli-validated).
public struct Chunker: Sendable {
    public let minDuration: TimeInterval
    public let maxDuration: TimeInterval
    public static let sampleRate = 16_000
    private var pending: [Float] = []
    private var pendingStart: TimeInterval = 0
    private var position: TimeInterval = 0
    /// Sample offset (within `pending`) of the latest speech-end boundary, if any.
    private var boundary: Int?

    public init(minDuration: TimeInterval = 3.0, maxDuration: TimeInterval = 5.0) {
        self.minDuration = minDuration
        self.maxDuration = max(maxDuration, minDuration)
    }

    public var pendingDuration: TimeInterval { Double(pending.count) / Double(Self.sampleRate) }

    /// Feed audio; returns zero or more chunks.
    public mutating func feed(_ samples: [Float]) -> [AudioChunk] {
        pending.append(contentsOf: samples)
        position += Double(samples.count) / Double(Self.sampleRate)
        var out: [AudioChunk] = []
        let maxSamples = Int(maxDuration * Double(Self.sampleRate))
        while pending.count >= maxSamples {
            out.append(cut(at: maxSamples, reason: .maxDuration))
        }
        return out
    }

    /// Mark that speech ended `now`; cuts a chunk if the pending audio is at least `minDuration`.
    public mutating func markSpeechEnd() -> AudioChunk? {
        boundary = pending.count
        guard pendingDuration >= minDuration else { return nil }
        return cut(at: pending.count, reason: .speechEnd)
    }

    /// Emit whatever is left (utterance end).
    public mutating func flush() -> AudioChunk? {
        guard !pending.isEmpty else { return nil }
        return cut(at: pending.count, reason: .flush)
    }

    public mutating func reset() {
        pending.removeAll(); pendingStart = 0; position = 0; boundary = nil
    }

    private mutating func cut(at count: Int, reason: AudioChunk.Reason) -> AudioChunk {
        // At max duration, prefer the last speech boundary if it yields at least minDuration.
        var n = count
        if reason == .maxDuration, let b = boundary, Double(b) / Double(Self.sampleRate) >= minDuration, b < count { n = b }
        let samples = Array(pending[0..<n])
        pending.removeFirst(n)
        let start = pendingStart
        let end = start + Double(n) / Double(Self.sampleRate)
        pendingStart = end
        boundary = boundary.flatMap { $0 > n ? $0 - n : nil }
        return AudioChunk(samples: samples, range: start...end, reason: reason == .maxDuration && n != count ? .speechEnd : reason)
    }
}
