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
    /// Normalised 0…1 input level, one per ≈50 ms block. The pipeline has always emitted
    /// `.level(rms:)`; this forwards it so meters don't have to infer level from engine state.
    public var onLevel: (@Sendable (Float) -> Void)?
    /// Capture reported success and then produced nothing (the pipeline's no-audio watchdog), or a
    /// start failed after `.started`. Never silent: a meter that cannot move must say so.
    public var onCaptureFailure: (@Sendable (String) -> Void)?
    /// Seconds to wait for the async pipeline start before giving up (a hung HAL must not hang the hotkey).
    public var startTimeout: TimeInterval = 3
    /// Tests replaying fixtures set this false; live capture keeps the TCC check.
    public var requireMicrophonePermission = true
    /// P1.5.2 — keeps the last utterance's samples so the dual-path reconciler can re-run both
    /// passes after landing. Reset at `start()`, frozen at `stop()`. Off when nil.
    public var utteranceTap: UtteranceAudioTap?

    /// Who is allowed to hold the shared capture graph, and who wins when two want it.
    ///
    /// One graph, one owner. Before 1.7.4 `start()` silently returned success when the source was
    /// already running, so the onboarding mic meter and the ASR engine could each believe they had
    /// configured capture while only the first one actually had: the second got a stream whose ring,
    /// VAD and utterance tap still held the *previous* owner's state, and whichever one stopped
    /// first killed capture under the other.
    public enum Owner: String, Sendable {
        /// Dictation. Outranks everything: a held hotkey must never lose to a meter.
        case engine
        /// The onboarding mic-check level meter.
        case meter
        /// `--mic-selftest` and other diagnostics.
        case diagnostics

        var rank: Int { self == .engine ? 1 : 0 }
    }

    private let lock = NSLock()
    private var forwarder: Task<Void, Never>?
    private var owner: Owner?
    /// The owner that was displaced by a higher-ranked `start()`, so a meter can say "dictation took
    /// the microphone" instead of silently going flat.
    public var onPreempted: (@Sendable (Owner) -> Void)?

    /// Who currently holds capture, if anyone. Diagnostics / tests.
    public var currentOwner: Owner? { lock.withLock { owner } }

    public init(pipeline: AudioPipeline) { self.pipeline = pipeline }

    public var deviceName: String? { pipeline.source.device?.name }

    public func prewarm() throws {
        // Opening the HAL device is TCC-gated; without the microphone permission AVAudioEngine
        // prepares fine but delivers silence, so a denied permission is surfaced at `start()`.
        Task.detached(priority: .userInitiated) { [pipeline] in
            do { try await pipeline.prewarm() } catch { Log.engine.warning("audio prewarm failed: \(error)") }
        }
    }

    public func start() throws { try start(for: .engine) }

    /// Opens capture for `owner`, or fails loudly.
    ///
    /// The three outcomes, none of them silent:
    /// * nobody holds the graph → a fresh start (ring cleared, VAD reset, utterance tap reset);
    /// * a lower-or-equal-ranked owner holds it → it is torn down completely and restarted for the
    ///   new owner, who therefore gets a stream configured for *its* utterance, not an inherited one;
    /// * a higher-ranked owner holds it → `AudioCaptureError.busy`, so the caller can say so.
    public func start(for owner: Owner) throws {
        guard !requireMicrophonePermission || Self.microphoneAuthorized else { throw AudioCaptureError.noInputDevice }
        let displaced: Owner? = try lock.withLock {
            if let current = self.owner {
                guard owner.rank >= current.rank else { throw AudioCaptureError.busy(owner: current.rawValue) }
                return current
            }
            return nil
        }
        if let displaced {
            // Never inherit somebody else's running graph. Restarting is what guarantees the
            // recognizer is fed a stream with a cleared ring, a reset VAD and an empty utterance tap.
            Log.engine.notice("audio source: \(owner.rawValue) takes capture from \(displaced.rawValue); restarting the graph")
            stopGraph()
            onPreempted?(displaced)
        }
        lock.withLock { self.owner = owner }
        utteranceTap?.reset()

        let events = pipeline.events()
        forwarder = Task.detached(priority: .userInteractive) { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .audio(let samples, _):
                    self.utteranceTap?.append(samples)
                    samples.withUnsafeBufferPointer { self.sink?($0) }
                case .level(let rms):
                    self.onLevel?(min(1, rms * 4))
                case .micQuality(let q):
                    self.onMicQuality?(q)
                case .deviceChanged(let from, let to):
                    self.onDeviceChanged?(from, to)
                case .captureFailed(let reason):
                    Log.engine.error("audio source: \(reason)")
                    self.onCaptureFailure?(reason)
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
            // Reporting success for a pipeline that never started is what let the mic check show a
            // dead meter under a "listening" label. A timeout is a start failure.
            Log.engine.error("audio pipeline start timed out after \(startTimeout)s")
            lock.withLock { self.owner = nil }
            forwarder?.cancel()
            throw AudioCaptureError.engineStartFailed("start timed out after \(startTimeout)s")
        }
        if let error = box.error {
            lock.withLock { self.owner = nil }
            forwarder?.cancel()
            throw error
        }
    }

    public func stop() { stop(for: .engine) }

    /// Releases capture **only if `owner` still holds it**. A meter that was preempted by dictation
    /// calling `stopMonitoring()` a moment later must not close the microphone out from under the
    /// utterance that took it — that is the other half of the shared-source bug.
    public func stop(for owner: Owner) {
        let mine = lock.withLock { () -> Bool in
            guard self.owner == owner else { return false }
            self.owner = nil
            return true
        }
        guard mine else { return }
        stopGraph()
    }

    /// Tears the capture graph down. The owner slot is the caller's business.
    private func stopGraph() {
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
