import Foundation

/// Replays a WAV (any rate/channels) through the exact same sink the HAL source uses, in
/// `blockDuration` slices. Deterministic: same input → same 16 kHz buffers, byte for byte.
/// `realtime: true` paces delivery at wall-clock speed (for manual/Lab runs); tests use `false`.
public final class FixtureCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    private(set) public var device: AudioDeviceInfo?
    public let samples16k: [Float]
    public let blockDuration: TimeInterval
    public let realtime: Bool
    private var thread: Thread?
    private let stopFlag = NSLock()
    private var stopped = false
    private(set) public var prewarmed = false
    private(set) public var delivered = 0
    /// Fires once all samples have been pushed (from the replay thread).
    public var onFinished: (() -> Void)?

    public init(wav: WAVFile, blockDuration: TimeInterval = 0.05, realtime: Bool = false, device: AudioDeviceInfo = .fixture) {
        if wav.sampleRate == 16_000 && wav.channels == 1 {
            samples16k = wav.samples
        } else {
            samples16k = AudioConverter16k(sampleRate: Double(wav.sampleRate), channels: wav.channels).convert(samples: wav.samples)
        }
        self.blockDuration = blockDuration
        self.realtime = realtime
        self.device = device
    }

    public convenience init(url: URL, blockDuration: TimeInterval = 0.05, realtime: Bool = false) throws {
        self.init(wav: try WAVFile.read(url: url), blockDuration: blockDuration, realtime: realtime)
    }

    public func prewarm() throws { prewarmed = true }

    /// Pushes every block through `sink`. Synchronous unless `realtime` (then a thread paces it).
    public func start() throws {
        try prewarm()
        stopFlag.lock(); stopped = false; stopFlag.unlock()
        if realtime {
            let t = Thread { [self] in self.pump() }
            t.name = "voiceplus.fixture.replay"
            thread = t
            t.start()
        } else {
            pump()
        }
    }

    public func stop() {
        stopFlag.lock(); stopped = true; stopFlag.unlock()
    }

    public func switchDevice(to newDevice: AudioDeviceInfo?) throws {
        let old = device
        device = newDevice ?? .fixture
        onDeviceChanged?(old, device)
    }

    /// Push an arbitrary block (used by chaos tests to interleave device swaps with audio).
    public func push(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { sink?($0) }
        delivered += samples.count
    }

    private func pump() {
        let block = max(1, Int(blockDuration * 16_000))
        var i = 0
        while i < samples16k.count {
            stopFlag.lock(); let s = stopped; stopFlag.unlock()
            if s { return }
            let end = min(i + block, samples16k.count)
            samples16k.withUnsafeBufferPointer { p in
                sink?(UnsafeBufferPointer(rebasing: p[i..<end]))
            }
            delivered += end - i
            i = end
            if realtime { Thread.sleep(forTimeInterval: blockDuration) }
        }
        onFinished?()
    }
}
