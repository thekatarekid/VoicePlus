import Combine
import Foundation

/// The engine used when nothing on this machine can recognise speech — no ASR model on disk and
/// no OS speech fallback.
///
/// It exists so the app can be *honestly broken* instead of quietly convincing. Before 1.6.9 the
/// composition root fell back to `MockEngine` loaded with the `email_reply` fixture in exactly
/// this situation (every fresh install, during onboarding), so the pill showed — and the injector
/// typed into the user's frontmost app — sentences the user never said.
///
/// Contract: it never emits `.partial`, `.final`, or `.previewing`, and `stop()` returns no spans.
/// The only thing it publishes is `EngineState.unavailable(reason)` while the hotkey is held, so
/// the pill can say why nothing is happening.
public final class UnavailableEngine: EngineProtocol, @unchecked Sendable {
    /// Short, user-facing explanation shown in the pill.
    public let reason: String
    /// How long the notice stays up after the hotkey is released.
    public var lingerMs: Int

    private let broadcaster = EngineEventBroadcaster()
    private let stateSubject: CurrentValueSubject<EngineState, Never>
    private let lock = NSLock()
    private var lingerTask: Task<Void, Never>?

    public init(reason: String = "No speech model installed", lingerMs: Int = 1500) {
        self.reason = reason
        self.lingerMs = lingerMs
        self.stateSubject = CurrentValueSubject(.idle)
    }

    public var state: EngineState { stateSubject.value }
    public var statePublisher: AnyPublisher<EngineState, Never> { stateSubject.eraseToAnyPublisher() }

    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    /// Nothing to warm. Deliberately does not throw: prewarm runs on hotkey-down and a throw there
    /// would only produce a log line, not a visible explanation.
    public func prewarm() async throws {}

    public func start(prewarm: Bool) async throws {
        cancelLinger()
        setState(.unavailable(reason))
    }

    /// Always empty. The caller must not inject anything.
    public func stop() async throws -> [TranscriptSpan] {
        scheduleLinger()
        return []
    }

    public func cancel() async {
        cancelLinger()
        setState(.idle)
    }

    private func setState(_ s: EngineState) {
        stateSubject.send(s)
        broadcaster.send(.state(s))
    }

    /// Keeps the notice on screen briefly after release, so a quick tap still shows why.
    private func scheduleLinger() {
        cancelLinger()
        let ms = lingerMs
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            self.setState(.idle)
        }
        lock.withLock { lingerTask = task }
    }

    private func cancelLinger() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            defer { lingerTask = nil }
            return lingerTask
        }
        task?.cancel()
    }
}
