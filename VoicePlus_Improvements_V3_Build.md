# VoicePlus — Improvements V3 · Build Document

Execution plan for the V3 improvements, on top of the current VoicePlus app. Written to be run end to
end by a coding agent. Every item from the V3 plan is here as tasks with files, tests and acceptance.

---

## 0. How to run this document

- Read `VoicePlus_Improvements_V3.md` Sections 0–4 first. They are the contract.
- Work item by item (Section 3). Within a wave, run tasks marked **[P]** in parallel subagents.
- One subagent = one task or one item. It owns the listed directories and test target only.
- Every task ends with: build clean, its tests green, a ≤15-line report, a scoped commit.
- Evidence is labelled: `implemented` · `fixture-verified` · `hardware-verified`. Never upgrade a label.
- Hardware checks go on the owner checklist (Section 5). They are not blockers for the next task.

### Ground rules
- Toolchain: `eval "$(Scripts/bootstrap-toolchain.sh)"` once per shell. Swift Testing only.
- Scratch path per task: `swift build --scratch-path .build-<task>`; tests with
  `swift test --scratch-path .build-<task> --filter <Module>Tests`.
- `Shared/` and `Package.swift`: additive only, mention in the report.
- Commit: `git add <paths> && git commit -m "<task id>: <what>"`. Never `git add -A`, push, or rebase.
- Log tool is `/usr/bin/log`. Bare `log` is a zsh builtin and returns nothing.
- Flags never get deleted. Losing candidates get `defaultOn = false`.
- No new SwiftPM dependency anywhere in this document.
- The pill and notch are **not redesigned**. Add rows and states in the existing style only.

### Existing facts to rely on
| Fact | Where |
|---|---|
| Final recognizer factory | `Engine/ASRRuntime/BundledModel.swift` (`RecognizerFactory.makeFinal`, `makePreview`) |
| Preview recognizers | `Engine/ASRRuntime/Recognizers.swift` (`EOUPreviewRecognizer`, `PollingPreviewRecognizer`) |
| Capture chain in production | `App/Services/EngineFactory.swift:101` wraps `CoreAudioCaptureSource` in `AcousticCaptureSource` |
| Voice-processing capture | `Engine/Audio/Robustness/VoiceProcessingCaptureSource.swift`, used only by `App/Services/MicSelfTest.swift` |
| Robustness profile | `Engine/Audio/Robustness/AcousticStage.swift` (`RobustnessProfile`, `.default`, `.raw`) |
| Recorder and replay | `Engine/Audio/UtteranceRecorder.swift`, `Tests/EngineTests/RecordingReplayTests.swift` |
| Real corpus | `Fixtures/real-room/builtin/` (20 utterances) + `Fixtures/real-room/script.md` |
| Injector | `Injection/TextInjector.swift`, `Injection/FocusGuard.swift`, `Injection/InjectionTypes.swift`, `Injection/AppAdapter.swift` |
| Coordinator | `App/Services/DictationCoordinator.swift` (`finalize()` clears `handsFree`) |
| Lander and landing diff | `App/Services/UtteranceLander.swift` |
| Pill | `App/UI/PillView.swift` (`PillModel`), `App/UI/PillPanelController.swift`, `App/UI/PresenceIndicatorController.swift` |
| Hotkey | `App/Core/HotkeyStateMachine.swift`, `App/Services/HotkeyService.swift` |
| Mute | `App/Ambient/MuteController.swift`, `App/Services/HandsFreeController.swift` |
| Settings tabs | `App/Settings/SettingsView.swift` (`SettingsTab` enum, line ~255) |
| Model tiers | `App/Onboarding/OnboardingDependencies.swift` (`case fast, balanced, best`) |
| AX context | `App/Services/AXContextProviders.swift`, `Engine/Biasing/` |
| Learning | `Engine/Adapt/` (`LearnedLexicon.swift`, `AdapterTrainer.swift`, `LexiconSanity`) |
| Correction ledger | `App/Correction/CorrectionLedger.swift` (behind `dualPath`) |
| Lab | `Lab/Harness/`, `Lab/UI/LabPanelViewModel.swift`, `Lab/DataPanel/` |
| Qwen3-ASR CoreML source (MIT) | `/Users/adityakatare/Documents/Codex/2026-09-08/https-github-com-muesli-hq-muesli/work/muesli/native/MuesliNative/Sources/MuesliCore/Qwen3ASR/` |
| Qwen weights (1.2 GB, on disk) | `~/Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b` |

---

## 1. Parallel execution map

Waves run in order. Inside a wave, every **[P]** task runs concurrently in its own subagent.

| Wave | Tasks | Needs |
|---|---|---|
| 0 | R0 · R1.4 · R1.5 · R2.1 · R4.1a · R5.1 · R6.1 | nothing |
| 1 | R2.2 · R2.3 · R2.4 · R2.5 | R2.1 |
| 2 | R3 · R4.1b · R4.2 · R4.3 · R5.2 · R5.3 · R6.2 | R2 complete |
| 3 | R5.4 · R7 | R5.2–R5.3 · R0 + R6 |
| 4 | R8 | R3 + R7 |

Release A is cut when R0, R1, R2, R4.1, R5, R6 are done. Release B when R3, R4.2, R4.3, R7, R8 are done.

Suggested subagent split for wave 0 (seven agents, no shared files):

| Agent | Task | Owns | Tests |
|---|---|---|---|
| a | R0 | `DESIGN.md` | none |
| b | R1.4 | `Engine/Audio/` | `EngineTests` |
| c | R1.5 | `Engine/ASRRuntime/`, `Lab/Harness/`, `Tests/EngineTests/RecordingReplayTests.swift` | `EngineTests`, `LabTests` |
| d | R2.1 | `Shared/Types/` | `SharedTests` |
| e | R4.1a | `Pipeline/` stages `wakeVerb`, `adapt.lexicon` | `PipelineTests` |
| f | R5.1 | `Engine/ASRRuntime/Qwen3ASR/` | `EngineTests` |
| g | R6.1 | `App/Onboarding/`, `App/Settings/`, `Engine/ASRRuntime/ModelCatalog.swift` | `AppTests`, `EngineTests` |

---

## 2. Definitions used by every task

- **Segment:** audio `[t0, t1]` closed by key release (hold) or endpoint (latch). Has `sessionID`,
  `segmentIndex`.
- **Provisional text:** preview words shown in the pill. Free to change.
- **Committed text:** final text for one segment, sent to the field once, never retracted.
- **Held:** committed text with no safe destination. Waits for Insert here / Copy / Discard.
- **Delivery outcome:** `delivered(verified)`, `delivered(unverified)`, `held`, `failed`.
- **Readback rule:** a method that posted without throwing has possibly landed. Never try another
  method after it. Outcome is `delivered(unverified)` if readback cannot confirm.

---

## 3. Items and tasks

### R0 — DESIGN.md for window, settings, onboarding · [P] wave 0

- [x] **R0.1 Write `DESIGN.md`** at the repo root.
  - Contents: typography (SF Pro, SF Mono), one accent, dark-first, spacing scale, contrast targets,
    state vocabulary, focus behaviour, reduced motion, error sizing, copy voice.
  - Document the **existing** pill and notch rows as they are. Do not propose changes.
  - Specify the one window (sidebar + detail) and the onboarding steps from V3 §9.
  - Acceptance: every window and onboarding state has a spec; reduced-motion and increased-contrast
    variants listed; no web views; no pill redesign.

### R1 — Real-audio loop (R1.1–R1.3 done)

- [x] **R1.4 Capture defaults by measurement · [P] wave 0**
  - Add a test in `Tests/EngineTests/` that runs `Fixtures/real-room/builtin/*-raw.wav` through three
    chains: raw tap, tap + spectral gate (`RobustnessProfile.default`), voice-processing + gate.
    Voice-processing cannot run offline; emulate its effect only if a reproducible path exists,
    otherwise mark that column `hardware-verified pending` and add a `--mic-selftest-vp`-style
    hardware check the owner runs.
  - Score per file against `script.md` (see R1.5 scorer). Print a WER table.
  - Set the production default from the table. Wire the choice into
    `App/Services/EngineFactory.swift:101` so the profile and the capture source agree; the manifest
    `aec` field must match the graph's `vp=` flag.
  - Harden capture: unplug while listening, reconnect, sleep/wake → clear state, no wedge, no lost
    finalized text. Add tests against the capture protocol and mocks.
  - Tests: `EngineTests`. Acceptance: table committed to `Engine/Audio/Robustness/SUITES.md`;
    default chosen from it; manifest and graph agree; hot-swap tests green.

- [x] **R1.5 Preview choice · [P] wave 0**
  - Add per-file scoring to `RecordingReplayTests`: match recordings to `script.md` lines by timestamp
    order; normalize (lowercase, strip punctuation); print WER per file and total.
  - Add a preview replay: feed each raw WAV in 100 ms chunks to `EOUPreviewRecognizer` and to
    `PollingPreviewRecognizer(over TDT v3)`; record the final preview string and time to first word.
  - Print a table: candidate × (WER, first-word p50, CPU time).
  - Make both candidates selectable in Lab (`LabConfigChoice`) and behind a flag `previewBackend`.
  - Tests: `EngineTests`, `LabTests`. Acceptance: table in the report; default set by measurement and
    recorded in the decisions log; flag exists with the winner as default.

### R2 — Two surfaces, ordered commit, delivery, recovery · P0

- [x] **R2.1 Shared types · [P] wave 0 · serial gate for wave 1**
  - `Shared/Types/TranscriptSpan.swift`: add `stability: Stability` (`provisional`, `committed`,
    `final`) with default `.final` so existing initializers compile.
  - Add `SegmentID { sessionID: UUID, index: Int }` and `DeliveryOutcome` enum
    (`delivered(verified: Bool, method: String)`, `held(reason: String)`, `failed(reason: String)`).
  - Keep `confidence`, `audioRange`, `provenance` untouched. Update `ConfidenceContract` only if needed.
  - Tests: `SharedTests` (encode/decode round trip, default stability). Acceptance: whole package
    builds; no existing test changes except added cases.

- [x] **R2.2 Engine segments · [P] wave 1**
  - In `Engine/ASRRuntime/RealEngine.swift` and the audio pipeline: close a segment on key release
    (hold) and on endpoint (latch). Emit `EngineEvent` with `SegmentID` and stability.
  - Bound the ring buffer and the pending-segment backlog (max 2). Beyond the bound, commit pass-1.
  - Reject results whose `SegmentID` is not the current session or is older than the last committed.
  - Tests: `EngineTests` (segment closure, ordering, stale rejection, backlog bound) using
    `MockEngine`/fixture audio. Acceptance: tests green; no change to fixture WER.

- [x] **R2.3 Injection: readback rule, Chromium adapter, held queue · [P] wave 1**
  - `Injection/TextInjector.swift`: implement the readback rule. After a method returns `true` without
    throwing, do not iterate further. If readback does not confirm, return
    `.injected(method:, verified: false)`. Only a thrown error before posting falls through.
  - `Injection/AppAdapter.swift`: add `ChromiumAdapter` for `com.brave.Browser`,
    `com.google.Chrome`, `com.microsoft.edgemac`, `company.thebrowser.Browser`. Order:
    `[.keystroke, .paste]`. Readback: compare `AXSelectedText`/caret movement, else skip verification.
    Register it before `DefaultAdapter`.
  - `Injection/FocusGuard.swift`: remove auto-delivery on focus return. Queue becomes **held**. Expose
    `held: [HeldText]` with `insertHere()`, `copy()`, `discard()`. Update existing tests to the new rule.
  - Add secure-field refusal: if focused role is `AXSecureTextField` (or subrole), return
    `.failed(reason: "secure field")` without posting.
  - Add a never-inject list (bundle IDs, stored in settings); refuse and hold.
  - Ordered commit queue: deliver segments in `SegmentID` order; never deliver the same ID twice.
  - Tests: `InjectionTests` (no second method after a posted one; Chromium order; held not
    auto-delivered; secure refusal; never-inject; ordering; duplicate suppression). Acceptance: the
    Brave log pattern (`keystroke failed` then `paste failed`) cannot occur; all tests green.

- [x] **R2.4 Pill and app surface · [P] wave 1**
  - `App/UI/PillView.swift` / `PillPanelController.swift` / `PresenceIndicatorController.swift`:
    on land, replace the preview with the committed text for ~1.2 s, then return to ready. Existing
    row style. Add an *unverified* variant of the landed row ("Landed · not confirmed").
  - Add a *held* row: text, destination name, three actions (Insert here / Copy / Discard). Same
    actions in the status-item menu.
  - Error copy per V3 §6: "Destination changed — Copy text", "Microphone disconnected — Choose
    microphone", "No speech detected — Try again". No raw errors.
  - Quit warning when held text exists.
  - Wire `DeliveryOutcome` from `UtteranceLander` into the pill state.
  - Tests: `AppTests` (state transitions, held actions, quit guard, copy strings). Acceptance: every
    outcome has a row; no new mark, sound, or animation beyond the existing style.

- [x] **R2.5 Repair commands · [P] wave 1**
  - `Actions/`: `scratch that`, `no, <replacement>`, `put it back`, bound to the last committed
    segment's text region. Apply only if the region still matches (AX read); else show a suggestion in
    the pill. Use `CorrectionLedger` as the record for "put it back". Never blind backspaces or ⌘Z.
  - Quoted commands remain dictation. Repair context expires after the next non-repair utterance.
  - Tests: `ActionsTests`, `AppTests`. Acceptance: matrix of region-matches / region-changed /
    quoted-command green.

- **R2 item gate (owner checklist):** delivery matrix in Notes, Mail, Brave, Slack, VS Code,
  Terminal, Numbers; 50 consecutive dictations; latency p50 ≤ 700 ms final; zero duplicates. Re-run
  the twenty-sentence session in Brave: every outcome verified or unverified, none failed.

### R3 — Coordinator, latch, mute · [P] wave 2 (with R4)

- [ ] **R3.1 Rename and coordinator**
  - Rename `handsFree` → `latched` across `App/` (`DictationCoordinator`, `PillModel`,
    `HandsFreeController` → `LatchController` or keep file, rename API). Remove the `finalize()` line
    that clears the mode.
  - One `SessionCoordinator` owns start/stop/cancel and mic arbitration for hotkey, menu, onboarding,
    meetings. Build on the existing ranked audio ownership; do not duplicate it.
- [ ] **R3.2 Latch behaviour**
  - Endpoint-driven segment closure while latched (R2.2 events). Single tap stops and finalizes.
    Escape cancels pending, keeps inserted text.
  - Focus change while latched: pause delivery, hold, require explicit resumption into a named target.
  - Lock/sleep: stop capture, cancel pending insertion; no silent resume.
- [ ] **R3.3 Mute and speaker guard**
  - Verify persistent mute across relaunch (test with a temp defaults suite).
  - Speaker filtering on + mismatch or uncertain → suppress insertion, show honest "speaker model
    unavailable" when weights are absent.
- Tests: `AppTests`, `EngineTests` (state machine covering every V3 §8 row). Acceptance: tests green;
  owner checklist: latch across three apps with focus changes and one sleep/wake; mute survives relaunch.

### R4 — Context, formatting, learning

- [x] **R4.1a Fix provenance no-ops · [P] wave 0**
  - Find the stages registered as `wakeVerb` and `adapt.lexicon` (grep the stage IDs in `Pipeline/`
    and `App/Services/AppContainer.swift`). Make each output span append its `StageID` to
    `provenance`. If a stage is dead by design, remove it from the registry instead.
  - Tests: `PipelineTests` contract tests for both. Acceptance: zero `contract violation` lines in a
    replay of the corpus through `AppContainer`'s pipeline.
- [ ] **R4.1b Ranked context list · [P] wave 2**
  - `Engine/Biasing/`: one `ContextRanker` merging explicit corrections + Dictionary (highest), focused
    window text, recent confirmed vocabulary (lowest). Dedupe, cap 400, per-session discard.
  - `PromptBuilder`: turns the list into a bounded string for the refinement prompt; strips
    instruction-like text (imperatives, "ignore", "system:", URLs); never logs it.
  - Consumer today: refinement gate check and entity-recall measurement in Lab.
  - Tests: `EngineTests`, `LabTests`. Acceptance: entity recall and false insertions on the corpus with
    and without the list reported; prompt never exceeds cap; screen text never persisted.
- [ ] **R4.2 Field-role formatting and continuation · [P] wave 2**
  - `Pipeline/Formatters/`: choose formatter by AX role + app (terminal role inside an editor →
    terminal rules: no auto-cap, no trailing period, never submit). Preserve code identifiers.
  - Continuation: from text before cursor decide leading space, capitalization, paragraph break.
  - Tests: golden files for terminal, editor, chat, mail, mid-sentence. Acceptance: goldens green.
- [ ] **R4.3 Dictionary and learning UI · [P] wave 2**
  - Dictionary view lists learned entries: spelling, "heard as", origin, remove / forget. Removal takes
    effect on the next utterance (test it).
  - Benchmark tab shows recall and false-insertion counters from R4.1b.
  - Tests: `AppTests`. Acceptance: removal provably stops influence; counters render.

### R5 — Qwen3-ASR refinement, flagged

- [x] **R5.1 Port the CoreML module · [P] wave 0**
  - Copy the six Swift files from the Qwen3ASR source directory (`Qwen3AsrConfig`, `Qwen3AsrManager`,
    `Qwen3AsrModels`, `Qwen3RoPE`, `Qwen3StreamingManager`, `WhisperMelSpectrogram`) and its
    `LICENSE-Apache-2.0` into `Engine/ASRRuntime/Qwen3ASR/`. Add the source project's MIT notice as
    `LICENSE-MIT`. Imports are Foundation, Accelerate, OSLog only; no new dependency.
  - Gate every type with `@available(macOS 15, *)`. On macOS 14 the feature reports unavailable.
  - `RefinementSession` protocol: `refine(samples: [Float], context: String, deadline: Duration) async
    throws -> [TranscriptSpan]`. Implement `MockRefinementSession` and `Qwen3RefinementSession`.
  - Weights: resolve from the existing FluidAudio cache path if present; else download-on-enable via
    `ModelManager` with manifest and integrity like other models.
  - Tests: `EngineTests` (mock; a real-weights test that skips when weights are absent, and when
    present transcribes one corpus file and prints WER). Acceptance: builds on macOS 14 target;
    real-weights test passes on the owner's Mac.
- [ ] **R5.2 Refine stage · [P] wave 2**
  - `Pipeline/`: `RefineStage` replaces span text in place, keeps `audioRange`, re-aligns word timing,
    appends provenance with the pass name. Honors deadline (10.2) and backlog ≤ 2. Timeout → pass-1.
  - A late result never overwrites committed text (check `stability == .committed`).
  - Tests: `PipelineTests`. Acceptance: contract tests green; timeout path tested.
- [ ] **R5.3 Gate policy and settings · [P] wave 2**
  - Gate: streaming uncertainty below threshold, context near-miss (phonetic), non-English, long
    segment. Thresholds in a settings struct. Voice tab: refinement Auto / Always / Never.
  - Flag `qwenRefinement`, default off.
  - Tests: `PipelineTests`, `AppTests`. Acceptance: gate recall on the corpus reported.
- [ ] **R5.4 Benchmark · wave 3 (after R5.2–R5.3)**
  - Lab configs: Parakeet only · Qwen only · two-pass. Run on `Fixtures/real-room/builtin/` and the
    fixture suites. Report WER by segment class, latency p50/p95, peak memory.
  - Decision: default-on only if useful gain on difficult speech, no clean-speech regression, deadline
    met (or latch-only mode recorded), thermal acceptable over 30 min latched (owner checklist).
  - Acceptance: table in the decisions log; flag default set from it. Either outcome is complete.

### R6 — One model stack and onboarding

- [x] **R6.1 Remove the tier picker · [P] wave 0**
  - `App/Onboarding/OnboardingDependencies.swift`: remove `fast / balanced / best`. One stack:
    `parakeetTDTv3` + `parakeetEOU160`. Install on first run with existing progress and integrity UI.
  - `Engine/ASRRuntime/ModelCatalog.swift` / `BundledModel.swift`: keep the CTC and Whisper entries
    only as fallbacks; hide them from Settings › Models. Qwen appears only when refinement is enabled.
  - Existing installs: keep what is on disk; do not re-download.
  - Tests: `AppTests`, `EngineTests`. Acceptance: no picker; fresh state installs one stack; existing
    manifest untouched.
- [ ] **R6.2 Onboarding flow · [P] wave 2**
  - Steps: Welcome → Microphone with real level meter → Accessibility → choose and try the key with a
    real landing in a practice field → Done. No provider setup, no enrollment, no ambient gate.
  - Practice field uses the R2 commit path. Onboarding says plainly when the model is still installing.
  - Tests: `AppTests` (step order, permission dead-end avoidance, landing uses the real path).
    Acceptance: owner checklist: clean account, under two minutes, first dictation works.

### R7 — One window, one menu · wave 3 (after R0, R6)

- [ ] **R7.1 Window shell**: sidebar + detail. Sections: Today / Timeline, Meetings, Dictionary / Apps,
  Voice (enrollment, mic, Benchmark), Privacy (Data Panel), Settings.
- [ ] **R7.2 Fold in**: Data Panel → Privacy; Lab UI → Voice › Benchmark; enrollment window → Voice.
  Remove the nine-tab `TabView`; keep every setting reachable.
- [ ] **R7.3 Menu**: glyph and idle notch presence open the same menu; Stop and Mute during capture;
  copy / recover text; start meeting; open app / settings / quit.
- Constraint: **do not touch the pill's look**.
- Tests: `AppTests`, `LabTests`. Acceptance: every state per `DESIGN.md`; notch and notchless
  displays; no standalone windows remain (owner checklist).

### R8 — Ambient and Timeline · wave 4 (after R3, R7)

- [ ] **R8.1 Opt-in and capture**: separate switch, default off; enrolled speaker only; transcript
  only; reuse meeting storage; never reaches any injection path (test it).
- [ ] **R8.2 Retention**: seven-day default; expiry and delete clear search indexes; audio retention a
  separate switch.
- [ ] **R8.3 Timeline view**: search, source filters, delete, delete-all. Code name `AmbientTimeline`.
- [ ] **R8.4 Indicator**: reflects actual microphone ownership.
- Tests: `AppTests`, `EngineTests`, `SharedTests`. Acceptance: retention and deletion verified;
  indicator matches ownership (owner checklist).

---

## 4. Verification per release

### Release A checklist
- [ ] R0, R1.4, R1.5, R2, R4.1, R5, R6 reports filed with evidence labels.
- [ ] Whole package `swift build` clean; all test targets green.
- [ ] Replay of the corpus through the `AppContainer` pipeline: zero contract violations.
- [ ] Latency table: preview p50 ≤ 300 ms; final p50 ≤ 700 ms, p95 ≤ 1200 ms.
- [ ] `Packaging/release.sh` candidate built; `verify_install.sh` OK.
- [ ] Owner session (Section 5) results attached; unverified items listed.

### Release B checklist
- [ ] R3, R4.2, R4.3, R7, R8 reports filed.
- [ ] State-machine tests for every latch/mute row green.
- [ ] No standalone windows; every setting reachable.
- [ ] Ambient text provably never reaches injection.
- [ ] Owner session results attached.

---

## 5. Owner hardware checklist (agent fills in the numbers, owner runs it)

One session after R2, then one per release candidate. Each line is pass / fail / not tried.

1. Dictate one sentence each into Notes, Mail, Brave, Slack, VS Code, Terminal, Numbers. Text lands
   once. Pill shows the final text on land.
2. Dictate, switch apps before release. Pill shows *held* with Insert here / Copy / Discard. Returning
   to the app does **not** insert by itself.
3. Twenty sentences in a row in Brave. No duplicates. Any "not confirmed" rows are listed.
4. Unplug or disconnect the microphone mid-dictation. App recovers; error names an action.
5. Sleep and wake. Dictation works without relaunch.
6. Double-tap latch, speak three sentences with pauses, switch apps, come back, single tap. Segments
   landed in order; nothing landed in the wrong app.
7. Mute, quit, relaunch. Still muted.
8. Fresh user account: onboarding under two minutes; first dictation lands.
9. Latched for 30 minutes. Fan and heat acceptable; no wedge.

---

## 6. Report format (per task)

```
Task: R2.3
Built: readback rule, ChromiumAdapter, held queue, secure-field refusal, never-inject list
Files: Injection/TextInjector.swift, Injection/AppAdapter.swift, Injection/FocusGuard.swift, Tests/InjectionTests/...
Tests: InjectionTests 71 green (+25)
Evidence: implemented + fixture-verified; hardware pending (owner checklist 1–3)
Deviations: none
Unverified: Brave selection readback on real page
```

---

## 7. Execution status (agent-maintained)

Legend: `[ ]` not started · `[~]` in progress · `[x]` done (build clean + tests green + acceptance addressed).
Evidence labels: `impl` = implemented · `fix` = fixture-verified · `hw` = hardware-verified.

| Item | Wave | Status | Evidence | Notes |
|---|---|---|---|---|
| R0.1 DESIGN.md | 0 | [x] | impl | `be0d1ca` 769 lines; pill documented as-is |
| R1.4 capture defaults | 0 | [x] | fix | `1baf516` raw tap wins: 0.1000 vs gate 0.1182, and 7/7 SNR points |
| R1.5 preview choice | 0 | [x] | fix | `74bd335` scorer + previewBackend flag + preview formatting |
| R2.1 shared types | 0 | [x] | impl | `c46042d` 51 SharedTests green; wave-1 gate opened |
| R4.1a provenance no-ops | 0 | [x] | fix | `96d801d` 202 stage runs, 0 contract violations |
| R5.1 Qwen port | 0 | [x] | fix | `f52255a` + `c6c8887`: forced decoder ids; WER 1.000 → 0.000, corpus 0.1724 |
| R6.1 remove tier picker | 0 | [x] | impl | `0646ccd` build-verified; test run was blocked |
| R2.2 engine segments | 1 | [x] | fix | `d680ec1` 16 new; fixture WER unchanged (before/after build) |
| R2.3 injection rules | 1 | [x] | fix | `60751e6` 104 InjectionTests green (+38, 10 changed) |
| R2.4 pill + app surface | 1 | [x] | impl | `727fbd6` AppTests 550/550; no-redesign held |
| R2.5 repair commands | 1 | [x] | impl | `afd959f` 24 new, 186 ActionsTests green |
| R3 coordinator/latch/mute | 2 | [x] | impl | `2785f28` 24 new; every V3 §8 row; 3 carried gaps (§8 below) |
| R4.1b ranked context | 2 | [x] | fix | `914ce7b` recall 0.600→0.800, false ins. 2→6 |
| R4.2 field-role formatting | 2 | [x] | fix | `baad052`+`97e55d7` 6 goldens; AX-hints wiring in flight |
| R4.3 dictionary + learning UI | 2 | [ ] | — | |
| R5.2 refine stage | 2 | [x] | impl | `4075723` 31 new; withdraws confidence on rewrite |
| R5.3 gate policy + settings | 2 | [ ] | — | |
| R6.2 onboarding flow | 2 | [~] | — | in flight |
| R5.4 benchmark | 3 | [ ] | — | early data: Qwen 0.1724 vs Parakeet 0.0990 → gate likely fails, flag stays off |
| R7 one window, one menu | 3 | [ ] | — | |
| R8 ambient + Timeline | 4 | [ ] | — | |

### Release artifacts

| Wave | Version | DMG | Status |
|---|---|---|---|
| 0+1 | 1.8.0 | `Packaging/releases/VoicePlus_V3-w01_1.8.0.dmg` | **built** from `727fbd6`, verify_install OK, 15 MB |
| 2 | 1.9.0 | `Packaging/releases/VoicePlus_V3-w2_1.9.0.dmg` | pending |
| 3 | 1.10.0 | `Packaging/releases/VoicePlus_V3-w3_1.10.0.dmg` | pending |
| 4 | 1.11.0 | `Packaging/releases/VoicePlus_V3-w4_1.11.0.dmg` | pending |


Previous DMGs are never deleted or overwritten; `release.sh` refuses to overwrite.

---

## 8. Carried gaps (found during implementation, not yet closed)

Recorded so they are not lost between waves. None is a regression; each is work the item surfaced.

| # | Gap | From | Why it is open |
|---|---|---|---|
| G1 | **Escape is not bound to a key.** `SessionCoordinator.escape()` exists and is tested, but nothing invokes it. | R3.2 | A global `keyDown` monitor needs Input Monitoring, which V3 §2.1 keeps behind an escape hatch; a bare-Escape Carbon hot key would steal Escape from every app. Needs a design decision, not just wiring. |
| G2 | **`handsFree` → `latched` rename is incomplete.** Still present in `App/UI/PillView.swift`, `StatusItemController.swift`, `App/Core/MenuModel.swift`, `App/Services/AppContainer.swift`, `App/AppDelegate.swift`, `Pipeline/WakeVerb/WakeVerbPreRoute.swift`, `Engine/Audio/AudioPipeline.swift` (+ their tests). | R3.1 | R3 stopped at files other agents owned; deprecated aliases keep everything building. Finish when `App/Settings` and `App/Onboarding` are free. |
| G3 | **Speaker filtering has no Settings toggle.** `SpeakerFilter` is explicit opt-in but nothing in the UI can opt in. | R3.3 | Settings UI belongs to R4.3 / R8. |
| G4 | **`PromptBuilder` char cap saturates.** 1000-char cap filled at 189 of 400 terms, so the cap, not the ranker, decides what the model sees. | R4.1b | R5.3 to decide by measurement whether to raise it. |
| G5 | **`GatekeeperLatencyTests.classifyStaysUnderBudget` is a cold-start flake.** Passes in isolation, fails under parallel load. | observed by 3 agents | Confirm at the release gate on an idle machine; do not treat as a regression. |
| G6 | **Qwen is measurably worse overall** (corpus mean WER 0.1724 vs Parakeet 0.0990) while now being correct (WER 0.000 on the probe line). | R5.1 / R5.4 | R5.4 must split by segment class before the flag decision is final. Flag stays off. |

