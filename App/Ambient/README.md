# App/Ambient — ambient state + hard mute (P5.4)

| File | Role |
|---|---|
| `AmbientStateModel.swift` | `AmbientState` (listening / muted / processing) with SF Symbols for menu bar + notch; `AmbientStateModel` — mute is a hard latch (wins over processing, cleared only by `unmute()`), persistent `badge`, directed-speech "warm" beat. |
| `MuteController.swift` | Owns the model, persists the latch (`MuteStore`; `UserDefaultsMuteStore` live, `InMemoryMuteStore` tests) so a relaunch stays muted; observer fan-out for `StatusItemController` / notch view. |
| `NotYouCorrection.swift` | "Not you" hook: recent triggers → `DirectedSpeechExample` into a `DirectedSpeechTeacher` (P5.1 classifier implements it); `.notMe` also pushes the speaker embedding into the `SpeakerProfileUpdating` negatives. |

Wiring into `AppContainer` / `StatusItemController` / notch overlay is left to the AppWave integration agent
(this module is pure models; UI bindings: `model.menuBarSymbol`, `model.notchSymbol`, `model.badge`).
Tests: `Tests/AppTests/Ambient*`.
