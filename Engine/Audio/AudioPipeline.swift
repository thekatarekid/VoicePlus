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
    /// Hands-free endpoint decision (only when `AudioPipeline.Options.handsFree`).
    case endpoint(Endpointer.Decision)
    case deviceChanged(from: AudioDeviceInfo?, to: AudioDeviceInfo?)
    /// Ring-buffer overrun: `dropped` samples lost since last report.
    case overrun(dropped: Int)
    case stopped(totalSamples: Int)
}

/// Capture → ring buffer → 16 kHz stream → {mic quality, level, VAD, chunker, endpointer}.
/// One instance per utterance lifecycle; `start()`/`stop()` may be called repeatedly.
public final class AudioPipeline: @unchecked Sendable {
    public struct Options: Sendable {
        public var chunkMin: TimeInterval = 3.0
        public var chunkMax: TimeInterval = 5.0
        public var handsFree = false
        public var endpointer = Endpointer()
        /// Ring capacity in seconds of 16 kHz audio.
        public var ringSeconds: Double = 30
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

        source.sink = { [ring, semaphore] buf in
            ring.write(buf)
            semaphore.signal()
        }
        source.onDeviceChanged = { [weak self] old, new in
            self?.broadcaster.send(.deviceChanged(from: old, to: new))
        }
        let pumpThread = Thread { [weak self] in self?.pumpLoop() }
        pumpThread.name = "voiceplus.audio.pump"
        pumpThread.qualityOfService = .userInteractive
        pump = pumpThread
        pumpThread.start()

        broadcaster.send(.started(device: source.device))
        try source.start()
    }

    /// Stops capture, drains everything already captured, emits final chunk + `.stopped`.
    public func stop() async {
        guard setRunning(false) else { return }
        source.stop()
        semaphore.signal()                 // wake pump so it drains and exits
        await worker?.value
        worker = nil
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
        if options.handsFree, let d = endpointer.tick(now: now) { broadcaster.send(.endpoint(d)) }
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
