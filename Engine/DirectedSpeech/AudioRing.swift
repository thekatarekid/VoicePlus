import Foundation

/// Rolling RAM-only audio ring (default 10 s @ 16 kHz). Never written to disk; `wipe()` zeroes it.
public final class RollingAudioRing: @unchecked Sendable {
    public let capacity: Int
    public let sampleRate: Int
    private var buffer: [Float]
    private var head = 0          // next write index
    private var filled = 0
    private var total = 0         // samples ever written (stream clock)
    private let lock = NSLock()

    public init(seconds: TimeInterval = 10, sampleRate: Int = 16_000) {
        self.sampleRate = sampleRate
        capacity = Int(seconds * Double(sampleRate))
        buffer = [Float](repeating: 0, count: capacity)
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return filled }
    public var streamTime: TimeInterval { lock.lock(); defer { lock.unlock() }; return Double(total) / Double(sampleRate) }

    public func append(_ samples: [Float]) {
        lock.lock(); defer { lock.unlock() }
        for s in samples {
            buffer[head] = s
            head = (head + 1) % capacity
        }
        total += samples.count
        filled = min(capacity, filled + samples.count)
    }

    /// Samples in `range` (stream seconds). Parts that fell out of the ring are omitted.
    public func samples(in range: ClosedRange<TimeInterval>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let oldest = total - filled
        let lo = max(oldest, Int((range.lowerBound * Double(sampleRate)).rounded()))
        let hi = min(total, Int((range.upperBound * Double(sampleRate)).rounded()))
        guard hi > lo else { return [] }
        var out = [Float](); out.reserveCapacity(hi - lo)
        for i in lo..<hi { out.append(buffer[(head - (total - i) + capacity * 2) % capacity]) }
        return out
    }

    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<capacity { buffer[i] = 0 }
        head = 0; filled = 0; total = 0
    }
}
