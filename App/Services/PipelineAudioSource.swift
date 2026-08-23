import AVFoundation
import Engine
import Foundation
import Shared

/// P1.12 T1 — the one-line-ish bridge Engine/Audio/README promised: an `AudioPipeline`
/// (capture → ring → 16 kHz → mic quality / VAD / level) exposed as the push-style
/// `AudioSource` that `RealEngine` consumes. Mic-quality and level side channels are
/// surfaced through callbacks so the pill can show them even though `RealEngine` only
/// forwards audio.
public final class PipelineAudioSource: AudioSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public let pipeline: AudioPipeline
    public var onMicQuality: (@Sendable (MicQuality) -> Void)?
    public var onDeviceChanged: (@Sendable (AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    /// Seconds to wait for the async pipeline start before giving up (a hung HAL must not hang the hotkey).
    public var startTimeout: TimeInterval = 3
    /// Tests replaying fixtures set this false; live capture keeps the TCC check.
    public var requireMicrophonePermission = true
    /// P1.5.2 — keeps the last utterance's samples so the dual-path reconciler can re-run both
    /// passes after landing. Reset at `start()`, frozen at `stop()`. Off when nil.
    public var utteranceTap: UtteranceAudioTap?

    private let lock = NSLock()
    private var forwarder: Task<Void, Never>?
    private var running = false

    public init(pipeline: AudioPipeline) { self.pipeline = pipeline }

    public var deviceName: String? { pipeline.source.device?.name }

    public func prewarm() throws {
        // Opening the HAL device is TCC-gated; without the microphone permission AVAudioEngine
        // prepares fine but delivers silence, so a denied permission is surfaced at `start()`.
        Task.detached(priority: .userInitiated) { [pipeline] in
            do { try await pipeline.prewarm() } catch { Log.engine.warning("audio prewarm failed: \(error)") }
        }
    }

    public func start() throws {
        guard !requireMicrophonePermission || Self.microphoneAuthorized else { throw AudioCaptureError.noInputDevice }
        let already = lock.withLock { () -> Bool in let r = running; running = true; return r }
        if already { return }
        utteranceTap?.reset()

        let events = pipeline.events()
        forwarder = Task.detached(priority: .userInteractive) { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .audio(let samples, _):
                    self.utteranceTap?.append(samples)
                    samples.withUnsafeBufferPointer { self.sink?($0) }
                case .micQuality(let q):
                    self.onMicQuality?(q)
                case .deviceChanged(let from, let to):
                    self.onDeviceChanged?(from, to)
                case .stopped:
                    return
                default:
                    break
                }
            }
        }

        // `AudioSource.start()` is synchronous; run the async pipeline start on the pool and
        // wait briefly so errors (no device, engine start failure) still propagate to the engine.
        let box = ErrorBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInteractive) { [pipeline] in
            do { try await pipeline.start() } catch { box.error = error }
            done.signal()
        }
        if done.wait(timeout: .now() + startTimeout) == .timedOut {
            Log.engine.warning("audio pipeline start timed out after \(startTimeout)s; continuing without audio")
        }
        if let error = box.error {
            lock.withLock { running = false }
            forwarder?.cancel()
            throw error
        }
    }

    public func stop() {
        let was = lock.withLock { () -> Bool in let r = running; running = false; return r }
        guard was else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInteractive) { [pipeline] in
            await pipeline.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + startTimeout)
        forwarder?.cancel()
        forwarder = nil
    }

    static var microphoneAuthorized: Bool {
        if ProcessInfo.processInfo.environment["VOICEPLUS_MOCK_PERMISSIONS"] == "1" { return true }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _error: Error?
        var error: Error? {
            get { lock.withLock { _error } }
            set { lock.withLock { _error = newValue } }
        }
    }
}

/// Lab / soak feed: an `AudioSource` with no hardware behind it. `feed(url:)` (or `push`)
/// delivers 16 kHz samples to whatever `RealEngine` installed as `sink`.
public final class FileFeedAudioSource: AudioSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var blockSize = 800 // 50 ms

    public init() {}
    public func prewarm() throws {}
    public func start() throws {}
    public func stop() {}

    public func push(_ samples: [Float]) {
        var i = 0
        while i < samples.count {
            let end = min(i + blockSize, samples.count)
            samples[i..<end].withUnsafeBufferPointer { sink?($0) }
            i = end
        }
    }

    public func feed(url: URL) throws {
        push(try SampleAudioSource.load16k(url: url))
    }
}

/// Accumulates one utterance's 16 kHz samples (bounded) for post-landing reconciliation.
public final class UtteranceAudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [Float] = []
    public let maxSamples: Int
    public init(maxSeconds: TimeInterval = 120) { maxSamples = Int(maxSeconds * 16_000) }
    public func reset() { lock.withLock { buffer.removeAll(keepingCapacity: true) } }
    public func append(_ samples: [Float]) {
        lock.withLock { if buffer.count < maxSamples { buffer.append(contentsOf: samples.prefix(maxSamples - buffer.count)) } }
    }
    public var samples: [Float] { lock.withLock { buffer } }
}
