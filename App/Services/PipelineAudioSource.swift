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
    /// Seconds to wait for the async pipeline start before giving up (a hung HAL must not hang the
    /// hotkey). V4.10: unless overridden (`--mic-selftest` sets `selfTestBudget`), this is the start
    /// budget of the device about to open — `budget(for:)` — not one number for every mic.
    public var startTimeout: TimeInterval {
        get { lock.withLock { startTimeoutOverride } ?? Self.budget(for: startTransport()) }
        set { lock.withLock { startTimeoutOverride = newValue } }
    }
    private var startTimeoutOverride: TimeInterval?
    /// Tests replaying fixtures set this false; live capture keeps the TCC check.
    public var requireMicrophonePermission = true
    /// P1.5.2 — keeps the last utterance's samples so the dual-path reconciler can re-run both
    /// passes after landing. Reset at `start()`, frozen at `stop()`. Off when nil.
    public var utteranceTap: UtteranceAudioTap?

    // G0.2 — the pipeline has always emitted `.vad`, `.chunk` and `.endpoint`; the events loop
    // used to drop them on the floor (`default: break`), which is why the latch runtime's
    // `noteVAD`/`noteEndpoint` were never called. They are forwarded, in pipeline order, from the
    // forwarder task (not the main thread).
    /// Speech start / end as the pipeline's VAD saw it (stream seconds).
    public var onVAD: (@Sendable (VADEvent) -> Void)?
    /// Latched-mode endpoint decisions. Only emitted while the pipeline is latched (`setLatched`).
    public var onEndpoint: (@Sendable (Endpointer.Decision) -> Void)?
    /// 3–5 s ASR-sized chunks, cut at speech ends where possible.
    public var onChunk: (@Sendable (AudioChunk) -> Void)?

    /// Flips `AudioPipeline.Options.latched` on the live pipeline: from the next audio block the
    /// pipeline drives its endpointer and emits `.endpoint` (forwarded to `onEndpoint`), without
    /// restarting capture. Survives `start()`/`stop()` until flipped back.
    public func setLatched(_ on: Bool) { pipeline.setLatched(on) }

    /// Whether the live pipeline is currently latched.
    public var isLatched: Bool { pipeline.isLatched }

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

        // V4.7 — key-down → first buffer, once per turn. `start(for:)` is called on key-down, so its
        // entry is the closest point to the press this layer can see.
        let pressedAt = DispatchTime.now().uptimeNanoseconds
        let describing = pipeline.source as? any CaptureGraphDescribing
        let events = pipeline.events()
        forwarder = Task.detached(priority: .userInteractive) { [weak self] in
            var awaitingFirstBuffer = true
            for await event in events {
                guard let self else { return }
                switch event {
                case .audio(let samples, _):
                    if awaitingFirstBuffer {
                        awaitingFirstBuffer = false
                        let ms = Double(DispatchTime.now().uptimeNanoseconds &- pressedAt) / 1_000_000
                        let graph = describing.map { $0.diagnostics.lastStartWasWarm ? "warm" : "cold" } ?? "n/a"
                        Log.engine.info("audio: key-down → first buffer \(String(format: "%.0f", ms)) ms (\(owner.rawValue), graph=\(graph), device=\(self.deviceName ?? "-"))")
                    }
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
                case .vad(let event):
                    self.onVAD?(event)
                case .endpoint(let decision):
                    self.onEndpoint?(decision)
                case .chunk(let chunk):
                    self.onChunk?(chunk)
                case .started, .overrun:
                    // No consumer yet. Listed rather than `default:` so a new pipeline event is a
                    // compile error here instead of another silently dropped signal.
                    break
                case .stopped:
                    return
                }
            }
        }

        // `AudioSource.start()` is synchronous; run the async pipeline start on the pool and
        // wait briefly so errors (no device, engine start failure) still propagate to the engine.
        // V4.10 — how briefly depends on the device: a Bluetooth or Continuity mic legitimately
        // takes seconds to open, a built-in one does not.
        let budget = startTimeout
        let box = ErrorBox()
        let attempt = StartAttempt()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInteractive) { [weak self, pipeline] in
            do { try await pipeline.start() } catch { box.error = error }
            done.signal()
            // A start that outlived its budget and then succeeded has opened a microphone nobody
            // owns — the indicator would stay lit behind an error. Close it again unless another
            // owner took the graph in the meantime.
            guard attempt.finish(), box.error == nil, self?.currentOwner == nil else { return }
            Log.engine.notice("audio source: a start that ran out of budget finished late; closing the unowned capture")
            await pipeline.stop()
        }
        if done.wait(timeout: .now() + budget) == .timedOut, attempt.abandon() {
            // Reporting success for a pipeline that never started is what let the mic check show a
            // dead meter under a "listening" label. A timeout is a start failure — and it names the
            // device (A03), because "start timed out" never said which microphone was slow.
            let device = startDeviceLabel()
            Log.engine.error("audio pipeline start timed out after \(budget)s on \(device)")
            lock.withLock { self.owner = nil }
            forwarder?.cancel()
            throw AudioCaptureError.startTimedOut(device: device, seconds: budget)
        }
        if let error = box.error {
            lock.withLock { self.owner = nil }
            forwarder?.cancel()
            throw error
        }
    }

    /// V4.10 start budgets. Built-in opens in well under a second; USB and wired display audio in a
    /// couple; Bluetooth (SCO negotiation), Continuity (reported as `.other`), virtual and aggregate
    /// devices can take several. Unknown gets the generous one.
    public static func budget(for transport: AudioDeviceInfo.Transport?) -> TimeInterval {
        switch transport {
        case .builtIn?: return 3
        case .usb?, .displayPort?: return 5
        case .bluetooth?, .virtual?, .aggregate?, .other?, nil: return 8
        }
    }

    /// What `--mic-selftest` waits: wide on purpose, so a slow device is diagnosed, not truncated.
    public static let selfTestBudget: TimeInterval = 15

    /// The transport of the device about to open: the resolved one when the graph exists (the
    /// launch warm-up makes that the normal case), else the system default input.
    private func startTransport() -> AudioDeviceInfo.Transport? {
        pipeline.source.device?.transport ?? AudioDeviceEnumerator.defaultInputDevice()?.transport
    }

    private func startDeviceLabel() -> String {
        pipeline.source.device?.name ?? AudioDeviceEnumerator.defaultInputDevice()?.name ?? "The microphone"
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

    /// Ends the pipeline's run. The capture source underneath keeps its graph paused between turns
    /// (V4.7); `release(reason:)` on the source is the full teardown. The owner slot is the caller's
    /// business.
    private func stopGraph() {
        let forwarder = self.forwarder
        self.forwarder = nil
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInteractive) { [pipeline] in
            await pipeline.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.stopTimeout)
        // G0.2 handoff: `pipeline.stop()` returns with the run's last events (the final VAD end, the
        // tail chunk, an endpoint, `.stopped`) still queued for the forwarder. Cancelling at once
        // dropped them; let it drain to `.stopped` instead. Bounded, because a pipeline that was not
        // running sends no `.stopped` and must not hold the caller.
        if let forwarder {
            let drained = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInteractive) {
                await forwarder.value
                drained.signal()
            }
            if drained.wait(timeout: .now() + Self.drainTimeout) == .timedOut { forwarder.cancel() }
        }
    }

    static let stopTimeout: TimeInterval = 3
    static let drainTimeout: TimeInterval = 0.5

    static var microphoneAuthorized: Bool {
        if ProcessInfo.processInfo.environment["VOICEPLUS_MOCK_PERMISSIONS"] == "1" { return true }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// One start's race against its budget: exactly one of "returned" and "given up" wins.
    private final class StartAttempt: @unchecked Sendable {
        private enum State { case pending, finished, abandoned }
        private let lock = NSLock()
        private var state = State.pending
        /// The start returned. True when the caller had already given up on it.
        func finish() -> Bool {
            lock.withLock {
                let abandoned = state == .abandoned
                if state == .pending { state = .finished }
                return abandoned
            }
        }
        /// The caller gives up. False when the start returned just in time; its result then stands.
        func abandon() -> Bool {
            lock.withLock {
                guard state == .pending else { return false }
                state = .abandoned
                return true
            }
        }
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
