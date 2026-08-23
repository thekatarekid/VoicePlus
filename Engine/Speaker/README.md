# Engine/Speaker — speaker identification (P5.3)

| File | Role |
|---|---|
| `MFCCEmbedder.swift` | `SpeakerEmbedder` protocol, `SpeakerEmbedding` (`.cosine` L2 neural vector or `.gaussian` mean+std summary; `similarity`, `centroid`, `blended`), `MFCCEmbedder` — offline fallback: 30 MFCC (c0 dropped) + deltas per 10 ms frame → diagonal Gaussian (58 means + 58 stds); similarity = 1/(1+D/0.08) with D the variance-normalised mean distance. All vDSP. |
| `FluidSpeakerEmbedder.swift` | WeSpeaker 256-d via FluidAudio diarizer models (reuses Engine/Meeting `FluidSpeakerEmbedding`); `SpeakerEmbedderFactory.make()` picks it when models are on disk, never downloads. |
| `SpeakerEnrollment.swift` | Onboarding-2 flow: 3 prompts → embeddings → centroid `SpeakerProfile` (JSON, no audio kept). Rejects inconsistent utterances. Profile holds "not you" negatives + slow reinforcement. |
| `SpeakerGate.swift` | Similarity gate → `.user/.other/.unknown`; hands-free drops `.other`. Thresholds: 0.5 MFCC (gaussian), 0.6 WeSpeaker (cosine). |

Tests: `Tests/EngineTests/Speaker*`. The TV/podcast rejection suite enrolls one TTS voice (Samantha/Daniel/Rishi)
from the fixture manifests and measures rejection of the other two voices on the MFCC fallback.
The FluidAudio path is exercised only when `~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml` exists.
