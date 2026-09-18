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
    /// Latched-mode endpoint decision (only when `AudioPipeline.Options.latched`).
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
        public var latched = false
        public var endpointer = Endpointer()
        /// Ring capacity in seconds of 16 kHz audio.
        public var ringSeconds: Double = 30
        /// How long after a successful `start()` to wait for the first audio block before calling
        /// the capture broken and emitting `.captureFailed`. 0 disables the watchdog.
        /// A working built-in mic delivers its first ~50 ms block well inside this window.
        public var noAudioTimeout: TimeInterval = 2.0
        public init() {}
    }

    public let source: any AudioCaptureSource
    public let vad: any VADProtocol
    public let options: Options
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
    /// Live latch flag (guarded by `stateLock`). `options.latched` is only its initial value.
    private var latched: Bool

    /// Whether the endpointer is currently driven (`.endpoint` events emitted).
    public var isLatched: Bool { stateLock.withLock { latched } }

    /// G0.2 — flips `Options.latched` on a live pipeline, without restarting capture. Takes effect
    /// from the next processed audio block. The endpointer's speech/silence bookkeeping runs
    /// regardless, so latching mid-utterance endpoints from the real speech history.
    public func setLatched(_ on: Bool) { stateLock.withLock { latched = on } }

    // processing state (touched only by the worker task)
    private var chunker: Chunker
    private var endpointer: Endpointer
    private let micQuality = MicQualityAnalyzer()
    private var vadPending: [Float] = []
    private var position = 0          // 16k samples delivered
    private var vadPosition = 0       // samples fed to VAD
    private(set) public var totalSamples = 0
    private(set) public var lastMicQuality: MicQuality?

    public init(source: any AudioCaptureSource, vad: any VADProtocol, options: Options = Options()) {
        self.source = source
        self.vad = vad
        self.options = options
        self.ring = RingBuffer(capacity: Int(options.ringSeconds * 16_000))
        self.chunker = Chunker(minDuration: options.chunkMin, maxDuration: options.chunkMax)
        self.endpointer = options.endpointer
        self.latched = options.latched
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
        chunker.reset(); endpointer.reset(); micQuality.reset()
        vadPending.removeAll(); position = 0; vadPosition = 0; totalSamples = 0; lastMicQuality = nil; lastOverruns = 0
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
        for s in samples { acc += s * s }
        broadcaster.send(.level(rms: (acc / Float(samples.count)).squareRoot()))

        if let q = micQuality.feed(samples) { lastMicQuality = q; broadcaster.send(.micQuality(q)) }

        for chunk in chunker.feed(samples) { broadcaster.send(.chunk(chunk)) }

        vadPending.append(contentsOf: samples)
        while vadPending.count >= vad.frameSize {
            let frame = Array(vadPending[0..<vad.frameSize])
            vadPending.removeFirst(vad.frameSize)
            vadPosition += vad.frameSize
            await runVAD(frame)
        }
        let now = Double(position) / 16_000
        if isLatched, let d = endpointer.tick(now: now) { broadcaster.send(.endpoint(d)) }
    }

    private func runVAD(_ frame: [Float]) async {
        guard let step = try? await vad.process(frame: frame), let event = step.event else { return }
        broadcaster.send(.vad(event))
        switch event {
        case .speechStart(let t): endpointer.speechStarted(at: t)
        case .speechEnd(let t):
            endpointer.speechEnded(at: t)
            if let chunk = chunker.markSpeechEnd() { broadcaster.send(.chunk(chunk)) }
        }
    }

    private func finishProcessing() async {
        if !vadPending.isEmpty {
            var frame = vadPending
            frame.append(contentsOf: [Float](repeating: 0, count: vad.frameSize - frame.count))
            vadPending.removeAll()
            await runVAD(frame)
        }
        if lastMicQuality == nil, let q = micQuality.flush() { lastMicQuality = q; broadcaster.send(.micQuality(q)) }
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
