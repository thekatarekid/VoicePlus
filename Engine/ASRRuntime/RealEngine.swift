import Combine
import Foundation
import Shared

/// Resolves which recognizers an utterance uses. Decoupled so tests inject mocks and so the
/// choice can change between utterances as background downloads land.
public protocol RecognizerProvider: Sendable {
    func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?)
    /// Changes whenever a *different* set of models is on disk, so a cached resolve can be spotted
    /// as stale. Providers with a fixed answer keep the default and are never re-resolved.
    func revision() async -> Int
}

public extension RecognizerProvider {
    func revision() async -> Int { 0 }
}

public struct StaticRecognizerProvider: RecognizerProvider {
    public let final: FinalRecognizer
    public let preview: PreviewRecognizer?
    public init(final: FinalRecognizer, preview: PreviewRecognizer? = nil) { self.final = final; self.preview = preview }
    public func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) { (final, preview) }
}

public struct ModelManagerRecognizerProvider: RecognizerProvider {
    public let manager: ModelManager
    public init(manager: ModelManager) { self.manager = manager }
    public func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?) {
        let final = try await RecognizerFactory.makeFinal(manager: manager)
        return (final, await RecognizerFactory.makePreview(manager: manager, final: final))
    }

    /// A bitmask of which models are on disk. A download that lands mid-session flips a bit, which
    /// is what tells `RealEngine` to throw away a recognizer it resolved before the download —
    /// otherwise the Apple Speech fallback that was chosen at first launch stays in place until the
    /// app is relaunched, and the 1.2 GB the user just waited for does nothing.
    public func revision() async -> Int {
        var mask = 0
        for (bit, id) in ModelID.allCases.enumerated() where await manager.isPresent(id) {
            mask |= 1 << bit
        }
        return mask
    }
}

/// Per-utterance sample store + serialised preview feeding.
actor UtteranceBuffer {
    private(set) var samples: [Float] = []
    private var previewTask: Task<Void, Never>?
    private var lastText = ""

    func append(_ block: [Float]) { samples.append(contentsOf: block) }
    func reset() { samples.removeAll(); lastText = ""; previewTask?.cancel(); previewTask = nil }

    /// Runs preview on `block` after any in-flight preview finishes; calls `onText` only on change.
    func schedulePreview(_ block: [Float], using preview: PreviewRecognizer, onText: @escaping @Sendable (String) -> Void) {
        let previous = previewTask
        previewTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            guard let text = try? await preview.feed(block) else { return }
            if await self.updateText(text) { onText(text) }
        }
    }

    private func updateText(_ text: String) -> Bool {
        guard text != lastText else { return false }
        lastText = text
        return true
    }

    func drain() async { await previewTask?.value }
}

/// Engines that publish captured input level continuously, not just while the state machine happens
/// to sit in `.listening`. Consumers (the pill waveform) bind this instead of reading levels out of
/// `EngineState`, which stops carrying them the moment a preview arrives.
public protocol AudioLevelPublishing: AnyObject {
    /// Normalised 0…1 input level, ≈10 per second while capturing.
    var audioLevels: AnyPublisher<Float, Never> { get }
}

/// The real `EngineProtocol` implementation (P1.3 T4): audio → streaming preview (EOU) into the
/// pill, and on release a final TDT pass whose spans replace the preview (no dual-path yet — Bet 4
/// is Phase 1.5).
public final class RealEngine: EngineProtocol, @unchecked Sendable {
    private let audio: AudioSource
    private let provider: RecognizerProvider
    private let broadcaster = EngineEventBroadcaster()
    private let stateSubject = CurrentValueSubject<EngineState, Never>(.idle)
    private let buffer = UtteranceBuffer()
    private let lock = NSLock()
    private var recognizers: (final: FinalRecognizer, preview: PreviewRecognizer?)?
    /// `provider.revision()` at the time `recognizers` was resolved; a change means a better model
    /// landed on disk since and the cache has to go.
    private var recognizerRevision = 0
    private var listening = false
    private var lastLevelEmit = Date.distantPast
    private let levelSubject = PassthroughSubject<Float, Never>()
    /// Seconds per preview block handed to the preview recognizer.
    public var previewBlock: TimeInterval = 0.16
    /// Shortest utterance the final pass is given. Matches FluidAudio's own floor
    /// (`ASRConstants.minimumRequiredSamples` = 4800 samples = 300 ms of 16 kHz audio); below it the
    /// decoder can only throw, so `stop()` returns no spans instead of surfacing that throw.
    public var minimumUtteranceSeconds: TimeInterval = 0.3
    private var previewPending: [Float] = []
    static let sampleRate: Double = 16_000

    public init(audio: AudioSource, provider: RecognizerProvider) {
        self.audio = audio
        self.provider = provider
    }

    public convenience init(audio: AudioSource, manager: ModelManager) {
        self.init(audio: audio, provider: ModelManagerRecognizerProvider(manager: manager))
    }

    public var state: EngineState { stateSubject.value }
    public var statePublisher: AnyPublisher<EngineState, Never> { stateSubject.eraseToAnyPublisher() }
    /// Input level for the whole utterance — `.listening` *and* `.previewing`.
    public var audioLevels: AnyPublisher<Float, Never> { levelSubject.eraseToAnyPublisher() }
    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    private func setState(_ s: EngineState) {
        stateSubject.send(s)
        broadcaster.send(.state(s))
    }

    public func prewarm() async throws {
        // Re-resolving on a revision change is what makes "pick a model, wait, dictate" work without
        // a relaunch. Before this the pair resolved on the very first utterance was kept for the
        // whole process, so a model that finished downloading afterwards was never used — flatly
        // contradicting this file's own header, which promises the choice can change per utterance.
        let revision = await provider.revision()
        let have = lock.withLock { recognizers != nil && recognizerRevision == revision }
        if !have {
            setState(.prewarming)
            do {
                let r = try await provider.resolve()
                lock.withLock { recognizers = r; recognizerRevision = revision }
            } catch {
                setState(.error(EngineMessage.describe(error))); throw error
            }
        }
        try audio.prewarm()
        if case .prewarming = state { setState(.idle) }
    }

    public func start(prewarm: Bool) async throws {
        let already = lock.withLock { listening }
        if already { throw EngineError.alreadyListening }
        if prewarm { try await self.prewarm() }
        let recs = lock.withLock { recognizers }
        guard let recs else { throw EngineError.modelUnavailable("prewarm() not called") }
        await buffer.reset()
        await recs.preview?.reset()
        lock.withLock { listening = true; previewPending.removeAll() }
        audio.sink = { [weak self] ptr in self?.ingest(Array(ptr)) }
        // `listening` is set *before* capture opens, because the sink can fire from inside
        // `audio.start()`. That makes the throw below the one place where the flag can outlive the
        // session it describes: until 1.7.3 a failed `audio.start()` (denied microphone, HAL start
        // timeout, format mismatch) left `listening == true` with no capture behind it, so every
        // later `start()` threw `alreadyListening` — "VoicePlus is already recording." — for the
        // rest of the process. Roll the whole session back here rather than relying on some caller
        // to notice and call `cancel()`; not one of the five callers did.
        do {
            try audio.start()
        } catch {
            audio.sink = nil
            lock.withLock { listening = false; previewPending.removeAll() }
            await buffer.reset()
            setState(.error(EngineMessage.describe(error)))
            throw error
        }
        setState(.listening(level: 0))
    }

    private func ingest(_ block: [Float]) {
        lock.lock()
        guard listening else { lock.unlock(); return }
        let preview = recognizers?.preview
        previewPending.append(contentsOf: block)
        var toPreview: [Float]?
        if Double(previewPending.count) / 16_000 >= previewBlock { toPreview = previewPending; previewPending.removeAll() }
        let emitLevel = Date().timeIntervalSince(lastLevelEmit) > 0.1
        if emitLevel { lastLevelEmit = Date() }
        lock.unlock()

        Task { await buffer.append(block) }
        if emitLevel {
            let rms = sqrt(block.reduce(0) { $0 + $1 * $1 } / Float(max(block.count, 1)))
            let level = min(1, rms * 4)
            // Levels flow for the whole utterance. `EngineState` can only carry a level in
            // `.listening`, and the first preview moves the state to `.previewing` — publishing the
            // level separately is what keeps the pill's waveform alive past that point (a state
            // update here would instead throw the preview text away every 100 ms).
            levelSubject.send(level)
            if case .listening = state { setState(.listening(level: level)) }
        }
        if let toPreview, let preview {
            Task { [weak self] in
                guard let self else { return }
                await self.buffer.schedulePreview(toPreview, using: preview) { [weak self] text in self?.emitPartial(text) }
            }
        }
    }

    private func emitPartial(_ text: String) {
        lock.lock(); let live = listening; lock.unlock()
        guard live, !text.isEmpty else { return }
        // Preview has no per-word confidence upstream; mark it neutral (0.5) and time-bound it to
        // the audio captured so far. Final spans replace these at landing.
        let span = TranscriptSpan(text: text, confidence: 0.5, audioRange: 0...0, provenance: [.asr])
        broadcaster.send(.partial([span]))
        setState(.previewing(text: text))
    }

    public func stop() async throws -> [TranscriptSpan] {
        let recs: (final: FinalRecognizer, preview: PreviewRecognizer?)? = try lock.withLock {
            guard listening else { throw EngineError.notListening }
            listening = false
            return recognizers
        }
        audio.stop()
        audio.sink = nil
        setState(.finalizing)
        await buffer.drain()
        let samples = await buffer.samples
        guard let final = recs?.final else {
            setState(.error(EngineError.modelUnavailable("final").readable))
            throw EngineError.modelUnavailable("final")
        }
        // Too little audio to transcribe is a normal human thing to do (a stray tap of the key, a
        // start/stop that raced the HAL) — not an error worth a red pill. FluidAudio throws
        // `ASRError.invalidAudioData` below 300 ms, and until 1.6.6 that reached the user as the raw
        // token "invalidAudioData". Never call the recognizer where the answer is already known.
        let seconds = Double(samples.count) / Self.sampleRate
        if seconds < minimumUtteranceSeconds {
            Log.engine.notice("final pass skipped: \(String(format: "%.2f", seconds)) s captured, minimum is \(String(format: "%.2f", self.minimumUtteranceSeconds)) s")
            broadcaster.send(.final([]))
            setState(.landed)
            setState(.idle)
            return []
        }
        do {
            let t0 = Date()
            let spans = try await final.recognize(samples)
            Log.engine.info("final pass \(final.name): \(spans.count) spans, \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms for \(String(format: "%.1f", seconds)) s audio")
            broadcaster.send(.final(spans))
            setState(.landed)
            setState(.idle)
            return spans
        } catch {
            setState(.error(EngineMessage.describe(error)))
            throw error
        }
    }

    public func cancel() async {
        let was = lock.withLock { let w = listening; listening = false; return w }
        if was { audio.stop(); audio.sink = nil }
        await buffer.reset()
        setState(.idle)
    }
}

extension RealEngine: AudioLevelPublishing {}

/// Engines that can say how much audio the current utterance holds.
///
/// A caller that is about to finalise (the onboarding dictation test, a hands-free endpointer) can
/// then refuse a doomed final pass and say "I didn't hear anything" in its own words, instead of
/// letting a decoder-specific error escape into the UI.
public protocol CapturedAudioReporting: AnyObject {
    /// Seconds of audio captured so far in the current utterance.
    var capturedSeconds: Double { get async }
    /// Below this, `stop()` will not run the final pass at all.
    var minimumUtteranceSeconds: TimeInterval { get }
}

extension RealEngine: CapturedAudioReporting {
    public var capturedSeconds: Double {
        get async { Double(await buffer.samples.count) / Self.sampleRate }
    }
}

extension RealEngine {
    /// Test/diagnostic hook: samples captured so far in the current utterance.
    public func bufferedSampleCount() async -> Int { await buffer.samples.count }
}
