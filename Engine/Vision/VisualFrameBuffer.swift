import Foundation

/// One mouth crop (88×88 gray, `MouthCropper.side`²) at a capture time; nil pixels = no face.
public struct MouthCropFrame: Equatable, Sendable {
    public var time: TimeInterval
    public var pixels: [UInt8]?
    public init(time: TimeInterval, pixels: [UInt8]?) { self.time = time; self.pixels = pixels }
}

/// The mouth crops for one utterance.
public struct VisualClip: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var frames: [MouthCropFrame]

    public init(start: TimeInterval, end: TimeInterval, frames: [MouthCropFrame]) {
        self.start = start; self.end = end; self.frames = frames.sorted { $0.time < $1.time }
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// Auto-AVSR's video rate.
    public static let modelFPS: Double = 25

    /// Nearest-crop resample onto a `fps` grid over `[start, end)`. A slot whose nearest crop is
    /// more than 1.5 source-frame gaps away, or has no face, is nil.
    public func resampled(fps: Double = VisualClip.modelFPS, maxGap: TimeInterval = 0.1) -> [[UInt8]?] {
        let count = Int((duration * fps).rounded())
        guard count > 0, !frames.isEmpty else { return [] }
        var out: [[UInt8]?] = []
        out.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let t = start + (Double(i) + 0.5) / fps
            while j + 1 < frames.count, abs(frames[j + 1].time - t) <= abs(frames[j].time - t) { j += 1 }
            out.append(abs(frames[j].time - t) <= maxGap ? frames[j].pixels : nil)
        }
        return out
    }

    /// Fraction of model-rate slots with a tracked face — "a face is tracked" (LR2) when ≥ 0.6.
    public var faceCoverage: Double {
        let slots = resampled()
        guard !slots.isEmpty else { return 0 }
        return Double(slots.filter { $0 != nil }.count) / Double(slots.count)
    }

    /// Model-rate frames with gaps filled from the nearest tracked neighbour (the model needs a
    /// dense sequence). Empty when nothing was tracked.
    public func denseFrames(fps: Double = VisualClip.modelFPS) -> [[UInt8]] {
        let slots = resampled(fps: fps)
        let tracked = slots.indices.filter { slots[$0] != nil }
        guard !tracked.isEmpty else { return [] }
        return slots.indices.map { i in
            if let f = slots[i] { return f }
            let nearest = tracked.min { abs($0 - i) < abs($1 - i) }!
            return slots[nearest]!
        }
    }
}

/// Where a recogniser gets the current utterance's mouth crops.
public protocol VisualClipProviding: AnyObject, Sendable {
    /// The crops for the last `duration` seconds (ending now); nil when the camera is not
    /// collecting crops.
    func visualClip(duration: TimeInterval) -> VisualClip?
}

/// V5 LR5 — how long mouth crops may live in memory.
///
/// * Outside an utterance the buffer is a ≤ `idleSeconds` (1 s) pre-roll: older crops are dropped
///   on every append, so an idle camera never accumulates video.
/// * While an utterance is open (`beginUtterance()`), crops are kept for that utterance only,
///   capped at `maxSeconds`.
/// * `endUtterance()` seals the utterance's crops for the recogniser that finalises it: they are
///   handed over **once** (`visualClip`) and dropped after `sealedLifetime` if nobody asks.
public struct CropRetention: Equatable, Sendable {
    public var idleSeconds: TimeInterval
    public var maxSeconds: TimeInterval
    public var sealedLifetime: TimeInterval
    public init(idleSeconds: TimeInterval = 1, maxSeconds: TimeInterval = 60, sealedLifetime: TimeInterval = 10) {
        self.idleSeconds = idleSeconds; self.maxSeconds = maxSeconds; self.sealedLifetime = sealedLifetime
    }
    public static let standard = CropRetention()
}

/// Thread-safe store of mouth crops under `CropRetention` (LR5). Holds crops only — never a camera
/// frame. `clear()` drops everything, open or sealed.
public final class VisualFrameBuffer: VisualClipProviding, @unchecked Sendable {
    public let retention: CropRetention
    public var maxSeconds: TimeInterval { retention.maxSeconds }
    private let lock = NSLock()
    private var frames: [MouthCropFrame] = []
    private var open = false
    private var sealed: (frames: [MouthCropFrame], end: TimeInterval)?
    private let now: @Sendable () -> TimeInterval

    public init(retention: CropRetention = .standard,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.retention = retention; self.now = now
    }

    public convenience init(maxSeconds: TimeInterval,
                            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.init(retention: CropRetention(maxSeconds: maxSeconds), now: now)
    }

    public func append(_ frame: MouthCropFrame) {
        lock.withLock {
            frames.append(frame)
            trim(newest: frame.time)
            expireSealed(at: now())
        }
    }

    /// An utterance started (hold key down / latch / audio capture started): keep its crops.
    public func beginUtterance() {
        lock.withLock {
            open = true
            sealed = nil
        }
    }

    /// The utterance ended: seal its crops for the one recogniser read, back to the idle pre-roll.
    public func endUtterance() {
        lock.withLock {
            guard open else { return }
            open = false
            let t = now()
            sealed = frames.isEmpty ? nil : (frames, t)
            frames.removeAll { $0.time < t - retention.idleSeconds }
        }
    }

    public var isUtteranceOpen: Bool { lock.withLock { open } }
    /// Whether a sealed utterance is waiting for its recogniser.
    public var hasSealedClip: Bool { lock.withLock { expireSealed(at: now()); return sealed != nil } }

    public func clear() {
        lock.withLock { frames.removeAll(); sealed = nil; open = false }
    }

    /// Crops held right now (live + sealed).
    public var count: Int { lock.withLock { expireSealed(at: now()); return frames.count + (sealed?.frames.count ?? 0) } }

    /// Seconds between the oldest and the newest crop held right now (live + sealed).
    public var heldSpan: TimeInterval {
        lock.withLock {
            expireSealed(at: now())
            let times = frames.map(\.time) + (sealed?.frames.map(\.time) ?? [])
            guard let lo = times.min(), let hi = times.max() else { return 0 }
            return hi - lo
        }
    }

    public func clip(from: TimeInterval, to: TimeInterval) -> VisualClip {
        let picked = lock.withLock { frames.filter { $0.time >= from - 0.1 && $0.time <= to + 0.1 } }
        return VisualClip(start: from, end: to, frames: picked)
    }

    /// A sealed utterance is handed over once (and dropped); otherwise the live crops ending now.
    public func visualClip(duration: TimeInterval) -> VisualClip? {
        let t = now()
        let handed: (frames: [MouthCropFrame], end: TimeInterval)? = lock.withLock {
            expireSealed(at: t)
            defer { sealed = nil }
            return sealed
        }
        if let handed {
            let from = handed.end - duration
            return VisualClip(start: from, end: handed.end,
                              frames: handed.frames.filter { $0.time >= from - 0.1 && $0.time <= handed.end + 0.1 })
        }
        return clip(from: t - duration, to: t)
    }

    // MARK: private (lock held)

    private func trim(newest: TimeInterval) {
        let keep = open ? retention.maxSeconds : retention.idleSeconds
        let cutoff = newest - keep
        if let first = frames.firstIndex(where: { $0.time >= cutoff }), first > 0 { frames.removeFirst(first) }
    }

    private func expireSealed(at t: TimeInterval) {
        if let s = sealed, t - s.end > retention.sealedLifetime { sealed = nil }
    }
}
