import Combine
import Foundation
import Shared

/// V5 LR3 — silent dictation. An `EngineProtocol` that never opens the microphone: the hold key
/// (or latch) brackets the utterance exactly as for voice, the camera's mouth crops for that span go
/// through `AVSRRecognizer(videoOnly: true)`, and the final spans enter the same pipeline.
///
/// The app swaps this in (`SwappableEngine`) while `LipMode.lipsOnly` is on and swaps the voice
/// engine back when it goes off.
public final class LipsOnlyEngine: EngineProtocol, @unchecked Sendable {
    public static let noFaceMessage = "Lips only: I can't see your face — look at the camera and try again."
    public static let notInstalledMessage = "Lip-reading model not installed"

    private let recognizer: AVSRRecognizer
    private let isModelInstalled: @Sendable () -> Bool
    private let clock: @Sendable () -> TimeInterval
    /// Called when an utterance ends (recognised, failed or cancelled) — the crop buffer is cleared.
    private let onUtteranceEnd: @Sendable () -> Void
    private let broadcaster = EngineEventBroadcaster()
    private let stateSubject = CurrentValueSubject<EngineState, Never>(.idle)
    private let lock = NSLock()
    private var startedAt: TimeInterval?

    public init(recognizer: AVSRRecognizer,
                isModelInstalled: @escaping @Sendable () -> Bool,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                onUtteranceEnd: @escaping @Sendable () -> Void = {}) {
        precondition(recognizer.videoOnly, "LipsOnlyEngine needs AVSRRecognizer(videoOnly: true)")
        self.recognizer = recognizer
        self.isModelInstalled = isModelInstalled
        self.clock = clock
        self.onUtteranceEnd = onUtteranceEnd
    }

    public var state: EngineState { stateSubject.value }
    public var statePublisher: AnyPublisher<EngineState, Never> { stateSubject.eraseToAnyPublisher() }
    public func events() -> AsyncStream<EngineEvent> { broadcaster.subscribe() }

    private func set(_ s: EngineState) {
        stateSubject.send(s)
        broadcaster.send(.state(s))
    }

    public func prewarm() async throws {
        guard isModelInstalled() else {
            set(.unavailable(Self.notInstalledMessage))
            throw EngineError.modelUnavailable(Self.notInstalledMessage)
        }
    }

    public func start(prewarm: Bool) async throws {
        if prewarm { try await self.prewarm() } else if !isModelInstalled() {
            set(.unavailable(Self.notInstalledMessage))
            throw EngineError.modelUnavailable(Self.notInstalledMessage)
        }
        let already = lock.withLock { () -> Bool in
            if startedAt != nil { return true }
            startedAt = clock(); return false
        }
        if already { throw EngineError.alreadyListening }
        set(.listening(level: 0))
    }

    public func stop() async throws -> [TranscriptSpan] {
        guard let start = lock.withLock({ () -> TimeInterval? in defer { startedAt = nil }; return startedAt }) else {
            throw EngineError.notListening
        }
        defer { onUtteranceEnd() }
        set(.finalizing)
        let duration = max(0, clock() - start)
        do {
            let spans = try await recognizer.recognizeLips(duration: duration)
            broadcaster.send(.final(spans))
            set(.landed)
            set(.idle)
            return spans
        } catch AVSRError.noFaceTracked {
            set(.error(Self.noFaceMessage))
            broadcaster.send(.final([]))
            return []
        }
    }

    public func cancel() async {
        let was = lock.withLock { () -> Bool in defer { startedAt = nil }; return startedAt != nil }
        if was { onUtteranceEnd() }
        set(.idle)
    }
}
