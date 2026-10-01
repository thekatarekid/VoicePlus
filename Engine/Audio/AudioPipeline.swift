import Foundation
import Shared

/// Everything downstream (P1.3 ASR, P1.4 acoustic, the pill) sees from audio. FROZEN — add cases
/// only; never rename or change payloads. See Engine/Audio/README.md.
public enum AudioPipelineEvent: Equatable, Sendable {
    case started(device: AudioDeviceInfo?)
    /// 16 kHz mono samples as they arrive (≈50 ms blocks). `position` = seconds since start.
    case audio(samples: [Float], position: TimeInterval)
    case level(rms: Float)
    case micQuality(MicQuality)
    case vad(VADEvent)
    /// 3–5 s chunk ready for ASR.
    case chunk(AudioChunk)
    /// Latched-mode endpoint decision. Emitted only while the pipeline is latched (`isLatched`,
    /// set by `Options.latched` at init and by `setLatched(_:)` live). While latched the endpointer
    /// re-arms after every decision, so one capture yields one decision per segment.
    case endpoint(Endpointer.Decision)
    case deviceChanged(from: AudioDeviceInfo?, to: AudioDeviceInfo?)
    /// Ring-buffer overrun: `dropped` samples lost since last report.
    case overrun(dropped: Int)
    /// Capture reported success but produced nothing: the no-audio watchdog fired, or a start
    /// failed after `.started` was announced. Added in 1.6.4 — a silent meter must be an error.
    case captureFailed(reason: String)
    case stopped(totalSamples: Int)
}

/// Capture → ring buffer → 16 kHz stream → {mic quality, level, VAD, chunker, endpointer}.
/// One instance per utterance lifecycle; `start()`/`stop()` may be called repeatedly.
public final class AudioPipeline: @unchecked Sendable {
    public struct Options: Sendable {
        public var chunkMin: TimeInterval = 3.0
        public var chunkMax: TimeInterval = 5.0
        /// Latch mode (V3 §4.7): drive `Endpointer` so a session can close a segment and keep
        /// listening. Off for a plain hold, where the key release ends the utterance.
        /// The initial value only — `AudioPipeline.setLatched(_:)` changes it live.
        public var latched = false
        /// Bounds for latched endpointing. Its no-speech and segment bounds count from the last
        /// decision, not from `start()`. The initial value only — `setEndpointer(_:)` changes it live.
        public var endpointer = Endpointer()
        /// Ring capacity in seconds of 16 kHz audio.
        public var ringSeconds: Double = 30
        /// How long after a successful `start()` to wait for the first audio block before calling
        /// the capture broken and emitting `.captureFailed`. 0 disables the watchdog.
        /// A working built-in mic delivers its first ~50 ms block well inside this window.
        public var noAudioTimeout: TimeInterval = 2.0
        /// How long a capture may deliver nothing but bit-exact-zero samples before it is called
        /// broken (`CaptureSilenceWatchdog`). `noAudioTimeout` covers "no blocks at all"; this
        /// covers the far commoner macOS failure where the blocks arrive and are all silence —
        /// a revoked microphone grant, a muted input, a tap the engine reconfigured out from under
        /// us. 0 disables it. Only ever fires when *no* non-zero sample was seen in the capture.
        public var digitalSilenceTimeout: TimeInterval = CaptureSilenceWatchdog.defaultTimeout
        /// V5 C1 — audio after `start()` that level-based mic-quality warnings ignore (the floor
        /// estimates skip it). 0.3 s under Apple voice processing, whose AGC is still adapting
        /// (`CaptureGraphPlan`); 0 for the plain tap.
        public var levelWarmup: TimeInterval = 0
        /// V5 C1 — log the AGC's adaptation time once per capture (`AGCAdaptationTracker`).
        public var tracksAGC = false
        public init() {}
    }

    public let source: any AudioCaptureSource
    public let vad: any VADProtocol
    /// The options as they stand **now**: `latched` and `endpointer` are the live values
    /// (`setLatched(_:)`, `setEndpointer(_:)`), everything else is what the pipeline was built with.
    /// B1 reconciles the two answers G0.2 left behind (`options.latched` used to keep returning the
    /// initial value while `isLatched` had moved on).
    public var options: Options {
        stateLock.withLock {
            var live = initialOptions
            live.latched = latched
            live.endpointer = endpointerConfig
            return live
        }
    }
    private let initialOptions: Options
    private let ring: RingBuffer
    private let broadcaster = Broadcaster()
    private let semaphore = DispatchSemaphore(value: 0)
    private var pump: Thread?
    private var worker: Task<Void, Never>?
    private var frameContinuation: AsyncStream<[Float]>.Continuation?
    private let stateLock = NSLock()
    private var running = false
    private var lastOverruns = 0
    private var sawAudio = false
    private var watchdog: DispatchWorkItem?
    /// Live latch flag (guarded by `stateLock`). `Options.latched` is only its initial value.
    private var latched: Bool
    /// Live endpointer configuration (guarded by `stateLock`); the worker adopts it at the next block.
    private var endpointerConfig: Endpointer
    private var endpointerConfigPending = false
    /// Set when latch is left: the worker re-arms the endpointer at the next block (guarded by `stateLock`).
    private var endpointerRearmPending = false

    /// Whether the endpointer is currently driven (`.endpoint` events emitted).
    public var isLatched: Bool { stateLock.withLock { latched } }

    /// G0.2 — flips `Options.latched` on a live pipeline, without restarting capture. Takes effect
    /// from the next processed audio block. The endpointer's speech/silence bookkeeping runs
    /// regardless, so latching mid-utterance endpoints from the real speech history.
    ///
    /// B1 — leaving latch (`true` → `false`) also re-arms the endpointer from the next block, so a
    /// later latch in the same capture starts from a clean segment rather than a spent decision.
    public func setLatched(_ on: Bool) {
        stateLock.withLock {
            if latched && !on { endpointerRearmPending = true }
            latched = on
        }
    }

    /// B2 — replaces the latched endpointer's bounds (trailing silence, no-speech timeout, segment
    /// bound) on a live pipeline. Adopted at the next processed block; the speech heard so far is
    /// kept, so changing the pause mid-segment re-times that segment instead of dropping it.
    public func setEndpointer(_ endpointer: Endpointer) {
        stateLock.withLock {
            endpointerConfig = endpointer
            endpointerConfigPending = true
        }
    }

    // processing state (touched only by the worker task)
    private var chunker: Chunker
    private var endpointer: Endpointer
    /// Stream time the endpointer's no-speech and segment bounds count from (worker only).
    private var endpointArmedAt: TimeInterval = 0
    /// A `.noSpeech` was reported; the endpointer re-arms when speech is next heard (worker only).
    private var endpointAwaitingSpeech = false
    private let micQuality = MicQualityAnalyzer()
    /// Worker-only, like `chunker`: blocks are processed strictly in order, so it needs no lock.
    private var silence: CaptureSilenceWatchdog
    /// V5 C1 — worker-only, like `silence`. Fed only when `Options.tracksAGC`.
    private var agc = AGCAdaptationTracker()
    /// The AGC outcome of the last capture (nil until decided or when not tracked).
    private(set) public var lastAGCOutcome: AGCAdaptationTracker.Outcome?
    private var vadPending: [Float] = []
    private var position = 0          // 16k samples delivered
    private var vadPosition = 0       // samples fed to VAD
    private(set) public var totalSamples = 0
    private(set) public var lastMicQuality: MicQuality?
    /// What `lastMicQuality` was computed from (floor, signal, floor source): diagnostics for the Lab
    /// and tests. Set with it, on the worker; read it after `stop()`.
    private(set) public var lastMicMeasurement: MicQualityAnalyzer.Measurement?

    public init(source: any AudioCaptureSource, vad: any VADProtocol, options: Options = Options()) {
        self.source = source
        self.vad = vad
        self.initialOptions = options
        self.ring = RingBuffer(capacity: Int(options.ringSeconds * 16_000))
        self.chunker = Chunker(minDuration: options.chunkMin, maxDuration: options.chunkMax)
        self.endpointer = options.endpointer
        self.latched = options.latched
        self.endpointerConfig = options.endpointer
        self.silence = CaptureSilenceWatchdog(timeout: options.digitalSilenceTimeout)
        self.micQuality.warmup = options.levelWarmup
    }

    /// Fresh stream per call; every event after subscribing is delivered in order.
    public func events() -> AsyncStream<AudioPipelineEvent> { broadcaster.subscribe() }

    /// Just the 16 kHz audio, for consumers that do their own analysis.
    public func audioBuffers() -> AsyncStream<[Float]> {
        let events = broadcaster.subscribe()
        return AsyncStream { cont in
            let t = Task {
                for await e in events {
                    if case .audio(let s, _) = e { cont.yield(s) }
                    if case .stopped = e { break }
                }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    /// Open the device, prepare converters, load VAD state. Idempotent; call on hotkey-down.
    public func prewarm() async throws {
        try source.prewarm()
        await vad.reset()
    }

    public func start() async throws {
        guard setRunning(true) else { return }
        resetProcessing()
        // Stream time restarts at 0: the endpointer's bounds count from here, with the live config.
        rearmEndpointer(stateLock.withLock { () -> Endpointer in
            endpointerConfigPending = false
            endpointerRearmPending = false
            return endpointerConfig
        }, at: 0)
        await vad.reset()
        ring.clear()

        let (stream, cont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        frameContinuation = cont
        worker = Task { [weak self] in
            guard let self else { return }
            for await frame in stream { await self.process(frame) }
            await self.finishProcessing()
        }

        source.sink = { [weak self, ring, semaphore] buf in
            ring.write(buf)
            semaphore.signal()
            self?.noteAudioArrived()
        }
        source.onDeviceChanged = { [weak self] old, new in
            self?.broadcaster.send(.deviceChanged(from: old, to: new))
        }
        let pumpThread = Thread { [weak self] in self?.pumpLoop() }
        pumpThread.name = "voiceplus.audio.pump"
        pumpThread.qualityOfService = .userInteractive
        pump = pumpThread
        pumpThread.start()

        do {
            // Prewarm first so `source.device` is resolved before we announce it. Wrapped sources
            // (`AcousticCaptureSource`) forward `inner.device`, which is nil until the inner source
            // has opened the HAL — which is why every `.started` used to report device=nil.
            try source.prewarm()
            broadcaster.send(.started(device: source.device))
            try source.start()
        } catch {
            broadcaster.send(.captureFailed(reason: Self.reason(for: error)))
            await unwindFailedStart()
            throw error
        }
        armNoAudioWatchdog()
    }

    /// A start that threw must not leave the pump thread and worker task running behind a
    /// pipeline that reports itself stopped.
    private func unwindFailedStart() async {
        guard setRunning(false) else { return }
        cancelWatchdog()
        source.sink = nil
        semaphore.signal()
        await worker?.value
        worker = nil
    }

    static func reason(for error: Error) -> String {
        (error as? AudioCaptureError).map(String.init(describing:)) ?? String(describing: error)
    }

    /// Stops capture, drains everything already captured, emits final chunk + `.stopped`.
    public func stop() async {
        guard setRunning(false) else { return }
        cancelWatchdog()
        source.stop()
        // After `stop()` the source has flushed its tail; dropping the sink stops a late tap
        // callback from writing into a ring nobody is draining any more.
        source.sink = nil
        semaphore.signal()                 // wake pump so it drains and exits
        await worker?.value
        worker = nil
    }

    // MARK: no-audio watchdog

    /// Armed once capture reports success. `AVAudioEngine` happily starts on a graph whose tap can
    /// never fire (1.6.3: pinned device at 48 kHz, node cached at 44.1 kHz), so "started" is not
    /// evidence of audio — the first block is.
    private func armNoAudioWatchdog() {
        let window = options.noAudioTimeout
        guard window > 0 else { return }
        stateLock.lock()
        // Audio can already have arrived inside `source.start()` (fixture replay, pre-roll flush).
        let already = sawAudio
        let item = already ? nil : DispatchWorkItem { [weak self] in self?.reportNoAudio(after: window) }
        if let item { watchdog?.cancel(); watchdog = item }
        stateLock.unlock()
        guard let item else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + window, execute: item)
    }

    private func cancelWatchdog() {
        stateLock.lock(); let item = watchdog; watchdog = nil; stateLock.unlock()
        item?.cancel()
    }

    private func noteAudioArrived() {
        stateLock.lock()
        let first = !sawAudio
        sawAudio = true
        let item = first ? watchdog : nil
        if first { watchdog = nil }
        stateLock.unlock()
        item?.cancel()
    }

    private func reportNoAudio(after window: TimeInterval) {
        stateLock.lock()
        let silent = running && !sawAudio
        watchdog = nil
        stateLock.unlock()
        guard silent else { return }
        let device = source.device?.name ?? "the selected input"
        let reason = "No sound is reaching VoicePlus. Capture started on \(device) but not one audio block arrived in \(String(format: "%.1f", window))s."
        Log.engine.error("audio: \(reason)")
        broadcaster.send(.captureFailed(reason: reason))
    }

    /// Blocks arrived and every sample in them was bit-exact zero: the stream is open and silenced.
    /// Reported on the same `.captureFailed` channel as "no blocks at all" — both are the design's
    /// A05, "recorder opens but receives no samples" — so one consumer covers both.
    private func reportDigitalSilence(after seconds: TimeInterval) {
        stateLock.lock(); let live = running; stateLock.unlock()
        guard live else { return }
        let device = source.device?.name ?? "the selected input"
        let reason = CaptureSilenceWatchdog.reason(device: device, seconds: seconds)
        Log.engine.error("audio: \(reason)")
        broadcaster.send(.captureFailed(reason: reason))
    }

    /// Waits until every sample pushed so far has been processed. Test/Lab helper.
    public func drain() async {
        semaphore.signal()
        while ring.available > 0 { await Task.yield() }
        // Queue a sentinel and wait for the worker to reach it.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            drainWaiters.append(c)
            frameContinuation?.yield([])
        }
    }
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Returns false if already in the requested state.
    private func setRunning(_ value: Bool) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard running != value else { return false }
        running = value
        return true
    }

    // MARK: pump (dedicated thread, moves ring → ordered stream)

    private func pumpLoop() {
        while true {
            semaphore.wait()
            let samples = ring.read()
            if !samples.isEmpty { frameContinuation?.yield(samples) }
            let over = ring.overruns
            if over != lastOverruns { broadcaster.send(.overrun(dropped: over - lastOverruns)); lastOverruns = over }
            stateLock.lock(); let r = running; stateLock.unlock()
            if !r {
                let rest = ring.read()
                if !rest.isEmpty { frameContinuation?.yield(rest) }
                frameContinuation?.finish()
                return
            }
        }
    }

    // MARK: processing (worker task, strictly ordered)

    private func resetProcessing() {
        chunker.reset(); endpointer.reset(); micQuality.reset(); silence.reset(); agc.reset(); lastAGCOutcome = nil
        vadPending.removeAll(); position = 0; vadPosition = 0; totalSamples = 0; lastMicQuality = nil; lastMicMeasurement = nil; lastOverruns = 0
        stateLock.lock(); sawAudio = false; stateLock.unlock()
    }

    private func process(_ samples: [Float]) async {
        if samples.isEmpty {           // drain sentinel
            let waiters = drainWaiters; drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        let start = Double(position) / 16_000
        position += samples.count
        totalSamples += samples.count
        broadcaster.send(.audio(samples: samples, position: start))

        var acc: Float = 0
        var anyNonZero = false
        for s in samples {
            acc += s * s
            if s != 0 { anyNonZero = true }
        }
        let rms = (acc / Float(samples.count)).squareRoot()
        broadcaster.send(.level(rms: rms))
        if initialOptions.tracksAGC, let outcome = agc.feed(rms: rms, duration: Double(samples.count) / 16_000) {
            lastAGCOutcome = outcome
            if let line = agc.logLine { Log.engine.info("\(line)") }
        }

        // A capture that is *being silenced* rather than merely quiet. Decided on the same block
        // whose RMS was just published, so the verdict is a function of the audio, not of timing.
        if case .digitalSilence(let seconds) = silence.note(seconds: Double(samples.count) / 16_000,
                                                            allZero: !anyNonZero) {
            reportDigitalSilence(after: seconds)
        }

        for chunk in chunker.feed(samples) { broadcaster.send(.chunk(chunk)) }

        vadPending.append(contentsOf: samples)
        while vadPending.count >= vad.frameSize {
            let frame = Array(vadPending[0..<vad.frameSize])
            vadPending.removeFirst(vad.frameSize)
            vadPosition += vad.frameSize
            // F1 (V4.18): the analyzer grades VAD speech against the pre-speech floor; `runVAD` hands
            // it the events. It is fed one VAD frame at a time, just before the VAD hears that frame,
            // so every event reaches it at the same sample whatever size of block the ring handed
            // over: its verdict is a function of the audio, not of scheduling.
            feedMicQuality(frame)
            await runVAD(frame)
        }
        let now = Double(position) / 16_000
        if let d = latchedEndpoint(now: now) { broadcaster.send(.endpoint(d)) }
    }

    // MARK: latched endpointing (B1/B2, worker only)

    /// Adopts a configuration or re-arm requested from another thread, then ticks the endpointer if
    /// latched. Every latched decision re-arms it from `now`, which is what turns "one decision per
    /// `start()`" into "one decision per segment":
    /// * `.endpoint` — re-armed at once; the next segment starts in silence.
    /// * `.maxDuration` — re-armed at once, still in speech if the speaker is; the words carry on.
    /// * `.noSpeech` — reported once, then re-armed when speech is next heard (not every timeout).
    private func latchedEndpoint(now: TimeInterval) -> Endpointer.Decision? {
        let (on, config, reconfigure, rearm) = stateLock.withLock { () -> (Bool, Endpointer, Bool, Bool) in
            defer { endpointerConfigPending = false; endpointerRearmPending = false }
            return (latched, endpointerConfig, endpointerConfigPending, endpointerRearmPending)
        }
        if rearm {
            rearmEndpointer(config, at: now)
        } else if reconfigure {
            endpointer.trailingSilence = config.trailingSilence
            endpointer.noSpeechTimeout = endpointArmedAt + config.noSpeechTimeout
            endpointer.maxUtterance = endpointArmedAt + config.maxUtterance
        }
        if endpointAwaitingSpeech, endpointer.speechHeard {
            rearmEndpointer(config, at: now, continuingSpeech: endpointer.inSpeech)
        }
        guard on, let decision = endpointer.tick(now: now) else { return nil }
        switch decision {
        case .endpoint: rearmEndpointer(config, at: now)
        case .maxDuration: rearmEndpointer(config, at: now, continuingSpeech: endpointer.inSpeech)
        case .noSpeech: endpointAwaitingSpeech = true
        }
        return decision
    }

    /// A fresh endpointer whose no-speech and segment bounds count from `t`. `Endpointer` compares
    /// its bounds with absolute stream time, so the bounds move rather than the clock — which keeps
    /// `.endpoint(at:)` in stream seconds, as every consumer already reads it.
    private func rearmEndpointer(_ config: Endpointer, at t: TimeInterval, continuingSpeech: Bool = false) {
        var fresh = config
        fresh.reset()
        fresh.noSpeechTimeout = t + config.noSpeechTimeout
        fresh.maxUtterance = t + config.maxUtterance
        if continuingSpeech { fresh.speechStarted(at: t) }
        endpointer = fresh
        endpointArmedAt = t
        endpointAwaitingSpeech = false
    }

    /// Once per capture: the analyzer returns its verdict exactly once.
    private func feedMicQuality(_ samples: [Float]) {
        if let q = micQuality.feed(samples) { publishMicQuality(q) }
    }

    private func publishMicQuality(_ q: MicQuality) {
        lastMicQuality = q
        lastMicMeasurement = micQuality.measurement
        broadcaster.send(.micQuality(q))
    }

    private func runVAD(_ frame: [Float]) async {
        guard let step = try? await vad.process(frame: frame), let event = step.event else { return }
        broadcaster.send(.vad(event))
        micQuality.note(event)             // F1: speech segments and the end of the pre-speech window
        switch event {
        case .speechStart(let t): endpointer.speechStarted(at: t)
        case .speechEnd(let t):
            endpointer.speechEnded(at: t)
            if let chunk = chunker.markSpeechEnd() { broadcaster.send(.chunk(chunk)) }
        }
    }

    private func finishProcessing() async {
        if !vadPending.isEmpty {
            feedMicQuality(vadPending)     // the real tail, not the VAD's zero padding
            var frame = vadPending
            frame.append(contentsOf: [Float](repeating: 0, count: vad.frameSize - frame.count))
            vadPending.removeAll()
            await runVAD(frame)
        }
        if lastMicQuality == nil, let q = micQuality.flush() { publishMicQuality(q) }
        if let chunk = chunker.flush() { broadcaster.send(.chunk(chunk)) }
        broadcaster.send(.stopped(totalSamples: totalSamples))
        let waiters = drainWaiters; drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: fan-out

    final class Broadcaster: @unchecked Sendable {
        private let lock = NSLock()
        private var conts: [UUID: AsyncStream<AudioPipelineEvent>.Continuation] = [:]
        func subscribe() -> AsyncStream<AudioPipelineEvent> {
            let id = UUID()
            return AsyncStream(bufferingPolicy: .unbounded) { c in
                lock.lock(); conts[id] = c; lock.unlock()
                c.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.lock.lock(); self.conts[id] = nil; self.lock.unlock()
                }
            }
        }
        func send(_ e: AudioPipelineEvent) {
            lock.lock(); let targets = Array(conts.values); lock.unlock()
            targets.forEach { $0.yield(e) }
        }
    }
}
