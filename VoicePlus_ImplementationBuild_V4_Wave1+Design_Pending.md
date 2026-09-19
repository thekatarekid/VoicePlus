# VoicePlus V4 Wave 1 + Design: pending decisions

Date: 2026-09-19 · Build: 1.11.1 (`VoicePlus_V4-w1_1.11.1.dmg`, sha256 `8a2edfd5…`)

Purpose: items that need the owner's decision or were deliberately left open after 1.11.x.

Numbers #1, #2 and #5 are the owner's issue numbers from the 1.11.1 fresh-install report. Issues #3, #4 and #6
are bugs. They were fixed in code as FX1–FX5 for 1.11.2 (build doc §9), so they are not listed here. The open items
those fixes left are at the end of §B.

---

## A. Decisions needed

### #1 Bundle the speech models in the DMG, or keep the first-run download?

**Question.** "The DMG is only ~20 MB and the models download during onboarding. I thought we decided to bundle them."

**What the app does today, and why.**
- No DMG has ever contained a model. All 26 DMGs in `Packaging/releases` are 11.7 MB (0.0.1) to 20.9 MB (1.11.1).
  `Packaging/make_app.sh` has never copied a Models folder. `/Applications/VoicePlus.app` is 51 MB, almost all binary.
- Bundling was planned in the V1 and V2 drafts (V1: all three models in `Contents/Resources/Models`, ~2.5 GB per DMG;
  V2:89: "bundle the validated default stack"). V3 reversed it on purpose on 2026-09-11 (commit `ceab873`):
  `VoicePlus_Improvements_V3.md` §0 decision #6 "No updater and no bundled models", §5.4, §12.3 "Do not build: an
  updater or bundled models", §13 table. Reason given: the download bugs bundling was meant to fix were already fixed,
  and without an updater every patch would be a ~700 MB manual download at a release cadence of days. V3 says to
  revisit "when there are users beyond the author".
- R6.1 (`0646ccd`, 2026-09-11) built "one stack, installed automatically on first run". V4.50 added the speaker
  weights to the same download.
- `ModelManager.locate()` (`Engine/ASRRuntime/ModelManager.swift:223-236`) looks in
  `~/Library/Application Support/VoicePlus/Models`, then FluidAudio's cache, then legacy folders. It never looks in
  the app bundle.
- The "GBs" you remember were most likely the model caches in Application Support (Qwen 0.6B at 1.2 GB left there by
  Muesli, plus pre-1.7.13 duplicate Parakeet downloads), not the app or the DMG. This is inferred: the fresh wipe
  removed those folders.
- Misleading names that suggest bundling: the `BundledModel` enum (`Engine/ASRRuntime/BundledModel.swift`, nothing is
  bundled), `PRODUCT-SPEC.md:455` ("tiny bundled model"), `VoicePlus_UIUX_V1.md:327` ("Parakeet + EOU + Qwen3 ASR
  bundled · 0 KB").

**Facts.**
- Download today: ~700 MB on disk (Parakeet TDT v3 469 MB, EOU 120M 160 ms 219 MB, speaker 13 MB). Onboarding
  quotes 914 MB because the catalog estimates are high (EOU listed as 400 MB); that is being fixed separately.
- Adding Qwen 0.6B int8 would add ~1.2 GB (~1.9 GB total). CoreML weights barely compress in a UDZO DMG.
- The first-run download is what exposes the "speech model isn't ready" race (#3). Bundling would hide it, but the
  race is fixed in code either way.

**Options.**
1. **Keep the download (current V3 policy).** DMG stays ~20 MB, patches stay small. Cost: first run needs ~700 MB and
   a network connection before dictation works. Clean-up: rename `BundledModel`, fix PRODUCT-SPEC:455 and the UIUX_V1
   line, and make the onboarding step say "one-time ~700 MB download, stored in Application Support".
2. **Bundle in every DMG.** Zero-download install. Cost: every patch is a ~720 MB DMG (~1.9 GB with Qwen) with no
   updater to deliver deltas; a model-staging step outside git (Models/ is gitignored) and a read-only bundle lookup
   in `locate()` that migration and clean-up code must never touch.
3. **Two DMGs per release (hybrid).** A "Full" DMG (~720 MB, models inside) for fresh installs and the current ~20 MB
   DMG for upgrades. `locate()` already reuses models on disk, so upgrades stay small. Removes V3's objection without
   an updater. Cost: two artefacts per release and a slightly longer release script.

**Recommendation.** Option 1 while you are the only user; switch to option 3 when the app goes to anyone else. Either
way, do the naming and copy clean-up now so the docs match the build.

**Once decided.** Record it in `DECISIONS.md` (it overrides or confirms V3 §5.4/§12.3).
- Option 1: rename `BundledModel`; fix `PRODUCT-SPEC.md:455`; mark V1/V2 §1 and `VoicePlus_UIUX_V1.md:327` superseded;
  onboarding copy. About half a day.
- Option 2 or 3: `Scripts/fetch_release_models.sh` (pinned, SHA256-checked cache outside git), a copy step in
  `make_app.sh` that fails on a missing or unverified model, a `verify_install.sh` check, a `Bundle.main/Models`
  first candidate in `ModelManager.locate()` kept out of migration, parking and delete paths, and a check that
  FluidAudio loads from a read-only signed location without re-downloading. Option 3 also adds a second DMG to
  `release.sh`. About 2–3 days, plus a clean-account install test.

---

### #2 Should Qwen3-ASR run alongside Parakeet?

**Question.** "Why doesn't 1.11.1 use Qwen3-ASR for post-processing with Parakeet v3 and the realtime EOU model?
Older versions used it and were several GB. Wasn't Qwen doing a good job?"

**What the app does today, and why.**
- No VoicePlus release has ever run Qwen during live dictation, and no DMG has ever included it.
- Qwen3-ASR 0.6B int8 was ported from Muesli's MIT source on 2026-09-11 (R5.1 `f52255a`) and is in 1.9.0 and later,
  but only as code.
- The `qwenRefinement` flag (`Shared/Types/FeatureFlag.swift:58-69`) was created default-off in `c903352`
  (2026-09-11) and has never been turned on. R5.4 (`1b1e9d5`, `DECISIONS.md` R5.4) kept it off because it failed all
  three gate conditions.
- The flag is not wired. `RealEngine.refiner` (`Engine/ASRRuntime/RealEngine.swift:228-232`) is never assigned in
  App code, and `RefinementAvailability.makeQwen3Session()` is only called from tests. So turning the flag on does
  nothing. Qwen has no `ModelCatalog` entry and its default provisioner refuses to download, so nothing fetches it.
- Settings is misleading: the Voice tab can say "Ready: the second-pass model is on this Mac"
  (`App/Settings/VoiceSettings.swift:64-74`) even though the engine never uses it.
- Your good experience with Qwen most likely came from **Muesli**, which uses Qwen3-ASR 0.6B as its main recognizer
  **plus a local Qwen 3.5 LLM that cleans up the text afterwards**. That text clean-up is a different job from a
  second recognition pass, and VoicePlus has never tested it. This is inferred from Muesli's config, not proven.

**Facts (DECISIONS.md R5.4, 20 of your real-room recordings, M2 Pro, debug build).**

| | Parakeet only | Qwen only | Two-pass (gated) |
|---|---|---|---|
| Mean WER | **0.099** | 0.178 | 0.112 |
| Sentences better / worse than Parakeet | — | 1 / 7 | 0 / 2 |
| Latency | — | p50 2249 ms, p95 3792 ms | p95 1816 ms (budget 1500 ms) |
| Peak memory | ~90 MB | ~1.9 GB | ~1.9 GB |

- By class, Qwen vs Parakeet: entities 0.197 vs 0.081; utterances ≥ 7 s 0.335 vs 0.182; digits 0.738 vs 0.405.
  Synthetic noisy speech: 0.229 vs 0.022.
- Limits of the test: only 20 English sentences from one session; only the int8 0.6B model (the 1.7B the plan named
  was never measured); no Hinglish; the scorer has no number normalisation, so digit lines partly measure
  formatting. With the 3 digit lines removed Parakeet still leads (~0.045 vs ~0.079). The 7-to-1 split is consistent
  but weak (sign test p ≈ 0.07).

**Options.**
1. **Leave it off and relabel.** Change the flag description and the "Ready" line to say the second pass is not
   connected in this build; fix the stale comment in `RealEngine.swift:228`. No risk, no gain. About 1 hour.
2. **Wire it and re-benchmark properly.** Connect `RealEngine.refiner` behind the flag with a 1500 ms deadline, add a
   Qwen catalog entry and download, then re-run the gate on ≥ 100 of your recordings (several sessions and mics,
   ≥ 12 s dictations, Hinglish), with number-normalised scoring, a release build, and a 1.7B arm. Default stays off
   unless it wins. Cost: ~1.2 GB more download and ~1.9 GB memory when on. About 3–5 days plus your recording time.
3. **Test LLM text clean-up instead.** Measure a local LLM clean-up stage (existing Ollama path in
   `Providers/LocalServerProvider.swift`, or a small bundled model) on the same corpus for punctuation, numbers,
   fillers and formatting, with latency and memory budgets. Most likely the thing you liked in Muesli.

**Recommendation.** Option 1 now (the UI should not claim something the app cannot do), then option 3 in the next
wave. Take option 2 only for Hindi / Hinglish, where Parakeet v3 has no coverage and Qwen is most likely to win
(`RefinementGate` already has a non-English condition that never fired on the English corpus).

**Once decided.** Record in `DECISIONS.md` (planned vs shipped: Qwen never ran live).
- Option 1: `FeatureFlag.swift`, `VoiceSettings.swift`, `RealEngine.swift` comment.
- Option 2: App engine composition, `ModelCatalog.swift`, `Qwen3Weights.swift` provisioner, onboarding size,
  `Lab/Harness/Scoring.swift` normaliser, `Tests/AppTests/RefinementBenchmarkCorpusTests.swift`.
- Option 3: a new Pipeline stage plus a benchmark arm; needs a spec entry first.

---

### #5 Notch look: should the pill reach the top edge of the screen?

**Question.** "The pill hangs below the notch instead of touching the top of the screen."

**What the app does today, and why.**
- By design, the pill's top edge sits at the bottom of the menu bar: 39 pt below the screen top on your display
  (1800 × 1169, camera housing 220 × 38 pt, menu bar 39 pt). `NotchGeometry.pillTopEdge`
  (`App/Core/NotchGeometry.swift:176-178`) = screen top − topBand, where topBand = max(safe-area top, menu-bar height).
- The rule dates from `f1c5db8` (2026-08-29, first shipped in 1.6.1). Before that the pill started at the very top and
  the part behind the camera was invisible, so only its two ends showed. The fix moved the whole panel down,
  background included.
- `design/design_v1.md` §4 requires it: line 111 "Preserve current placement directly below the physical notch /
  menu-bar safe band… No content is drawn behind the camera housing"; line 146 "Keep the upper corners square when
  attached". The prototype does the same. `Tests/AppTests/NotchGeometryTests.swift:142-146` and `:183-192` lock it in.
- Why it looks worse in 1.11.x: S2 (`aef6b41`, 2026-09-19) widened the pill from 320 to 560 pt, so ~170 pt of menu
  bar now shows above each side.

**Facts.**
- Log: `shown={{620, 966}, {560, 164}}`, top at 1130; housing bottom at 1131, so a **1 pt strip of menu bar** sits
  between the camera and the pill (and the idle chin, which shares the same edge).
- `panel.hasShadow = true` (`App/UI/PillPanelController.swift:22`) most likely draws the thin light rim along the
  pill's top edge (inferred from the screenshot; the view draws no border).
- The pill grows from a 560 × 1 line at the band, not out of the notch.

**Options.**
1. **Merge with the notch (recommended).** Extend only the black background up to the screen top so the pill joins
   the camera housing, as Dynamic Island-style apps do. All text, Spool and controls stay below the band. Also drop
   the window shadow for a bottom-only shadow, close the 1 pt seam, and grow the pill out of the housing.
   Click-through: while the pill takes the mouse (preview, held, actions), the black wings over the menu bar would
   swallow clicks on status items within ±280 pt of centre. Fix by hit-testing only the content area (return nil in
   the top band), or by making the band part only the notch width plus a margin.
2. **Keep the current rule, polish it.** Drop the window shadow, close the 1 pt seam (anchor to the safe-area top when
   attached), and draw a notch-width black "neck" so the join reads as one piece. Side wings stay below the menu bar.
   Partly addresses "should touch the top".
3. **Leave as is.**

**Recommendation.** Option 1 with the narrower band (notch width plus margin), so no menu-bar items are covered or
blocked.

**Once decided.** This reverses the §4 rule, so amend `design/design_v1.md` §4 and add a `DECISIONS.md` entry.
- Code: `App/Core/NotchGeometry.swift` (split panel frame from content area, `contentTopInset`),
  `App/UI/PillPanelController.swift` (shadow, hit-testing), `App/UI/PillView.swift` (lane inset),
  presence chin geometry (`NotchPresenceGeometry.swift`).
- Tests: `NotchGeometryTests` (:142-146, :183-192; guard becomes "content clears the housing"),
  `NotchPresenceTests.sharesTheTopBoundaryWithThePill`.
- Effort: option 1 about 1–2 days plus an on-device look; option 2 about half a day.

---

## B. Known gaps carried from the release

- **Meetings "Ask" is not built**; the tab shows "Needs a configured service". Build doc §3 S7c, §8 (carried to V4
  Wave 2/3).
- **Meetings don't keep their audio**, so the transcript has no audio seek. Build doc §3 S7c; meetings-owns-the-mic
  (V4.46–V4.47) is in §8.
- **No auto-updater.** Settings › Updates runs on `NoopUpdater`; updates are a manual DMG install. Tied to #1 (V3
  §5.4). Build doc §7 S7g row.
- **Mic-quality check can overestimate SNR.** The analyzer's own floors have no hold, so on 9 / 20 corpus files the
  start-up dip is taken as the floor and SNR reads 6–26 dB high. It never causes a false warning now (quiet-room gate
  20 / 20 since 1.11.1) but must be fixed before the corpus sets the SNR limits. `DECISIONS.md` (F1 / SNR hypothesis),
  progress.md "F1 fix".
- **SNR thresholds are still a hypothesis** (poor < 10 dB, bad < 5 dB); calibrate in Wave 2. `DECISIONS.md`.
- **Prosody script not yet recorded.** `Fixtures/prosody/script.md` (15 questions, 15 two-clause, 10 exclamations).
- **Tag `release/phase-V4-w1/v1.11.0` not created** (1.11.1 is tagged); no GitHub release for either (`--no-github`).
- **Live VoiceOver cursor on the pill untested.** progress.md Wave 4 / release.
- **Silero VAD not measured in tests**: `SileroVAD.loadIfAvailable()` returns nil in the test process, so the mic
  gate was measured with the energy VAD only. progress.md "V4 Wave 1 gates".
- **Parallel test runs can fail 4 timing assertions under load** (Refine deadlines, golden latency); serial runs are
  green. progress.md R1.
- **Still unverified on hardware:** tape flight and marks on real carets, notch placement, VoiceOver and high
  contrast, onboarding on a clean account and an external monitor, the fn system-action prompt, timing gates.
  Release notes `Packaging/notes/phase-V4-w1.md` "Not verified".
- **Ad-hoc signed only**, no Developer ID or notarization; first launch needs right-click › Open.
- **Out of scope for this wave** (build doc §8): caret OCR ladder, unified ITN and coverage, prosody punctuation,
  voice-processing IO / level gate / speaker-gate defaults, turn-anchored voice, Notes mode beyond the held queue,
  mobile companion.
- **Left open by the 1.11.2 fixes (FX1–FX5, build doc §9):**
  - AX callers outside `Injection/LiveSystemAccess` still call AX directly with no own-pid / main-thread guard:
    SelectionDetector, TapeFlightTarget, DestinationMarksOverlay, RecoverySheetServices, RepairFanoutPanel,
    LiveAXNodeAccess, Actions (LiveActionSystem, AXRegionText, AXHitTesting) and Engine LiveProviders.
  - If the onboarding window is not key, the own-process write falls back to keystrokes to our own pid on main. It
    does not deadlock, but the read-back may be unverified.
  - The pill stays up for about 27 s after a landing. This was not investigated.
  - The behaviour rules that used to sit in M07 and K03 copy (name the wait after 2 s; a quiet first isolated tap)
    have not been checked as coded.
  - `AppContainer.refreshEngineIfNeeded` is only tested through `RefreshGate`.
  - To check on the installed 1.11.2 app:
    - "Try your first sentence" lands its text with no freeze.
    - The chin rests after fn is released and its pulse is centred.
    - There is no "speech model isn't ready" after a fresh download.
    - The new recovery captions read well on screen.

---

## C. Owner hardware checks

Run the 15 items in `VoicePlus_ImplementationBuild_V4_Wave1+Design.md` §5 (numbers to collect are listed per item),
and record `Fixtures/prosody/script.md`.

---

## Status

| Item | Decision | Date decided | Follow-up task |
|---|---|---|---|
| #1 Model bundling | | | Option 1: rename `BundledModel`, fix spec/UIUX copy, onboarding copy · Option 2/3: model staging + `locate()` bundle root (+ second DMG for 3) |
| #2 Qwen3-ASR | | | Relabel flag and "Ready" text; then LLM clean-up benchmark or wired Qwen re-benchmark (≥ 100 recordings, 1.7B, Hinglish) |
| #5 Notch look | | | Amend design §4 + DECISIONS.md; NotchGeometry content inset, hit-testing, shadow, 1 pt seam |
| Meetings Ask / audio | | | V4 Wave 2/3 (build doc §8) |
| Auto-updater | | | Decide with #1 |
| Analyzer SNR floor hold | | | Before Wave 2 SNR calibration |
| Hardware checks + prosody recording | | | Owner, build doc §5 |
