import Combine
import Foundation

/// Events an engine emits while an utterance is in flight.
public enum EngineEvent: Equatable, Sendable {
    case state(EngineState)
    /// Cumulative preview spans so far (may be revised by later partials).
    case partial([TranscriptSpan])
    /// Final spans for the utterance; emitted once, right before `stop()` returns.
    case final([TranscriptSpan])
    case micQuality(MicQuality)
}

public enum EngineError: Error, Equatable, Sendable {
    case notListening
    case alreadyListening
    case modelUnavailable(String)
    case fixtureNotFound(String)
    case fixtureInvalid(String)
}

/// The contract between WS-A's real engine and everything else (UI, pipeline, Lab).
/// `MockEngine` conforms; P1.3's `ASRRuntime` engine must conform too.
public protocol EngineProtocol: AnyObject, Sendable {
    /// Current state; also published via `statePublisher`.
    var state: EngineState { get }
    var statePublisher: AnyPublisher<EngineState, Never> { get }

    /// A fresh event stream per call. Each subscriber gets every event emitted after subscribing.
    func events() -> AsyncStream<EngineEvent>

    /// Load models / warm caches. Idempotent. Engines may call this on hotkey-down.
    func prewarm() async throws

    /// Begin capturing an utterance. `prewarm: true` is equivalent to calling `prewarm()` first.
    func start(prewarm: Bool) async throws

    /// End capture and return the final spans. Emits `.final` then returns.
    func stop() async throws -> [TranscriptSpan]

    /// Abort without producing text.
    func cancel() async
}

public extension EngineProtocol {
    func start() async throws { try await start(prewarm: true) }
}

/// Fan-out helper so multiple consumers can each get an `AsyncStream<EngineEvent>`.
/// Engines own one of these; `EngineProtocol.events()` returns `subscribe()`.
public final class EngineEventBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]

    public init() {}

    public func subscribe() -> AsyncStream<EngineEvent> {
        let id = UUID()
        // Register eagerly (not inside the lazy `AsyncStream { }` builder, which only runs on
        // first iteration) so events sent between `subscribe()` and the consumer's first
        // `for await` are buffered instead of lost.
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream()
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        return stream
    }

    public func send(_ event: EngineEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets { continuation.yield(event) }
    }

    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets { continuation.finish() }
    }
}
