# Engine/Meeting — meeting capture (P5.5)

Local-only meeting capture: mic + system audio, echo-cancelled, VAD-chunked, diarized "You"/"Others",
extractive notes, local persistence. **No bot ever joins a call**; "Join & Record" only opens the
event's meeting URL in the user's own browser and starts capture on this machine.

Attribution: the system-audio design (CoreAudio process tap + heartbeat watchdog + ScreenCaptureKit
audio-only fallback, 3–5 s VAD chunking) is ported from **Muesli** (Muesli-HQ/muesli, MIT License,
Copyright (c) Muesli contributors). Code here is a re-implementation against our `AudioCaptureSource`
contract; where structure follows Muesli it is noted in file headers.

| File | Role |
|---|---|
| `SystemAudioRecorder.swift` | `ProcessTapSystemAudioSource` (macOS 14.2+, `CATapDescription`/`AudioHardwareCreateProcessTap`), `ScreenCaptureSystemAudioSource` (SCStream, audio only, no video output), `CaptureWatchdog` (heartbeat → restart → fallback), `SystemAudioRecorder` orchestrator. Both live sources conform to `AudioCaptureSource` so fixtures substitute 1:1. |
| `EchoCanceller.swift` | `NLMSEchoCanceller`: reference-aware AEC (system playback is the far-end reference for the mic). |
| `DualCapture.swift` | Two `AudioCaptureSource`s → AEC → per-channel VAD + `Chunker` → `MeetingChunk`s. |
| `Diarization.swift` | `MeetingSpeaker`, `SpeakerLabeler`; `ChannelLabeler` (mic=You, system=Others) always; `FluidDiarizer` (FluidAudio `DiarizerManager` + enrolled user embedding, cosine match) when models are on disk. Never downloads. |
| `MeetingNotes.swift` | `MeetingNotesProvider` protocol; `ExtractiveNotesProvider` — deterministic TF-scored extractive summary, action items, decisions. A Providers-backed LLM provider is injected at integration. |
| `MeetingDetector.swift` | Pure state machine over camera + calendar signals → `MeetingPrompt` (Join & Record / Record / Ignore). Live signals: `CameraInUseMonitor` (CoreMediaIO `DeviceIsRunningSomewhere`), `EventKitCalendarSignal`. |
| `MeetingSession.swift` | Transcript + notes model; `MeetingStore` persists JSON + Markdown under `AppPaths.supportDirectory()/Meetings/<id>/`. |

Untested live (no hardware/TCC in CI): process tap creation, SCStream, CoreMediaIO listener, EventKit.
Everything else runs on fixtures + mocks (`Tests/EngineTests/Meeting*`).
