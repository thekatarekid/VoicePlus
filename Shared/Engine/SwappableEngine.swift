import Combine
import Foundation

/// Something that can say "I cannot recognise speech at all" without the caller having to know
/// which concrete engine class is behind it. `UnavailableEngine` says yes; `SwappableEngine`
/// forwards the question to whatever it is wrapping right now.
public protocol EngineAvailabilityReporting: AnyObject {
    var isUnavailable: Bool { get }
}

/// A stable `EngineProtocol` face over an engine that can be replaced at runtime.
///
/// The composition root resolves the recognizer exactly once, at launch, and hands the resulting
/// engine to a dozen collaborators (`DictationCoordinator`, the pill, onboarding, the act session).
/// Before 1.7.0 a launch with no ASR model on disk quietly substituted `MockEngine`, so the
/// staleness was invisible — you got fabricated transcripts instead of silence. With
/// `UnavailableEngine` telling the truth instead, the same staleness means the app is *permanently
/// dead* after the user downloads a model: everyone still holds the engine that can never
/// transcribe.
///
/// This box fixes the lifetime, not the contents. Subscribers bind to *its* `statePublisher` and
/// `events()` once and keep working across any number of swaps.
///
/// Utterance safety: swapping cancels the outgoing engine, and a `stop()` whose matching `start()`
/// happened on an earlier occupant returns no spans. A swap mid-utterance therefore lands nothing —
/// never half an utterance, never the same utterance twice.
public final class SwappableEngine: EngineProtocol, EngineAvailabilityReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _current: any EngineProtocol
    /// Bumped on every swap. `start()` records it; `stop()` refuses to return spans if it moved.
    private var generation = 0
    private var startedGeneration: Int?
    private let stateSubject: CurrentValueSubject<EngineState, Never>
    private let broadcaster = EngineEventBroadcaster()
    private var stateSubscription: AnyCancellable?
    private var eventForwarder: Task<Void, Never>?

    /// Called after a successful swap, with the engine that is now in place.
    public var onSwap: ((any EngineProtocol) -> Void)?

    public init(_ engine: any EngineProtocol) {
        _current = engine
        stateSubject = CurrentValueSubject(engine.state)
        attach(engine)
    }

    deinit { eventForwarder?.cancel() }

    /// The engine in the box right now. Read it for identity checks; never store it.
    public var current: any EngineProtocol { lock.withLock { _current } }

    public var isUnavailable: Bool {
        let engine = current
        if let reporting = engine as? EngineAvailabilityReporting { return reporting.isUnavailable }
        return false
    }

    // MARK: EngineProtocol

    public var state: EngineState { stateSubject.value }
    public var statePublisher: AnyPublisher<EngineState, Never> { stateSubject.eraseToAnyPublisher() }
    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    public func prewarm() async throws { try await current.prewarm() }

    public func start(prewarm: Bool) async throws {
        let engine = lock.withLock { () -> any EngineProtocol in
            startedGeneration = generation
            return _current
        }
        do { try await engine.start(prewarm: prewarm) } catch {
            lock.withLock { startedGeneration = nil }
            throw error
        }
    }

    public func stop() async throws -> [TranscriptSpan] {
        let (engine, stale) = lock.withLock { () -> (any EngineProtocol, Bool) in
            let stale = startedGeneration != nil && startedGeneration != generation
            startedGeneration = nil
            return (_current, stale)
        }
        // The utterance started on an engine that has since been replaced. Its audio belongs to
        // nobody now: the outgoing engine was cancelled at swap time, and asking the incoming one
        // to stop would either throw `notListening` or hand back somebody else's samples.
        guard !stale else { return [] }
        return try await engine.stop()
    }

    public func cancel() async {
        lock.withLock { startedGeneration = nil }
        await current.cancel()
    }

    // MARK: Swapping

    /// Replaces the engine. Any utterance in flight on the outgoing engine is cancelled, so nothing
    /// half-recognised can land.
    public func swap(to engine: any EngineProtocol) async {
        let outgoing = current
        guard outgoing !== engine else { return }
        // Unconditionally, not `if outgoing.state.isActive`: published state is not evidence about
        // capture. An engine whose `start()` threw part-way sits in `.error` while still holding the
        // microphone, and that is precisely the engine a swap is most likely to be replacing.
        // `cancel()` is idempotent on every engine in the tree.
        await outgoing.cancel()
        detach()
        lock.withLock {
            _current = engine
            generation &+= 1
            // `startedGeneration` is deliberately left alone: it is what tells the next `stop()`
            // that its utterance began on an engine that is no longer here.
        }
        attach(engine)
        // Republish immediately: a subscriber that only ever sees `sink` values would otherwise sit
        // on the outgoing engine's last state until the new one happens to change.
        publish(engine.state)
        onSwap?(engine)
    }

    private func attach(_ engine: any EngineProtocol) {
        stateSubscription = engine.statePublisher.sink { [weak self] state in
            self?.stateSubject.send(state)
        }
        let stream = engine.events()
        eventForwarder = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.broadcaster.send(event)
            }
        }
    }

    private func detach() {
        stateSubscription?.cancel()
        stateSubscription = nil
        eventForwarder?.cancel()
        eventForwarder = nil
    }

    private func publish(_ state: EngineState) {
        stateSubject.send(state)
        broadcaster.send(.state(state))
    }
}
