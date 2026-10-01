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

/// Thread-safe rolling store of mouth crops. Bounded to `maxSeconds` (default 60 s ≈ 11.6 MB at
/// 25 fps); `clear()` after each utterance. Holds crops only — never a camera frame.
public final class VisualFrameBuffer: VisualClipProviding, @unchecked Sendable {
    public let maxSeconds: TimeInterval
    private let lock = NSLock()
    private var frames: [MouthCropFrame] = []
    private let now: @Sendable () -> TimeInterval

    public init(maxSeconds: TimeInterval = 60,
                now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maxSeconds = maxSeconds; self.now = now
    }

    public func append(_ frame: MouthCropFrame) {
        lock.withLock {
            frames.append(frame)
            let cutoff = frame.time - maxSeconds
            if let first = frames.firstIndex(where: { $0.time >= cutoff }), first > 0 { frames.removeFirst(first) }
        }
    }

    public func clear() { lock.withLock { frames.removeAll() } }

    public var count: Int { lock.withLock { frames.count } }

    public func clip(from: TimeInterval, to: TimeInterval) -> VisualClip {
        let picked = lock.withLock { frames.filter { $0.time >= from - 0.1 && $0.time <= to + 0.1 } }
        return VisualClip(start: from, end: to, frames: picked)
    }

    public func visualClip(duration: TimeInterval) -> VisualClip? {
        let end = now()
        return clip(from: end - duration, to: end)
    }
}
