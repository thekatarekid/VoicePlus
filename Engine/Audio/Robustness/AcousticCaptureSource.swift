import Foundation
import Shared

/// Wraps any `AudioCaptureSource` and runs the sample-level acoustic chain (neural AEC slot →
/// noise suppression) on its output before the pipeline's ring buffer. Also implements the
/// Bluetooth pre-roll: on `prewarm()` the inner source is *started* into a private buffer so a
/// slow-opening transport (SCO) is already streaming when the user begins talking; `start()`
/// flushes the last `profile.prerollSeconds` of that buffer to the sink first.
///
/// Drop-in: `AudioPipeline(source: AcousticCaptureSource(wrapping: inner, profile: p), ...)`.
public final class AcousticCaptureSource: AudioCaptureSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    public var device: AudioDeviceInfo? { inner.device }
    public let inner: any AudioCaptureSource
    public private(set) var profile: RobustnessProfile
    public let chain: AcousticChain
    /// Assessment of the current device (transport / SCO rate), computed at prewarm.
    public private(set) var bluetooth: BluetoothInputAssessment?
    /// Samples kept from the preroll and flushed at `start()` (for tests / Lab).
    public private(set) var prerollFlushed = 0

    private let lock = NSLock()
    private var preroll: [Float] = []
    private var prerolling = false
    private var live = false
    private let prerollCapacity: Int

    public init(wrapping inner: any AudioCaptureSource, profile: RobustnessProfile = .default, aec: (any AcousticStage)? = nil) {
        self.inner = inner
        self.profile = profile
        self.chain = AcousticChain(profile: profile, aec: aec)
        self.prerollCapacity = Int(profile.prerollSeconds * 16_000)
        inner.sink = { [weak self] buf in self?.ingest(buf) }
        inner.onDeviceChanged = { [weak self] old, new in
            guard let self else { return }
            self.bluetooth = BluetoothInputDetector.assess(new)
            self.chain.reset()
            self.onDeviceChanged?(old, new)
        }
    }

    /// Opens the device and, when the profile asks for pre-roll, begins capturing into the
    /// pre-roll buffer immediately (the "AirPods first word never clipped" guarantee).
    public func prewarm() throws {
        try inner.prewarm()
        bluetooth = BluetoothInputDetector.assess(inner.device)
        lock.lock(); let needStart = prerollCapacity > 0 && !prerolling && !live; if needStart { prerolling = true }; lock.unlock()
        if needStart { try inner.start() }
    }

    public func start() throws {
        try prewarm()
        lock.lock()
        let wasPrerolling = prerolling
        prerolling = false
        live = true
        let held = preroll
        preroll.removeAll(keepingCapacity: true)
        lock.unlock()
        if !held.isEmpty {
            prerollFlushed += held.count
            deliver(chain.process(held))
        }
        if !wasPrerolling { try inner.start() }
    }

    public func stop() {
        inner.stop()
        lock.lock(); live = false; prerolling = false; preroll.removeAll(); lock.unlock()
        let tail = chain.flush()
        if !tail.isEmpty { deliver(tail) }
        chain.reset()
    }

    public func switchDevice(to device: AudioDeviceInfo?) throws { try inner.switchDevice(to: device) }

    // MARK: internals

    private func ingest(_ buf: UnsafeBufferPointer<Float>) {
        lock.lock()
        if prerolling && !live {
            preroll.append(contentsOf: buf)
            if preroll.count > prerollCapacity { preroll.removeFirst(preroll.count - prerollCapacity) }
            lock.unlock()
            return
        }
        lock.unlock()
        let out = chain.process(Array(buf))
        deliver(out)
    }

    private func deliver(_ samples: [Float]) {
        guard !samples.isEmpty, let sink else { return }
        samples.withUnsafeBufferPointer { sink($0) }
    }
}
