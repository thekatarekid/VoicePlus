import Foundation
import os

/// Single-producer / single-consumer ring buffer of Float samples.
/// The audio callback (producer) never allocates and never blocks on the consumer: writes that
/// do not fit are counted in `overruns` and dropped. Index exchange uses `os_unfair_lock`
/// (macOS 14 has no `Synchronization.Atomic`), held only for two integer loads/stores, so the
/// producer is wait-free in practice. Capacity is fixed at init.
public final class RingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var head = 0   // next write index
    private var tail = 0   // next read index
    private var count = 0
    private var lock = os_unfair_lock()
    private(set) public var overruns = 0
    private(set) public var totalWritten = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit { storage.deallocate() }

    public var available: Int {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return count
    }

    /// Returns number of samples actually written.
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        os_unfair_lock_lock(&lock)
        let free = capacity - count
        let n = min(free, samples.count)
        let h = head
        os_unfair_lock_unlock(&lock)
        guard let base = samples.baseAddress else { return 0 }
        let first = min(n, capacity - h)
        storage.advanced(by: h).update(from: base, count: first)
        if n > first { storage.update(from: base + first, count: n - first) }
        os_unfair_lock_lock(&lock)
        head = (h + n) % capacity
        count += n
        totalWritten += n
        if n < samples.count { overruns += samples.count - n }
        os_unfair_lock_unlock(&lock)
        return n
    }

    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { write($0) }
    }

    /// Pops up to `maxCount` samples (all available by default).
    public func read(maxCount: Int = .max) -> [Float] {
        os_unfair_lock_lock(&lock)
        let n = min(count, maxCount)
        let t = tail
        os_unfair_lock_unlock(&lock)
        guard n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        let first = min(n, capacity - t)
        out.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: storage.advanced(by: t), count: first)
            if n > first { (dst.baseAddress! + first).update(from: storage, count: n - first) }
        }
        os_unfair_lock_lock(&lock)
        tail = (t + n) % capacity
        count -= n
        os_unfair_lock_unlock(&lock)
        return out
    }

    public func clear() {
        os_unfair_lock_lock(&lock)
        head = 0; tail = 0; count = 0
        os_unfair_lock_unlock(&lock)
    }
}
