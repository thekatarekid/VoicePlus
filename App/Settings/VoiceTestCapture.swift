import AVFoundation
import Engine
import Foundation
import Shared

/// S7e — the microphone test's capture. V5 O1 (§10): it joins the app's one capture graph
/// (`AppCaptureGraph.shared()` — the engine's `AudioPipeline`, or without an engine the single
/// standalone fallback) as `PipelineAudioSource.Owner.meter`, reading its own `Broadcaster`
/// subscription. It no longer builds a `CoreAudioCaptureSource()` of its own, so a test run during a
/// meeting or ambient listening is one HAL client, not two. There is still no recognizer on this
/// path, so nothing a test hears can be typed.
///
/// The shared graph follows `InputSelectionPolicy`, the same key the Voice picker writes: the test
/// opens the microphone dictation would use.
///
/// `release()` ends the meter's claim and subscription. When nothing else holds the graph it stops
/// (the macOS microphone indicator goes off, design §8.4 "Stop testing releases the microphone"); the
/// fallback graph is also released fully (`release(reason: .idle)`), while the engine's graph stays
/// prepared between turns as it always does (V4.7). Opening happens off the main thread: the HAL can
/// take seconds on a Bluetooth or Continuity device and the window must not freeze.
///
/// Untested here: the HAL, TCC and device removal need real hardware. The state machine that
/// consumes these events is tested through `VoiceTestCapturing` mocks; the graph sharing through a
/// fixture-fed graph (`VoiceTestSharedGraphTests`).
public final class LiveVoiceTestCapture: VoiceTestCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let registry: AppCaptureGraph
    private var audio: PipelineAudioSource?
    private var subscription: AudioPipeline.Subscription?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncStream<VoiceTestCaptureEvent>.Continuation?
    private var generation = 0

    public init(registry: AppCaptureGraph = .app) {
        self.registry = registry
    }

    public var isOpen: Bool { lock.withLock { audio != nil } }

    public func open() -> AsyncStream<VoiceTestCaptureEvent> {
        release()
        let (stream, continuation) = AsyncStream<VoiceTestCaptureEvent>.makeStream()
        let audio = registry.shared()
        let subscription = audio.pipeline.subscribe()
        let events = subscription.events
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            self.audio = audio
            self.subscription = subscription
            self.continuation = continuation
            return self.generation
        }
        let reader = Task.detached(priority: .userInitiated) {
            var device: AudioDeviceInfo?
            for await event in events {
                switch event {
                case .started(let started):
                    device = started ?? device
                    continuation.yield(.started(device: started?.name ?? audio.deviceName))
                case .audio(let samples, let position):
                    continuation.yield(.audio(samples: samples, position: position))
                case .level(let rms):
                    continuation.yield(.level(min(1, rms * 4)))
                case .vad(let vad):
                    continuation.yield(.vad(vad))
                case .deviceChanged(let from, _):
                    let gone = from ?? device
                    if let gone, !AudioDeviceEnumerator.inputDevices().contains(where: { $0.uid == gone.uid }) {
                        continuation.yield(.deviceRemoved(name: gone.name))
                    }
                case .captureFailed:
                    continuation.yield(.failed(.noAudio))
                case .stopped:
                    return
                default:
                    break
                }
            }
        }
        lock.withLock { self.reader = reader }
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let joined = audio.pipeline.isRunning
                try audio.start(for: .meter)
                // A Stop that landed while the HAL was opening must still win.
                guard let self, self.isCurrent(generation) else {
                    audio.stop(for: .meter)
                    self?.releaseIfIdleFallback(audio)
                    return
                }
                // Joining a graph that was already running (a meeting, ambient) emits no `.started`.
                if joined { continuation.yield(.started(device: audio.deviceName)) }
                Log.app.info("voice test: capture open on \(audio.deviceName ?? "default device")")
            } catch {
                Log.app.error("voice test: capture could not start: \(error)")
                continuation.yield(.failed(Self.failure(for: error)))
            }
        }
        return stream
    }

    public func release() {
        let (audio, subscription, reader, continuation) = lock.withLock { () -> (PipelineAudioSource?, AudioPipeline.Subscription?, Task<Void, Never>?, AsyncStream<VoiceTestCaptureEvent>.Continuation?) in
            defer {
                self.audio = nil
                self.subscription = nil
                self.reader = nil
                self.continuation = nil
                self.generation += 1
            }
            return (self.audio, self.subscription, self.reader, self.continuation)
        }
        guard let audio else { return }
        audio.stop(for: .meter)
        subscription?.cancel()
        releaseIfIdleFallback(audio)
        reader?.cancel()
        continuation?.finish()
        Log.app.info("voice test: microphone released")
    }

    /// The standalone fallback graph is released fully once nobody uses it; the engine's graph is not.
    private func releaseIfIdleFallback(_ audio: PipelineAudioSource) {
        guard registry.isFallback(audio), !audio.isCapturing else { return }
        audio.pipeline.source.release(reason: .idle)
    }

    private func isCurrent(_ generation: Int) -> Bool { lock.withLock { self.generation == generation && audio != nil } }

    static func failure(for error: Error) -> VoiceTestCaptureFailure {
        switch error as? AudioCaptureError {
        case .noInputDevice?:
            // `PipelineAudioSource.start` reports a missing grant as `.noInputDevice` too.
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? .noInputDevice : .permissionDenied
        case .busy?:
            return .busy
        case .noAudio?:
            return .noAudio
        default:
            return .couldNotStart(String(describing: error))
        }
    }
}
