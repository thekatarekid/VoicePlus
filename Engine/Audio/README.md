# Engine/Audio + Engine/VAD — the `AudioPipeline` contract (P1.2)

**Frozen API.** P1.3 (ASR runtime), P1.4 (acoustic robustness) and the pill consume this. Add enum
cases / optional fields only; never rename or change payloads.

```
AudioCaptureSource ──▶ RingBuffer (16 kHz mono) ──▶ pump thread ──▶ ordered worker Task
   HAL / fixture                                                     ├─ .audio(samples, position)
                                                                     ├─ .level(rms)
                                                                     ├─ MicQualityAnalyzer ─▶ .micQuality
                                                                     ├─ VADProtocol ──────▶ .vad(.speechStart/.speechEnd)
                                                                     ├─ Chunker 3.0–5.0 s ─▶ .chunk(AudioChunk)
                                                                     └─ Endpointer ───────▶ .endpoint (hands-free only)
```

## Usage
```swift
let vad = await VADFactory.make()                       // Silero if model on disk, else EnergyVAD; never downloads
let source = CoreAudioCaptureSource()                    // or FixtureCaptureSource(url:) for WAV replay
var options = AudioPipeline.Options(); options.handsFree = true
let pipeline = AudioPipeline(source: source, vad: vad, options: options)

let events = pipeline.events()                           // AsyncStream<AudioPipelineEvent>, one per subscriber
Task { for await e in events { switch e {
    case .audio(let samples, let position): ...          // 16 kHz Float, ≈50 ms blocks, in order, nothing dropped
    case .micQuality(let q): pill.show(q)                // once, from the first 300 ms of signal
    case .vad(let ev): ...                               // speechStart(at:) / speechEnd(at:) seconds from start
    case .chunk(let c): await asr.transcribe(c.samples)  // 3–5 s, cut at speech ends; `.flush` chunk at stop
    case .endpoint(let d): await pipeline.stop()         // .endpoint(at:) / .noSpeech / .maxDuration
    case .deviceChanged(let from, let to): ...
    case .overrun(let dropped): ...                      // ring buffer full (consumer stalled)
    case .stopped(let total): ...                        // always the last event
    default: break } } }

try await pipeline.prewarm()     // hotkey-down: opens the device, installs tap, resets VAD
try await pipeline.start()       // begins delivery; emits .started(device:)
await pipeline.stop()            // drains everything captured, emits final chunk + .stopped
pipeline.audioBuffers()          // AsyncStream<[Float]> of just the 16 kHz audio
```

## Pieces
| File | Role |
|---|---|
| `AudioCaptureSource.swift` | `AudioCaptureSource` protocol; `CoreAudioCaptureSource` = AVAudioEngine input tap with the HAL device pinned via `kAudioOutputUnitProperty_CurrentDevice`; route changes handled through `AudioDeviceMonitor` + `InputSelectionPolicy`, audio already captured is never lost. |
| `AudioDevice.swift` | `AudioDeviceInfo`, HAL enumeration (`AudioDeviceEnumerator`), `AudioDeviceMonitor` (`AudioObjectAddPropertyListenerBlock` on default input + device list). |
| `RingBuffer.swift` | SPSC Float ring; producer never blocks/allocates; overruns counted, not hidden. |
| `AudioConverter16k.swift` | `AVAudioConverter` any-format → 16 kHz mono Float32 (streaming or one-shot flush). |
| `InputSelectionPolicy.swift` | Device choice: per-device prefs in `UserDefaults` (`audio.input.preferredUID`, `audio.input.pref.<uid>`) → keep current → system default unless display/virtual → built-in. |
| `MicQualityAnalyzer.swift` | SNR (p90/p10 frame RMS), clipping fraction, low level over 300 ms of signal (leading pause skipped; 1.5 s deadline). |
| `Chunker.swift` / `Endpointer.swift` | 3.0 / 5.0 s chunking at speech boundaries; hands-free endpoint after trailing silence (1.2 s default), no-speech timeout, max duration. |
| `WAVFile.swift` / `FixtureCaptureSource.swift` | Dependency-free WAV reader/writer; deterministic replay through the same sink as the HAL source. `AudioFixtures.url(suite, file)`. |
| `VAD/VADProtocol.swift` | `VADProtocol` (frame-synchronous, 16 kHz), `VADEvent`, offline `segments(in:)`. |
| `VAD/EnergyVAD.swift` | Fallback: min-statistics noise floor + hysteresis, 20 ms frames. F1 0.98 on `Fixtures/audio/vad`. |
| `VAD/SileroVAD.swift` | FluidAudio `VadManager` streaming wrapper (256 ms frames); `VADFactory.make()` picks it only when the CoreML model is already on disk. |
| `VAD/VADScoring.swift` | Frame-level P/R/F1 vs `labels.json`. |

## Threading
Capture callback → `RingBuffer.write` → `DispatchSemaphore.signal`. A dedicated pump thread moves
samples into an unbounded `AsyncStream`; a single worker `Task` consumes it, so all analysis and
all events are strictly ordered. `stop()` awaits the worker, so `.stopped` means fully drained.

## Not exercised by tests (needs a mic + TCC permission)
`CoreAudioCaptureSource` start/tap/pin and live route-change callbacks. Everything else runs
against fixtures; `AudioDeviceMonitor`/`AudioDeviceEnumerator` are smoke-tested against the real HAL.

## Acoustic robustness (P1.4) — `Audio/Robustness`, `Audio/Bluetooth`
`AcousticCaptureSource(wrapping: source, profile: RobustnessProfile)` slots between any capture source and
`AudioPipeline`: neural AEC slot (LocalVQE/DTLN, Apache-2.0/MIT, weights + GGML runtime not bundled →
passthrough) → `SpectralGateNoiseSuppressor` (toggle per profile) → sink; Bluetooth pre-roll on `prewarm()`.
`VoiceProcessingCaptureSource` is the Apple-AEC variant of `CoreAudioCaptureSource`.
`BluetoothInputDetector.assess(device)` classifies SCO 8k/16k as low-quality and yields a `MicQuality` + message.
See `Robustness/SUITES.md` for the Lab fixture registration and `Robustness/AEC.swift` for license notes.
