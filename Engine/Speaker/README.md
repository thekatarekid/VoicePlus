# Engine/Speaker — speaker identification (P5.3, H2, H3)

| File | Role |
|---|---|
| `MFCCEmbedder.swift` | `SpeakerEmbedder` protocol, `SpeakerEmbedding` (`.cosine` L2 neural vector or `.gaussian` mean+std summary; `similarity`, `centroid`, `blended`), `MFCCEmbedder` — offline fallback: 30 MFCC (c0 dropped) + deltas per 10 ms frame → diagonal Gaussian (58 means + 58 stds); similarity = 1/(1+D/0.08) with D the variance-normalised mean distance. All vDSP. `identifiesSpeakers == false`. |
| `FluidSpeakerEmbedder.swift` | WeSpeaker v2 256-d via FluidAudio's diarizer models (reuses Engine/Meeting `FluidSpeakerEmbedding`). `SpeakerEmbedderFactory.make()` (H3) picks it when a complete copy is on disk — our install (`ModelID.speakerEmbedding` under `Models/speaker-diarization`) first, then FluidAudio's cache (`FluidAudio/Models/speaker-diarization`) — and never downloads. Otherwise MFCC, labelled "Voice filtering unavailable" (X03). |
| `SpeakerEnrollment.swift` | Prompted enrollment (3 prompts, onboarding-2 / Voice) and **passive** enrollment (H2, V4.49): 10 hold-to-talk utterances with ≥ 1.5 s of VAD speech → centroid `SpeakerProfile`; `progress`, `learnedCount`; Codable so progress survives relaunch (embeddings only, no audio). Rejects inconsistent utterances. Profile holds "not you" negatives, slow reinforcement, and the "Not you" `thresholdFloor`. |
| `SpeakerGate.swift` | Similarity gate → `.user/.other/.unknown`; latched mode drops `.other`. Thresholds: 0.5 MFCC (gaussian), 0.6 WeSpeaker (cosine), lifted by the profile's "Not you" floor up to +0.2 (`effectiveThreshold`). |
| `SpeakerFilter.swift` | Whether text may be inserted: off / active / not enrolled / model unavailable. `unavailableLabel` "Voice filtering unavailable", recovery `X03`; `availability(of:)`. |

The weights (H3, V4.50) are part of `ModelStack.models`: `FluidInference/speaker-diarization-coreml`,
`pyannote_segmentation.mlmodelc` + `wespeaker_v2.mlmodelc`, 13,720,676 bytes, fetched by `FluidAudioFetcher`.

The app side lives in `App/Services/LatchController.swift`: `observeHoldUtterance(samples:speechSeconds:)`
(passive enrollment), `install(profile:)` (filtering on + `LatchRuntime.speakerGuard`), `attach(runtime:segmentAudio:)`,
`insertionDecision(for:samples:)` (a hold is never filtered), `markNotYou(reason:)`.

Tests: `Tests/EngineTests/Speaker*`, `PassiveEnrollmentTests`, `SpeakerModelCatalogTests`;
`Tests/AppTests/PassiveEnrollmentLatchTests`. The TV/podcast rejection suite enrolls one TTS voice
(Samantha/Daniel/Rishi) from the fixture manifests and measures rejection of the other two voices on the MFCC
fallback. The WeSpeaker path is exercised only where the weights exist on disk.
