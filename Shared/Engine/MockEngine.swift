import Combine
import Foundation

/// A scripted transcript fixture: `Fixtures/transcripts/<name>.json`.
public struct TranscriptFixture: Codable, Equatable, Sendable {
    public struct ScriptedSpan: Codable, Equatable, Sendable {
        public var text: String
        public var confidence: Float
        public var audioStart: TimeInterval
        public var audioEnd: TimeInterval
        public var alternates: [Alternate]
        /// Delay before this span is emitted as a partial, in milliseconds.
        public var delayMs: Int

        public init(text: String, confidence: Float, audioStart: TimeInterval, audioEnd: TimeInterval,
                    alternates: [Alternate] = [], delayMs: Int = 0) {
            self.text = text
            self.confidence = confidence
            self.audioStart = audioStart
            self.audioEnd = audioEnd
            self.alternates = alternates
            self.delayMs = delayMs
        }

        enum CodingKeys: String, CodingKey { case text, confidence, audioStart, audioEnd, alternates, delayMs }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                text: try c.decode(String.self, forKey: .text),
                confidence: try c.decode(Float.self, forKey: .confidence),
                audioStart: try c.decode(TimeInterval.self, forKey: .audioStart),
                audioEnd: try c.decode(TimeInterval.self, forKey: .audioEnd),
                alternates: try c.decodeIfPresent([Alternate].self, forKey: .alternates) ?? [],
                delayMs: try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
            )
        }

        public var span: TranscriptSpan {
            TranscriptSpan(text: text, confidence: confidence, audioRange: audioStart...audioEnd,
                           alternates: alternates, provenance: [.asr])
        }
    }

    public var name: String
    public var register: Utterance.Register
    public var micQuality: MicQuality?
    public var spans: [ScriptedSpan]

    public init(name: String, register: Utterance.Register = .unknown, micQuality: MicQuality? = nil, spans: [ScriptedSpan]) {
        self.name = name
        self.register = register
        self.micQuality = micQuality
        self.spans = spans
    }

    enum CodingKeys: String, CodingKey { case name, register, micQuality, spans }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            register: try c.decodeIfPresent(Utterance.Register.self, forKey: .register) ?? .unknown,
            micQuality: try c.decodeIfPresent(MicQuality.self, forKey: .micQuality),
            spans: try c.decode([ScriptedSpan].self, forKey: .spans)
        )
    }

    public static let directoryName = "transcripts"

    /// Loads `Fixtures/transcripts/<name>.json` from the package root.
    public static func load(named name: String, fixturesDirectory: URL? = AppPaths.fixturesDirectory()) throws -> TranscriptFixture {
        guard let dir = fixturesDirectory else { throw EngineError.fixtureNotFound(name) }
        let url = dir.appendingPathComponent(directoryName).appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw EngineError.fixtureNotFound(url.path) }
        do {
            return try JSONDecoder().decode(TranscriptFixture.self, from: Data(contentsOf: url))
        } catch {
            throw EngineError.fixtureInvalid("\(url.path): \(error)")
        }
    }
}

/// Streams scripted spans from a fixture so UI/pipeline/Lab can develop without WS-A.
/// `delayScale` multiplies every fixture delay (0 for instant tests, 1 for realistic demos).
public final class MockEngine: EngineProtocol, @unchecked Sendable {
    public var fixture: TranscriptFixture
    public var delayScale: Double
    /// Simulated prewarm time in milliseconds (also scaled).
    public var prewarmMs: Int

    private let lock = NSLock()
    private let broadcaster = EngineEventBroadcaster()
    private let stateSubject: CurrentValueSubject<EngineState, Never>
    private var streamingTask: Task<Void, Never>?
    private var emitted: [TranscriptSpan] = []
    private var prewarmed = false

    public init(fixture: TranscriptFixture, delayScale: Double = 1, prewarmMs: Int = 50) {
        self.fixture = fixture
        self.delayScale = delayScale
        self.prewarmMs = prewarmMs
        self.stateSubject = CurrentValueSubject(.idle)
    }

    public convenience init(fixtureNamed name: String, delayScale: Double = 1) throws {
        self.init(fixture: try TranscriptFixture.load(named: name), delayScale: delayScale)
    }

    // MARK: EngineProtocol

    public var state: EngineState { stateSubject.value }
    public var statePublisher: AnyPublisher<EngineState, Never> { stateSubject.eraseToAnyPublisher() }

    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    public func prewarm() async throws {
        if locked({ prewarmed }) { return }
        setState(.prewarming)
        try await sleep(ms: prewarmMs)
        locked { prewarmed = true }
        if state == .prewarming { setState(.idle) }
    }

    public func start(prewarm: Bool) async throws {
        if state.isActive { throw EngineError.alreadyListening }
        if prewarm { try await self.prewarm() }
        locked { emitted = [] }

        if let quality = fixture.micQuality {
            broadcaster.send(.micQuality(quality))
            if quality.verdict != .good { setState(.warning(quality)) }
        }
        setState(.listening(level: 0))

        let scripted = fixture.spans
        let task = Task { [weak self] in
            guard let self else { return }
            for scripted in scripted {
                if Task.isCancelled { return }
                try? await self.sleep(ms: scripted.delayMs)
                if Task.isCancelled { return }
                let snapshot: [TranscriptSpan] = self.locked {
                    self.emitted.append(scripted.span)
                    return self.emitted
                }
                self.setState(.listening(level: min(1, 0.2 + Float(scripted.text.count) / 20)))
                self.broadcaster.send(.partial(snapshot))
                self.setState(.previewing(text: snapshot.joinedText))
            }
        }
        locked { streamingTask = task }
    }

    public func stop() async throws -> [TranscriptSpan] {
        guard state.isActive else { throw EngineError.notListening }
        setState(.finalizing)
        // Flush: whatever has not been emitted yet lands instantly on stop (like a real decoder draining).
        await drainStreamingTask()
        let scriptedSpans = fixture.spans
        let final: [TranscriptSpan] = locked {
            emitted.append(contentsOf: scriptedSpans.dropFirst(emitted.count).map(\.span))
            return emitted
        }
        broadcaster.send(.final(final))
        setState(.landed)
        setState(.idle)
        return final
    }

    public func cancel() async {
        await drainStreamingTask()
        locked { emitted = [] }
        setState(.idle)
    }

    // MARK: Helpers

    /// Cancels the partial-emitting task and waits for it to exit so no partial can land after us.
    private func drainStreamingTask() async {
        let task: Task<Void, Never>? = locked {
            let t = streamingTask
            streamingTask = nil
            return t
        }
        task?.cancel()
        await task?.value
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func setState(_ new: EngineState) {
        stateSubject.send(new)
        broadcaster.send(.state(new))
    }

    private func sleep(ms: Int) async throws {
        let scaled = Double(ms) * delayScale
        guard scaled > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000))
    }
}
