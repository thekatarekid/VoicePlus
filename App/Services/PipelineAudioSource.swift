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

    /// V5 O1 — consumers that *keep* audio rather than own an utterance: the meeting mic leg and the
    /// ambient timeline (V5 §O2 "recorders"). A recorder never pre-empts an `Owner` and is never
    /// pre-empted by one; it only keeps the one capture graph running and holds its own
    /// `AudioPipeline.Subscription`. Dictation that starts while a recorder runs **joins** the
    /// running graph (no restart, no gap in the recording); dictation that ends leaves it running.
    public enum Recorder: String, Sendable, CaseIterable {
        case meeting
        case ambient
    }

    private let lock = NSLock()
    /// Serialises every graph transition (owner start/stop, recorder attach/detach). Recursive so a
    /// callback fired inside a transition (`onPreempted`) may itself stop an owner.
    private let transition = NSRecursiveLock()
    private var forwarder: Task<Void, Never>?
    private var forwarderSubscription: AudioPipeline.Subscription?
    private var owner: Owner?
    /// V5 O1 — attached recorders, by subscription id (guarded by `lock`).
    private var recorders: [UUID: Recorder] = [:]
    /// This bridge has the pipeline running (guarded by `lock`).
    private var graphRunning = false
    /// The owner that was displaced by a higher-ranked `start()`, so a meter can say "dictation took
    /// the microphone" instead of silently going flat.
    public var onPreempted: (@Sendable (Owner) -> Void)?

    /// Who currently holds capture, if anyone. Diagnostics / tests.
    public var currentOwner: Owner? { lock.withLock { owner } }

    /// V5 O1 — the recorders currently attached (sorted, one entry per attachment).
    public var activeRecorders: [Recorder] {
        lock.withLock { recorders.values.sorted { $0.rawValue < $1.rawValue } }
    }

    /// V5 O1 — anyone (an owner or a recorder) holds the capture graph.
    public var isCapturing: Bool { lock.withLock { owner != nil || !recorders.isEmpty } }

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
    /// The outcomes, none of them silent:
    /// * nobody holds the graph → a fresh start (ring cleared, VAD reset, utterance tap reset);
    /// * a lower-or-equal-ranked owner holds it → it is torn down completely and restarted for the
    ///   new owner, who therefore gets a stream configured for *its* utterance, not an inherited one;
    /// * a higher-ranked owner holds it → `AudioCaptureError.busy`, so the caller can say so;
    /// * V5 O1 — a recorder keeps the graph running → the owner joins it: its own subscription, an
    ///   empty utterance tap and a re-armed endpointer, but no restart (that would cut the recording).
    public func start(for owner: Owner) throws {
        if requireMicrophonePermission, let refusal = Self.authorizationRefusal() { throw refusal }
        transition.lock(); defer { transition.unlock() }
        let (displaced, shared): (Owner?, Bool) = try lock.withLock {
            if let current = self.owner {
                guard owner.rank >= current.rank else { throw AudioCaptureError.busy(owner: current.rawValue) }
                return (current, !recorders.isEmpty)
            }
            return (nil, !recorders.isEmpty)
        }
        if let displaced {
            if shared {
                // Recorders keep the graph: the displaced owner just loses its stream.
                Log.engine.notice("audio source: \(owner.rawValue) takes capture from \(displaced.rawValue); recorders keep the graph running")
                lock.withLock { self.owner = nil }
                detachForwarder()
            } else {
                // Never inherit somebody else's running graph. Restarting is what guarantees the
                // recognizer is fed a stream with a cleared ring, a reset VAD and an empty utterance tap.
                Log.engine.notice("audio source: \(owner.rawValue) takes capture from \(displaced.rawValue); restarting the graph")
                stopGraph()
            }
            onPreempted?(displaced)
        }
        lock.withLock { self.owner = owner }
        utteranceTap?.reset()
        startForwarder(for: owner)

        if lock.withLock({ graphRunning }) && pipeline.isRunning {
            pipeline.rearmEndpointer()
            Log.engine.info("audio source: \(owner.rawValue) joins the running capture (recorders: \(activeRecorders.map(\.rawValue).joined(separator: ",")))")
            return
        }
        do {
            try startGraph()
        } catch {
            lock.withLock { self.owner = nil }
            cancelForwarder()
            throw error
        }
    }

    /// The owner's forwarder: pipeline events → `sink` and the side-channel callbacks.
    private func startForwarder(for owner: Owner) {
        // V4.7 — key-down → first buffer, once per turn. `start(for:)` is called on key-down, so its
        // entry is the closest point to the press this layer can see.
        let pressedAt = DispatchTime.now().uptimeNanoseconds
        let describing = pipeline.source as? any CaptureGraphDescribing
        let subscription = pipeline.subscribe()
        let events = subscription.events
        let task = Task.detached(priority: .userInteractive) { [weak self] in
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
        lock.withLock {
            forwarder = task
            forwarderSubscription = subscription
        }
    }

    private func cancelForwarder() {
        let (task, subscription) = lock.withLock { () -> (Task<Void, Never>?, AudioPipeline.Subscription?) in
            defer { forwarder = nil; forwarderSubscription = nil }
            return (forwarder, forwarderSubscription)
        }
        subscription?.cancel()
        task?.cancel()
    }

    /// Starts the pipeline inside the device's start budget.
    private func startGraph() throws {
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
            // owner (or a recorder) took the graph in the meantime.
            guard attempt.finish(), box.error == nil, self?.isCapturing != true else { return }
            Log.engine.notice("audio source: a start that ran out of budget finished late; closing the unowned capture")
            await pipeline.stop()
        }
        if done.wait(timeout: .now() + budget) == .timedOut, attempt.abandon() {
            // Reporting success for a pipeline that never started is what let the mic check show a
            // dead meter under a "listening" label. A timeout is a start failure — and it names the
            // device (A03), because "start timed out" never said which microphone was slow.
            let device = startDeviceLabel()
            Log.engine.error("audio pipeline start timed out after \(budget)s on \(device)")
            throw AudioCaptureError.startTimedOut(device: device, seconds: budget)
        }
        if let error = box.error { throw error }
        lock.withLock { graphRunning = true }
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
    ///
    /// V5 O1 — while a recorder is attached the graph keeps running: the owner's stream is drained
    /// up to now and ended, and nothing else changes.
    public func stop(for owner: Owner) {
        transition.lock(); defer { transition.unlock() }
        let (mine, shared) = lock.withLock { () -> (Bool, Bool) in
            guard self.owner == owner else { return (false, false) }
            self.owner = nil
            return (true, !recorders.isEmpty)
        }
        guard mine else { return }
        if shared { detachForwarder() } else { stopGraph() }
    }

    // MARK: Recorders — V5 O1

    /// Attaches a recorder to the one capture graph, starting it if nobody holds it. The returned
    /// subscription carries every pipeline event from now on; hand it back to `detachRecorder(_:)`.
    /// Never pre-empts an owner and is never refused because one holds the graph.
    public func attachRecorder(_ recorder: Recorder) throws -> AudioPipeline.Subscription {
        if requireMicrophonePermission, let refusal = Self.authorizationRefusal() { throw refusal }
        transition.lock(); defer { transition.unlock() }
        let subscription = pipeline.subscribe()
        let alreadyRunning = lock.withLock { () -> Bool in
            recorders[subscription.id] = recorder
            return graphRunning
        }
        if !(alreadyRunning && pipeline.isRunning) {
            do {
                try startGraph()
            } catch {
                lock.withLock { recorders[subscription.id] = nil }
                subscription.cancel()
                throw error
            }
        }
        Log.engine.info("audio source: recorder \(recorder.rawValue) attached (owner: \(currentOwner?.rawValue ?? "none"), joined running graph: \(alreadyRunning))")
        return subscription
    }

    /// Detaches a recorder. The last claim to leave stops the graph (its stream then ends with
    /// `.stopped`); otherwise the recorder's stream is drained up to now and ended.
    public func detachRecorder(_ subscription: AudioPipeline.Subscription) {
        transition.lock(); defer { transition.unlock() }
        let (removed, unclaimed) = lock.withLock { () -> (Recorder?, Bool) in
            let r = recorders.removeValue(forKey: subscription.id)
            return (r, owner == nil && recorders.isEmpty)
        }
        guard let removed else { subscription.cancel(); return }
        if unclaimed {
            stopGraph()
        } else {
            drainPipeline()
        }
        subscription.cancel()
        Log.engine.info("audio source: recorder \(removed.rawValue) detached (graph \(unclaimed ? "stopped" : "kept for \(currentOwner?.rawValue ?? "recorders")"))")
    }

    /// The owner leaves a graph recorders keep running: everything captured so far reaches it, then
    /// its stream ends and its forwarder finishes. Bounded like `stopGraph()`.
    private func detachForwarder() {
        let (task, subscription) = lock.withLock { () -> (Task<Void, Never>?, AudioPipeline.Subscription?) in
            defer { forwarder = nil; forwarderSubscription = nil }
            return (forwarder, forwarderSubscription)
        }
        drainPipeline()
        subscription?.cancel()
        if let task {
            let drained = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInteractive) {
                await task.value
                drained.signal()
            }
            if drained.wait(timeout: .now() + Self.drainTimeout) == .timedOut { task.cancel() }
        }
    }

    /// Processes every sample already in the ring so it has been published to subscribers. Only
    /// while running: a stopped pipeline has nothing to drain (and its drain would never return).
    private func drainPipeline() {
        guard pipeline.isRunning else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInteractive) { [pipeline] in
            await pipeline.drain()
            done.signal()
        }
        _ = done.wait(timeout: .now() + Self.stopTimeout)
    }

    /// Ends the pipeline's run. The capture source underneath keeps its graph paused between turns
    /// (V4.7); `release(reason:)` on the source is the full teardown. The owner slot is the caller's
    /// business.
    private func stopGraph() {
        let forwarder = lock.withLock { () -> Task<Void, Never>? in
            defer { self.forwarder = nil; forwarderSubscription = nil; graphRunning = false }
            return self.forwarder
        }
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
        // Q10 — the live probe, not a launch-time answer.
        return MicrophoneStatusProbe.shared.probe(.tick) == .authorized
    }

    /// What a `start()` should do about the current TCC answer. Pure, so the mapping is testable
    /// without a microphone — `AVCaptureDevice.authorizationStatus` is read by the caller.
    ///
    /// The whole point is the asymmetry that used to be flattened. Until now every non-authorized
    /// answer threw `.noInputDevice`, which the recovery catalogue reads as A01 "No microphone
    /// found" — sending a user whose microphone is fine and whose *grant* is missing off to look at
    /// their hardware. And `.notDetermined` was a dead end for ever, because nothing on the capture
    /// path ever asked for the grant.
    public enum AuthorizationDecision: Equatable, Sendable {
        /// Open the microphone.
        case proceed
        /// Refuse, and ask macOS for the grant first: this is the one state a prompt can resolve.
        case requestThenRefuse
        /// Refuse. Only System Settings can change this.
        case refuse
    }

    public static func decide(_ status: AVAuthorizationStatus) -> AuthorizationDecision {
        switch status {
        case .authorized: return .proceed
        case .notDetermined: return .requestThenRefuse
        // `.denied`, `.restricted` (MDM / Screen Time), and anything Apple adds later.
        default: return .refuse
        }
    }

    public static func label(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "granted"
        case .notDetermined: return "not requested yet"
        case .denied: return "turned off"
        case .restricted: return "blocked by a profile on this Mac"
        @unknown default: return "unavailable"
        }
    }

    /// nil when capture may open; otherwise the error to throw, which classifies to P01
    /// "Microphone access is off" rather than A01 "No microphone found".
    static func authorizationRefusal(probe: MicrophoneStatusProbe = .shared) -> AudioCaptureError? {
        if ProcessInfo.processInfo.environment["VOICEPLUS_MOCK_PERMISSIONS"] == "1" { return nil }
        // Q10 — re-read before refusing; a stale `.denied` overridden by a fresh capture proceeds,
        // and a fresh denial refuses on this very call.
        let status = probe.probe(.beforeRefusal)
        switch decide(status) {
        case .proceed:
            return nil
        case .requestThenRefuse:
            // This press cannot be served — the prompt is asynchronous and the user has to answer
            // it — but the *next* one can. Asking here is also the only call that ever puts
            // VoicePlus into Privacy & Security › Microphone at all.
            Log.app.notice("audio source: microphone access has never been requested; asking macOS now")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.app.notice("audio source: microphone access \(granted ? "granted" : "refused")")
            }
            return .notPermitted(status: label(for: status))
        case .refuse:
            return .notPermitted(status: label(for: status))
        }
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

/// V5 O1 — an `AudioCaptureSource` over a recorder subscription to the app's one capture graph, so
/// a consumer written against "a microphone" (`DualCapture(mic:)`) needs no change and opens no
/// second HAL client. `start()` attaches a recorder to `PipelineAudioSource` (starting the shared
/// graph only if nobody holds it); `stop()` detaches it (stopping the graph only if it was the last
/// claim). The graph's device, route changes and teardown stay the shared graph's business: this
/// adapter never switches or releases the device under dictation.
public final class SharedMicrophoneSource: AudioCaptureSource, @unchecked Sendable {
    public var sink: ((UnsafeBufferPointer<Float>) -> Void)?
    public var onDeviceChanged: ((AudioDeviceInfo?, AudioDeviceInfo?) -> Void)?
    public let recorder: PipelineAudioSource.Recorder
    /// Resolved at `start()`: the app swaps its pipeline when a model lands, and a meeting started
    /// later must join the graph that exists *then*.
    private let resolve: () -> PipelineAudioSource?
    private let lock = NSLock()
    private var attached: (audio: PipelineAudioSource, subscription: AudioPipeline.Subscription)?
    private var pump: Task<Void, Never>?

    public init(recorder: PipelineAudioSource.Recorder, audio: @escaping () -> PipelineAudioSource?) {
        self.recorder = recorder
        self.resolve = audio
    }

    public convenience init(_ audio: PipelineAudioSource, recorder: PipelineAudioSource.Recorder) {
        self.init(recorder: recorder, audio: { audio })
    }

    public var device: AudioDeviceInfo? {
        (lock.withLock { attached?.audio } ?? resolve())?.pipeline.source.device
    }

    /// Whether this adapter currently holds a recorder claim.
    public var isAttached: Bool { lock.withLock { attached != nil } }

    /// The shared graph is prepared by the app (V4.7 launch warm-up); nothing to build here.
    public func prewarm() throws {}

    public func start() throws {
        guard !isAttached else { return }
        guard let audio = resolve() else { throw AudioCaptureError.noInputDevice }
        let subscription = try audio.attachRecorder(recorder)
        let events = subscription.events
        let task = Task.detached(priority: .userInteractive) { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .audio(let samples, _):
                    samples.withUnsafeBufferPointer { self.sink?($0) }
                case .deviceChanged(let from, let to):
                    self.onDeviceChanged?(from, to)
                case .stopped:
                    return
                default:
                    break
                }
            }
        }
        lock.withLock {
            attached = (audio, subscription)
            pump = task
        }
    }

    /// Detaches, then waits (bounded) until every sample already published has reached `sink`, so a
    /// caller that drains right after `stop()` (`DualCapture.stop()`) gets the tail.
    public func stop() {
        let (claim, task) = lock.withLock { () -> ((audio: PipelineAudioSource, subscription: AudioPipeline.Subscription)?, Task<Void, Never>?) in
            defer { attached = nil; pump = nil }
            return (attached, pump)
        }
        guard let claim else { return }
        claim.audio.detachRecorder(claim.subscription)
        guard let task else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInteractive) {
            await task.value
            done.signal()
        }
        if done.wait(timeout: .now() + PipelineAudioSource.drainTimeout) == .timedOut { task.cancel() }
    }

    /// The device is the shared graph's; a recorder never re-points dictation's microphone.
    public func switchDevice(to device: AudioDeviceInfo?) throws {}

    /// Never tears the shared graph down: a recorder only lets go of its claim.
    public func release(reason: CaptureReleaseReason) { stop() }
}
