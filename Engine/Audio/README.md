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

## Which microphone, and proving what it captured (1.7.15)

**Device choice.** `InputSelectionPolicy` gave the system default `+50`, which dwarfs every
transport score — so the moment AirPods connect and macOS makes them the default input, dictation
dropped onto an HFP/SCO link at 8 kHz (CVSD) or 16 kHz (mSBC): telephony bandwidth, and exactly the
input that produces phonetically-adjacent errors. That bonus is now withheld from a narrowband
Bluetooth mic (`BluetoothInputMode.isNarrowbandSpeech`), so the built-in or a USB mic wins instead.
It is still chosen when it is the only input, an explicit user pin (`audio.input.preferredUID`)
still overrides, and wideband Bluetooth (≥24 kHz, LE Audio) is untouched. `InputSelectionPolicy.decide`
returns `Choice.avoidedNarrowbandBluetooth` so the substitution can be stated rather than made
silently — `CoreAudioCaptureSource.prewarm()` logs it, and Settings › General › Microphone says it.

**`UtteranceRecorder` — the diagnostic that settles an accuracy report.** Opt-in, off by default,
local only, newest 20 utterances kept. Wired into `AcousticCaptureSource`, which writes both sides
of the chain: `<stamp>-raw.wav` (what capture delivered, pre-DSP), `<stamp>-processed.wav` (what the
recognizer got), and `<stamp>.json` (device, transport, nominal rate, capture-graph summary,
profile, level stats). Files land in `~/Library/Application Support/VoicePlus/Recordings`.

### Capturing and replaying one bad dictation

1. Settings › General › Microphone → turn on **“Save recordings of what I dictate.”** The note
   under it turns orange while it is on; nothing is uploaded.
2. Dictate the sentence that comes out wrong. Note what you actually said.
3. Turn the toggle back off.
4. Replay it through the real model:

   ```sh
   eval "$(Scripts/bootstrap-toolchain.sh)"
   VOICEPLUS_REPLAY_TEXT="the quick brown fox jumps over the lazy dog" \
     swift test --scratch-path .build-capture --filter replaySavedRecordings
   ```

   Add `VOICEPLUS_REPLAY=/path/to/one-raw.wav` to replay a single file or another folder.

The output prints, per recording, the manifest, the level, what the model heard, and the WER.
Reading it:

| What you see | What it means |
|---|---|
| Replay WER is low, live dictation was wrong | The audio was fine; the fault is downstream of capture (landing, post-processing). |
| Replay WER is high, and the audio sounds fine to you | Capture is faithful; the model is genuinely failing on this voice/room. |
| `-raw` scores well but `-processed` badly | The acoustic chain is the culprit — compare against `RobustnessProfile.raw`. |
| `deviceRate` is 8000/16000 with `transport=bluetooth` | Captured over a Bluetooth phone-call link. Pick the Mac's mic. |
| `rms` far below −40 dBFS | Input gain is very low; raise it in System Settings › Sound › Input. |

`Tests/EngineTests/LiveCapturePathWERTests.swift` covers the link the fixture suites cannot: at
16 kHz `AudioConverter16k` is a **no-op**, so no test had ever exercised the 44.1 kHz tap conversion
a real mic forces. Measured on this hardware: WER 0.0140 identically at 16 k, 44.1 k and 48 k, and
flat from −20 to −60 dBFS. Resampling and absolute level are both ruled out.
