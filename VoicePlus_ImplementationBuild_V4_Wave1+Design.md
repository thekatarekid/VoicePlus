# VoicePlus — Implementation Build V4 · Wave 1 + Spool Design

Execution plan for **every Wave 1 item of `VoicePlus_Improvements_V4.md` §14.2** and **the complete
Spool design (`design/design_v1.md`, prototype `design/design_v1.html`)**, on top of `main` @ `d79cc98`
(1.10.0 candidate). Written to be run end to end by a coding agent with parallel subagents. Output is
release **1.11.0**.

---

## 0. How to run this document

- Read first: `VoicePlus_Improvements_V4.md` §0–§14 (why), `design/design_v1.md` §3–§13 (what it must look
  like and do), this document (how). `VoicePlus_Improvements_V3.md` §1 rules still apply.
- Work wave by wave (§1). Inside a wave every task marked **[P]** runs in its own subagent at the same
  time. A wave is done when every task in it reports done. Do not start a wave early.
- **One subagent = one task.** It owns only the paths listed under *Owns* and its test target. Two tasks
  in the same wave never own the same file; where a file is shared it is listed under *Shared, disjoint
  regions* with the function each task may touch.
- Every task ends with: whole package builds clean, its tests green, a ≤15-line report (§6), a scoped commit.
- Evidence labels: `implemented` · `fixture-verified` · `hardware-verified`. Never upgrade a label. Hardware
  checks go to §5; they never block the next wave.
- The prototype is the visual reference. Open `design/design_v1.html` for geometry, motion and copy; the
  Spool SVG geometry is in its JS (`function art / face / lens / rig / limb / tapeRibbon`, lines ~850–1013)
  and is ported, not redrawn.

### Ground rules
- Toolchain: `eval "$(Scripts/bootstrap-toolchain.sh)"` once per shell. Swift Testing only. No XCTest, no
  simulators. Swift 5 language mode.
- Scratch path per task: `swift build --scratch-path .build-<task>`; tests
  `swift test --scratch-path .build-<task> --filter <Module>Tests`. Release verification uses
  `swift test --no-parallel` (progress.md: parallel runs flake ~14 timing assertions).
- `Shared/` and `Package.swift`: additive only, and only in wave 0 tasks. Report every touch.
- Commit: `git add <paths> && git commit -m "<task id>: <what>"`. Never `git add -A`, never push, never
  rebase or reset. If `index.lock` exists, wait 2 s and retry.
- No new SwiftPM dependency. ScreenCaptureKit, Vision, AVFoundation, Accessibility are system frameworks.
- Flags are never deleted; a losing candidate gets `defaultOn = false`.
- Copy voice is *Problem — Action* (DESIGN.md §7.1). No raw enum tokens or filenames in a headline.
- Nothing revises text after it lands (V3 §4.1). Insertion is once per turn, guarded by turn ID.

### Existing facts to rely on
| Fact | Where |
|---|---|
| Capture graph | `Engine/Audio/AudioCaptureSource.swift` (`CoreAudioCaptureSource`, `buildGraph`, `pin`, `syncClientFormat`, `verifyFormats`); `Engine/Audio/Robustness/AcousticCaptureSource.swift` (0.5 s pre-roll) |
| Start budget | `App/Services/PipelineAudioSource.swift:23` `startTimeout = 3`; events loop `:100-119` (`default: break` drops `.vad/.chunk/.endpoint`) |
| Launch order | `App/AppDelegate.swift:45-54` awaits `AppContainer.build`; `CapabilityWatcher` built in `wire()`; `AppContainer.swift:315-329` `warmUpEngine()` at `.utility` |
| Model maintenance | `Engine/ASRRuntime/ModelManager.swift:91-124` synchronous `runMaintenance` |
| Engine | `Engine/ASRRuntime/RealEngine.swift` (`minimumUtteranceSeconds = 0.3` `:155`; `stop()` `:436-458`; `prewarm()` `:231` unused) |
| Latch | `App/Services/LatchRuntime.swift` (`tick/noteVAD/noteEndpoint` `:167/182/196` uncalled; `endpointer` `:102`; raw `joinedText` inject `:406`); `Engine/Audio/AudioPipeline.swift:34` `Options.latched` |
| Coordinator | `App/Services/DictationCoordinator.swift` (`handle(_:)` `:159`; `endSession` `:300-318` lands immediately); `App/Services/SessionCoordinator.swift` (ranks) |
| Formatting | `Pipeline/Formatters/FieldRole/{FieldRoleFormatter,Continuation,FieldRules,FieldRole}.swift`; `Pipeline/Style/StyleStage.swift`; `Pipeline/Formatters/ProseFormatter.swift` (`Numbers` `:295-437`, `renderedText` `:47-56`) |
| Field context | `App/Services/FieldContextReader.swift:37-64` (caret fallback `:60`); `Injection/LiveSystemAccess.swift:28-62` |
| Lander | `App/Services/UtteranceLander.swift` (`land` `:117`; `joinedText` at `:132,154,167,178,191,201`; continuation `:207-221`) |
| Join | `Shared/Types/TranscriptSpan.swift:163` `joinedText` (joins empty spans) |
| Mic quality | `Engine/Audio/MicQualityAnalyzer.swift`; `AudioPipeline.swift:281`; `App/Core/PillState.swift:73-77` |
| Pill | `App/UI/PillView.swift` (`PillViewModel`), `PillPanelController.swift`, `App/Core/PillState.swift`, `PillPresentation.swift` (`PillDwell`), `PillDelivery.swift` (`DeliveryCopy`, `HeldTextStore`) |
| Geometry | `App/Core/NotchGeometry.swift` (`absoluteMaximumSize` 560×96 `:79`), `NotchPresenceGeometry.swift` (rest 54×10, hover 190×24) |
| Presence | `App/UI/PresenceIndicatorController.swift`, `PresenceIndicatorView.swift` |
| Menu | `App/UI/StatusItemController.swift` (SF-symbol icon `:114`), `App/Core/MenuModel.swift` |
| Hotkey | `App/Core/HotkeyStateMachine.swift` (`Kind.fn` = key 63, `maskSecondaryFn`); `App/Services/HotkeyService.swift` (Carbon `RegisterEventHotKey` `:569-610`, no permission for chords) |
| Deixis / ink | `Actions/Timeline/EventTapRecorder.swift:28,100-111`; `App/Overlay/{OverlayWindow,InkOverlayController,StrokeGeometry}.swift`; `App/Services/DeixisService.swift`; `Actions/Deixis/{DeixisResolver,AXHitTesting}.swift`; `App/AppDelegate.swift:198-209` |
| Word rects | `App/Correction/CorrectionOverlay.swift` (`WordRectProvider`, `kAXBoundsForRangeParameterizedAttribute`), `App/Repair/RepairFanoutPanel.swift:26` |
| Confidence | `Shared/Types/TranscriptSpan.swift:59,91-93` (`isLowConfidence` < 0.5), `Engine/Confidence/WordConfidence.swift`, `Engine/Reconcile/WordAligner.swift` |
| Speaker | `Engine/Speaker/{SpeakerGate,SpeakerFilter,SpeakerEnrollment,FluidSpeakerEmbedder,MFCCEmbedder}.swift`; `App/Services/LatchController.swift:37` (`speakerFilteringEnabled = false`), `:119-126`; `LatchRuntime.swift:91` (`speakerGuard`) |
| Window | `App/Settings/MainWindowSection.swift:14` (six sections), `:104` (subpages `general, models, voice, personas, dictionary, snippets, flags, connectors, sync, data, benchmark`); `MainWindowView.swift`; `SectionState.swift` |
| Onboarding | `App/Onboarding/OnboardingStateMachine.swift:21` (`welcome, microphone, accessibility, firstDictation, done`) |
| Permissions | `App/Core/PermissionMatrix.swift:5` (`microphone, accessibility, inputMonitoring`) |
| Recorder | `Engine/Audio/UtteranceRecorder.swift:27` (`retainedUtterances = 20`) |
| Meetings | `Engine/Meeting/*`, `App/Services/MeetingCoordinator.swift`, `App/Settings/Meetings*` |
| Timeline / Today | `App/Settings/TodayTimeline.swift`, `TodaySectionViewModel.swift` |
| Adapters | `Injection/AppAdapter.swift` (`ElectronAdapter` set `:125`, `ChromiumAdapter` `:157`) |
| Design system today | `DESIGN.md` (§8 documents the pill "as-is", §9 window, §11 onboarding) |
| Corpus + replay | `Fixtures/real-room/`, `Tests/EngineTests/RecordingReplayTests.swift`; `Fixtures/audio/{clean,noisy,silence,vad}` |

### The verified design is authoritative
`design/design_v1.html` and `design/design_v1.md` have been iterated on and verified by the owner. Their
states, colours, geometry, animations, copy and screens are requirements, not suggestions. Order of
authority for anything visible: **prototype code → design_v1.md → this document → DESIGN.md → V4 plan.**
Where the prototype simulates something the markdown specifies for the real product (live audio, real
insertion), the markdown's real-product rule applies; that is the design, not a deviation.

Copy and art are not retyped by hand. Both come from fixtures generated out of the prototype:
`node Scripts/spool_golden.mjs` writes `Fixtures/spool/spool_spec.json`, `Fixtures/spool/spool_golden.json`
and `Fixtures/design/design_copy.json` (pill copy for 26 states, 12 screen titles and subtitles, 14 empty
states, the per-screen error mapping, the 26-row state inventory, the 59-entry recovery catalogue). Tests
compare the Swift strings and drawings with these files. Re-run the script whenever `design_v1.html` changes.

### Owner decisions that differ from the verified design (the only permitted differences)
| Topic | Verified design | Owner decision | How it is applied |
|---|---|---|---|
| Default key | Right Control | **fn / 🌐** | Every string containing "Right Control" in the copy fixture is rendered with the configured key label instead; nothing else in the string changes |
| Voice enrollment | optional, in the Voice section | **also a step in onboarding**, skippable | Inserted after "Try dictation", before "Ready"; uses the Voice section's enrollment view and copy |
| Deixis box | not in the design | **box + screenshot, thumbnail in the pill** | Drawn in the text lane under the transcript, never in the character bay, never over Spool; uses the design's chip styling |
| V4 settings (latch pause, spacing, unknown-caret style, draw-without-key, recordings retention, screen text) | not in the design | required by V4 Wave 1 | Added as ordinary rows in the design's existing subpages with the design's row, toggle and select components; no new subpage |

Everything else follows the design exactly. In particular: hold lands once on release; Escape cancels
during a turn; readback that cannot confirm is always "⚠ Inserted · not confirmed" (V4.20 is withdrawn);
error and held notices stay until the user acts (no timed dismissal); the latch pill shows the design's
timer only (the V4.38 countdown ring is withdrawn); the Settings subnav has exactly the design's seven
subpages.

---

## 1. Parallel execution map

```
wave 0  gates (4 agents, ≤ 1 h each, all [P])
        G0.1 Shared types   G0.2 audio event forwarding   G0.3 DESIGN.md v2 + tokens   G0.4 PillState/EngineState cases
                │                    │                              │                          │
wave 1  ────────┴────────────────────┴──────────────────────────────┴──────────────────────────┴───────────
        A audio start   B latch   C speech guards   D caret+formatting   E numbers   F1 SNR   G deixis box
        H speaker       I hotkey+Escape   J small fixes   S1 Spool art   S6 menu glyph   S9 recovery catalogue
                │
wave 2  ────────┴──────────────────────────────────────────────────────────────────────────────────────────
        S2 pill + presence   S3 turn controller   S7a window shell ─► S7b–S7g six sections [P]   S8 onboarding   S12 mascot policy + action surfaces
                │
wave 3  ────────┴──────────────────────────────────────────────────────────────────────────────────────────
        S4 tape flight (S2, S3)   S5 uncertainty marks + correction (S2, S3)   S10 a11y + motion (S2, S7a–g)   S11 catalogue wiring (S9 → all)
                │
wave 4  ────────┴───  R release: full test run, fixtures replay, DMG 1.11.0, logs, owner checklist
```

| Wave | Tasks | Needs |
|---|---|---|
| 0 | G0.1 · G0.2 · G0.3 · G0.4 | nothing |
| 1 | A1–A5 · B1–B4 · C1–C3 · D1–D7 · E1–E2 · F1 · G1–G3 · H2–H3 · I1–I2 · J1–J2 · S1 · S6 · S9 | wave 0 |
| 2 | S2 · S3 · S7a → (S7b · S7c · S7d · S7e · S7f · S7g) · S8 · S12 | wave 1; S7b–S7g also need S7a |
| 3 | S4 · S5 · S10 · S11 | wave 2 |
| 4 | R1–R4 | wave 3 |

### Subagent split (no two agents own the same file inside a wave)

| Wave | Agent | Task(s) | Owns | Tests |
|---|---|---|---|---|
| 0 | a | G0.1 | `Shared/Types/` (new files + additive fields) | `SharedTests` |
| 0 | b | G0.2 | `App/Services/PipelineAudioSource.swift` (events loop only) | `AppTests` |
| 0 | c | G0.3 | `DESIGN.md`, `App/Core/DesignTokens.swift` (new) | `AppTests` |
| 0 | d | G0.4 | `App/Core/PillState.swift`, `Shared/Types/EngineState.swift` (additive cases) | `AppTests`, `SharedTests` |
| 1 | a | A1–A5 | `Engine/Audio/AudioCaptureSource.swift`, `Engine/Audio/Robustness/AcousticCaptureSource.swift`, `Engine/ASRRuntime/ModelManager.swift`, `App/Services/PipelineAudioSource.swift` (**`start()/stop()` only**), `App/Services/AppContainer.swift` (`warmUpEngine`, build order), `App/AppDelegate.swift` (**launch order only, lines 45–54**) | `EngineTests`, `AppTests` |
| 1 | b | B1–B4 | `App/Services/LatchRuntime.swift`, `LatchController.swift` (**latch wiring only**), `SessionCoordinator.swift`, `DictationCoordinator.swift` (**latch paths only**), `Engine/Audio/AudioPipeline.swift` (`Options` API), `App/Settings/SettingsStore.swift` (new keys) | `AppTests`, `EngineTests` |
| 1 | c | C1–C3 | `Engine/ASRRuntime/RealEngine.swift`, `Engine/ASRRuntime/HallucinationGuard.swift` (new), `Engine/Audio/Endpointer.swift` | `EngineTests` |
| 1 | d | D1–D7 | `Pipeline/Formatters/FieldRole/`, `Pipeline/Style/StyleStage.swift`, `App/Services/FieldContextReader.swift`, `App/Services/LandingMemory.swift` (new), `App/Services/UtteranceLander.swift`, `Injection/LiveSystemAccess.swift`, `Injection/SystemAccess.swift` (additive) | `PipelineTests`, `AppTests`, `InjectionTests` |
| 1 | e | E1–E2 | `Pipeline/Formatters/ProseFormatter.swift` (`Numbers`, `Assembler`), `Engine/ASRRuntime/PreviewFormatter.swift` | `PipelineTests`, `EngineTests` |
| 1 | f | F1 | `Engine/Audio/MicQualityAnalyzer.swift`, `Engine/Audio/AudioPipeline.swift` (**`process()` mic-quality lines only**) | `EngineTests` |
| 1 | g | G1–G3 | `Actions/Timeline/`, `Actions/Deixis/`, `App/Overlay/`, `App/Services/DeixisService.swift`, `App/Services/ScreenTextService.swift` (new), `App/Core/PermissionMatrix.swift`, `App/AppDelegate.swift` (**hotkey.onAction block, lines 198–209**) | `ActionsTests`, `AppTests` |
| 1 | h | H2–H3 | `Engine/Speaker/`, `Engine/ASRRuntime/ModelCatalog.swift`, `App/Services/LatchController.swift` (**enrollment/filter fields only**) | `EngineTests`, `AppTests` |
| 1 | i | I1–I2 | `App/Services/HotkeyService.swift`, `App/Core/HotkeyStateMachine.swift`, `App/Services/EscapeHotkey.swift` (new) | `AppTests` |
| 1 | j | J1–J2 | `Engine/Audio/UtteranceRecorder.swift`, `Injection/AppAdapter.swift` | `EngineTests`, `InjectionTests` |
| 1 | k | S1 | `App/UI/Spool/` (new directory) | `AppTests` |
| 1 | l | S6 | `App/UI/StatusItemController.swift`, `App/Core/MenuModel.swift`, `App/UI/MenuBarGlyph.swift` (new) | `AppTests` |
| 1 | m | S9 | `App/Core/RecoveryCatalog.swift` (new), `Engine/ASRRuntime/EngineErrorMessage.swift` | `AppTests`, `EngineTests` |
| 2 | a | S2 | `App/UI/PillView.swift`, `PillPanelController.swift`, `PresenceIndicator*.swift`, `App/Core/NotchGeometry.swift`, `NotchPresenceGeometry.swift`, `PillPresentation.swift`, `PillDelivery.swift` (copy) | `AppTests` |
| 2 | b | S3 + S11 | `App/Services/TurnController.swift` (new), `DictationCoordinator.swift`, `UtteranceLander.swift`, `App/Services/TurnStore.swift` (new), `Injection/FocusGuard.swift`, `Injection/TextInjector.swift` (commit guard) | `AppTests`, `InjectionTests` |
| 2 | c | S7a (first), then hands off | window shell + `App/UI/Components/` | `AppTests` |
| 2 | e–j | S7b · S7c · S7d · S7e · S7f · S7g (after S7a) | one section each, paths in §3 | `AppTests` |
| 2 | k | S12 | `App/UI/Spool/SpoolSurfacePolicy.swift`, `App/Transform/` (preview UI), `App/UI/ConsentPanels.swift`, `App/UI/ActionPreview*.swift` | `AppTests` |
| 2 | d | S8 | `App/Onboarding/` | `AppTests` |
| 3 | a | S4 | `App/Overlay/TapeFlight*.swift` (new), `App/UI/Spool/` (anchor API) | `AppTests` |
| 3 | b | S5 | `App/Correction/`, `App/UI/Marks/` (new), `Engine/Reconcile/WordAligner.swift` (additive) | `AppTests`, `EngineTests` |
| 3 | c | S10 | cross-cutting, `App/UI/`, `App/Settings/` (accessibility modifiers only) | `AppTests` |
| 3 | d | S11 | every consumer of error copy (`App/`, `Engine/ASRRuntime/EngineErrorMessage.swift`) | `AppTests` |
| 4 | one | R1–R4 | `progress.md`, `DECISIONS.md`, `Packaging/`, `Fixtures/prosody/script.md` | all |

For a Workflow script: wave = `phase`, agent row = one `agent()` call with `label: "<wave>:<task>"`, and
the *Owns* column is the only path list in its prompt. Use `parallel()` inside a wave, `pipeline()` across
waves. Agents in wave 1 have no dependency on each other except the file-ownership rule above.

---

## 2. Definitions used by every task

- **Turn:** one press-to-outcome cycle with a `TurnID`. Hold = one turn; latch = one turn per segment.
- **Final payload:** the immutable `[TranscriptSpan]` + rendered text published after the final pass and
  formatting. Shown in the pill during dwell; inserted exactly once; never revised.
- **Dwell:** time the final payload is visible before insertion. 900 ms default; 1800 ms when any span
  `isLowConfidence`; 600 / 900 / 1500 / manual in Settings. Hover, focus, selection or Review freezes it.
- **Caret state:** `known(before, after)` · `endOfField(before)` · `unknown`. Never map a missing range to
  `endOfField`.
- **Landing memory:** the element identity, the text we last landed and how it ended, valid until any
  click, key, scroll, app switch or 30 s.
- **Delivery outcome:** `delivered(verified)` · `delivered(unverified)` · `partial` · `held` · `failed`.
  Readback rule unchanged (V3 §6): a posted method is never followed by another.
- **Segment (latch):** audio closed by an endpoint after `pauseSeconds` of trailing silence; lands through
  the same turn gate as a hold, serialized by `SegmentID`.
- **Spool pose:** the pure model (`reelAngle`, `reelDirection`, eyelids, brows, pupils, mouth, tape tension,
  twist phase, amplitude) that the pill state maps to. Presentation only; never a write trigger.
- **Screen text:** lines + boxes returned by the OCR service for a rect, kept in memory for one turn.

---

## 3. Items and tasks

### Wave 0 — gates

- [ ] **G0.1 Shared types · [P]**
  - `Shared/Types/CaretState.swift`: `enum CaretState { case known(before: String, after: String), endOfField(before: String), unknown }` + `var textBefore/textAfter`.
  - `Shared/Types/TranscriptSpan.swift`: add `punctuationOrigin: PunctuationOrigin = .model` (`.model`, `.spoken`, `.stage`) Codable with default; add `var renderedText: String` on `[TranscriptSpan]` (skips empty spans, collapses runs of spaces). Keep `joinedText` for tests only.
  - `Shared/Types/TurnRecord.swift` (design §12): `turnID`, `startedAt`, destination snapshot (`bundleID`, role, element hash, display), `rawText`, `finalText`, `uncertainSpans: [Range<Int>]`, capture timestamps, `writeAttempted`, `outcome: DeliveryOutcome`, `retainedAudioPath?`.
  - `Shared/Types/ScreenText.swift`: `protocol ScreenTextReader { func lines(in rect: CGRect, display: CGDirectDisplayID) async throws -> [ScreenTextLine] }`, `ScreenTextLine { text, box: CGRect, confidence, characterBoxes: [CGRect]? }`.
  - `Shared/Types/DeliveryOutcome`: add `.partial(method:)` if absent.
  - Tests: `SharedTests` round trips + `renderedText` vs `joinedText` table. Acceptance: whole package builds; no existing test changed except added cases.

- [ ] **G0.2 Audio event forwarding · [P]**
  - `App/Services/PipelineAudioSource.swift` events loop (`:100-119`): replace `default: break` with
    `onVAD: ((VADEvent) -> Void)?`, `onEndpoint: ((Endpointer.Decision) -> Void)?`, `onChunk: ((AudioChunk) -> Void)?`
    forwards; add `setLatched(_ on: Bool)` that flips `AudioPipeline.Options.latched` on the live pipeline.
  - Tests: `AppTests` — a mock pipeline emitting `.vad/.endpoint` reaches the callbacks; `setLatched` is observed by the pipeline. Nothing else in this file changes (wave 1 A owns `start/stop`).

- [ ] **G0.3 DESIGN.md v2 + tokens · [P]**
  - `DESIGN.md`: replace §8 ("the pill as-is") with design_v1 §3, §4, §6 (Spool, geometry table, state inventory I0–Q2); add the token table (§3), typography, spacing/radii; keep §5 focus rules and §7 copy voice; amend §9–§11 with the design §8 window, menu and onboarding. Record the authority order and the owner decisions from §0 of this document, and replace the old rule that forbade "hands-free" in UI copy with the verified latched copy.
  - `App/Core/DesignTokens.swift`: `enum Tokens` — colours as `NSColor(name:dynamicProvider:)` with the dark/light pairs from design §3 (canvas, sidebar, surface, elevated, ink, secondary ink, separator, accent, ready, attention, uncertainty, pill), the six Spool material tokens, typography roles (title 24/30, section 17/24, body 13/20, meta 11/16, pill transcript 14/20 medium, pill status 11/16, key 11/16, tabular digits), spacing scale, radii (window 16, group 10, control 7, pill 18 standalone / lower-only when attached).
  - Tests: `AppTests` contrast test computing WCAG ratios for every ink/surface pair in both themes (≥ 4.5:1 text, ≥ 3:1 lines). Acceptance: all pairs pass or the failing pair is adjusted and recorded in DESIGN.md.

- [ ] **G0.4 State cases · [P]**
  - `App/Core/PillState.swift`: add `.ready(hint: String)`, `.muted`, `.starting`, `.listeningQuiet`, `.latched(elapsed: TimeInterval)`, `.cancelled`, `.finishing(elapsedWarning: Bool)`, `.finalPreview(FinalPreviewInfo)` (text, uncertainCount, dwellRemaining, paused, manual), `.inserting(text:)`, `.landed` gains `.partial`, `.correcting`, `.editing`, `.undoAvailable`, `.meeting(MeetingPillInfo)`; keep every existing case. `messageLines` and `caseName` extended. `PillStateReducer` maps the new `EngineState` cases (below) 1:1; nothing else changes.
  - `Shared/Types/EngineState.swift`: add `.starting`, `.finishing`, `.cancelled` (additive).
  - Tests: `AppTests` reducer table for every case. Acceptance: builds; existing `PillTests` unchanged.

### Wave 1 — A · Audio start and warm-up (V4.6–V4.10)

- [ ] **A1 Format sync (V4.9) · [P]**
  - `CoreAudioCaptureSource.buildGraph`: call `syncClientFormat(unit:)` **unconditionally** after `pin` (including the "already the system default" early return). If `verifyFormats` still disagrees, recreate the `AVAudioEngine` (make `engine` a `var`; tear down tap/monitor; rebuild once) and verify again; only then throw `.formatMismatch`.
  - Keep the route monitor running while stopped (or re-enumerate at the top of `prewarm`) so a device change between turns is seen.
  - Tests: `EngineTests` — pure `GraphRebuildPolicy` (formats agree → no rebuild; disagree after sync → rebuild once; disagree twice → throw); diagnostics record `clientFormatPushed` on the default-device path. Evidence: `implemented`; §5 item 1 for hardware.

- [ ] **A2 Adaptive start budget (V4.10) · [P]**
  - `PipelineAudioSource.startTimeout` becomes `budget(for transport:)`: builtIn 3 s, USB 5 s, Bluetooth / Continuity / virtual 8 s (self-test keeps 15).
  - Error copy via `RecoveryCatalog` ids: timeout → **A03** "Couldn't start this microphone" naming the device; format → **A04** "This microphone needs reconnecting". Subtitle keeps "Nothing was typed".
  - Tests: budget table; error mapping. Evidence: `implemented`.

- [ ] **A3 Hotkey armed before the container (V4.6) · [P]**
  - `AppDelegate.applicationDidFinishLaunching`: construct `HotkeyService` + `CapabilityWatcher` first; then `Task { AppContainer.build }`. A press before the container lands shows `.starting` ("Starting microphone…"); if the key is still down when the container lands, capture starts; if released, nothing lands (K03 quiet return). One queued press max.
  - Tests: `AppTests` with a fake container future: press-before-ready → `.starting`; still-held → capture; released → nothing; two presses → one.

- [ ] **A4 Warm-up at launch, graph kept between turns (V4.7) · [P]**
  - `AppContainer.warmUpEngine()`: `.userInitiated`; after `preloadModel()` call `engine.prewarm()` (audio graph built, mic **not** open) and again on `.deviceChanged`.
  - `CoreAudioCaptureSource.stop()`: between turns `engine.pause()` with the tap left installed and the AUHAL pinned; full `engine.stop()` only on hard mute, quit, device change or 10 min idle. `start()` from paused state must not re-enumerate or re-pin.
  - Log key-down → first buffer (ms) per turn at `.info`.
  - Tests: `EngineTests` capture-state machine (`prepared → running → paused → running`, `paused → stopped` on mute/idle); no HAL calls on `paused → running` (count through the diagnostics struct). Evidence: `implemented`; §5 items 2–3 for the p95 < 150 ms and the mic indicator off while paused.

- [ ] **A5 Maintenance off the build path (V4.8) · [P]**
  - `ModelManager.runMaintenance` runs detached after `wire()`; still under the cross-process lock; `ModelManager.init` no longer blocks on it. Tests: init returns before maintenance completes (fake lock).

### Wave 1 — B · Latch (V4.32, V4.33, V4.37, V4.38 publish)

- [ ] **B1 Endpoint loop (V4.32) · [P]**
  - On `.enterLatch`: `audio.setLatched(true)`; subscribe `onVAD` → `LatchRuntime.noteVAD`, `onEndpoint` → `LatchRuntime.noteEndpoint`; drive `LatchRuntime.tick` from the audio position; on `.endpoint` call `closeSegmentAtEndpoint()` → engine closes the segment → `.closed(reason: .endpoint)` → delivery.
  - Delivery takes a **fresh focus snapshot at segment close**, never the key-release one. Focus changed since the segment's speech began → `.held` (D01 copy). Segments are serialized by `SegmentID`.
  - On leaving latch: `setLatched(false)`, endpointer reset.
  - Tests: `AppTests` with `MockEngine` + scripted VAD: three pauses → three landings in order; focus change mid-segment → that segment held, next lands; no endpoint → nothing lands until the stop tap. Evidence: `implemented` + `fixture-verified` (`Fixtures/audio/vad`).

- [ ] **B2 Pause setting (V4.33) · [P]**
  - `SettingsKeys` entry `latch.pauseSeconds` (read through the `SettingsStore` protocol) (1.0–5.0, default 2.0) → `LatchRuntime.endpointer = Endpointer(trailingSilence: pause, noSpeechTimeout: 8, maxUtterance: 30)`; live update while latched. UI row is S7g (Shortcuts subpage). Tests: setting round trip; endpointer rebuilt on change.

- [ ] **B3 Field context in the latch path (V4.37) · [P]**
  - `LatchRuntime.swift:406`: replace the raw `joinedText` injection with `UtteranceLander.land` (continuation, field rules, `renderedText`). Tests: latch segment lands through the lander (spy).

- [ ] **B4 Latch presentation feed · [P]**
  - `LatchRuntime` publishes `elapsed` → `DictationCoordinator` → `pill.model.apply(.latched(elapsed:))` for
    the design's timer. No countdown ring (V4.38 withdrawn to match the design). Tests: elapsed advances,
    resets on a new latch.

### Wave 1 — C · Speech guards (V4.21–V4.23)

- [ ] **C1 Decode only if the VAD saw speech (V4.21) · [P]**
  - `RealEngine` receives `noteVAD(_:)` (wired from `onVAD`) and accumulates speech seconds per open segment. `stop()` and the endpoint close decode only when `speechSeconds ≥ 0.3`; otherwise return `[]` with `EngineStopReason.noSpeech`. Coordinator maps it to **A06** "No speech detected — Try again" as a quiet return (fades 1200 ms).
  - Tests: `EngineTests` — silence hold → no decode call (spy decoder); 0.4 s speech → decode. `Fixtures/audio/silence` replay lands nothing.

- [ ] **C2 Hallucination guard (V4.22) · [P]**
  - `Engine/ASRRuntime/HallucinationGuard.swift`: pure `verdict(text:, speechRatio:, speechSeconds:, meanConfidence:, tokens:) -> Verdict`. Drop when (speechRatio < 0.2 ∧ normalized text ∈ filler set {"you", "thank you", "thanks for watching", "bye", "the end", "subtitles by", "okay"}) ∨ (any token repeats ≥ 4× consecutively) ∨ (meanConfidence < 0.3 ∧ speechSeconds < 1). Applied in `RealEngine` after the final pass; drops are logged with the utterance stamp and count in `EngineDiagnostics`.
  - Tests: verdict table (≥ 12 rows incl. "Thank you." with 60 % speech ratio → keep).

- [ ] **C3 Pre-roll only when the graph was already running (V4.23) · [P]**
  - `AcousticCaptureSource.start()`: prepend `held` only if `prewarmed` was true **before** this key-down (A4 makes that the normal case); a press that opened the mic gets no pad. Tests: two-path test with a fake inner source.

### Wave 1 — D · Caret and formatting (V4.1–V4.5, V4.13, V4.16, V4.17)

- [ ] **D1 Three-valued caret (V4.2, V4.3) · [P]**
  - `FieldContextReader` returns `CaretState`. Rungs: `kAXSelectedTextRange` on `kAXValue` → `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange` / `AXTextMarkerRangeForUnorderedTextMarkers` (WebKit/Chromium; add the parameterized reads to `LiveSystemAccess`, mocked in `MockSystemAccess`) → `unknown`. `endOfField` only when a range is known and equals the value length. Remove the `?? count` fallback at `:60`.
  - Tests: `AppTests` + `InjectionTests` — value without range → `unknown` (not end); marker range answers → `known`; secure → refused as before.

- [ ] **D2 Model punctuation is provisional (V4.1) · [P]**
  - `SpokenPunctuation` stage marks spans it creates `.spoken`. `FieldRoleFormatter`: `stripAddedTrailingPeriod` strips a `.model` period when the caret is `known` with non-empty `after` or when `before` does not end a sentence; `applyFirstWordCase` lowercases a `.model` capital when `before` ends with a word character or a space after a non-terminal; `.spoken` marks are always kept.
  - `FieldRolePipeline`: StyleStage is disabled whenever a caret state exists that is not `endOfField`-after-terminal; with no context (`unknown`) StyleStage is **off**.
  - Tests: `PipelineTests` matrix (mid-sentence word → lowercase, no period; after "." + space → capital; empty field → capital + period for ≥ 3 words).

- [ ] **D3 Continuation rules (V4.4) · [P]**
  - `Continuation.swift`: table — after `[.!?]`+space → capital, no leading space; after a word → " " + lowercase + no period; before a word → trailing " ", no period; inside a word → no spaces; empty → capital, period only if ≥ 4 words; `unknown` → **no leading space**, ≥ 3 words keep model casing/punctuation, 1–2 words stripped; `paragraphIntent` branch removed unless wired.
  - Setting `formatting.unknownCaretStyle` = `sentence` (default) | `asSpoken` (S7g renders it).
  - Tests: full table; `unknown` never produces a leading space.

- [ ] **D4 `renderedText` everywhere (V4.13) · [P]**
  - `UtteranceLander` `:132,154,167,178,191,201`, `LatchRuntime` (B3 does its line), `CodeSwitchService` if it joins. Tests: filler-removed first span → no leading space; ITN-collapsed spans → single spaces.

- [ ] **D5 Landing memory (V4.16) · [P]**
  - `App/Services/LandingMemory.swift`: records element identity (bundle, role, AX hash), landed text, ending class (word / space / terminal), timestamp. Invalidated by NSEvent global monitors for mouse-down, scroll, key-down (Accessibility trust; if unavailable, mouse + app switch + 30 s TTL only), app activation. `FieldContextReader` consults it when the AX rung is `unknown` → `known(before: lastLanded, after: "")`.
  - Tests: sequence of two landings → second joins correctly; click between → `unknown`.

- [ ] **D6 Spacing setting (V4.17) · [P]** — `formatting.spacing` = automatic | always | never; applied in `Continuation`. Tests: three modes.

- [ ] **D7 Per-app caret capability memory (V4.5) · [P]** — after N = 5 landings in a bundle where every AX rung was `unknown`, skip the AX round-trip (go to landing memory), reset when a rung answers. Tests: counter and reset.

### Wave 1 — E · Numbers (V4.11, V4.12)

- [ ] **E1 Punctuation-tolerant ITN (V4.11) · [P]**
  - `Numbers.parse`: strip trailing `[,.;:!?]` from each token before lookup, carry the mark of the **last consumed** token, re-attach to the emitted number. The `and` bridge checks the stripped next token. Tests: "five thousand one hundred and fifty." → "5,150."? — **no grouping separators** by default (design has 2,340 in script 05; keep `Numbers` grouping as it is today); "one, two, three, four." unchanged by E1 alone (E2 handles it).

- [ ] **E2 Digit sequences by timing (V4.12) · [P]**
  - ≥ 3 consecutive single-digit spans with inter-span `audioRange` gaps < 250 ms and no `.spoken` comma → concatenate ("1234"); with gaps ≥ 250 ms or spoken commas → list "1, 2, 3, 4". Years ("twenty twenty six") and phone-style runs covered by the same rule. `Assembler` writes the result into one span and blanks the rest (D4 renders cleanly).
  - `PreviewFormatter` digitizer gains `hundred` and `and` so preview and final agree on the common cases (full unification is V4.14, Wave 2).
  - Tests: timing table with synthetic `audioRange`s; corpus replay on `Fixtures/real-room` script line 05 unchanged.

### Wave 1 — F · SNR that measures SNR (V4.18)

- [ ] **F1 MicQualityAnalyzer v2 · [P]**
  - Noise floor = p10 of 10 ms frame RMS over the pre-speech window (key-down → first VAD `speechStart`, min 200 ms; else the running 4 s minimum from `EnergyVAD`'s floor tracker). Signal = p90 over VAD-speech frames of the first 1 s of speech. Emit **once**, after both exist. `lowLevel` only when speech peak < −40 dBFS; a pause is never graded. Verdict: poor < 10 dB, bad < 5 dB (recorded as `hypothesis` in DECISIONS.md, to be set by Wave 2 corpus). `flush()` at stop grades only if speech was seen.
  - Feed: `AudioPipeline.process` passes VAD events to the analyzer (F1 owns those lines; C1 owns nothing in `AudioPipeline`).
  - Tests: `EngineTests` on `Fixtures/audio/clean` (≥ 20 dB, `.good`), `noisy` (< 10 dB), `silence` (no verdict), synthetic 1.5 s pause then speech (no `lowLevel`).

### Wave 1 — G · Deixis box, screenshot, OCR service (V4.27–V4.31, V4.53)

- [ ] **G1 Rectangle gesture, key-gated (V4.27, V4.28, V4.31) · [P]**
  - `EventTapRecorder`: left-drag while `HotkeyService.isDictationKeyDown` (add: true between key-down and key-up of the bound key) → `RegionCapture` (rect in display coords); bare drag ignored unless setting `deixis.drawWithoutKey` (default off, latch only). `InkStrokeCapture` replaced by `RegionCapture`; `StrokeGeometry` becomes `RegionGeometry` (orange 1 px rectangle, hand-drawn corner jitter optional, 1.5 s fade after the utterance).
  - `AppDelegate` hotkey block: overlay ordered front only while the key is down; `.enterLatch` ends deixis capture and hides the overlay; key-down inside latch re-arms for the drag.
  - Tests: `ActionsTests` gesture table (key down + drag → region; drag alone → nothing; latch + setting → region). `AppTests` overlay visibility per action.

- [ ] **G2 Screen capture + OCR service and permission (V4.53, V4.29) · [P]**
  - `App/Services/ScreenTextService.swift` implements `ScreenTextReader`: `SCShareableContent` + `SCScreenshotManager.captureImage` (macOS 14) of the window under the rect at backing scale; `VNRecognizeTextRequest` (`.accurate`, `usesLanguageCorrection` by field role, `customWords` from `LearnedLexicon`, recognition languages en + configured); returns lines with boxes converted to points. Frame held in memory for the turn; never written.
  - `PermissionMatrix`: add `screenRecording` (optional; `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`; asked the first time a box is drawn, with a one-line explanation; denial → box carries AX text only and the pill says "Screen text isn't available").
  - Tests: protocol mock; point/pixel conversion; permission state machine. Evidence: `implemented`; §5 item 6.

- [ ] **G3 Box → element + text + image (V4.29, V4.30 data) · [P]**
  - `DeixisService`: on region → AX hit-test (existing) → element role/title; text inside the rect via `kAXStringForRange` over the element's visible range when available, else `ScreenTextService.lines(in:)`; build `DeixisRegion { rect, element, text, imageID, source: .ax | .ocr }`; `contextLine` extended (`region 1 = <role> "<title>" text: "<…>"`); image kept for the utterance and exposed to S2's chip through `DeixisService.currentRegions`.
  - Tests: AX text present → no OCR call; absent → OCR; region cleared at turn end.

### Wave 1 — H · Speaker enrollment plumbing (V4.49, V4.50)

- [ ] **H2 Passive enrollment · [P]**
  - `SpeakerEnrollment`: accumulate embeddings from hold-to-talk utterances with ≥ 1.5 s of VAD speech; after 10 build the profile; expose `progress`. `LatchController.install(profile:)` sets `speakerFilteringEnabled = true` and assigns `LatchRuntime.speakerGuard`; "Not you" correction (`NotYouCorrection`) adjusts the threshold. Filter applies to latch segments only (hold is the user by definition).
  - Tests: 10 synthetic utterances → profile; filter rejects a far embedding (cosine < 0.6) and passes a near one; hold never filtered.

- [ ] **H3 Embedding weights (V4.50) · [P]**
  - `ModelCatalog`: add the FluidAudio speaker-embedding model (the diarizer's WeSpeaker CoreML; verify the exact repo id and size through `FluidSpeakerEmbedder`) as a required download with Parakeet; `SpeakerEmbedderFactory.make()` returns it when present so `identifiesSpeakers == true`. MFCC stays the fallback and is labelled "Voice filtering unavailable" (X03 copy). Tests: descriptor round trip; factory choice.

### Wave 1 — I · Hotkey default and Escape (V4.51, design §5)

- [ ] **I1 fn default (V4.51) · [P]**
  - `HotkeyService.defaultBinding = .fn`; stored bindings win. `HotkeyBinding.label` used for every hint: "Hold or Double Tap fn / 🌐 to dictate" ("Hold fn / 🌐 to dictate" when latch is disabled). Read `AppleFnUsageType` (`com.apple.HIToolbox`); if ≠ 0 expose `fnSystemActionConflict` for onboarding/Settings (S7g/S8 render the prompt + "Open Keyboard settings"). If no fn event is ever seen in 3 presses during onboarding's key test, offer Right ⌥ (S8).
  - Tests: default resolution; stored binding precedence; label interpolation; conflict flag from a fake defaults.

- [ ] **I2 Escape during a turn · [P]**
  - `App/Services/EscapeHotkey.swift`: Carbon `RegisterEventHotKey(kVK_Escape, 0)` registered on turn start (listening / finishing / preview), unregistered on idle, held, error or menu. Fires `TurnController.escape()` (S3): before write → cancel, nothing inserted, `.cancelled` 800 ms; after write begins → resolve outcome, then offer Undo. Never registered while idle.
  - Tests: registration lifecycle per state; double Escape idempotent.

### Wave 1 — J · Small fixes

- [ ] **J1 Recording retention (V4.52) · [P]** — `UtteranceRecorder.retainedUtterances` from `SettingsKeys` entry `recordings.retain` (`100` default, `0` = keep all); folder size reported; manifest gains `corpus: String?` (label set from Privacy, S7f). Tests: pruning at 100 and never at 0.
- [ ] **J2 Claude desktop adapter (V4.40) · [P]** — add the Claude app's bundle id to `ElectronAdapter` (verify with `osascript -e 'id of app "Claude"'`; record the id in the report). Tests: match.

### Wave 1 — S1 · Spool art — exact port of the prototype (design §3.1, §11.1)

**Source of truth is the prototype's code, not the prose.** `design/design_v1.html` lines ~850–1000
(`const Spool=(()=>{ … })()`) plus its frame loop `drawWave()` (~line 1047). Where `design_v1.md` and the
prototype differ, the prototype wins, except where §S1.6 below says otherwise. Do not redraw Spool.

**Parity fixtures (already generated, committed with this document):**
- `Scripts/spool_golden.mjs` — loads the Spool module straight out of `design_v1.html` with node and writes
  the fixtures. `node Scripts/spool_golden.mjs --full` also writes `Fixtures/spool/spool_full.local.json`
  (22 MB, git-ignored) for diffing a failing frame.
- `Fixtures/spool/spool_spec.json` — every constant the port needs: material and housing colours, the
  26-state → 7-pose table, live states, still-frame times, scene geometry, reel-angle rules, time remaps,
  loop-stop rule, the 59 error → pose mappings, the menu-bar glyph geometry, the number format.
- `Fixtures/spool/spool_golden.json` — 624 scene frames (26 states × 11 times × 2 reel angles, plus
  narrow-width and still frames), 26 cameos and 6 tape-flight frames: SHA-256 of each SVG, and the full SVG
  for one representative frame per state.

#### S1.1 What the prototype actually draws (Spool uses only `rig` case 25, `tapeRibbon`, `scene`, `cameo`, `flight`)
- `face()`, `glove()`, `limb()`, `lens()` in the file belong to earlier mascots and are **never called**.
  Spool has no gloves, arms or magnifier. Do not port them.
- **Housing** 126 × 108 body at (−63, −58) r13 in `dark`, over it 122 × 105 at (−61, −60) r12 with the
  linear gradient `gradientTop → gradientMid (60 %) → gradientBottom`; top highlight path, left edge light;
  two write-protect notches, cream top tab, four corner screws (±53, −49 / 35), "SIDE A" / "01" label strip
  (#f0dcc1, text #665342, 5.2 pt, letter-spacing 1.5), dark window 102 × 48 r13 (#362f2a).
- **Internal tape**: the 17-point ribbon polyline from the inlet (−62, 22) round the guide to the reels,
  width 8, drawn with `tapeRibbon`. **Guide roller** at (−51, rollerY) r4.2 / r1.8, inlet block at (−65, 17).
- **Reel eyes** at (±27, −12): oxide pack r21 with five winding rings (r 20 → 14.4, shadow, 0.38 pt, 72 %);
  rotating hub r12.7 (#f5e7c9) with three spokes (#745d46) at 0/120/240°; **pupil** r4.8 (#2f332c) with
  highlight r1.5 offset by `glance`; lid **shutters** in housing colour from y −34 down by `lid`; **brows**
  (#624c3e, 2 pt) at y −38 + `brow`; faint cream catch-light arc.
- **Mouth** = pressure-pad opening: trapezoid (−27, 18)…(35, 38) in `dark`, pad 44 × 13 (#e3c4a0), mouth
  shape per pose (S1.3). Two capstan dots at (±39, 27). **Status lamp** 10 × 3 at (21, 40). Feet 20 × 6 at
  (−43, 44) and (23, 44). Mouth anchor point `data-spool-mouth` at (0, 31).
- Whole body transformed by `translate(0, lift) rotate(lean)`; the **inlet end point (ex, ey)** is the
  rotated (−62, 22) plus lift, and the pill's tape lane must end exactly there.

#### S1.2 State → pose (26 states, 7 poses) and overlays
| Pose | States |
|---|---|
| `ready` | idle, ready, starting, quiet, cancelled, muted, unavailable, blocked, paused, notes |
| `listen` | listening, latched, warning, meeting |
| `finish` | finishing, editing (t fixed at 1.5) |
| `preview` | preview, inserted, undo |
| `review` | uncertain, correcting |
| `insert` | inserting |
| `error` | held, unconfirmed, partial, error |

Overlays on top of the pose: `warning` adds two concerned brow strokes; `muted` / `blocked` /
`unavailable` add the shutter plate (104 × 49, #82634f), two closed-eye lines (#c7a383) and the padlock
latch at the mouth; `paused` adds two pause bars (#eedabb); `quiet` forces tape amplitude 0; `cancelled`
retracts the pill tape with a clip over 0.32 s; `editing` / `notes` add an 18 × 6 progress marker moving
40 pt/s along the tape lane. The error catalogue (S9) maps each of the 59 ids to one of these states via
`errorPoses` in the spec.

#### S1.3 Per-pose parameters (t = seconds in the state, after the time remap)
`sm(x)` = smoothstep on clamp(x, 0, 1). `inspect = sm(t/0.7)`, `p = sm(t/1.5)`.
| Parameter | listen | finish | preview | review | insert | error | ready |
|---|---|---|---|---|---|---|---|
| lean ° | 1.6·sin 2.3t | e^(−3t)·sin 11t·2 | 0 | −4·inspect | −3·wind + 2.2·pop | −2·inspect | 0 |
| lift | 0 | 2·sin πp | 0 | 0 | 2·wind − 3·pop | 0 | 0 |
| glance (pupil x) | −1.5 | 0 | 0 | −3.5·inspect | 2·send | 0 | 0 |
| lid | blink·32 | 5p | 6 | right eye 10·inspect | 5·land | 0 | 0 |
| brow | 0 | 2p | −1 | L −5·inspect, R 3·inspect | −3·wind | ±3·inspect (tilted) | 0 |
| mouth | oval 9±1.5 × 3.1±0.7 (sin 3t, 5t) + lip | oval shrinks 8→4 × 3→1.7, two strain lines | smile | lopsided | feed slot 26 × (5 + 8·opening) + smile when land > 0.1 | frown | smile |
| roller dip | 0 | p | 0 | 0 | 1.7·sm(t/0.3)·(1 − sm((t − 1.4)/0.3)) | 0 | 0 |
| lamp | #e1b77a | #a29279 | #b7c999 | #a29279 | #b7c999 | #cf9286 + brake | #a29279 |

Insert phases: `wind = sm(t/0.45)·(1 − sm((t−0.45)/0.25))`, `send = sm((t−0.45)/0.65)`,
`land = sm((t−1.45)/0.45)`, `pop = sin(π·clamp((t−0.35)/1.15))`, mouth `opening = sm(t/0.35)·(1 − sm((t−1.4)/0.35))`.
Blink: `(max(0, 1 − |(t mod 4.8) − 4.35| / 0.13))²` — one blink every 4.8 s while listening.
Error brake: pad at (−57, 22 − 7·(1 − inspect)) in #cf9286. Time remaps: finishing `min(t·1.5/0.55, 1.5)`,
inserting `min(t, 1.2)`, editing fixed 1.5.

#### S1.4 Reel angle (external state, never reset)
Accumulated by the host each frame with `dt` clamped to 0.05 s: live states `−150·dt`; finishing
`−150·(1 − t/0.55)·dt` while t < 0.55; inserting `+440·dt` while t < 1.05; every other state holds the angle.
Negative = counterclockwise. Both reels share one angle. Reduce Motion: no accumulation.

#### S1.5 Pill tape lane and still frames
- Scene 560 × 164: character centre (width − 78, 80) at scale 1; below 460 wide scale 0.69 at (width − 54, 74).
- Lane: 97 samples from (16, 104) to the inlet end; y eased with u⁹; wave
  `activity·10·sin(πu)·(0.75·sin(2π·1.65u − 4t) + 0.2·sin(2π·3u − 2t))`; twist roll
  `activity·2.25·sin(2π·1.65u − 1.8t)·sin(πu)^0.6`; width 8·scale. `activity` = 1 in live states,
  `1 − sm(t/0.55)` while finishing, 0 otherwise.
- `tapeRibbon`: flat quads, reverse colour where cos(roll) < 0, cut-edge highlight on top edge
  (#D3A582, 0.65, 85 %), shadow on bottom edge (#573A2B, 0.8), three faint grain lanes at ±0.28 and centre
  (0.3 pt, 22 %), end cap in edge colour.
- Still frames (cameos, Reduce Motion): t = 1.4, except finishing 0.55, inserting 0.4, cancelled 0.8;
  angle 0. Cameo viewBox (−76, −72, 152, 132).
- Frame loop runs only while live, editing, notes, inserting < 1.1 s, or within 0.8 s after a state change;
  stops when hidden or Reduce Motion.

#### S1.6 Real-product rules from design_v1.md that the prototype only simulates
The prototype is labelled a simulation (design §14). design_v1.md specifies what the real engine drives;
these are part of the verified design and are tested separately from the golden frames.
1. **Tape amplitude follows real audio** (design §5 step 2, §11): multiply `activity` by the smoothed capture
   level (0…1, attack 40 ms, release 250 ms). Silence flattens the tape. Never loop a canned ribbon when no
   audio arrives.
2. **Silence parks the reels** (design §6 C2 "flat tape, parked reels"): `listening → quiet` after 1.5 s of
   VAD silence; `quiet` accumulates no angle. Speech returns to `listening` from the same angle.
3. **Listening reel speed** is the prototype's 150°/s, modulated by speech activity (design §11 "about
   150°/s counterclockwise, modulated by speech activity"): `150 · (0.6 + 0.4 · level)`.
4. **Hint copy** uses the configured key label (owner decision, §0).

#### S1.7 Implementation
- `App/UI/Spool/SpoolRig.swift`: pure function `rig(pose:t:angle:) -> SpoolDrawing` returning primitives
  (paths, ellipses, rects, text, groups with transforms) with the exact coordinates above.
- `App/UI/Spool/SpoolSVG.swift`: serialises a `SpoolDrawing` to SVG text using the prototype's attribute
  order and number format (`Number(x.toFixed(2))`: ≤ 2 decimals, no trailing zeros, no "−0"). **Test only**,
  used for parity.
- `App/UI/Spool/SpoolView.swift`: renders the same `SpoolDrawing` with SwiftUI `Canvas`; `TimelineView`
  drives `t` and the reel angle per S1.4; exposes `mouthAnchor` and `inletAnchor` in window coordinates.
- `App/UI/Spool/TapeRibbon.swift`, `SpoolScene.swift` (lane, overlays, clip retract), `SpoolFlight.swift`
  (the flight path maths, drawn by S4), `SpoolPoseTable.swift` (26 → 7 map, overlays, still times).
- **Parity tests (`AppTests/SpoolParityTests.swift`) — the acceptance gate for S1:**
  - every entry in `spool_golden.json` `hashes`, `cameos` and `flights`: SHA-256 of `SpoolSVG` output equals
    the golden hash; on mismatch print the Swift SVG and the `representative` SVG for that state so the diff
    is readable, and tell the agent to run `node Scripts/spool_golden.mjs --full` for the exact frame;
  - `spool_spec.json` constants equal the Swift constants (colours, pose table, still times, geometry);
  - reel-angle integrator reproduces S1.4 over a scripted state sequence;
  - the S1.6 deviations are tested separately (silence → zero amplitude; quiet → no accumulation).
- Evidence: `fixture-verified` against the prototype. Visual side-by-side with the prototype in §5 item 7.

### Wave 1 — S6 · Menu bar glyph and status menu (design §4 "menu-bar identity", §8.8)

- [ ] **S6 · [P]**
  - `App/UI/MenuBarGlyph.swift`: the prototype's glyph exactly (`spool_spec.json` › `menuGlyph`): viewBox 32 × 24, rounded rect (1, 2, 30 × 21, r4, stroke 1.5), eyes r4 at (10, 10) and (22, 10), mouth `M11 17q5 4 10 0`; scaled into an 18 × 16 pt `NSImage`, `isTemplate = true`, stroke only. Replaces the SF symbol in `StatusItemController.refreshIcon`. Never tinted.
  - Menu (`MenuModel`): Ready / Muted / Blocked line, current microphone, Start dictation (click-to-stop), Mute, Held text (N), Open VoicePlus, Settings, Quit (capture guard: Stop and quit / Cancel; held drafts saved). Opening the menu never records.
  - Tests: `MenuModelTests` item table per state; glyph renders non-empty at 1× and 2×.

### Wave 1 — S9 · Recovery catalogue (design §10)

- [ ] **S9 `App/Core/RecoveryCatalog.swift` · [P]**
  - Data: all 59 entries (`P01…X08`) **loaded from or tested against `Fixtures/design/design_copy.json` › `errors`** (id, family, trigger, headline, consequence, action, data policy) and `spool_spec.json` › `errorPoses` (Spool treatment and pose key); Spool treatment (`.heldTape`, `.attentiveReview`, `.setupLatch`, `.closedShutters`, `.quietReturn`, `.unconfirmedHold`, `.liveWarning`, `.scopedNotice`).
  - Mapping: `RecoveryCatalog.entry(for: Error | DeliveryReason | PermissionState | EngineState)` covering `AudioCaptureError`, `EngineError`, `ProviderError`, `ModelManager` errors, `DeliveryReason`, `SpeakerError`, `PairingError`, plus the catch-all X08.
  - `EngineErrorMessage.describe` routes through the catalogue; raw text goes to `Log` only.
  - Tests: every mapped error yields a headline with no `[A-Za-z]+Error`, camelCase token, `.bin`, `.partial`, or path in it (regex); every catalogue id is reachable by at least one mapping or is marked `defensive`. Consumers switch in S11.

### Wave 2 — S2 · Pill and presence (design §4, §6; copy fixture; V4.30)

- [ ] **S2**
  - `NotchGeometry`: idle chin 64×14; hover hint 360×38 (text-sized, min 190); active 560×164; actionable 560×204; compact ceiling `min(560, usable − 32) × 204`; narrow (< 460) review layout with an 84 pt cameo bay; upper corners square when attached, all rounded when floating (external display, 8 pt below the menu bar); nothing behind the camera housing (safe-area from `ScreenMetrics`). Replace `absoluteMaximumSize`.
  - `PillView` layout: status row (status · destination · timer, per the copy fixture), text lane (natural-language, newest two lines, leading fade, stable prefix), confidence dots lane, tape lane (S1 ribbon), key-hint row ("Release fn / 🌐 · Esc"), action row on 204 pt states; 132 pt character bay on the right (`SpoolView`), never text under the face.
  - **Copy comes from `Fixtures/design/design_copy.json` › `pill`**, one entry per state: status line,
    helper line, buttons (label, primary or not), notice layout and warn tone. The sample transcript in the
    fixture is replaced by the real text; "Mail" by the real destination name; "Right Control" by the
    configured key label; the timer by the real elapsed time. Examples of what that yields:

    | State | Status | Helper | Buttons |
    |---|---|---|---|
    | starting | Starting microphone… | Recording starts when the microphone is open | — |
    | listening | Listening | Release fn / 🌐 to finish | — |
    | quiet | Listening · quiet | Still listening while you hold | — |
    | latched | Latched · hands-free | Tap fn / 🌐 to finish | Finish |
    | finishing | Finishing… | Microphone closed · nothing inserted yet | — |
    | preview | Ready for <app> | Final text · inserts after the preview | (manual: **Insert text**, Cancel) |
    | uncertain | Ready for <app> · 1 word to review | Final preview · hover to pause | (manual: **Insert text**, Cancel) |
    | inserting | Inserting in <app>… | Same text · one insertion attempt | — |
    | inserted | ✓ Inserted in <app> | 1 word to review in the field | — |
    | held | ⚠ Destination changed · text held | Nothing was typed into the new field | **Insert here**, Copy text, Discard… |
    | unconfirmed | ⚠ Inserted · not confirmed | Check the field before trying again | **Check text**, Dismiss |
    | partial | ⚠ Only part may have been inserted | Review both versions to avoid duplicate text | **Review result** |
    | warning | ⚠ Microphone sounds unclear | Keep speaking, or check your microphone | Check microphone |
    | cancelled | Cancelled | You can start a new dictation | — |
    | muted | ⊘ VoicePlus is muted | Unmute when you are ready | **Unmute** |
    | error | ⚠ Couldn't finish this dictation | These words were recovered. Nothing inserted. | **Review text**, Copy text |

    The full 26-state list, including unavailable, editing, undo, meeting, paused, notes, correcting and
    blocked, is in the fixture. DESIGN.md's old rule against the words "hands-free" in UI copy is replaced by
    the verified latched copy (G0.3 records it). The "Finishing" 2 s / 10 s strings ("Still finishing your
    text", "Use available text", "Cancel") come from design §5.
  - **Warning (C5):** the design's warning state, not a new chip. Live words stay; Spool keeps listening with
    the concerned-brow overlay; status and button from the fixture.
  - **Readback:** any delivery that readback did not confirm, whether readback ran and showed nothing or could
    not run (Google Docs), is the design's `unconfirmed` state. V4.20 is withdrawn.
  - **Dwell (`PillDwell`):** inserted 650 ms; cancelled 800 ms; quiet no-result returns 800–1600 ms
    (design §10); final preview per S3; **held, unconfirmed, partial, error, unavailable, blocked stay until
    the user acts** (design §10 "Error notices remain until action/dismissal").
  - **Deixis thumbnail (owner addition, §0):** in the text lane, under the transcript and above the tape lane,
    using the design's chip style; never in the character bay.
  - Tests: `DesignCopyParityTests` (every pill state's rendered status, helper and button labels equal the fixture after the three substitutions); `NotchGeometryTests` (every state size, notch exclusion, external display), `PillTests` (state → rows/copy), hover logic, chip presence. Evidence: `implemented`; §5 items 7–9.

### Wave 2 — S3 + S11 · Turn controller: preview before insert (design §5, §12) and turn record

- [ ] **S3 `App/Services/TurnController.swift`**
  - Owns one turn: `TurnID`; key-down snapshot (app, field element hash, selection, `kAXValue` hash as text version, display, secure flag); `starting` until capture is really open (≤ 80 ms target logged); `listening` / `listeningQuiet` (VAD idle > 1.5 s); key-up → `finishing` (mic closed immediately) → engine final pass + lander formatting → **final payload** (immutable) → `finalPreview` with dwell (600/900/1500/manual; 1800 when any `isLowConfidence`; hover/focus/selection/Review pause) → revalidate snapshot (`FocusGuard.matches` + value hash unchanged or caret still inside our landing memory) → inject once (`TextInjector` gains an idempotent commit guard keyed by `TurnID` + target revision) → `inserting` → outcome → `landed(verified/unverified/partial)` or `held`.
  - Timeouts: 2 s "Still finishing your text"; 10 s "Use available text" (if a partial exists) / "Cancel". Late results after cancel or after "use available" are dropped by `TurnID`. Duplicate key-up / key repeat ignored. New press while finishing → K04 "Finishing your previous dictation".
  - Escape (I2): before write → cancel; after → resolve, then Undo (5 s, range-safe via `ReplaceRange`).
  - Latch: each closed segment enters the same gate; serialized; hold never inserts intermediate segments.
  - `DictationCoordinator.endSession` hands to the controller instead of landing directly; `UtteranceLander` remains the format + inject step and returns the payload without injecting when asked (`land(…, inject: false)` + `inject(payload:)`).
  - **S11** `TurnStore` (GRDB, in `Shared`'s DB): one `TurnRecord` per turn (G0.1) written at snapshot, updated at each transition; Today reads from it (S7b). Recovery persistence is independent of history retention ("Kept for this session only" when persistence is off).
  - Tests: `AppTests` controller with a mock clock and mock injector: dwell timing; pause; low-confidence extension; manual review; revalidation failure → held with D01 copy; stale callback by old `TurnID` ignored; duplicate key-up; Escape before/after write; latch serialization; record fields at every transition. `InjectionTests`: commit guard refuses a second inject for the same `TurnID` + revision. Evidence: `implemented` + `fixture-verified`; §5 items 8–10.

### Wave 2 — S7 · Main window (design §8, §9) — split into seven parallel tasks

Reference for every S7 task: `design/design_v1.html` › **App surfaces** (screen picker + the
content / empty / loading / error / partial variant switch) and `design/design_v1.md` §8.1–§8.6, §8.9, §9.
Each screen renders exactly one base state through `SectionState` (content / empty / loading / error) plus
a scoped banner for partial data. Loading never looks like empty. Retry is scoped and disabled while
retrying. A failed save keeps the entered value and the previous active value.

```
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ ● ● ●  VoicePlus                                        Search…  (⌘F)    │
 ├───────────────────┬──────────────────────────────────────────────────────┤
 │ Today        ⌘1   │  <page title 24/30>                  [primary action] │
 │ Meetings     ⌘2   │                                                      │
 │ Dictionary … ⌘3   │   S7b … S7g own this pane, one section each          │
 │ Voice        ⌘4   │                                                      │
 │ Privacy      ⌘5   │                                                      │
 │ Settings     ⌘6   │                                                      │
 │                   │                                                      │
 │ • On this Mac     │  Hold [fn / 🌐] to speak.   (still Spool cameo)      │
 └───────────────────┴──────────────────────────────────────────────────────┘
   sidebar 208–240 pt       24 pt outer padding · 20–24 pt section gaps
   S7a owns the frame, sidebar, toolbar, search field, routing
```

- [ ] **S7a Window shell · gate for S7b–S7g (≤ 2 h, runs first inside wave 2)**
  - Owns: `App/Settings/MainWindowController.swift`, `MainWindowView.swift`, `MainWindowSection.swift`,
    `MainWindowViewModel.swift`, `SectionState.swift`, `App/UI/Components/` (new: `PageHeader`, `GroupBox`,
    `RowView`, `EmptyState`, `ScopedBanner`, `StatusTag` good/warn/neutral, `SegmentedControl`, `KeyCap`,
    `SpoolCameo` wrapper around S1).
  - 1080×720 preferred, 820×560 minimum; sidebar 208–240; tokens from G0.3; ⌘1–6, ⌘, (Settings), ⌘F (focus
    the section's local search); scroll and selection preserved per section; one page title; toolbar holds
    only relevant actions; "• On this Mac" footer.
  - Subpage routing for Settings: exactly the design's General, Shortcuts, Appearance, Models, Providers, Sync,
    Updates. Existing subpages are re-homed, not given a new page: `benchmark` → Voice › benchmarks
    disclosure (design §8.4); `flags` and `data` → Privacy › Diagnostics disclosure (design §8.5);
    `snippets` and `personas` → Dictionary & Apps (design §8.3). Every setting stays reachable (R7 proof
    re-run).
  - Page titles, subtitles, empty states and each screen's error example come from
    `Fixtures/design/design_copy.json` (`screens`, `emptyCopy`, `screenError`), e.g. Today "Your words, right
    where you left them.", Voice "Make sure we hear you clearly.", Models "Ready means verified and loaded.",
    Providers & Sync "Local first. Connections when you choose." Loading uses "Loading <section>…" with
    "No empty-state claim while the data is still loading", Models "Verifying the speech model…"; empty and
    loading states carry the `ready` Spool cameo.
  - Publishes one protocol per section (`SectionScreen`) so S7b–S7g drop their views in without touching
    the shell.
  - Tests: `MainWindowShellTests` (sections, shortcuts, subpage routing, state preservation, component
    snapshots of each `SectionRendering`).

The six tasks below run **in parallel** after S7a. Each owns only its files.

- [ ] **S7b Today, turn detail, recovery sheet (design §8.1) · [P]**
  - Owns: `App/Settings/Today*.swift`, `App/Settings/TurnDetail*.swift` (new), `App/Settings/RecoverySheet*.swift` (new).
  - Held / recoverable first (Review · Copy); then chronological rows: time · destination · excerpt ·
    Inserted / Held / Unconfirmed / "1 to review", read from `TurnStore` (S3). No vanity counters as home.
  - Turn detail: final text (selectable), uncertainty count, optional original transcript, destination,
    delivery evidence (method, verified or not), Copy / Review / Delete; still held-tape Spool beside status.
  - Recovery sheet: full payload, current destination preview, **Insert here** (explicit re-target, revalidate
    after the user picks a field), Copy (acknowledged only when the copy is verified), Discard (confirmation
    when it is the only saved copy); closing keeps the draft; history off → "Kept until resolved" / "Kept for
    this session only".
  - States: "Nothing dictated yet" + shortcut; history-off variant; "Loading recent dictations…"; "History
    can't be read" + Retry with held drafts still shown; "This draft is no longer available"; "Opening saved
    text…".

- [ ] **S7c Meetings: library, detail, capture panel (design §8.2) · [P]**
  - Owns: `App/Settings/Meetings*.swift`, `App/UI/MeetingPanel*.swift` (new), `App/UI/MeetingPromptPanel.swift`.
  - Library list / detail; detail header (title · date · duration · Local); tabs Notes (Summary, Decisions,
    Action items) / Transcript (speaker labels, timestamps, search, uncertainty marks; audio seek only when
    audio is retained) / Ask (disabled with "Needs a configured service" until one exists, route disclosed).
  - Expanded capture panel 560×360: static compact cassette in the header, Transcript / Notes, Pause, Stop,
    timer, explicit mic and system-audio track indicators; Q0 / Q1 / Q2 pill states (S2) mirror the same
    capture state.
  - Unfinished-recording banner above the affected list (retained duration, Recover / Discard); affected row
    only; system-audio denied → mic-only with a missing-track notice; no calendar never blocks manual start.
  - States: "No meetings yet" + Start recording; "Loading meetings…"; "Preparing transcript…"; "No speech
    captured"; Notes failure keeps the transcript.

- [ ] **S7d Dictionary & Apps (design §8.3) · [P]**
  - Owns: `App/Settings/DictionaryApps*.swift`, `LearnedDictionaryViewModel.swift`, `SnippetsSettings.swift`,
    `App/Onboarding/ContactsImport.swift` (UI only).
  - Segmented Dictionary / Apps. Dictionary: search, term, spoken variant, language, source, add/edit, import
    preview, inline duplicate/conflict resolution, Contacts import (explain → preview → commit). Snippets and
    personas as rows here.
  - Apps: "Uses default" vs override shown distinctly; per-app style, insertion eligibility (never-inject),
    contextual-reading switch (screen text, G2), overlay capability badge (word marks supported / not, S5);
    code and terminal profile verbatim, never auto-Return.
  - States: "Add a word VoicePlus keeps getting wrong."; "Every app uses your defaults"; loading; inline save
    failure with the prior value still active.

- [ ] **S7e Voice (design §8.4) · [P]**
  - Owns: `App/Settings/Voice*.swift`, `App/Onboarding/SpeakerEnrollmentWindow.swift` (embedded view mode).
  - Input selector, real level meter, test sentence with states idle / capturing / analyzing / result / no
    samples / too short / device removed (Stop releases the mic); Spool moves only during a real test or
    enrollment capture, parks while analyzing.
  - Speaker enrollment: status (enrolled / learning N of 10 / off), re-enroll, "Not you" history (H2).
  - Language with a model-capability note and mixed-script preview; benchmarks inside a disclosure.
  - States: "No voice enrolled"; "No microphones found" (distinct); "Looking for microphones…".

- [ ] **S7f Privacy (design §8.5) · [P]**
  - Owns: `App/Settings/Privacy*.swift`, `App/Settings/DataPanel*.swift` (if present), recordings UI; the
    Diagnostics disclosure hosts feature flags and the data panel.
  - Rows: microphone, typing access, optional context (**Screen Recording**, G2), history retention, audio
    retention, **recordings: keep the last 100 / keep all, corpus label, folder size, Reveal in Finder,
    Delete all (J1)**, meeting capture, sync.
  - On-device vs service disclosure; dated network activity list (destination, purpose, time, allowed /
    blocked); unreadable log shows an error, never "Nothing left this Mac"; scoped delete with counts and a
    remaining-items list on partial failure; hard mute (closed-shutter Spool); diagnostics redacted by
    default with an export preview.

- [ ] **S7g Settings subpages (design §8.6) · [P]**
  - Owns: `App/Settings/SettingsView.swift`, `SettingsViewModels.swift`, `VoiceSettings.swift` (model part),
    `ConnectorsSettings.swift`, `SyncSettings.swift`, `BenchmarkSettingsViewModel.swift`.
  - General: launch at login, sound cues (off by default; no success sound before verification), **preview
    dwell 600 / 900 / 1500 / manual**, manual-review preference, **spacing automatic / always / never (D6)**,
    **unknown-caret style (D3)**.
  - Shortcuts: key recorder with conflict result, hold explanation, latch opt-in, **latch pause 1–5 s (B2)**,
    **fn system-action prompt + "Open Keyboard settings" (I1)**, **draw-without-key in latch (G1)**, test area.
  - Appearance: follow system / light / dark (window only; the pill stays dark), Reduce Motion, presence
    visibility, Larger Text. No mascot picker.
  - Models: compatible model, installed size, real byte progress → Verifying → Loading → Ready, retry /
    cancel, last working model; speaker-embedding model row (H3).
  - Providers (connectors + provider route, connectivity, secure credential field; secrets never in errors),
    Sync (pairing comparison, devices, paused/offline, conflict review), Updates (installed, checking,
    available, downloading, install-ready, failure; protects capture and drafts). No Advanced subpage.

### Wave 2 — S12 · Mascot use and action surfaces (design §8.8, §8.9) · [P]

- [ ] **S12**
  - Owns: `App/UI/Spool/SpoolSurfacePolicy.swift` (new), `App/Transform/` (preview UI only),
    `App/UI/ConsentPanels.swift`, `App/UI/ActionPreview*.swift` (new).
  - `SpoolSurfacePolicy`: one table the other surfaces consult, per design §8.9:

    | Surface | Spool |
    |---|---|
    | Today / empty history | small still cameo beside the hold hint; never spins for loading |
    | Turn detail / recovery sheet | still held-tape pose beside delivery status |
    | Meetings library / detail / Notes / Ask | static mark; progress uses labelled UI |
    | Meeting capture panel | reels and tape mirror actual capture only |
    | Dictionary & Apps, Settings, Models, Providers, Sync, Updates | static mark; native progress, no spinning tape |
    | Voice test / enrollment | moves only during real capture; parks while analyzing |
    | Privacy / mute | closed-shutter pose beside hard mute |
    | Onboarding | still cameo; moves only during the real dictation test |
    | Status menu | monochrome glyph only (S6) |
    | Correction popover | optional still attentive cameo |

    Never plays beside long-form reading; no pet mechanics, skins or confetti. Prototype usage to match:
    empty and loading screens use the `ready` cameo; Today and Privacy content use `ready`, Turn detail and
    Recovery use `held`; each error notice uses `errorPoses[id]` from the spec.
  - Selected-text transforms: before / after preview in the pill, replace only after target revalidation,
    range-safe Undo (R1 editing, R2 undo states).
  - Outbound action preview: names the destination and the proposed action; a dictation is never sent just
    because it was inserted; no auto Enter/Send.
  - Tests: policy table (every surface → allowed motion), transform preview gate, action preview copy.

### Screen coverage (prototype picker → task)

| Prototype screen | Task |
|---|---|
| Today | S7b |
| Turn detail | S7b |
| Recovery sheet | S7b |
| Meetings | S7c |
| Dictionary & Apps | S7d |
| Voice | S7e |
| Privacy | S7f |
| Settings | S7g |
| Shortcuts | S7g |
| Models | S7g |
| Providers & Sync | S7g |
| Onboarding | S8 |
| Status menu | S6 |
| Correction popover | S5 |
| Pill, presence, menu-bar hint | S2 |
| Tape flight | S4 |
| Every screen × content / empty / loading / error / partial | S7a components + each section task |

### Wave 2 — S8 · Onboarding (design §8.7; V4.48; I1)

- [ ] **S8 `App/Onboarding/`**
  - Steps and copy follow the design (§8.7 and the prototype's onboarding screen; headings such as "Your
    voice, a little closer.", "Let VoicePlus hear you.", "Let your words reach the page."). The one owner
    addition is the Voice step. Steps: Welcome → Microphone (real meter) → Typing access (Accessibility, explained just before the prompt) → Model (real byte progress → Verifying → Loading; never "Ready" before load) → Try dictation (hold fn: live words above the ribbon with counterclockwise reels → release → final preview → insertion into the safe test field; one uncertain word demo + correction) → **Voice** (read four lines, ~30 s, `SpeakerEnrollmentWindow` reused; skippable; H2 passive fallback explained) → Ready. Optional later: Meetings/system audio, Calendar.
  - Closable window, never a full-screen trap; Back / Continue / Set up later; resume at the unfinished step; only the selected backend's permissions are requested (bare-modifier monitor needs no Input Monitoring).
  - fn: system-action conflict prompt (I1) before the key test; no fn event in 3 presses → offer Right ⌥.
  - Still Spool cameo on Welcome/Try; motion only during the real test.
  - Tests: `OnboardingStateMachineTests` for the new steps, resume, skip paths, fn fallback. Evidence: `implemented`; §5 item 12.

### Wave 3 — S4 · Tape flight (design §4 "mouth-to-caret")

- [ ] **S4 `App/Overlay/TapeFlight*.swift`**
  - Pointer-transparent overlay (reuse `OverlayWindow` type, separate instance) drawing the ribbon from `SpoolView.mouthAnchor` (window → screen coords) to the verified caret rect (`WordRectProvider` bounds-for-range at the insertion point, pre-insertion); reels clockwise meanwhile (S1 pose `inserting`).
  - Maths exactly as the prototype's `flight()` (use `SpoolFlight` from S1): head `sm(t/0.65)`, tail `sm((t−0.72)/0.33)` (gone at 1.05 s); cubic Bézier with `bend = min(110, |dy|·0.46)`, `c1 = from + (24, bend)`, `c2 = to + (max(45, |dx|·0.25), −bend/2)`; 121 samples between tail and head; lateral wave `sin(πu)·sin(2π·2.2u − 9t)·13` on x and 0.4× on y; ribbon width 9; roll `2.4·sin(2π·1.8u − 5t)·sin(πu)`. Parity: the six `flights` hashes in `spool_golden.json`.
  - Suppress (no flight, normal label/outcome) when: caret rect unavailable, target changed, secure field, other display, Reduce Motion. Clear immediately on interruption/state change. Never delays or triggers the write (S3 owns the write; the flight subscribes).
  - Tests: anchor math across displays and scale factors; suppression matrix; flight cancelled on state change. Evidence: `implemented`; §5 item 13.

### Wave 3 — S5 · Uncertainty marks and correction (design §7)

- [ ] **S5 `App/UI/Marks/`, `App/Correction/`**
  - In the pill: 2 px red dotted underline 3 px below baseline on every wrapped fragment of spans with `isLowConfidence`; "1 word to review"; accessible label; uncertain count drives the 1800 ms dwell (S3). Spans are mapped through formatting with `WordAligner`; removed fillers lose marks; unalignable rewrites flag the smallest reliable phrase or the whole result ("Review this phrase", T05).
  - In the destination: transparent non-activating overlay anchored to word rects (`WordRectProvider`), tracking scroll / zoom / wrap / window move / display change via AX notifications; hidden when the app leaves front, restored after revalidation. Ladder: VoicePlus fields → validated adapters (Notes, TextEdit, Mail, Safari as the first matrix; recorded per bundle) → "Word marks aren't available in this app" (D09) with marks retained in Review / Today. Never modifies target text.
  - Correction popover: anchored to the word; ≤ 3 credible alternatives from `alternates`, Edit…, Keep, "Remember spelling" (unchecked → `LearnedLexicon`); replace only if the original range still matches (`ReplaceRange`), else D10 copy and copy-to-clipboard; Escape closes; focus returns to the word/pill.
  - Tests: mark mapping table; overlay suppression ladder; popover model; range-guarded replace. Evidence: `implemented`; §5 item 14.

### Wave 3 — S10 · Accessibility, motion, keyboard (design §11)

- [ ] **S10**
  - Reduce Motion (`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` + Appearance setting): static Spool, no flight, no twist; numeric level readout replaces tape motion; state labels and dwell unchanged.
  - VoiceOver: announce start, stop, "final text ready · N words to review", delivery result; never per-token. Artwork `accessibilityHidden`.
  - Keyboard: Tab order in reading order for held/error actions; Escape closes a popover before cancelling a turn; focus returns predictably; no global key swallowing outside the turn (I2).
  - Larger Text reflow in the window; pill bounded with "Review all"; grapheme-safe mark placement (CJK, RTL, emoji tests).
  - Tests: motion flag → static pose; announcement sequence; keyboard order; grapheme tests.

### Wave 3 — S11 · Catalogue wiring

- [ ] **S11** — every pill, window, onboarding and menu error path resolves its copy through `RecoveryCatalog` (S9); `DeliveryCopy` constants become catalogue lookups; per design §10 retry semantics (no universal Retry; unconfirmed never auto-retries). Tests: a table-driven test walks every catalogue id through the pill row and window notice renderers.

### Wave 4 — R · Release 1.11.0

- [ ] **R1** `swift build` clean; `swift test --no-parallel` all green; `RecordingReplayTests` on `Fixtures/real-room/builtin` — WER unchanged ± 0.01 vs the 1.10.0 number in `DECISIONS.md`.
- [ ] **R2** `Fixtures/prosody/script.md` written (15 questions, 15 two-clause sentences, 10 exclamations; punctuation omitted from what the owner reads) for the owner's Wave 2 recording.
- [ ] **R3** `Packaging/release.sh V4-w1 1.11.0` from a clean worktree; `verify_install.sh`; DMG retained, none overwritten.
- [ ] **R4** `progress.md` (wave summaries, test count, DMG sha), `DECISIONS.md` (fn default, unknown-caret rule, SNR thresholds as hypothesis, pill geometry change, preview-before-insert), §7 of this document filled in; §5 handed to the owner with the numbers to collect.

---

## 4. Verification

### Build gates (agent)
- Whole package builds after every task; wave gate = every task's tests green + `swift test --no-parallel` at the end of waves 1, 2, 3.
- No fixture WER regression; no test deleted (updated copy tests are allowed and listed in the report).
- **Design parity gate:** `SpoolParityTests` (624 frames, 26 cameos, 6 flights) and `DesignCopyParityTests`
  (pill, screens, empty states, catalogue) green. A mismatch is fixed in Swift, never by editing a fixture;
  fixtures change only by re-running `node Scripts/spool_golden.mjs` after `design_v1.html` changes.
- Design acceptance scenarios (design §13, items 1–17) each mapped to a test or to a §5 line; the mapping table is written into §7.

### V4 Wave 1 gates (from `VoicePlus_Improvements_V4.md` §11)
| Gate | How measured |
|---|---|
| 0 phantom landings on 50 silent holds | `fixture-verified` with `Fixtures/audio/silence`; owner repeats live |
| Latch lands every ≥ 2 s pause, right caret ≥ 95 % | mock-engine test + owner 5-minute session in Docs and Claude |
| Mid-sentence placement ≤ 2 wrong in 30 × 5 apps | pipeline matrix + owner session |
| 0 mic warnings on the quiet-room corpus | `Fixtures/real-room/builtin` replay |
| digits class WER < 0.20 | replay of the script's number lines |
| cold launch → first landing p95 < 2.5 s; key-down → first buffer p95 < 150 ms | owner, from the `.info` timing log |

---

## 5. Owner hardware checklist (agent writes the numbers to collect; owner runs it)

1. Built-in mic, AirPods in mid-sentence, input switched in System Settings while latched, AirPods case open/close ×3, music through AirPods then dictate, 10 min idle then dictate (§12.7 A of V4). Pass: zero "needs reconnecting" / "couldn't start"; every start < 1 s on built-in.
2. Key-down → first buffer p95 from the log over 50 presses.
3. Mic indicator (orange dot) is **off** between turns while the graph is paused (A4).
4. 50 silent holds: 0 landings; "No speech detected" fades.
5. Latch in Docs, Claude, Notes: 5 minutes, pauses of 2–3 s, move the caret between pauses; count wrong placements and "another voice" chips.
6. Draw a box with the key held in Docs, Sheets, Figma: chip shows crop + text; deny Screen Recording once and confirm the AX-only fallback copy.
7. Spool side by side with `design/design_v1.html` (Spool studio, every state chip): same silhouette, colours, blink, lean, mouth and lamp per state; reels counterclockwise while listening, clockwise while inserting, still in preview/held/error, parked in silence (deliberate difference); inlet width continuous; nothing drawn behind the notch; floating pill on an external display.
8. Preview-before-insert: final text visible ≥ 900 ms before it lands; hover freezes it; Escape during preview inserts nothing; low-confidence word extends to 1.8 s.
9. "Inserted in Mail" with tick in Mail/Notes; "Inserted · not confirmed" in Docs; held row after an app switch during dwell, Insert here re-targets.
10. New press while finishing → "Finishing your previous dictation"; duplicate key-up cannot double-insert (hold, release, tap again fast).
11. Every window section in light and dark, high contrast, Larger Text; every empty/loading/error state reachable (history off, log unreadable, model missing).
12. Fresh user account: onboarding closable, under three minutes, fn system-action prompt appears when the key is set to Emoji/Dictation, voice step skippable, first dictation lands in the test field with one red-dotted word corrected.
13. Tape flight from the pill mouth to the caret in Notes; suppressed in a secure field and under Reduce Motion.
14. Red dotted marks in Notes/TextEdit/Mail; "Word marks aren't available in this app" in Docs; correction replaces only the marked word.
15. Mute → quit → relaunch still muted; lock/sleep clears latch; no auto-resume.

---

## 6. Report format (per task)

```
Task: D2
Built: model punctuation provisional; suppressors keyed on CaretState; StyleStage off without context
Files: Pipeline/Formatters/FieldRole/FieldRoleFormatter.swift, App/Services/FieldRolePipeline.swift, Tests/PipelineTests/...
Tests: PipelineTests 212 green (+31)
Evidence: implemented + fixture-verified; hardware pending (§5 item 5)
Deviations: none
Unverified: Chromium marker-range read on a real page
```

---

## 7. Execution status (agent-maintained)

Legend: `[ ]` not started · `[~]` in progress · `[x]` done (build clean + tests green + acceptance addressed).

| Wave | Task | Status | Commit | Tests (+added) | Evidence | Notes |
|---|---|---|---|---|---|---|
| 0 | G0.1 | [ ] | | | | |
| 0 | G0.2 | [ ] | | | | |
| 0 | G0.3 | [ ] | | | | |
| 0 | G0.4 | [ ] | | | | |
| 1 | A1–A5 | [ ] | | | | |
| 1 | B1–B4 | [ ] | | | | |
| 1 | C1–C3 | [ ] | | | | |
| 1 | D1–D7 | [ ] | | | | |
| 1 | E1–E2 | [ ] | | | | |
| 1 | F1 | [ ] | | | | |
| 1 | G1–G3 | [ ] | | | | |
| 1 | H2–H3 | [ ] | | | | |
| 1 | I1–I2 | [ ] | | | | |
| 1 | J1–J2 | [ ] | | | | |
| 1 | S1 | [ ] | | | | |
| 1 | S6 | [ ] | | | | |
| 1 | S9 | [ ] | | | | |
| 2 | S2 | [ ] | | | | |
| 2 | S3 + S11 store | [ ] | | | | |
| 2 | S7a | [ ] | | | | |
| 2 | S7b | [ ] | | | | |
| 2 | S7c | [ ] | | | | |
| 2 | S7d | [ ] | | | | |
| 2 | S7e | [ ] | | | | |
| 2 | S7f | [ ] | | | | |
| 2 | S7g | [ ] | | | | |
| 2 | S12 | [ ] | | | | |
| 2 | S8 | [ ] | | | | |
| 3 | S4 | [ ] | | | | |
| 3 | S5 | [ ] | | | | |
| 3 | S10 | [ ] | | | | |
| 3 | S11 | [ ] | | | | |
| 4 | R1–R4 | [ ] | | | | |

Design §13 acceptance mapping (fill in): scenario → test name or §5 line.

---

## 8. Out of scope here (carried to V4 Wave 2/3)

Caret OCR ladder (V4.54–V4.56), unified ITN (V4.14) and coverage (V4.15), prosody punctuation (V4.24–V4.26),
voice-processing IO / level gate / VAD-region decode / speaker gate defaults (§3 A–D), SNR thresholds by
corpus, turn-anchored voice (V4.41–V4.42), meetings-owns-the-mic (V4.46–V4.47), Notes mode (V4.35) beyond
the held queue, mobile companion, "Ask" in Meetings. Each is built behind a flag when its wave arrives; nothing
in this document should make them harder.
