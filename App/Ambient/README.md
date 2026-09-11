# App/Ambient — ambient state + hard mute (P5.4), ambient capture + Timeline retention (R8.1 / R8.2)

Two unrelated things share this directory, and it matters which is which:

* **Presence** (P5.4) — the glyph and the hard mute. About the *microphone*, not about speech.
* **Ambient capture** (R8) — transcript into the Timeline, and the seven days it lives. Off by
  default, behind its own switch, and it **never reaches an injection path** (V3 §8).

| File | Role |
|---|---|
| `AmbientStateModel.swift` | `AmbientState` (listening / muted / processing) with SF Symbols for menu bar + notch; `AmbientStateModel` — mute is hard (wins over processing, cleared only by `unmute()`), persistent `badge`, directed-speech "warm" beat. |
| `MuteController.swift` | Owns the model, persists the mute (`MuteStore`; `UserDefaultsMuteStore` live, `InMemoryMuteStore` tests) so a relaunch stays muted; observer fan-out for `StatusItemController` / notch view. |
| `NotYouCorrection.swift` | "Not you" hook: recent triggers → `DirectedSpeechExample` into a `DirectedSpeechTeacher` (P5.1 classifier implements it); `.notMe` also pushes the speaker embedding into the `SpeakerProfileUpdating` negatives. |
| `PresenceState.swift` | Idle-notch presence geometry / state. |
| `AmbientCaptureSettings.swift` | **R8.1** The three switches and their keys: `ambient.capture.enabled` (opt-in, off), `ambient.capture.everySpeaker` (off), and audio retention — which is the *recorder's existing* key, never a second one. Plus `ambient.retention.days` (R7.1's picker). |
| `AmbientCapture.swift` | **R8.1** `AmbientEntry`, `AmbientTranscriptSink`, `AmbientDiscardReason`, and `AmbientCaptureGate` — the enrolled-only decision. Evaluates R3's `SpeakerFilter` **as if it were on**: ambient may not inherit "filtering off allows every voice". |
| `AmbientInjectionAudit.swift` | **R8.1** The proof that ambient speech cannot be typed: a source audit both ways (`App/Ambient` names no delivery path; no injection path names an ambient-capture type) and a reflection audit of `AmbientEntry`. See `Tests/AppTests/AmbientNeverInjectsTests.swift`. |
| `AmbientRetention.swift` | **R8.2** `AmbientRetentionPolicy` (7 days, read from the picker) and `AmbientSweepResult`. |
| `AmbientTranscriptStore.swift` | **R8.1/R8.2** The Timeline's store. **Reuses `MeetingStore`** (same `MeetingRecord`/`MeetingUtterance`, JSON + Markdown), rooted at `…/VoicePlus/Ambient` so an ambient day is never listed as a meeting. One record per calendar day. Every delete path clears the transcript *and* the SQLite search index. |
| `AmbientWiring.swift` | **R8.1/R8.2** The composition seam: builds the store (sweeping retention at launch), reads the gate from settings, and connects `LatchRuntime.onTranscript`. Note what it is not — not a `LatchDelivering`, and it carries no destination. |

The search index itself is `Shared/Database/AmbientSearchIndex.swift` (`ambient_search_index`, added by
the additive `v2_ambient_search_index` migration). **Transcript text is not in SQLite** — only tokens,
so ambient content never enters a table that export, diagnostics or sync reads.

Presence wiring into `AppContainer` / `StatusItemController` / notch overlay is the AppWave integration
agent's. Ambient *capture* is attached with `AmbientWiring.attach(to: latchRuntime, sink:gate:)`; the
Timeline's store is installed via `MainWindowController.environment.timeline`, or built on demand by
`MainWindowController.make(deps:)`.

Tests: `Tests/AppTests/Ambient*`, `Tests/SharedTests/AmbientSearchIndexTests.swift`.
