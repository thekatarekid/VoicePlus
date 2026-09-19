import AVFoundation
import Engine
import Foundation
import Shared

/// S7e — the microphone test's own capture graph: the one `EngineFactory` and the onboarding meter
/// build — `AcousticCaptureSource(wrapping: CoreAudioCaptureSource())` → `AudioPipeline` →
/// `PipelineAudioSource` — minus the recognizer, so nothing a test hears can be typed.
///
/// `CoreAudioCaptureSource()` asks `InputSelectionPolicy` for its device, which reads the same key
/// the Voice picker writes: the test opens the microphone dictation would use.
///
/// `release()` is a full teardown — the pipeline stops and the source's kept graph is released
/// (`release(reason: .idle)`), so the macOS microphone indicator goes off when Stop is pressed
/// (design §8.4 "Stop testing releases the microphone"). Opening happens off the main thread: the
/// HAL can take seconds on a Bluetooth or Continuity device and the window must not freeze.
///
/// Untested here: the HAL, TCC and device removal need real hardware. The state machine that
/// consumes these events is tested through `VoiceTestCapturing` mocks.
public final class LiveVoiceTestCapture: VoiceTestCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var capture: AcousticCaptureSource?
    private var audio: PipelineAudioSource?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncStream<VoiceTestCaptureEvent>.Continuation?
    private var generation = 0

    public init() {}

    public var isOpen: Bool { lock.withLock { audio != nil } }

    public func open() -> AsyncStream<VoiceTestCaptureEvent> {
        release()
        let (stream, continuation) = AsyncStream<VoiceTestCaptureEvent>.makeStream()
        let capture = AcousticCaptureSource(wrapping: CoreAudioCaptureSource(), profile: .default)
        let pipeline = AudioPipeline(source: capture, vad: EnergyVAD())
        let audio = PipelineAudioSource(pipeline: pipeline)
        let events = pipeline.events()
        let generation = lock.withLock { () -> Int in
            self.generation += 1
            self.capture = capture
            self.audio = audio
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
                try audio.start(for: .meter)
                // A Stop that landed while the HAL was opening must still win.
                guard let self, self.isCurrent(generation) else {
                    audio.stop(for: .meter)
                    capture.release(reason: .idle)
                    return
                }
                Log.app.info("voice test: capture open on \(audio.deviceName ?? "default device")")
            } catch {
                Log.app.error("voice test: capture could not start: \(error)")
                continuation.yield(.failed(Self.failure(for: error)))
            }
        }
        return stream
    }

    public func release() {
        let (audio, capture, reader, continuation) = lock.withLock { () -> (PipelineAudioSource?, AcousticCaptureSource?, Task<Void, Never>?, AsyncStream<VoiceTestCaptureEvent>.Continuation?) in
            defer {
                self.audio = nil
                self.capture = nil
                self.reader = nil
                self.continuation = nil
                self.generation += 1
            }
            return (self.audio, self.capture, self.reader, self.continuation)
        }
        guard audio != nil || capture != nil else { return }
        audio?.stop(for: .meter)
        capture?.release(reason: .idle)
        reader?.cancel()
        continuation?.finish()
        Log.app.info("voice test: microphone released")
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
