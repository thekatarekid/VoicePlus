import Combine
import Foundation
import Shared

/// Resolves which recognizers an utterance uses. Decoupled so tests inject mocks and so the
/// choice can change between utterances as background downloads land.
public protocol RecognizerProvider: Sendable {
    func resolve() async throws -> (final: FinalRecognizer, preview: PreviewRecognizer?)
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
    private var listening = false
    private var lastLevelEmit = Date.distantPast
    /// Seconds per preview block handed to the preview recognizer.
    public var previewBlock: TimeInterval = 0.16
    private var previewPending: [Float] = []

    public init(audio: AudioSource, provider: RecognizerProvider) {
        self.audio = audio
        self.provider = provider
    }

    public convenience init(audio: AudioSource, manager: ModelManager) {
        self.init(audio: audio, provider: ModelManagerRecognizerProvider(manager: manager))
    }

    public var state: EngineState { stateSubject.value }
    public var statePublisher: AnyPublisher<EngineState, Never> { stateSubject.eraseToAnyPublisher() }
    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    private func setState(_ s: EngineState) {
        stateSubject.send(s)
        broadcaster.send(.state(s))
    }

    public func prewarm() async throws {
        let have = lock.withLock { recognizers != nil }
        if !have {
            setState(.prewarming)
            do {
                let r = try await provider.resolve()
                lock.withLock { recognizers = r }
            } catch {
                setState(.error("\(error)")); throw error
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
        try audio.start()
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
        if emitLevel, case .listening = state {
            let rms = sqrt(block.reduce(0) { $0 + $1 * $1 } / Float(max(block.count, 1)))
            setState(.listening(level: min(1, rms * 4)))
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
        guard let final = recs?.final else { setState(.error("no recognizer")); throw EngineError.modelUnavailable("final") }
        do {
            let t0 = Date()
            let spans = try await final.recognize(samples)
            Log.engine.info("final pass \(final.name): \(spans.count) spans, \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms for \(String(format: "%.1f", Double(samples.count) / 16_000)) s audio")
            broadcaster.send(.final(spans))
            setState(.landed)
            setState(.idle)
            return spans
        } catch {
            setState(.error("\(error)"))
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
