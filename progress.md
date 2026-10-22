# VoicePlus — Progress Log

## Environment / deviations
- 2026-08-23: No Xcode.app (CLT only, Swift 6.0.3). Build via SwiftPM; .app assembled by script; DMG via hdiutil; ad-hoc codesign, no notarization (no Developer ID identity). Unit/integration tests only (Swift Testing — see next line) — no Xcode UI tests.

- 2026-08-23 (P1.0): CLT has **no XCTest.framework** → all tests use **Swift Testing**. CLT also has stale leftovers (old `ManifestAPI/*.private.swiftinterface`, duplicate `usr/include/swift/module.modulemap`) that break every SwiftPM build; `Scripts/bootstrap-toolchain.sh` builds a cleaned user-local toolchain shim and `.claude/settings.json` exports `SWIFTPM_CUSTOM_LIBS_DIR`, `SWIFT_EXEC`, `SWIFT_EXEC_MANIFEST`. No sudo available to fix the CLT itself.
- 2026-08-23 (P1.0): Deps added via SwiftPM: GRDB.swift 7.8.0 (Shared), FluidAudio 0.15.6 (Engine; pulls a binary xcframework artifact → use `--disable-keychain` on first resolve).
- CI (`.github/workflows/ci.yml`) targets macos-14 + Xcode 16.2 and is unverified from this machine (no `gh` run possible offline); swiftlint step is conditional on the binary being present.

Entries before 2026-09-30 (Phases 1–6, Wave 0, V3 Spool parity) are archived in `docs/history/progress-2026-08-23_to_09-20.md`.

## 2026-09-30 — Presence chin hover target (pill hover area)
- Bug: the idle chin expanded to the "Hold or Double Tap fn / 🌐 to dictate" hint whenever the pointer came *near* the notch, and took the mouse over that whole band — a browser tab / window control under it could not be clicked or right-clicked.
- Cause: `PresenceGeometry.hoverRect` was the union of the 64 × 14 chin, the *narrowest hint row* (190 × 38) **and** the camera housing, inflated by 8 pt slop — a ~380 × 55 pt invisible target.
- Fix: the hover target is now the surface that is actually drawn — the chin at rest (state-correct size), the measured hint row once expanded — inflated by 2 pt. Housing union and the phantom hint-row reservation are gone; expand/collapse hysteresis is kept because the expanded row is fed back in as the target.
- Files: `App/Core/NotchPresenceGeometry.swift` (`hoverRect(on:size:)`, `hoverSlop` 8 → 2, `PresenceInteraction.isHovering(mouse:on:state:expandedRowWidth:)`), `App/UI/PresenceIndicatorController.swift` (hover test uses drawn surface), `DESIGN.md` §8.4, `Tests/AppTests/NotchPresenceTests.swift`.
- `swift build` clean; presence/pill focused gate **79 tests pass**; full suite rerun for the branch.
- Full suite on the change: **3,299 tests, 5 issues** — all wall-clock/real-hardware (`RefineStageTests` watchdog ×2, `RefinementSessionTests.deadlineIsHardAndReturnsPromptly`, `ASRGoldenTranscriptTests` latency, `VoiceSectionS7eTests` real-microphone). They ran while the 681 MB installer build saturated the machine; re-run idle with `--no-parallel` the same suites give **60/60 pass**. No presence/pill test is involved and the diff touches only presence geometry.
- Self-contained installer **1.12.10**, build **202609301106**: `Packaging/releases/VoicePlus_V3-Spool-Full_1.12.10.dmg`, 681 MB, SHA256 `1c61e8cd265c59b8e29fadfb1ae4a176364f95548259b5bce4a5faf49534966c` (740 MB app with bundled models). `FULL_INSTALLER=1 verify_install.sh` passes: bundled TDT/EOU/speaker inference from the read-only mount with an empty cache and no fetchers, clean-install launch, build-independent designated requirement, 9 TCC descriptions, no quarantine, owner-writable. DMG kept local and gitignored (>100 MB); public appcast/cask left unchanged, CHECKSUMS entry added.

## 2026-09-30 — Presence chin: green dot slid into the hint box (FX6)
- Bug: expanding the chin into the hover hint animated the 6 pt green dot toward the growing box's top-left corner before it faded (mid-transition screenshot from the owner).
- Cause: `PresenceIndicatorView.content` was one `if/else if/else` chain with no `.id()` and no explicit transition, under a container `.animation(..., value: hovered)`. SwiftUI structurally matched the single content child across the branch change, so it interpolated the dot leaf's **geometry** while the chin grew 64 × 14 → 360 × 38. The hint layout never contained the dot.
- Fix: new pure `PresenceContent` kind (`dot`/`levelBar`/`badge`/`hint`/`row`/`empty`) with `showsDot` + `identity`; `content` switches over it inside a `ZStack` with `.id(kind.identity)` and `.transition(.opacity)`, making the change an insert+remove that may only animate opacity. `identity` ignores the level payload so the level bar keeps one identity across ticks. Reduce Motion still instant (`motion.policy.transition` is nil).
- Files: `App/UI/PresenceIndicatorView.swift`, `Tests/AppTests/PresenceHoverTests.swift`.
- Tests: `theHintPresentationCarriesNoDot()`, `eachPresentationHasItsOwnViewIdentity()`. `swift build` clean; **64 Presence tests pass**. Mid-transition appearance on a real notched display still needs a manual hover check.

## 2026-09-30 — Auto-insertion, false "Couldn't confirm", and the Insert-now ribbon (V4.41)
- **Auto-insert never fired** (payload parked at "Ready for <app> · Insert now" though `preview.dwell = 900` = 600 ms auto): `TurnWiring.onPresent` applied `pauseDwell(.hover)`/`(.hiddenApp)` with **no matching resume**, and hover came from `PillViewModel.pointerInside` — a cached SwiftUI `onHover` flag that is never retracted when the panel flips `ignoresMouseEvents`, is ordered out, or moves out from under the pointer. One missed exit event stranded every later preview for the session. Fixed with a pure `TurnWiring.previewPauses(pointerInside:appHidden:)` (pause **or** resume, symmetric) plus a `pointerHitTest` seam re-derived from the real pointer on every render. Hardened afterwards: the hit test also accepts the pointer against the animation's **target** frame, so a mid-animation intermediate rectangle cannot resume a dwell the user is deliberately holding open.
- **False "Couldn't confirm insertion" after a successful insert**: `ElectronAdapter` (Claude, Slack, VS Code, Discord, Notion, Obsidian), `CursorAdapter` and `FigmaAdapter` never overrode `verifyReadback`, so they used `Readback.byValue` — and Claude's ProseMirror composer exposes no/stale `AXValue`. Landed text read back as `unconfirmed`/`unavailable` → `verified:false` → D06 every time. New shared `Readback.byValueOrCaret` (the fix browsers already had).
- **No ribbon on "Insert now"**: `TapeFlightController` armed its pre-insertion sample once, at preview time; a preview held for seconds inserted against a stale caret/`elementToken` → `.targetChanged` → suppressed. Now re-armed every 0.25 s while the preview is up, cancelled on `.inserting`. Bug 2 also killed it independently via `invalidate(.unconfirmed)`.
- **"It suddenly started working"**: the running process was `/Volumes/VoicePlus 1.12.10/VoicePlus.app`, not the installed copy. TCC keys grants by designated requirement, which for ad-hoc signatures pins this binary's cdhash (`AppCodeIdentity.pinsThisBuild`), so the DMG copy can be untrusted while the switch looks on; `AXIsProcessTrusted()` is re-read on `com.apple.accessibility.api` (82–213 ms), so a mid-session grant takes effect with no restart. The app detected only `/AppTranslocation/`, never `/Volumes/` — now reported in the permission report with a `fault` line when the DMG copy runs while `/Applications` exists.
- **Check destination after success**: false negative from bug 2, fixed at the verdict — the surface itself is correct for an unconfirmed write. **Sticky until the next hotkey**: correct by spec (DESIGN.md:52 and :468 "error and held notices stay until the user acts (no timed dismissal)"; design_v3 D06 lifetime = unconfirmed hold). Left unchanged.
- Files: `Injection/AppAdapter.swift`, `App/Services/TurnController.swift`, `App/UI/PillView.swift`, `App/UI/PillPanelController.swift`, `App/Overlay/TapeFlightController.swift`, `App/Core/PermissionMatrix.swift`, `App/Services/PermissionService.swift`.
- Tests: `Tests/InjectionTests/ClaudeDesktopAdapterTests.swift` (+3), `Tests/AppTests/TapeFlightTests.swift` (+2), new `Tests/AppTests/PreviewDwellPauseTests.swift` (6). **Full suite 3,311 passed** (`swift test --no-parallel`, 528.401 s), no flakes.
- Untested without real hardware: TCC identity for the installed copy, real dictation into Claude/Slack/VS Code ending in "✓ Inserted", auto-insert with the pointer parked near the notch, and the ribbon on a late Insert now.
- Self-contained installer **1.12.11**: `Packaging/releases/VoicePlus_V3-Spool-Full_1.12.11.dmg`, 681 MB, SHA256 `543912bb9133b3a752797f6042a4d3daeef082979307e9df402976c451293ff2`. `FULL_INSTALLER=1 verify_install.sh` OK (bundled TDT/EOU/speaker inference from the read-only mount, empty cache, no fetchers; clean-install launch, build-independent designated requirement, 9 TCC descriptions, no quarantine, owner-writable). Carries both the dot cross-fade and the auto-insertion fixes. DMG kept local + gitignored; public appcast/cask unchanged; CHECKSUMS entry added.
- Open for the owner: the running process is still the **disk-image copy** (`/Volumes/VoicePlus 1.12.10`), whose Accessibility trust is separate from `/Applications`. Evaluate 1.12.11 from `/Applications` after granting Accessibility to that copy, or the AX confound remains.

## 2026-10-01 — Capture: "Listening · quiet" forever, and the hotkey that showed no surface
- **Bug A — "Listening · quiet" with no audio, intermittent then sticky.** (1) **Digital-silence blindness:** `AudioPipeline.noteAudioArrived()` set `sawAudio` on *any* buffer, so a single all-zero block cancelled the only watchdog; a TCC-silenced, hardware-muted or detached input delivers bit-exact zeros at full rate → `rms 0` → no VAD edge → `listeningQuiet` with no exit (only speech clears it). (2) `PipelineAudioSource.onCaptureFailure` was fired but only ever **assigned** by the self-test/onboarding — on the dictation path a capture failure was a log line. (3) **No `AVAudioEngineConfigurationChange` observer** and warm resume reinstalls nothing; `AudioDeviceMonitor` watched only default-device/device-list changes, so a same-device rate change or wake killed the tap and every later press resumed the dead graph until the 600 s idle release — the intermittent-then-persistent pattern. (4) A denied mic reported A01 "No microphone found", and nothing called `requestAccess`, so `.notDetermined` was a dead end.
- Fix: pure `CaptureSilenceWatchdog` (fires on ~3 s of bit-exact zeros, **disarms permanently on the first non-zero sample** — so it can only fire on a capture where no audio ever arrived, never mid-dictation or during a long pause); configuration-change observer rebuilds the graph; P01 "Microphone access is off" + one-shot `requestAccess`; A05 "No audio is reaching VoicePlus".
- **Latch exit bug found on the way:** a silent latched turn called `cancel()`, which deliberately does not leave latch — turn failed with A05 but the pill stayed in latch dress bound to a dead pipeline. Now `endLatch()`.
- **Regression caught and resolved:** `LatchEndpointLoopTests.elapsedFollowsThePipeline` fed `S.silence` (bit-exact zeros — the signature of a *dead* mic) while modelling a user not speaking. Added `roomTone(_:)` (±1 LSB, never zero, 300× under the VAD threshold); `S.silence` stays exact-zero; all 10 other call sites checked and safe. Did NOT scope the watchdog off during latch — that would reinstate the original bug where it hurts most. Tightened `quietRoomNeverFires` to push a continuous 10 s noise floor (it previously passed via the disarm latch alone).
- **Bug B — fn hid the chin and showed no pill.** (1) Chin suppression driven by *intent*: `TurnController` presents `.starting` before capture, and the chin read `pill.$state.isVisible` while `PillPanelController` separately decided placement → any placement failure = chin off + no pill, both back on key-up. Now suppression requires a pill genuinely on screen (`surfaceOnScreen`). (2) **Sticky wedge:** `render`'s `defer { lastSurface = surface }` also ran on the no-host-display early return (sleep/lock/display switch), recording a *visible* surface with nothing ordered in; thereafter `render` only took the already-visible branch and never called `orderFrontRegardless()` again. Explicit `lastSurface`, `.hidden` on both no-placement paths. (3) Same wedge in the screen-parameter observer. (4) `captureFailed` retracted `.starting` with nothing in its place → now surfaces A03 / mapped recovery. Dead-tap detection already existed (`blocked(.relaunchNeeded)`); it was hidden by the phantom pill.
- **Correction to the 2026-09-30 note:** the disk-image/TCC hypothesis is **refuted** — `/Applications` and the `/Volumes` copy had the identical CDHash, so the microphone grant applied to both. Moving to `/Applications` was hygiene, not a fix.
- Pre-existing, not ours: an intermittent `SIGSEGV` in `Qwen3RefinementWERTests` faults inside CoreML/MPSGraph (`MLE5ProgramLibrary.lazyInitQueue`) with no frames of ours; files in the chain byte-identical to HEAD; did not reproduce in 4 clean baseline runs. Likely trigger: `Refinement.withDeadline` cancels only per generated token, so a timeout can fire mid-prediction. **Not fixed — out of scope.**
- Process: two agents ran tree-wide `git stash`/`restore` in the shared checkout, destroying each other's uncommitted edits; both recovered and the combined tree was re-verified. Future agents are forbidden tree-wide git mutations.
- Tests: `CaptureSilenceTests` (13), `CaptureSilentTurnTests` + `CaptureSilentLatchTests`, `HotkeyNoSurfaceTests` (10). **Full suite 3,345 passed** (`--no-parallel`, 493 s). Caveat: that run began when a parallel worktree had pushed free disk to 1.5 GB and the bootstrap printed its low-space refusal; it still compiled and passed (truncation fails to link or crashes, it does not false-pass).
- Untestable here: real zero-filled buffers from a silenced mic, `AVAudioEngineConfigurationChange` firing for real route changes (AirPods, sleep/wake), the A05/P01 surfaces appearing, and the fn key never leaving no surface.
- Self-contained installer **1.12.12**: `Packaging/releases/VoicePlus_V3-Spool-Full_1.12.12.dmg`, 681 MB, SHA256 `c7d6d51e40e1a9c21e35e5c15b3226b1d97271cf7320b0dbcb355d2900b759d8`. Built with 16 GB free (session scratch caches reclaimed first). `FULL_INSTALLER=1 verify_install.sh` OK incl. bundled TDT/EOU/speaker inference from the read-only mount, empty cache, no fetchers. Installed to `/Applications` and launched (owner-approved switch off the disk-image copy on 2026-10-01; all stale volumes ejected). DMG local + gitignored; public appcast/cask unchanged.

## 2026-10-01 — Investigation only: insertion, invisible pill, permission relaunch (no code changed)
- Full write-up and fix plan: `VoicePlus_Investigation_2026-10-01.md`.
- Insertion: Claude/Electron fields are invisible to AX (repo never sets `AXManualAccessibility`) → every verdict "readback unavailable" → sticky D06; readback also runs before keystrokes land. `dbe9393` passed only because its mock exposed a caret real Claude doesn't.
- Invisible-but-working pill: unconfirmed chains never pass through hidden, so the pill never re-chooses its display; likely pinned to an AirPlay TV after a 09:44–09:46 reconnect. "On screen" never checks which screen.
- Safety: dictated `\n` is typed as Return in Electron apps and sends the message.
- Quit-and-reopen is macOS's own sheet (Microphone/Input Monitoring/Screen Recording/Camera); VoicePlus's fault is trusting the cached mic status, so "Later" can't work.
- Corrections: the 2026-09-30 cdhash-pinning explanation was wrong (designated requirement is identifier-based since 1.6.4).

## 2026-10-01 — V5 W0+W1+W2
- **Floor:** minimum macOS is now 15.0 (J7): Package.swift `.macOS("15.0")` (tools 5.9), LSMinimumSystemVersion 15.0, CLAUDE.md.
- **New deps:** FluidAudio → FluidInference/FluidAudio@c388107 (Apache-2.0; replaces altic-dev fork, which lacks ultra/redux/LocalVqe); FluidUse@c9e967f (Apache-2.0) linked into Engine + Actions; transitive NemoTextProcessing.xcframework (~87 MB). Eval audio: LibriSpeech test-clean (~435 MB, gitignored, App Support/VoicePlus/Eval).
- J7 · done · floor 15 + Qwen3 guards removed · build clean
- J6 · done · deps above · FluidDependencySmokeTests (Laya/KevFast/LocalVqe, no download)
- J3 · done · .build-baseline/.build-release removed
- A2, X18 · done · comment fixes
- X19 · done · unreferenced types deleted (ZeroEditMenuView kept; SNREstimate/DeterministicActionLayer moved to tests)
- K20 · done · wire value "latched", reads "handsFree" one release · WakeVerb/OneMenu tests
- K22 · done · tags release/phase-V4-w1/v1.11.0 (19c22ea), v1.12.12 (ba26f5b)
- Q16 · blocked · owner runs lsregister -u "/Volumes/VoicePlus 1.12.10/VoicePlus.app" && lsregister -gc
- Q1 · done · ⇧↩ (Electron/Cursor/Chromium), ⌥↩ in Sheets, SubmitPolicy · NewlineSafetyTests
- Q2 · done · AXManualAccessibility / AXEnhancedUserInterface at key-down, per-pid cache · mock order tests
- Q3 · done · ReadbackSettler (AXObserver else 30 ms polls ≤ 400 ms), settle ms on commit report
- K18 · done · AXGuard for all AX roots + source audit
- Q4 · done · LandingVerdict .unreadable → neutral "Inserted in <app>"; sticky only .unconfirmed; DESIGN D06
- Q5 · done · caret ladder (range → text marker → element → window); flight hold fix in PillView
- Q6/Q7/Q8/Q9/Q12 · done · display chooser, per-display on-screen, self-healing pauses, canHide=false, pause copy
- K19 · partial · retention backstop (release + 1.5 s, fault log) + pill order events into TurnDiagnostics. 27 s not reproduced (needs live app). **Cause hypothesis:** a timed row reached the pill without a live retraction timer (bypassed scheduleRetractionIfTimed, or its timer replaced before firing); confirm from TurnDiagnostics after a hardware run.
- Settings rows · done · General › Insertion: "Expose text in Chromium browsers" (on), "Confirm in apps that hide their text" (off)
- Q10/Q11 · done · live mic probe + capture trial; IM tap re-create + "Listening again" · 117 permission tests
- Q13 · partial · turn_diagnostics store, 7-day sweep, no-text audit, Privacy › Diagnostics export · only pill events recorded; landing (K) and decision (O3) record() calls pending
- Q15 · done · deadline returns without cancelling prediction; RefinementInFlight drain; Qwen3CoreMLGate serialises load/predict
- J1 · done · relative deadlines, hardware-gated real-Qwen suites (VOICEPLUS_HARDWARE_TESTS), starvation-tolerant waits
- V1 · done · Lab harness/normaliser/metrics/fetchers; TDT v3 test-clean 2.08 % vs 1.93 % published (Δ +0.15, within ±0.3)
- V2 · done · baselines.json + --gate · V3 · done · NoiseMixer (babble/pink/white; MUSAN not fetched, 11 GB)
- V4 · partial · previewBackend kept off (WER better, p95 2.1 s fails), mic bounds kept (estimator blind to babble → K6/C6), segment classes no change; qwenRefinement not measured (weights absent)
- B4 · done · Lab/results/error-pairs/*.jsonl
- A3 · partial · verdict + kill criterion per X20 flag; per-flag V1 measurement pending (disk/datasets)
- H2 · done · 200-utt confusion matrix, route threshold 0.6 → 0.9 (acc 0.985; same-set tuned, re-check on V1)
- K21 · done · refinement row copy, Ready only when weights size-verified (Engine prepare should also verify)
- **Full suite** (`--no-parallel`, .build-v5a): 3478 passed, 0 failed, 447.5 s; real-Qwen suites skipped (hardware-gated). No gate fixes needed.
- **Needs hardware (T1):** Q1 two paragraphs into Claude; Q2 Claude caret; Q4/Q5 live AX rungs + unreadable field; Q6/Q7 two displays; Q8 Tab/VoiceOver; Q9 Hide Others; Q10 real TCC/mic; Q11 real tap; Q13 save panel; K19 repro; K21 row look; MUSAN/Svarah/Qwen3 weights (disk ~13 GB free).

## 2026-10-01 — V5 W3+W4
- C6 (+K17) · done · Silero VAD in the stack, bundled + verify_install, ModelManager.locate, loads via ModelResidency (1c45812, dd46e18) · K17 in-process fixture, mic gate on Silero + Energy
- D1+K7 · done · ITNStage (NeMo single-token currency/decimal/percent only, en-IN lakh/₹/day-first, 250 ms digit rule, AM/PM), preview == final via ITNWiring (d85c72b) · 62 targeted; LibriSpeech numeric 2.13 → 2.29 % (< 0.5 pp gate); gate fix: may/march as words
- HW1 · partial · ModelResidency actor in Shared (tiers, LRU, exclusive refusal, 5 min idle) + ASR/EOU/CTC/Silero registered (35b94b7) · 37 tests; D2/O4/CU2/M7/LR must register when built
- HW3 · partial · memory-pressure source, critical → lighter alternative · tests vs mocks; pill chip hookup (lane 1b) pending
- B2+E1 · done · ContextPromptSession → extra[context.prompt]; 2k doc tail (eb1debd) · 13 + 27 tests
- E2 / E3 / E4 · done · spreadsheetCell role + column header; web-form label hints, email/url compaction, password refusal; AppCategoryTable 38 → 108 (f92fe05, 5f61420) · 158 tests
- P1/P2/P3/P5 · done · Text Replacements, local names, 13.5k casing list (Wikidata CC0 + casks), likely-entity guard; P4 partial (phoneme path unused by ContextGate), P6 partial (rule-based, IndicXlit not converted), P7 partial (GLiNER2 weights absent; load bypasses ModelResidency) (265d4ed, 936c6e9)
- F1 / F4 / I1 / I2 · done · persona learning loop, personas in sync, What-to-expect card, zero-edit counter (40e102a, 473ce47, ad34bbb, f4c1b81) · 113/113 batch
- F2 · partial · personal.dictionary/personal.style + promptBlock (a91f4e3, c13c1e4); no reader until D2/CU8
- **Uncommitted in the working tree, no lane report** (left for lane/owner to review + commit): C1/C1b (VP-IO + LocalVQE capture enhancement), B1 (CTC boosting; old shallow-fusion biasers deleted), HW2 (ResidencyPlan, memory tier settings), D5 (ModelPrewarmer), E5/E6/K10/Q14 (browser sub-app, thread participants, context ladder, OCR caret band). Gate routed their AX roots through AXGuard in place (uncommitted).
- **B1 fixture gate fails:** recall 0.46 → 0.85, WER 10.96 → 5.42 %, but false insertions +0.93 pp > 0.5 ("stores" → "Postgres"); higher rescue similarity floor / rescue off did not change it — needs the lane.
- Not started: lane 4a (D2, D3, D4, I3), C3, C4, C5, K2, K4, K6, F3, B3, B5.
- Gate fixes (815241f): Chaos/OnboardingDictation expect Silero in the stack; FieldContextReader AX root via AXGuard (K18 audit); D1 month capitalisation fix completed.
- New deps/downloads: none new (NeMo ships with FluidAudio; parakeet-ctc-110m ~103 MB on disk for B1 live test; GLiNER2/IndicXlit/CMUdict full/LibriSpeech-PC not fetched).
- **Full suite** (`--no-parallel`, .build-v5a, working tree incl. uncommitted lanes): 3712/3713 passed, 478 s; sole failure B1 live gate. First run also showed AudioSourceOwnershipTests flake (passes alone and in rerun).
- **Needs hardware (T1):** real Excel/Numbers/Sheets cells + column header, Chrome/Safari form labels, Electron context (Claude/Slack/VS Code), live Text Replacements, EventKit names, GLiNER2 typing, CoreML memory/pressure events, VP-IO/LocalVQE V1 gate, ITN pill vs landed, fresh-install "vad: using silero".

## 2026-10-01 — V5 W3+W4 (completion)
- C1 · partial · VP-IO source + Settings › Voice "Noise and echo reduction" (Off/Apple/LocalVQE), AGC log, 300 ms warm-up (1430e93) · CaptureEnhancement tests; default Off until V1 VOiCES+MUSAN (live VP → T1)
- C1b · partial · LocalVQEStage + on-demand catalog, via ModelResidency .always (1430e93, 5c8cd74) · LocalVQEStage tests; weights not downloaded, no far-end reference
- C3 · done · narrowband SCO chip + Settings link (a3382a7) · NarrowbandInputNotice/Chip tests
- C4 · partial · SmartTurn consulted after ≥ 400 ms silence, inert without model (04bd22b) · synthetic endpoint tests; no CoreML export (upstream ONNX) → owner converts
- C5 · partial · .parakeetEOU320 on demand, 160 kept as default (9c3b55c) · V1 preview-WER gate not run
- K2 · done · NearFieldGate 12 dB turn-relative (870e2c2) · synthetic two-level tests
- K4 · done · turn-anchored WeSpeaker voice, 500 ms anchor, bar → 0.6 (69a70a9) · fixture tests
- K6 · done · mic-quality floor ignores first 100 ms, ≥ 200 ms pre-speech (0bf31a4)
- F3 · done · all dictation audio + sidecar, retention 30 d / 2 GB LRU, never synced, secure-field turn discarded (1bb3b61, 9345576)
- B1 · partial · two-manager CTC boosting, BoostGuard, biasers deleted, CTC via ModelResidency (2c33176, 10d12b7) · fixture gate passes: recall 0.46→0.85, FI 0.00 %, WER 10.96→4.17 %, +~400 ms/utt; Earnings-22/MUSAN gate → T1
- B5 · partial · Parakeet Ultra/Redux on demand, provisional ranking, NOTICE (cf9c40e) · default v3; Redux 8.06 vs v3 12.67 WER on test-clean-noisy, Redux ANE compile fails here (p50 199 vs 117 ms)
- B3 · done · real top-K=4 alternates with logProbs (b4efd70) · NBestAlternates + live v3 (14/32 spans); replay cost ~330 ms here (claimed 60) → T1
- HW2 · done · MemoryClass/ResidencyPlan, Settings › Models tier override (d82c820) · 11 tests; gated features register later
- D5 · done · prewarm on hotkey-down via ModelResidency, HW1 idle unload (e2e4ee3) · 7 tests; live now that D2 registers cleanup.llm; no timeout guard on a hung loader
- D2 · partial · llama.cpp b11321 XCFramework + LlamaCppProvider + GGUF catalog + CleanupStage + Settings › AI cleanup (441405e, a5412e3) · 75 cleanup tests; evaluate-first and V1 cleanup gate not run, model pick provisional
- D3 · done · CleanupGuard all rules, word-boundary anchors (01e1577, a5412e3)
- D4 · done · delimited template + sanitizer, red-team corpus (082df2e); deviation: transcript normalised, not directive-stripped
- I3 · done · "Why did it write that?" — 20-turn in-memory trace + sheet (7e39a70) · 12 tests; sheet UI manual
- E5 / E6 / K10 · done · browser sub-app routing, thread participants, context ladder (eee53d8, b769d6f, 9bb741b) · 138 lane tests
- Q14 · done · OCR caret band (9bb741b); gate fix 60c877a binds it to W1's "Confirm in apps that hide their text" row (was an orphan key)
- P1–P7 · partial · gate committed lane 4c leftovers (e4f4033): ContextGate phoneme path (P4), GLiNER2 via ModelResidency (P7), TransliterationStage registered (P6), attendee cache, Text Replacements global-domain read · P6 rule-based only (IndicXlit not converted)
- F2 · done · personal.* now read by D2 CleanupPrompt; CU8 later
- **New deps/downloads:** llama.cpp b11321 XCFramework (MIT, SwiftPM binary target, NOTICE in Packaging/llama). On-demand models (not bundled, not downloaded here unless noted): LocalVQE ~50 MB (Apache-2.0), parakeet-ctc-110m ~103 MB (on disk), Parakeet Ultra 632 MB / Redux 220 MB (CC-BY-4.0), EOU 320 ms, cleanup GGUF ~500 MB (SpeakoFlow Mini Q4_K_M), Smart Turn (BSD-2, needs CoreML conversion).
- **Full suite** (`--no-parallel`, .build-v5a): 3860 passed, 0 failed, 515 s (real-Qwen + real-GGUF suites skipped, hardware-gated).
- **Needs hardware/data (T1):** VP-IO/LocalVQE V1 gate (VOiCES, MUSAN), live AGC; SCO headset; Smart Turn CoreML; EOU 320 preview-WER; B1 Earnings-22 + MUSAN; B5 LibriSpeech-other/FLEURS-en-IN; B3 replay latency; D2 model eval + p95 ≤ 500 ms on M2 Pro; 8/24 GB first launch; browsers' AXURL/AXTitle; Mail/Slack participants; Screen Recording caret band in Docs/Figma; real two-speaker room (K4).

## 2026-10-02 — V5 W5+W6+W7
- O1 · done · one capture graph: Broadcaster subscriptions, meeting/ambient recorders, SharedMicrophoneSource into DualCapture (b466986) · SharedCaptureGraph 9 tests; open: AppDelegate never calls start/stop(.meeting) so lock/sleep don't stand a meeting down; VoiceTestCapture/LiveOnboarding/MicSelfTest still build their own CoreAudioCaptureSource (§10)
- O2 · done · UtteranceOwner/UtteranceTag recorders (d55bd02, b6a6ff1), late-tag-after-merge fix (02ff36e) · UtteranceTagRecorder 6 tests
- O3 · done · UtteranceDecision + UtteranceDecisionHub, Q13 .decision rows, recorder fan-out (30179c2) · 7 tests; arbiter now settles .arbiter (11dc129)
- O4+O5+L4 · done · IntentArbiter L0/L1/bands/L2, Kev/Intern/Laya via ModelResidency (11dc129); O5 context + band nudges (deea5b5) · mock-model tests; ≥ 90 % owner (Kev) + AMI ignore ≥ 95 % → T1
- L1 / L2 / L3 · done · AmbientMode off/note/act (e95621b, code in 485a7b5); V3 §8 + DESIGN amended, AmbientGuaranteesTests replace the never-inject audits (efdbfa2); ambient listener is a recorder on O1, per-segment ASR + SpeakerGate, X13 removed (2f25757)
- L5 · done · AmbientPowerPolicy + Lab CPUProbe (1928d00); offline M2 Pro: 0.11 % idle / 1.99 % speech; live in-app → T1
- L6 · partial · 150 scripted command lines + decide-set builder + arbiter eval backends (a1ee730); AMI/NOTSOFAR (~100 GB) not fetched
- K3 · done · 'Only react to my voice' (bb041a5)
- N1 / N3 / N4 · done · Notes section, pill chip + menu row, NotesStore with legacy Ambient fold + retention (9bc301b, 4dd0c42) · NotesStore/NotesSection tests
- N2 · partial · wake verb 'note …' stored via NotesRouter (be02b49) + ambient band / Listen & note wired; no-field, app switch, latch-in-meeting, agent-running and K4 routeToNotes decided but not called from live speech
- M1–M4 + M5 · done · meeting modes, hybrid echo veto, auto-pick, per-leg WAV recorder, Always/7 days/Never, shared F3 cap (7f8a95d)
- M14 · done · panel tag chips + 'Show my dictations' (e45cb63, fix beec3b9)
- M12 / M6 / M7 / M8 / M10 / M13 · done · embedding labeler wired (485a7b5, fix 2bfb70d), passive voiceprint (0ea0634), Sortformer live labels, 4 speakers/stream (a4ccccc), final re-diarization (9c333ea), VoiceprintStore (c42735b), descriptive labels (7dbcaef)
- M9 · partial · CAM++ backend + choice logic (4f1174c); DER not measured, default WeSpeaker; FunASR licence to verify
- M11 · partial · calendar / AX active speaker / transcript names → suggestions (cb094c2); OCR fallback and LR1 lips source not wired
- M-d · done · mic-elsewhere / call-app / browser-tab signals, Settings › Meetings, post-meeting hook (028fb08, 4888c63); fixes 88c603c · 76 tests; open: MeetingAutoExporter overlaps MeetingMarkdownExport; don't-notify list offers 6 of 11 browsers
- M17 / M16+M21 / M18+M20 / M19 / M22 / M23 · done · LLM notes + templates, Ask live/after (NLEmbedding deviation), named transcript + export, ask across meetings, provider picker, MCP server off by default (028fb08, d24a8b7, abf4a7d, 333344c, fd92f9a, 9e652b3)
- CU1 / CU8 / CU4 / CU9 / CU6 / CU7 / H4 · done · Computer use page (6e9905f); Qwen3.5-2B/4B GGUF shared local model for act.planner + meeting/style/N5/I3, JSON StepPlan with repair (4b4765c); catalogue retrieval (2214ab0); one 4B at a time (1748c9e); CU6 exact 99.78 % / paraphrased 92.42 %; ambient act (f6f941f); time-aligned deixis (221131f)
- CU2 · partial · CuaS1Chooser + forms chooser (4fc1c74); FluidUse pin lacks CuaS1FourBManager → UnavailableCuaS1Backend; real-model 80 % fixture → T1
- LANG1 · partial · Languages onboarding step + consumers (27670ec); cleanup-model switch, per-language P-series, per-app language memory, Settings › Languages page missing
- LANG2 / G2 / G3 · done · PillScriptMenu + ScriptOutputStage; Nemotron multilingual recognizer + preview via ModelResidency (82afb9e); script policy (71d64f8, fix cbfdc30)
- G1 · partial · Hinglish catalog/recognizer/routing/recipes (82afb9e); Srota CoreML conversion + MUCS/HiACC comparison not run → owner; 'shipped = .srota' placeholder
- LR1 / LR3 / LR5 · done · FaceSignals + camera row (21c1404, yaw fix 3cdd85d), lips-only engine (977f008), camera privacy (239bec9)
- LR2 · partial · AVSRRecognizer + recipe tools/avsr + NOTICE (7019f93); Auto-AVSR not converted, LR6 eval needs owner data
- K5 · done · 'Mic Modes…' row (40c8d33)
- K8 · partial · ProsodyPunctuationStage phases 1+2, flag off (a364f10); LibriSpeech-PC gate + engine audio → ProsodyCues wiring pending
- **New deps/downloads:** none new SwiftPM deps. New on-demand catalog entries (not downloaded here): Nemotron-3.5 multilingual 664 MB (OpenMDW-1.1), Qwen3-ASR Hinglish ~1.29 GB int8 (Apache-2.0, unpublished), Sortformer 255 MB, CAM++ 16.6 MB (licence to verify), Qwen3.5-2B/4B Q4_K_M GGUF (Apache-2.0), CUA-S1 4B ~4.0 GB + forms, Auto-AVSR (non-commercial, NOTICE). Disk ~7 GB free during lanes blocked conversions.
- **Full suite:** `--no-parallel`, .build-v5a: first run 4344 tests, 7 issues in 4 tests (719 s); gate fixes a4fca5a (AXGuard root in ActiveSpeakerAX; meeting weight boxes per ModelResidency; withDeadline cancelled-timer race; AudioPipeline.drain ordering); rerun 4344 passed, 0 failed, 636 s (hardware/dataset suites skipped).
- **Needs hardware/owner (T1):** live meeting + dictation on one graph; arbiter accuracy with Kev; ambient CPU in-app; Notes UI + Insert here; CoreAudio/AX/EventKit detection; Sortformer/CAM++/voiceprints on real meetings; real planner + CUA-S1 runs; Hinglish/Nemotron/AVSR models; IndicXlit; camera signals; AirPods mic modes.

## 2026-10-02 — V5 W8 + follow-ups
- Q13 · done · landing/decision/pause-resume events recorded (df2cbbf); verify fix: pause/resume carry the pill frame via PillPanelController provider (156c057) · TurnEventDiagnosticsQ13Tests, TurnDiagnosticsQ13Tests pass
- HW3 · done · LighterModelsChip wired via TurnWiring to ModelResidency lighter-mode observer (5cffc02, df2cbbf) · LighterModelsChipHW3Tests 3
- D5 · done · prewarm time-boxed 30 s (ecced4d); verify fix: timeout ends the pass instead of re-joining the stuck load (9883bb2) · ModelPrewarmerTests 9; ModelResidency still cannot cancel a stuck load
- M-d · done · one Markdown renderer for auto-export + hook payload, single 11-browser list for Don't-notify (c6b4d39) · MeetingExportOneRendererTests, MeetingsDontNotifyBrowsersTests
- K21 · done · Qwen3 Backend.prepare calls store.verify before load (0bc07a5) · Qwen3PrepareVerifyK21Tests
- O1 · done · MeetingSessionWiring start/stop(.meeting), voice test/onboarding meter/MicSelfTest on the shared graph (e7e471c) · MeetingSessionWiringTests, VoiceTestSharedGraphTests; --mic-selftest uses makeStandalone (own process)
- N2 · done · all 8 Notes routes live via UtteranceLander.notesClaim + LatchRuntime.notesRoute (d126fcb) · NotesLiveRoutesTests 11; app-switch/other-voice notes not O3-logged
- LANG1 · done · multilingual cleanup route, SCOWL per-language lists, per-app language memory, frontmost-app ASR routing, Settings › Languages (ce9d26f) · LanguageFollowUpTests; Qwen3AsrLanguageHint has no live consumer until refinement is wired (R5.2)
- T1 · done · VoicePlus_HumanTest.md: 470 cases + 26 owner actions (0c1b495) · structural check script; build-doc "DESIGN.md §10" recovery ref should read §7
- J5 · partial · AppcastUpdater (feed, channel, min-OS, delta/full, sha256, hdiutil + codesign check, swap + rollback), Settings › Updates, release.sh sha256 (92484fd) · AppcastUpdaterJ5Tests 24; feed host updates.adityakatare.in not live, no delta DMG produced, ad-hoc signing → TCC re-grant per update
- J2 · partial · workflow_dispatch ci.yml + Scripts/ci-test.sh (f9e5ca3) · CIWorkflowJ2Tests 5; never run on GitHub (owner: account restriction or self-hosted runner)
- J4 · blocked · owner: Developer ID cert + `notarytool store-credentials`; then make_app `--timestamp`, release.sh notarize + staple before shasum, drop disable-library-validation
- I4 · done · EgressReview + NoTelemetryAuditI4Tests (1dd59f3) · 8 tests; EgressGate is allow-all + kill switch, list enforced at source level
- **New deps/downloads:** none.
- **Full suite:** `--no-parallel`, .build-v5a: 4434 tests passed, 0 failed, 688 s (11:45 wall). No gate fixes needed.
- **Needs hardware/owner (T1):** real AX landings + pill frames; kernel memory pressure; llama.cpp prewarm latency; one HAL client + mic indicator, lock/sleep in meeting; Notes routes in live apps; multilingual cleanup quality/latency, SCOWL GBs download; end-to-end update (host appcast, Developer ID); CI run on GitHub; the 26 OA owner actions in VoicePlus_HumanTest.md.

## 2026-10-02 — V5 final installer 1.13.0
- Self-contained installer **1.13.0**: `Packaging/releases/VoicePlus_V5-Full_1.13.0.dmg`, 693 MB (726,797,928 bytes), SHA256 `2158e515d71eb485668038c4b423b1540ebe6fcdedddfb917f477d2f34fe4ea3`. Built with `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=~/Library/Application Support/VoicePlus/Models Packaging/release.sh V5-Full 1.13.0 --no-github` (release build in `.build-release`, 491 s; `.build-v5a` reclaimed first, 20 GB free).
- Bundled: TDT v3 + EOU 160 ms + speaker (SHA256-verified from the local cache) + Silero VAD (V5 C6, checked in); llama.framework (V5 D2, universal) embedded and ad-hoc signed. 110M CTC, Qwen/LLM weights and other large models stay on-demand downloads.
- Release fix: the self-containment audit in `make_app.sh` (and the same check in `verify_install.sh`) read `otool -L` with `NR>1`, so the universal llama.framework's second `(architecture arm64):` header line was reported as a non-portable dependency and the build aborted. Now only tab-indented dependency lines are read.
- `FULL_INSTALLER=1 verify_install.sh` **OK**: bundled TDT/EOU/speaker/Silero inference from the read-only mount (empty cache, no fetchers); version 1.13.0; LSMinimumSystemVersion 15.0; 9 TCC usage strings incl. camera; build-independent designated requirement; self-contained; owner-writable; no quarantine; headless launch of its own temp copy, stopped by pid only.
- Not installed to `/Applications`, user's running copy untouched. DMG local + gitignored; CHECKSUMS entry added; public appcast/cask unchanged (release.sh edits reverted). Tag `release/V5/v1.13.0`.
- Not verified: notarization/Developer ID (J4, owner), Gatekeeper first-open on a clean Mac, in-app update to 1.13.0 (feed host not live), real dictation with this build.

## 2026-10-02 — Fixes N1–N28 build
- N1 done (Contacts out of boost/spell/cleanup + repair alternates; replay 0 swaps) · N2 done · N3 done · N4 done · N5 done · N6 done (CTC resident at launch, 1.5 s deadline, stage ms in turn_records) · N7 done (snapshot + lease, AX deadlines)
- N8 done (no dwell, pull-back) · N9 done (resolver live everywhere) · N10 done · N11 done (rubric + learned weights; screen terms gated off) · N12 done · N13 done · N14 done (rubric in live prompt)
- N15–N27 done (see Investigation "Build status") · N28 partial (offered-vs-landed learning live; correction-based learning not wired)
- Tools: T-replay, T-probe, T-schema done.
- Gate 99378d9: AXGuard in pull-back, Contacts out of repair alternates, stale bundle test, mock torn-read crash fixed.
- **Full suite:** `--no-parallel`, .build-v6a: 4799 passed, 0 failed, 455 s.
- **Replay:** 41 recordings, 0 swaps, no Contacts in any channel. Open: "one, two, three." → "123  ".
- **New deps:** none.
- **Needs live test (S0–S2, deferred):** AX probe in real apps, ribbon in Claude/x.com/Docs, OCR rung (Screen Recording), pull-back across apps, shell process trees, rich paste in Sheets, Figma hold, clipboard managers honouring markers, first-launch CTC compile time + ~100 MB memory, FULL_INSTALLER DMG with CTC model.

## 2026-10-02 — N-fixes final installer 1.14.0
- `Packaging/releases/VoicePlus_N-fixes_1.14.0.dmg`, 779 MB (817,064,671 bytes), SHA256 `c398e91cf42871f2a8af633efe5cb90f391cfc07f94ca4e24d636f708c575bc8`. `FULL_INSTALLER=1 Packaging/release.sh N-fixes 1.14.0 --no-github`.
- Bundled: TDT v3 + EOU 160 ms + speaker (re-hashed from the 1.13.0 DMG; local cache now holds only CTC) + N6 CTC 110M boosting model (98 MB, `--require-boost`) + Silero VAD + llama.framework.
- `verify_install.sh` now fails a full installer lacking the N6 CTC model. `FULL_INSTALLER=1 verify_install.sh` **OK** (TDT/EOU/speaker/Silero inference from read-only mount, CTC present, 1.14.0, 9 TCC strings, self-contained, headless launch of temp copy).
- Not installed to /Applications; running app untouched; appcast/cask/notes reverted. Tag `release/N-fixes/v1.14.0`.
- Not verified: CTC inference in the bundle self-test (presence only), first-launch CTC compile time, notarization/Gatekeeper on a clean Mac, real dictation with this build.

## 2026-10-03 — H-fixes final installer 1.15.1 (supersedes 1.15.0)
- `Packaging/releases/VoicePlus_H-fixes_1.15.1.dmg`, 778 MB (816,532,836 bytes), SHA256 `8a4b1532545a76844e3d38e4eadc1b51565229a464c1bdbcebb7c9f0478d9a69`. `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=<1.14.0 DMG Models, read-only mount> Packaging/release.sh H-fixes 1.15.1 --no-github`.
- Built from a clean tree at b72c250 (includes gate commits 5c89231, 257f12c, 0af1e28), so tag `release/H-fixes/v1.15.1` matches the DMG. **Supersedes 1.15.0** (which predated 257f12c/0af1e28 and carried an uncommitted edit).
- Bundled: TDT v3 + EOU 160 ms + speaker + N6 CTC + Silero VAD + llama.framework. Qwen LLMs not bundled (onboarding download).
- `FULL_INSTALLER=1 verify_install.sh` **OK** (TDT/EOU/speaker/Silero inference, CTC present, 1.15.1, 9 TCC strings, self-contained, headless launch of temp copy).
- Not installed to /Applications; running app untouched; appcast/cask/notes reverted; `.build-v7a` reclaimed.
- Not verified: CTC inference in self-test (presence only), Gatekeeper/notarization on a clean Mac, real dictation with this build.

## 2026-10-03 — H-fixes final installer 1.15.0
- `Packaging/releases/VoicePlus_H-fixes_1.15.0.dmg`, 779 MB (817,691,008 bytes), SHA256 `e7c3b735286720e3f1ee955db9e86de127f35d219fc7f37d4aa5f3d1e147e9fc`. `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=<1.14.0 DMG Models> Packaging/release.sh H-fixes 1.15.0 --no-github`.
- Bundled: TDT v3 + EOU 160 ms + speaker + N6 CTC (re-hashed from the 1.14.0 DMG) + Silero VAD + llama.framework. Qwen LLMs not bundled (onboarding download).
- `FULL_INSTALLER=1 verify_install.sh` **OK** (TDT/EOU/speaker/Silero inference, CTC present, 1.15.0, 9 TCC strings, self-contained, headless launch of temp copy).
- Not installed to /Applications; running app untouched; appcast/cask/notes reverted; `.build-v7*` reclaimed. Tag `release/H-fixes/v1.15.0`.
- Build included uncommitted working-tree edits to `App/Debug/ReplayHarness.swift` + `App/main.swift` (replay `--near`, debug-only; not committed by release).
- Not verified: CTC inference in self-test (presence only), Gatekeeper/notarization on a clean Mac, real dictation with this build.

## 2026-10-03 — H-fixes build (H1–H37 + rounds 2–4)
- H1–H36 done, H4 delivered as X1, H30 as X7, H37 done at the gate (replay: 44D96491/7EA1E75A silent, E3C72C7E = hands-free session parent whose piece landed as ECA48A34; no lost speech). X1–X7 done (Option either side, chord-cancel, Claude second-tap drop, tap/hold thresholds, four LLM modes, Qwen 2B/4B download+delete, destination identity, hands-free routing). Per-item table: Investigation "Build status (H-fixes)".
- Gate commits: 5c89231 (replay `--near`, was uncommitted in the 1.15.0 DMG), 257f12c (K18 AXGuard in DestinationIdentity + 7 stale fn/menu/W3H test expectations), 0af1e28 (PillPanelController deinit detaches SwiftUI hosts; fixes a signal-6 teardown abort).
- **Full suite:** `--no-parallel`, .build-v7a: 5236 passed, 0 failed, 351 s (after two failing runs fixed above).
- **Replay:** 135111-082 `--near "…hold-to-talk…"` → "In case of hold-to-talk."; 6 other recent chat recordings 0 swaps, full stop / "?" kept.
- **New deps:** none.
- **Open:** live checks (Claude double-tap drop + tap re-enable + Secure Input, per-side Option on external keyboards, Electron background writes / switch-back, hover menu tracking, favicons); Qwen download/RSS/tokens-s and the 60-case Lab set unmeasured (mocked); Bayes gatekeeper routes some long narration as repairCommand (harmless, falls to dictation; could cap at 8 words); 1.15.0 DMG predates 257f12c/0af1e28 (superseded by 1.15.1).

## 2026-10-03 — Hotkey binding + notch/dot fixes
- **Hotkey root cause:** in 1.15.1, reading the stored binding also wrote it back, so the one-shot X1 fn→Option migration re-ran mid-session (log 22:53:14: "changed externally to fn" → "moves from fn to Option") and rewrote the owner's fn pick; the Option tap stayed armed, so Option kept dictating outside the app. Fix 83c4e52: migration runs once, eagerly, when the service is built (before the settings observer); the binding read is side-effect free. 11dc7bf: Settings/Today show the key the service actually runs (stored binding, else Option), so picking fn when only legacy `hotkey.choice`=fn existed is no longer a no-op.
- **Notch/dot root cause:** after a Space re-layout (WindowManager "batch reassociate", 22:51:19) the all-Spaces pill/ribbon/overlay windows were left on no Space; the pill was ordered in but off screen, so the chin presence indicator kept the surface — the white pulsing dot. Fix f3f7aa6: windows re-assert all-Spaces membership on order-in (+ rebuild fallback for pill/ribbon/ink); 5ed15e3: the off/on tag flip is committed (`CATransaction.flush()`) between halves so it reaches the WindowServer (bare flip was coalesced; repro'd on a standalone panel, 3/3 rejoin with the fix).
- **Gate:** f0a376b (`readinessFollowsWhatIsOnDisk` on the main actor; SIGSEGV race with `ModelStackInstaller.init`'s refresh), next commit (planner-model tests inject `downloaded:` instead of reading this Mac's real Qwen 2B; `UnavailableEngineTests` state log under a lock, SIGTRAP race).
- **Tests:** HotkeyUserPickSticksTests (runtime fn↔Option switching, legacy-choice pick), NotchSpaceMembershipTests (coalescing fake window; bare flip regression).
- **Full suite:** `--no-parallel`, .build-v8a: 5263 passed, 0 failed, 342 s (after two crashing runs fixed above).
- **Owner action:** after installing, pick fn / 🌐 once in Settings (shows Option first — that is what is bound now); `defaults read in.adityakatare.voiceplus hotkeyBinding` → fn.
- **Live check needed:** real Option tap off under fn (Accessibility); notch pill + ribbon after creating/removing a Space or connecting AirPlay; a hands-free pill already showing during a re-layout is not re-asserted; one spurious `rebuilding` warning per re-layout.

## 2026-10-04 — H-fixes installer 1.15.2 (supersedes 1.15.1)
- `Packaging/releases/VoicePlus_H-fixes_1.15.2.dmg`, 779 MB (817,709,498 bytes), SHA256 `1f1077f901f0f9860c1cd2ecf1fda883fa0c163e105aecdc470e70f52eedf0a2`. `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=<1.15.1 DMG Models, read-only mount> Packaging/release.sh H-fixes 1.15.2 --no-github`.
- Built from a clean tree at 2d8abad (hotkey 83c4e52/11dc7bf, notch f3f7aa6/5ed15e3, gate fixes), tag `release/H-fixes/v1.15.2`.
- `FULL_INSTALLER=1 verify_install.sh` **OK** (model inference, CTC present, 1.15.2, 9 TCC strings, self-contained, headless launch of temp copy; running pid 88893 left alone).
- Not installed to /Applications; running app untouched; appcast/cask/notes reverted; `.build-v8*` reclaimed.
- Not verified: real dictation with this build, Option silent under fn on a live system, notch pill after a Space re-layout.

## 2026-10-04 — r?, hands-free landing, notch animation fixes
- **"r?" root cause:** in Claude desktop the focused element was a blank AXGroup/AXButton, not the composer; the ladder typed keystroke chunks into it, Claude kept ~1 char per chunk while moving focus into the composer, and caret readback ("any forward move") reported verified. DB proof: composer held "r?" (FNV 638535913382343070) only after 20F4BBB5 (hold) and FA1356F3 (hands-free). Fix be7e683 + a5651a7: blank non-settable web/Electron focus = "no text field" → held to Notes; readback across a focus move confirms only when the new element holds the whole text; "\n" counts as blank.
- **Hands-free landing root causes:** own voice filtered to Notes as "another voice" (speaker check scored whole 17–42 s mostly-silent pieces; 0.008–0.36 vs 0.60) → 5d248bd + 2ec1184 (each piece's own voiced audio, noise-floor-relative; owner pieces now 0.65–0.73); sentence end (EOU) did not land a piece, or was dropped during the VAD hangover → 5d248bd + 3b5b584; stale AX caret after our own landing in Electron → 6befaaa/2f05a4b. Pause-to-land stays the configurable latch pause (Settings).
- **Notch root causes:** RC1 hands-free row keyed on per-piece `captureOpen` so each landing hid the pill and reopened it → keyed on the session (b27ce3e, 9197591); RC2 hands-free pieces never presented `.inserting` so no ribbon → landing after an armed preview starts the flight; RC3/RC4 chin widened at key-down and a cancelled tap's late "listening" reopened the pill → `PresenceRevealGate` (0.75 s), late live states dropped, pill opens from/closes into the chin's frame; RC5–RC7 hotkey reset when hands-free ends elsewhere, no summary reopen, Finish dictation always finishes.
- **Gate:** `swift build` clean; full suite `--no-parallel`, .build-v9a: **5306 passed, 0 failed, 362 s** (first run green; no gate fix needed).
- **Replay (debug `--replay`):** 2026-10-04-002148-805 (turn 20F4BBB5, the hold "r?") → "Is the dictation working properly?"; 002203-762 → same, 0 swaps. FA1356F3 (hands-free) kept only a 0.29 s tail WAV (002244-225, `invalidAudioData`), so its audio cannot be replayed; its turn record/sidecar text is the full "Is the dictation working properly? What about now?". The defect was injection, not recognition.
- **Live check needed:** Claude/Chromium AXButton/AXGroup settable flags (probe had no Accessibility); a full hands-free session on 1.15.3 (notch stays, ribbon per landing, 2 s pause + sentence-end landing, double-tap exit inserts the rest); open/close animation on tap/double-tap; very short pieces (e.g. "Finish dictation.", 1.3 s, scored 0.15) may still go to Notes; hands-free pieces' recordings are only a short tail (replay gap).

## 2026-10-04 — H-fixes installer 1.15.3 (supersedes 1.15.2)
- `Packaging/releases/VoicePlus_H-fixes_1.15.3.dmg`, 780 MB (817,898,226 bytes), SHA256 `0e26adf4e6deac53a4a1708c04613ec5c2248cb2bb51ecea8550f469af874d14`. `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=<1.15.2 DMG Models, read-only mount> Packaging/release.sh H-fixes 1.15.3 --no-github`.
- Built from a clean tree at 55a35a2 (r? be7e683/a5651a7, hands-free 5d248bd/6befaaa/2f05a4b/2ec1184/3b5b584, notch b27ce3e/9197591), tag `release/H-fixes/v1.15.3`.
- `FULL_INSTALLER=1 verify_install.sh` **OK** (model inference, 1.15.3, self-contained, headless launch of temp copy; running pid 1708 left alone).
- Not installed to /Applications; running app untouched; appcast/cask/notes reverted; `.build-v6a/.build-v9*` reclaimed.
- Not verified: real dictation with this build (hands-free session in Claude, tap/double-tap notch animation), Gatekeeper/notarization on a clean Mac.

## 2026-10-06 — Feature tap-to-talk (owner request)
- **Gesture:** with Settings › Shortcuts "Tap to talk" on (default), a press < 250 ms of the dictation key (any binding: Option either/left/right, fn / 🌐, Right Command…) keeps capturing after key-up (`HotkeyStateMachine.Action.tapToTalk`, phase `.tapTalking`); the next tap finishes and lands it through the hold's turn path (preview, outcome row, ribbon). Audio runs from the first key-down, so a second guarded tap inside 350 ms turns the same capture into hands-free (`.enterLatch`); with "Double-tap to latch" off the second tap just finishes. Hold-to-talk unchanged. A tap over a notice/error/outcome row still only dismisses it (X3). Re-press within 300 ms of the finishing tap folds (H29). K02 lost key-up on the finishing press finishes.
- **Silence:** `TapToTalkWatch` (DictationCoordinator) finishes and lands after "Stop after silence of" (3–30 s, default 10 s) counted from the last VAD speech end / new live words; no speech → H1 thresholds (< 0.6 s vanish, else "Didn’t hear anything"). Escape / failures / cancel reset the gesture (`HotkeyService.abandonTapToTalk`).
- **Chord rule:** before speech, a chord on the finishing press or a typed key while listening cancels silently; clicks/scrolls never cancel; after speech chords pass through.
- **Removed:** the single-tap hint ("Hold to talk · double-tap to lock") and its timers. **Copy:** ready hint "Tap, Hold or Double Tap <key> to dictate", lane note "Tap <key> to finish · Esc cancels", Shortcuts explanation, shortcut test panel (tap to talk / finished), onboarding first-dictation sentence, DESIGN.md.
- **Tests:** `TapToTalkTests` (tap→speak→tap lands end to end with RealEngine + mock mic; tap-tap → hands-free; hold; no-speech thresholds; live switch + binding change; silence timeout; Escape reset; probe; launch gate; deixis); full AppTests 2820 passed (.build-v10a).
- **Untested live:** real key timing with the Option event tap and Claude's second-tap drop, lane-note placement on the notch, VAD-driven silence timeout on real audio. Disk was at ~1 GB free during the build.

## 2026-10-06 — Verify lane A (launch fix 39c2ef8/5b3227b + tap-to-talk 0d725e2)
- **Launch tap gap (fixed):** `tapToTalkEnabled`/`doubleTapLatchEnabled` were wired only after the container (5 s), so a tap made right after launch was a plain cancelled tap and `LaunchPressGate.tapTalking` was unreachable live. `TapToTalkWiring.armEarly` now wires them from `UserDefaultsSettingsStore` before `armHotkeys()`.
- **Orphaned dictation (fixed):** a binding change (`setBinding`) or a re-arm (`stop()`) reset the machine to idle while a tap-to-talk / hands-free capture ran with no key held — the silence timeout then had nothing to finish and the new key opened a second press over it. `HotkeyStateMachine.rebind()` keeps `.tapTalking`/`.latched` (drops only a press in flight); the next tap ends it.
- **Double tap to stop (fixed):** with tap to talk on, the H29 fold window is max(300 ms, double-tap window 350 ms): the second tap of a habitual double tap to stop (already dropped from Claude by the Option tap) no longer starts a new tap-to-talk dictation. Tap to talk off: 300 ms as before.
- **Verified by reading:** RC2–RC5 engine/chord changes, Claude second-tap drop with tap to talk, chord pass-through after speech, timing boundaries (179/180/250 ms, 350 ms window measured key-down after first key-up). Tests: `TapToTalkVerifyTests` (13).
- **Not fixed / noted:** without the Option event tap (Accessibility missing) a typed key while tap-to-talk listens does not cancel (passive check runs only while the key is held); a tap during an outcome row still only dismisses it (X3 rule).

## 2026-10-06 — After-launch hotkey fix, tap-to-talk, open at login
- **Launch root causes (10-04 1.15.2 / 10-06 1.15.3, both first launches of a new bundle):** RC1 each install misses the CoreML/ANE compile cache → 40–50 s model recompile while the app already said "ready"; RC2 `RealEngine.start` awaited the model inline and key-up's `stop()` queued behind it on the coordinator's serial chain → mic stayed open until the model landed (1.9 s hold → 25.9 s of background video typed into Claude; 8.2 s hold → 30.3 s, turn lost); RC3 every press refused (K04) while that frozen turn was "finishing"; RC4 the next press's capture queued behind the dropped final pass (capture_open 3945 ms) → empty turn; RC5 20/58 presses on 10-06 silently chord-cancelled by scroll momentum / may-begin / resting-finger events.
- **Fixes:** 39c2ef8 (shared in-flight model load; start() returns once capture opens; stop() closes the mic at key-up and only the final pass waits; "Loading speech model…" hint), 5b3227b (`ChordInputFilter`: only discrete wheel / live gesture counts as a chord; cancel line names its cause).
- **Tap to talk (owner request):** 0d725e2 + 9fdcd0a. A tap (< 250 ms) of the dictation key starts a dictation, the next tap lands it; a double tap stays hands-free; hold-to-talk unchanged. Key = the dictation key chosen in Settings › Shortcuts (Option any/left/right, fn / 🌐, Right Command, any holdable key). Settings › Shortcuts: "Tap to talk" (default on), "Stop after silence of" (3–30 s, default 10 s).
- **Open at login:** 27649b7 + 51805f3. `SMAppService.mainApp`, default ON on first launch of an /Applications copy (retried if refused), user choice (`loginItem.userChoice`) wins after; Settings › General "Open at login" row with real status + "Open Login Items" when approval is needed; onboarding Ready checkbox. DMG/translocated copies cannot register (ad-hoc signing).
- **Gate:** `swift build` clean; full suite `--no-parallel`, .build-v10a: **5371 passed, 0 failed, 366 s** (first run green; no gate fix). Orphaned test helpers from .build-v7c/.build-v10a killed.
- **Live check needed:** first launch after installing 1.15.4 (model still compiling): a hold records exactly the hold, a second press is not refused; tap → speak → tap lands in Claude; tap-tap hands-free; silence timeout; scroll then hold Option not cancelled; login item registers and VoicePlus opens after a real macOS login.

## 2026-10-06 — H-fixes installer 1.15.4 (supersedes 1.15.3)
- `Packaging/releases/VoicePlus_H-fixes_1.15.4.dmg`, 780 MB (817,955,897 bytes), SHA256 `607673e15b547a391b69e1d593bd659cc02716a2e9bf8351601e298cb22c51cd`. `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=<1.15.3 DMG Models, read-only mount> Packaging/release.sh H-fixes 1.15.4 --no-github` (the first run's DMG step was cut off by a tool time limit after make_app; rerun with `SKIP_BUILD=1` on the same release build).
- Built from a clean tree at 7c459bc (launch fix 39c2ef8/5b3227b, tap-to-talk 0d725e2/9fdcd0a, open at login 27649b7/51805f3), tag `release/H-fixes/v1.15.4`.
- `FULL_INSTALLER=1 verify_install.sh` **OK** (TDT inference, CTC + VAD bundled, 1.15.4, 9 TCC strings, self-contained, headless launch of temp copy pid 43602, only that pid stopped).
- Not installed to /Applications; appcast/cask/notes reverted; `.build-v10*` reclaimed. Note: the owner's running 1.15.3 (pid 22234) was seen alive just before verification and was gone when verify_install started (verify reported no other instance, so it did not stop it); cause not found in logs.
- Not verified: real dictation with this build, first-launch press during the model compile, login item after a real login, Gatekeeper/notarization on a clean Mac.

## 2026-10-06 — Menu-bar glyph size, Spool app icon, installer 1.15.5
- **Menu-bar glyph (owner request):** d143a62. Status item image 18 × 16 → 24 × 18 pt (viewBox at 0.75, no letterboxing; the glyph was 13.5 pt tall). Menu heading glyph unchanged.
- **App icon (owner pick: E):** 447a541. Spool cameo (`Spool.cameo`, design_v3.html) on a dark tile; *uncertain* (tilted, one eyelid down, lopsided smirk) is `AppIcon.icns`; *ready* ships as `AppIcon-Ready.icns`. Sources/masters in `Packaging/icon/` (SVG, 1024 PNG rendered by a browser canvas, .icns, options sheet); `make_app.sh` copies both. Settings › General › "App icon" (`AppIconService`, key `appIcon.choice`): sets `NSApp.applicationIconImage` and a Finder custom icon on the bundle (Ready) or removes it (Uncertain); re-applied at launch if an update dropped it.
- Custom icon caveat (checked on an APFS clone of the 1.15.5 app): `NSWorkspace.setIcon` writes `Icon\r`; `codesign --verify` still exit 0, `--strict` fails ("detritus"). cdhash unchanged, so TCC grants should hold — not verified live.
- `Packaging/releases/VoicePlus_H-fixes_1.15.5.dmg`, 780 MB (818,259,172 bytes), SHA256 `e9f1863df1f7c160febda62337526508c28959a60804a5b7480ede7cd38df4e9`. `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=<1.15.4 DMG Models, read-only mount> Packaging/release.sh H-fixes 1.15.5 --no-github` from 447a541. `FULL_INSTALLER=1 verify_install.sh` **OK**. Appcast/cask/notes reverted.
- Tests: MenuBarGlyph, StatusMenuController, AppIconChoice, SettingsReachability: 33 passed (.build-icon, reclaimed). Full suite not run (disk was at 2 GB free; owner removed old DMGs).
- Not verified: the glyph in the real menu bar, the Settings picker swapping the Finder/Spotlight icon on the /Applications copy.

## 2026-10-07/08 — Context Writer, step 1 (owner: execute plan §10.1)
- Plan: `VoicePlus_ContextWriter_Plan.md`. Scope: packet v2 (§2), destination profiles (§3), per-change guard + Context Writer stage (§1), one-landing UX with sentence-wise correction (§4), booster scoped down, A1/A3/A6/C1, cloud backend (OpenRouter, DeepSeek V4.1 Flash default pending the bake-off — no key on this Mac yet), Lab `context-magic` suite, then a DMG.
- Contract first: `Shared/Writer/ContextPacket.swift` (`ContextPacket`, `WriterMode`, `VocabularyMatching`), built clean.
- Wave 1 done (8 agents; 3 hit the session limit mid-task, finished by the orchestrator):
  - A6: the stored `uncertainSpans` were right (they index `finalText` with its continuation space); the 10-06 doc rendered them on `rawText`. Writer seam hardened (`UncertainSpans` contract, record matched by trimmed words). ef22901, e524f6c.
  - Packet builder `ContextPacketBuilder` (+ `App/Services/Packet/`): destination record per surface, thread blocks, screen terms, tty foreground process, heard (pre-boost), sources. d3fa6c4, efbad5b.
  - Destination profiles (24, plan §3) + `WriterPrompt` (sanitised, per-section budgets, `UNCHANGED`). d937f59, cc3195b.
  - `ContextWriterStage` + per-change `WriterGuard` (phonetic/alternates/vocab evidence, region revert, preamble reject). f5e6af8.
  - Cloud backend `CloudWriterGenerator` (OpenRouter, DeepSeek V4.1 Flash default, fallbacks, latency routing, reasoning off, 2.5 s, prewarm); discovery defaults updated. 7f62bae.
  - C1 `RedictationLearner` (re-dictation aliases + undo as negative alias). 256a4e6, fc17f99.
  - Lab `context-magic` suite (24 cases from the bake-off, scorer parity, gates, `lab run --suites context-magic`). e3718a5, dba172e.
  - Correction settings (off/local/cloud, per-app) + page; `WriterLandingEvents` channel; HeardWords fixes. 8190499.
  - Targeted suites: 239 tests, 233 passed; remaining 6 = unfinished vocab matcher (perf 446 ms vs 25 ms budget, verbalizer forms) → wave 2.
- Wave 2 done (4 implementers + 4 adversarial reviewers):
  - Vocabulary: `SpokenFormVerbalizer`, `PhoneticVocabularyIndex` + `VocabularyMatcher` (Double Metaphone index; debug 5k terms: build ~410 ms off the hot path, query 1.8–4.7 ms; release ~0.25–0.45 ms), booster scoped down (no Contacts, no screen terms, cap 100). c8ba084, 3d34183.
  - Integration `WriterWiring`: per-run tier (Automatic/off/local/cloud + per-app), cloud OpenRouter + local shared-Qwen backends, writer at cleanup's position (cleanup skips while the writer runs), packet in the lander (pre-boost heard), vocabulary rebuilt off key-up, landing events, C1 observe, key-down prewarm, Lab cloud/local writers, `--replay --writer cloud|local|off --packet`. 6536f5d, ea97fb8, 677945e, d3a8ceb.
  - Landing UX: "Writing…" after 150 ms (no flicker), "Polished N words" + range-safe Undo, "Not polished", corrected-word shimmer (static tint under Reduce Motion), VoiceOver lines, DESIGN §8.10. ebb72cd.
  - Latency: cacheable prompt prefix (`WriterPrompt.renderParts`), local KV prefix cache (hybrid Qwen3.5 checkpoint restore), `prewarm(system:prefix:)`. Live on the owner's Qwen3.5-4B (M2 Pro, under build load): first token 2,183 ms cold → 246 ms prefix-warm; 48-token answer 2,587 → 661–1,362 ms. 8af36fd, d58352d.
  - Sentence speculation built but **left unwired**: measured on 93 of the owner's recordings, only 1 % of words reused with the shipped EOU preview (22 % on long holds with the polling preview); a reviewer also found a secure-field privacy hole in it. 798aee6, 4b6e43a.
- Review findings (28): wiring/privacy 7 (incl. HIGH: Automatic silently resolving to cloud whenever an OpenRouter key exists), landing UX 8, vocabulary 7, speculation 6 (dormant). Owner-level decisions taken: Automatic = local-or-off, cloud only when chosen; speculation off. Fix wave running.
- (wave-2 plan was) vocab finish · integrator (AppContainer/lander/Lab/replay wiring, booster as evidence, writer replaces cleanup when Correction is on) · landing UX (Writing…, polished/unpolished outcome, changed-word shimmer, undo correction) · latency (cacheable prompt prefix, local KV prefix cache, sentence speculation). Then full gate, DMG.
- Fix wave (3 fixers + 3 skeptics, 21/24 findings verified resolved): Automatic = On this Mac or Off, never Cloud (a70ebc4); no model load at key-up (`skipped:notResident`), plan-aware prewarm, cached-only availability on the landing path; undo correction wired to C1; RedictationLearner logs counts only (d58d7f5); booster gets typed spoken forms (ec8fdfc); landing UX: notes/Undo owned by the pill's turn, Undo only with trusted ranges in range-replaceable fields (not terminals), all-or-nothing multi-word undo, record follows undo (f76bd79); vocabulary precision: contractions/digits, interior window words, letter-name codes, Contacts only with interaction evidence, symbols (3e20545). Orchestrator: the local writer registers the shared model `.onDemand` (16 GB plans made the 4B `.exclusive`, so the writer never ran on this Mac) (6ee5ec0).
- Gate 1: 5,676 tests, 1 failure (order-dependent guard test; fixed 31269f0).
- **Real-recording verification** (`--replay <stamp> --writer local --packet <case>`, 16 of the owner's recordings, app pipeline: Parakeet → scoped booster → Context Writer with Qwen3.5-4B):
  - Found and fixed: the guard checked spelling, not sound — it refused "Till ⟦face⟧ two" → "phase" (Double Metaphone FS = FS, spelling 0.4) and every confident change ("Queen" → "Qwen"), against plan §1.4. Now: uncertain word → any sound-alike; confident word → same sound + context (screen/vocab term, or a named entity not in the word list); letters+digits read part by part ("A sixtien z" → "a16z"); false starts restarted on a content word may go. a4cb392, 7767b87. Replay also lacked the app's phonetic ear (fixed) and gained `--show-model`.
  - Booster scope-down alone fixes two of the owner's failures: "Add this" and "Invest final" now come out right (contact names "Adv", "*dial" no longer boosted).
  - Local Qwen3.5-4B, seen through `--show-model`: conservative — UNCHANGED on "Till face two" even with "Phase 2" on screen; "A sixteen Z." stays; it removes the false start "turned out the" but keeps "Queen"; with a thread in the packet it once copied the context into its reply (guard rejected it). Controls 5/5 kept. **The local tier does not deliver the magic; it is safe and mostly a no-op.** The cloud tier needs an OpenRouter key (none on this Mac) and the bake-off; the local fine-tune is plan step 4.
  - Latency (local, one process): first call 1.9 s (cold load); warm 350–490 ms for short dictations (UNCHANGED, one token), 1.1 s for the 26 s Qwen sentence. In the app the key-down prewarm + KV prefix cache make the warm path the normal one; a cold model at key-up is skipped, never waited for.
- Known gaps: sentence speculation unwired (1 % reuse with the EOU preview); after a writer Undo the repair session/zero-edit still hold the polished text (a follow-up repair is refused, never misapplied); the llama.cpp Metal teardown asserts at CLI exit (`ggml_metal_device_free`), seen in replay only; Contacts need the App to feed interaction evidence (`build(people:)`).
- Quit fix: llama.cpp's Metal teardown asserted at exit with a model loaded (seen in replay; the writer keeps its model resident) → `LlamaCppEngine.unloadAllShared()` before quit (bounded 2 s) and at replay exit; replay now exits 0. 4357a5e.
- **Gate 2:** full suite `--no-parallel` at 7767b87: **5,683 passed, 0 failed** (447 s).
- **Installer:** `Packaging/releases/VoicePlus_CW1_1.16.0.dmg`, 783 MB (821205741 bytes), SHA256 `aeb91c58f7df86f9cd0735c94b00405ec19984100425b08e9c8d9a5cd9bc26ec`. `FULL_INSTALLER=1 BUNDLE_MODELS_FROM=<1.15.5 DMG Models, read-only mount> Packaging/release.sh CW1 1.16.0 --no-github` from 4357a5e. `FULL_INSTALLER=1 verify_install.sh` **OK** (bundled TDT/EOU/speaker/Silero inference, 1.16.0, 9 TCC strings, self-contained, headless launch of a temp copy; only that pid stopped). Not installed to /Applications; appcast/cask/notes reverted.
- **What the owner gets in 1.16.0:** Settings › Models › Correction (Automatic = On this Mac with Qwen3.5-4B on this Mac; Cloud needs an OpenRouter key + an explicit choice); "Writing…" on the pill when the writer takes > 150 ms; "Polished N words" + Undo; the booster no longer turns words into contact names. Expect the local writer to change little (measured above); the magic needs the cloud tier (bake-off pending a key) or the local fine-tune (plan step 4).
- Not verified live: a real dictation with this build (pill states, Undo in Claude/Codex, the key-down prewarm + prefix cache under real use), the cloud tier end to end (no key), quitting the app with the model resident (verified only through the replay CLI).
