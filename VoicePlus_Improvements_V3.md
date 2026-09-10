# VoicePlus — Improvements V3

Product and execution plan · revised 11 September 2026

**Outcome:** speak naturally, land the right text in the intended place, and recover or repair without
losing work. Build on the current app. Validate continuously on real audio and real apps.

This document is self-contained. Sections 0–4 are the contract every item reads. Section 11 is the
item list (R0–R8). Section 13 lists decisions already made. Section 15 lists the actions only the owner
can take. The companion build document breaks the items into tasks.

---

## 0. Decisions at a glance

| # | Decision | Replaces |
|---|---|---|
| 1 | Real recordings first. **Done.** Capture and recognition are clean; what looked wrong was the notch preview | A model-first plan measured on synthetic fixtures |
| 2 | Two surfaces: the pill holds provisional text; the field receives committed text once, in order, never retracted. On land, the pill shows the **final** text | Direct injection of live text; a preview that misrepresents what landed |
| 3 | Hold = transient; double-tap = latch; single tap stops; hard mute persists | Same gesture, now with endpoint segmentation while latched |
| 4 | Ranked context feeds a recognizer that can change words | A post-hoc rescorer that cannot |
| 5 | Qwen3-ASR 0.6B via a ported CoreML module, behind a flag, default-on only if it wins on real recordings | An MLX runtime and an assumed gain |
| 6 | No updater and no bundled models. Remove the model *choice* only | 2.5 GB DMGs, a Sparkle dependency, a signing key |
| 7 | Ambient off by default, transcript only, enrolled speaker only, separate opt-in | Ambient on by default |
| 8 | **The pill and notch stay as they are.** New states needed by delivery (held, delivered) use the existing visual language. No new mark, no sound | A redesigned pill |
| 9 | One window, one menu; onboarding under two minutes with a real landing | Nine settings tabs and three standalone windows |
| 10 | Apple Silicon, macOS 14+. Intel not advertised | Ambiguous Intel support |
| 11 | Every gate is evidence from real audio and real apps; unverified checks are recorded as unverified | Synthetic-only gates presented as done |
| 12 | Two releases: A = delivery, preview, context, Qwen comparison, one model stack; B = latch, learning UI, window, ambient | One long revision with no installable candidate |
| 13 | Injection never retries a method that may already have landed. Chromium readback is fixed | Keystroke then paste on a stale accessibility value |

---

## 1. Execution rules

1.1 **Authority.** This document defines scope, priorities and acceptance. Where it conflicts with an
   earlier proposal or design draft, this document wins.

1.2 **Inspect before building.** A checked task, a green synthetic test, or a comment is not evidence of
   working hardware behaviour. Read the code path and its tests.

1.3 **Reuse.** Strengthen existing modules. Do not rebuild working infrastructure. Do not add features
   outside this document.

1.4 **Build the strongest candidate, then measure it.** No research project as a prerequisite. Compare on
   identical real recordings; let the measurement set the default. Flagged paths are never deleted; a
   losing candidate has its default flipped off.

1.5 **Three grades of evidence, always labelled:** implemented · fixture-verified · real-app or
   hardware-verified. Never ship mock speech, invented confidence, or simulated success. Never present a
   fixture number as a product claim.

1.6 **Preserve user data and preferences** across every change.

1.7 **Toolchain.** Command Line Tools only (Swift 6.0.3). `swift build` / `swift test`. Swift Testing
   (`import Testing`, `@Test`, `#expect`); no XCTest, no simulators, no Xcode UI tests. Run
   `eval "$(Scripts/bootstrap-toolchain.sh)"` once per shell. Add `--disable-keychain` when a binary
   artifact must download. App bundle: `Packaging/make_app.sh`. DMG: `Packaging/release.sh <phase>
   <version>`. Ad-hoc codesign only. `/usr/bin/log` is the log tool; bare `log` is a shell builtin.

1.8 **Parallel work.** Several agents share this checkout. Touch only your item's directories and test
   target. `Shared/` and `Package.swift` changes are minimal, additive, and reported. Isolated scratch
   path per item: `swift build --scratch-path .build-<item>`. Commit often and scoped; never
   `git add -A`, never push, never rebase.

1.9 **Record.** Dependency additions, measured decisions, flag-default changes and remaining gaps go in
   the repo's progress log and decisions log. Final report per item ≤15 lines.

1.10 **Hardware.** When an item needs a microphone, a TCC grant or a human voice, request a bounded
   session from the owner, continue with everything else, and record the dependent checks as unverified.

---

## 2. Current state (verified in the repo and on the owner's Mac, 11 September 2026)

### 2.1 What exists and works
- **Key handling.** One dictation key (default Right ⌥). Hold ≥250 ms = push-to-talk; tap <180 ms
  arms a double-tap; two taps within 350 ms = hands-free. Bare modifiers use `NSEvent` global monitors
  (no permission); chords use Carbon hot keys (no permission); an Input Monitoring event tap exists only
  behind an escape hatch. `App/Core/HotkeyStateMachine.swift`, `App/Services/HotkeyService.swift`. A
  separate act key (default Right ⌘) has a picker and an Off.
- **Permissions.** Injection and AX reading are guarded by `AXIsProcessTrusted()` on every call.
  Accessibility and Microphone are the two grants dictation needs; both are granted on the owner's Mac.
- **Audio ownership.** One capture graph with ranked owners; the engine outranks the meter; a start
  takes the graph clean or throws `busy`; a displaced owner's late stop cannot close the new owner's
  mic. Capture opens before the model resolves and buffers opening speech. The model preloads at launch.
- **Microphone selection.** `InputSelectionPolicy` avoids narrowband Bluetooth unless pinned or alone;
  Settings › General › Microphone has a picker with low-quality inputs labelled.
- **Recognition.** Final: Parakeet TDT 0.6B v3 (CoreML, 461 MB). Preview and endpointing: Parakeet
  Realtime EOU 120M (CoreML, 214 MB), through `EOUPreviewRecognizer`; a `PollingPreviewRecognizer`
  over the final model exists as the fallback preview. A TDT-CTC 110M "Fast" tier and a Whisper
  placeholder are in the catalog. `Engine/ASRRuntime/BundledModel.swift` resolves them. Model store:
  manifest per install, integrity verified / unverifiable / incomplete, atomic swap, parked-directory
  sweeper, cross-process lock.
- **Diagnostics.** Opt-in `UtteranceRecorder` saves raw and post-DSP WAVs plus a manifest, newest 20
  kept. `RecordingReplayTests` replays any folder through the shipping recognizer. `UtteranceLander`
  logs one "landing diff" line per utterance: raw recognised vs landed text, edit distance, stages.
- **Pipeline.** Stages are `[TranscriptSpan] -> [TranscriptSpan]`. `TranscriptSpan` carries `text`,
  `confidence`, `audioRange`, `alternates`, `provenance`, `needsRepair`. A contract stage enforces that
  confidence, range and provenance survive every stage, falling back to the stage input on violation.
  Formatters per app class, gatekeeper, voice repair on by default with a scripted beam backend.
- **Injection.** `TextInjector`: focus check → adapter → method order → try each, verify by AX readback,
  stop at first success. `InjectionOutcome` already distinguishes `injected(verified:)`,
  `abortedFocusChanged`, `failed`. `FocusGuard` queues on focus change and auto-delivers on return.
  Adapters: terminal, Figma, Cursor, spreadsheet, Electron, default `[.ax, .keystroke, .paste]`.
- **Context sources.** `App/Services/AXContextProviders.swift` reads the focused window through a
  cached AX reader (2 s TTL, visible portion, ≤200 blocks) into the biasing harvester and pipeline
  context. Held in memory per utterance, never written to disk.
- **Learning.** Corrections train a bias-list learner and a learned lexicon with a regression guard.
  `LexiconSanity` rejects document-sized pairs at store, ingest and use. No lexicon exists on the
  owner's Mac today.
- **Speaker and hands-free.** Enrollment window, `SpeakerGate`, `HandsFreeController`, persistent hard
  mute with a three-state glyph. `directedSpeech` flag off. Meeting capture with local diarized notes.
- **Pill and notch.** A notch-hosted presence with ready / listening / preview / landed / error rows,
  a waveform, and a menu on click. **It stays.**
- **Lab.** Replay harness, side-by-side configs (biasing on/off, repair on/off), report writer,
  Zero-Edit counter, Data Panel.
- **Tests.** 1430 passing at 1.7.15, Swift Testing throughout.

### 2.2 Measured on the owner's Mac (R1, 11 September)
Twenty real-room dictations of the Appendix A script, built-in microphone, replayed through the
shipping final recognizer, and cross-checked against the app's own log for the same session.

| Finding | Evidence | Consequence |
|---|---|---|
| **Capture and final recognition are clean** | WER 0.099 over 222 words; 15 of 22 errors are number formatting or reference drift | No capture-path or model work is justified by accuracy |
| **The pipeline lands what the model heard** | Landing diff distance 0 on 18 of 20; 2 and 4 (punctuation) on the other two | Post-processing is innocent |
| **What the owner saw in the notch was wrong on most of the twenty** | The notch shows the **streaming preview** from the 120M EOU model: no punctuation, numbers as words, a weaker model. The final text is never shown there | The *felt* accuracy problem is the preview, not the landed text. R2 shows the final text on land; R1.5 measures the preview |
| **Injection into Brave double-fired** | Seven dictations: `keystroke failed … readback unchanged`, then `paste failed … readback unchanged`. Both methods were posted; the outcome was recorded as failed | Chromium's AX value did not reflect the change. Text landed twice or a success was reported as failure. R2.3 fixes the rule |
| **No echo cancellation runs** | Every manifest: profile `aec=appleVoiceProcessing`, capture graph `vp=false` | The engine wraps a plain tap; voice processing is used only by the mic self-test. R1.4 decides by measurement |
| **Two stages are silent no-ops** | `wakeVerb` and `adapt.lexicon` fail the provenance contract on every span | Their output is discarded. R4 fixes or removes them |
| The earlier "quake brown fogs" report (≈55% WER) | Not reproduced; not in the log store | Likely a pre-1.7.13 build where the weakest model loaded first. Not pursued further |

### 2.3 Broken or unverified
- **Latch as specified does not exist.** The double-tap sets a hands-free flag that
  `DictationCoordinator.finalize()` clears on every finalize; nothing closes segments at endpoints while
  listening continues.
- **No updater.** `App/Core/Updater.swift` is a stub that reports `canCheckForUpdates == false`; the
  menu item is correctly disabled. Releases are manual 15 MB DMGs.
- **The shipped biaser cannot change a word.** `contextBiasing` is off; even on, it rescores tokens
  after greedy decoding.
- **Nine truncated Settings tabs** plus standalone Lab, Data Panel and enrollment windows.
- **Speaker identification** validated on synthetic audio only; the embedding backend has no weights.
- **No agent on the build machine has a microphone, a window server, or TCC grants.**
- **Names collide.** In code, "latch" is the persistent mute and the double-tap mode is "hands-free";
  "Timeline" is the input-event recorder. Section 4.7 fixes the vocabulary.
- **Notarization and Developer ID signing** are absent.

---

## 3. Prioritized scope

| Priority | Improvement | Reason |
|---|---|---|
| P0 | Delivery, focus guards, recovery, Chromium readback fix | Prevent misplaced, lost or duplicated text |
| P0 | Pill shows final text on land; preview measured and, if needed, swapped | The felt accuracy problem is the preview |
| P0, continuous | Real-audio benchmarks and actual-app tests | Choose by user outcomes |
| P1 | Ranked context, field-role formatting, continuation | Better entities; text that fits the destination |
| P1 | Gated Qwen3-ASR refinement | Better difficult speech within budget |
| P1 | One model stack, no picker; shorter onboarding | A working default without a choice |
| P1 | Latch that segments at endpoints; speaker safeguards | Sustained dictation with explicit control |
| P1 | One window, one menu | Capabilities and recovery easy to find |
| P1 | Inspectable, reversible learned corrections | Personalize without poisoning |
| P2 | Opt-in ambient capture and Timeline | Memory with explicit controls |

---

## 4. Architecture and interaction contract

```text
Microphone -> owned capture + ring buffer -> acoustic processing -> VAD
                                                                  |
                         +----------------------------------------+
                         v
                 streaming preview (EOU 120M today) ------------> PILL: live, provisional text
                         |
              key release / endpoint closes segment [t0, t1]
                         |
                 final recognition (Parakeet TDT v3)
                         |
              gate: worth refining? ---no---------------------------+
                         | yes                                      |
              Qwen3-ASR refinement + ranked context (deadline)      |
                         +------------------+-----------------------+
                                            v
                              destination-aware formatting
                                            |
                              ordered commit queue + destination check
                                            |
                                  +---------+----------+
                                  v                    v
                              insert once         hold for recovery
                                  |
                              verify (or mark unverified)
                                  |
                       delivered / uncertain / failed  ----> PILL: shows the final text on land
```

4.1 **Two surfaces.** The pill owns provisional text and revises it freely. The field receives committed
   text once, in spoken order, at segment boundaries, never retracted by the app. On land, the pill
   replaces the preview with the committed text for a beat, so what the user sees is what landed.
   Automatic refinement never revises inserted text; only an explicit, verified voice repair may.

4.2 **Hold.** Capture starts on key-down; release closes the final segment and is the endpoint. Long
   holds may close earlier segments at natural boundaries without ending capture.

4.3 **Latch.** Double-tap latches; endpoints close segments while listening continues. Single tap stops
   and finalizes. Escape cancels pending work; inserted text remains.

4.4 **Hard mute.** Stops every capture path, cancels pending insertion, discards uncommitted audio.
   Persists across relaunch; never auto-unmutes.

4.5 **Identity and ordering.** Session and segment identities reject stale results, preserve order, and
   prevent duplicate delivery. Buffers and the refinement backlog are bounded.

4.6 **One coordinator** owns start, stop, cancel and microphone arbitration across hotkey, menu,
   onboarding and meetings, on the existing ranked audio ownership.

4.7 **Vocabulary**

| User-facing | Meaning | Code (new) | Existing code to rename |
|---|---|---|---|
| Hold | push-to-talk while the key is down | `hold` | unchanged |
| Latch | double-tap; listening continues across endpoints | `latched` | `handsFree` |
| Mute | persistent hard mute | `muted`, `MuteController` | comments calling it the "mute latch" |
| Timeline | ambient transcript history in the window | `AmbientTimeline` | `InputTimeline` keeps its name and is never shown as "Timeline" |
| Held | committed text waiting for a destination | `held` | `FocusGuard` queue, with a new delivery rule |

---

## 5. Audio and recognition

### 5.1 Capture
- Capture-before-warm-up and preload exist. Failed starts and cancellation release ownership completely.
- Respect an explicit microphone choice; automatic selection avoids narrowband Bluetooth (exists).
  Handle unplug, reconnect and sleep/wake.
- **Echo cancellation is absent in production.** R1.4 measures three variants on the corpus: raw tap,
  raw tap + spectral gate (today), Apple voice-processing I/O + gate. Default chosen by WER; keep a
  bypass for evaluation.
- Preserve leading and trailing speech around VAD boundaries. Keep recording, quality, readiness and
  permission states distinct.

### 5.2 Preview
- The preview is what the user watches. Today it is the 120M EOU model's raw stream. R1.5 measures
  preview WER and latency on the corpus for two candidates: EOU 120M (today) and
  `PollingPreviewRecognizer` over TDT v3. Choose by measurement; both stay available.
- Preview text gets light formatting where cheap (capitalization, digits for spoken numbers) so it
  resembles the final text. It never claims punctuation it does not have.

### 5.3 Final and refinement
- **Final:** Parakeet TDT 0.6B v3. **Refinement candidate:** Qwen3-ASR 0.6B int8 on CoreML, with a text
  context prompt, by porting an MIT-licensed third-party Swift module (≈1,800 lines, gated
  `@available(macOS 15)` for its stateful decoder) into `Engine/ASRRuntime`, with attribution and the
  weights' Apache notice. No new SwiftPM dependency, no second runtime. The weights (1.2 GB) are already
  cached on the owner's Mac. Deployment target stays macOS 14; refinement shows as unavailable there.
- **1.7B is not the plan.** No CoreML build exists. An MLX route is opened only if 0.6B fails the R5
  gate on quality and 1.7B is shown, on the same corpus, to pass it. Recorded with numbers.
- Leaderboard figures, read speech, orientation only: Qwen3-ASR 1.7B ≈ 5.8, Parakeet TDT ≈ 6.0–6.3,
  Cohere ≈ 5.4 (rejected: 3.8 GB, no biasing). The 0.6B Qwen figure is not published; measure it.
- **Gate the second pass:** high streaming uncertainty, a context near-miss, non-English, or a long
  segment. Measure gate recall; do not assume the recognizer knows when it is wrong.
- **Deadline.** Final-segment refinement has a hard deadline (10.2). On timeout use pass-1; if none,
  hold for recovery. A late result never overwrites delivered text. Earlier segments refine off the
  critical path with a bounded backlog.
- **Provenance.** Record which pass produced a span; re-align word timing; never attach old confidence
  to different words. Mark unavailable confidence explicitly.

### 5.4 Model packaging
- **No bundled models and no updater in this revision.** The download path is verified, resumable,
  atomic and swept; the bug class bundling was meant to retire is closed. Bundling ~675 MB without
  incremental updates would make every patch a ~700 MB manual download at a cadence of days.
- **Remove the model choice.** One stack (TDT v3 + EOU 120M) installs on first run with the existing
  progress and integrity reporting. Qwen downloads only when refinement is enabled.
- Revisit bundling and an updater when there are users beyond the author.
- Sizes on disk: TDT v3 461 MB, EOU 214 MB, Qwen 0.6B int8 1.2 GB.
- Apple Silicon, macOS 14+. The binary is arm64 only; the Whisper "Intel fallback" is a placeholder.

---

## 6. Delivery, recovery and repair

```text
Capture -> Recognize -> Finalize -> Check destination -> Insert -> Verify or mark unverified
                                      |                           |
                                      +----> Held                 +--> Delivered (verified / unverified)
                                                                  +--> Failed
```

- Snapshot app, window, focused element, caret and surrounding text at activation; revalidate before
  each insertion. Same app does not mean same destination.
- Focus or target changes **hold** pending text. Returning focus alone does not insert it: offer
  **Insert here**, **Copy**, **Discard**, naming the destination. This reverses `FocusGuard`'s
  auto-delivery; its tests change.
- **Readback rule.** A method that was posted without error has *possibly landed*. If readback cannot
  confirm it, the outcome is `injected(verified: false)`, never a retry with another method. Only a
  method that threw before posting anything may fall through to the next. Chromium-based browsers get
  an adapter whose readback uses the selection or is skipped, and whose order is keystroke, then paste
  only on a thrown error.
- Reject secure fields (AX role) and apps on the never-inject list. If target safety cannot be
  established, hold for copying.
- Verified, unverified and failed are all surfaced. "Landed" copy means verified; unverified says so
  and exposes recovery. Never auto-retry an uncertain delivery.
- Finalized undelivered text stays in memory until handled or quit; warn before quitting with pending
  text. Persist only when history is enabled; never turn failed dictation into ambient capture.
- Errors name an action: "Destination changed — Copy text", "Microphone disconnected — Choose
  microphone", "No speech detected — Try again".
- Repair: **scratch that**, **no, <replacement>**, **put it back**, bound to the last committed region
  and only when that region still matches. Otherwise offer a suggestion. Never blind backspaces or ⌘Z.
- Silent correction stays off: `dualPath` keeps its default off; its `CorrectionLedger` backs "put it
  back". Repair does not depend on a live beam decoder.

---

## 7. Context, formatting and learning

```text
Explicit corrections + Dictionary  -- highest --+
Focused-window AX text ------------------------+--> rank / dedupe / cap 400 --> Qwen context prompt
Recent confirmed vocabulary -------- lowest ---+                                + refinement gate
App + field role + text before cursor --------------------------> formatting / continuation
```

7.1 The only consumer that can change a word is the Qwen prompt. The rescorer gets no work. Until R5,
   the list feeds the gate check and entity-recall measurement.

7.2 Visible words are the words about to be spoken; proper nouns are the dominant error class; a
   streaming CTC/TDT model cannot learn them. The reader exists; this plan gives it a consumer.

7.3 Bounded AX reads at activation and focus change; cache per target. No screenshots. Cap the prompt,
   strip instruction-like text, treat screen text as data. Discard after the session; exclude from
   history, diagnostics and sync; never to a provider without explicit consent. Degrade gracefully.

7.4 Format by field role as well as app: a terminal inside an editor gets terminal rules; preserve code
   identifiers; handle leading space, capitalization, paragraphs and mid-sentence insertion.

7.5 Learning: cap 400, tunable by entity recall and false insertions. Dictionary shows learned spelling,
   "heard as", origin, remove / forget with immediate effect. Document-sized or ambiguous pairs are
   rejected (exists). Fix `wakeVerb` and `adapt.lexicon` so they append provenance, or remove them.

---

## 8. Latch and ambient

| Mode / event | Behaviour |
|---|---|
| Hold | Capture only while activated; release finalizes |
| Latch | Continue across endpoints; persistent listening state; visible Stop |
| Focus changes while latched | Pause delivery, hold pending text, require explicit resumption into a named target |
| Speaker mismatch or uncertain, filtering on | Suppress insertion; never silently save another person's speech |
| Ambient enabled | Transcript into Timeline only; never type or act from ambient speech |
| Lock / sleep | Stop capture, cancel pending insertion; no silent resume |
| Hard mute | Stop every capture path; persist |

- Speaker identity is not directed-speech intent. Latch is an explicit dictation session.
- Enrollment is requested when enabling speaker filtering, never for hold-to-talk. Validate with real
  voices before any default-on.
- Ambient off by default, separate opt-in. When on: transcript only, enrolled user only, seven-day
  retention, no sync. Other speakers discarded unless broader capture is explicitly enabled.
- Timeline: search, source filters, delete, delete-all; expiry clears indexes. Audio retention is a
  separate choice. Indicators reflect actual microphone ownership.
- Wake words, wake verbs that act, and autonomous ambient actions are out of scope. `directedSpeech`
  stays off.

---

## 9. Product surfaces

9.1 **The pill and notch stay as they are today.** They do the job. This revision adds only what
   delivery needs, in the existing visual language: a *held* row with Insert here / Copy / Discard, an
   *unverified* variant of landed, and the final text shown on land. No new mark, no sound, no motion
   work. Model names, latency and thermal diagnostics live in Voice › Benchmark, not the pill.

9.2 **`DESIGN.md`** is written for the window, settings and onboarding only: typography, one accent,
   dark-first native macOS, spacing, contrast, state vocabulary, focus behaviour, reduced motion, error
   sizing, copy voice. It documents the existing pill states as they are. No web views anywhere.

```text
MENU                        ONE WINDOW (sidebar + detail)
status + microphone         Today / Timeline
dictate / latch / mute      Meetings
copy / recover text         Dictionary / Apps
start meeting               Voice (enrollment, mic, Benchmark)
open app / settings / quit  Privacy (egress log)
                            Settings
```

9.3 Left or right click on the glyph or idle notch presence opens the same menu. Explicit Stop and
   Mute during capture; destination focus preserved.

9.4 **Fold in:** Data Panel → Privacy; Lab → Voice › Benchmark; enrollment → Voice. Today prioritizes
   readiness, pending recovery and recent content.

9.5 **Onboarding:** Welcome → Microphone with a real level check → Accessibility → choose and try the
   key with a real landing in a practice field → Done. No model picker, no provider setup, no mandatory
   enrollment, no ambient gate.

9.6 **Privacy** states what is captured, saved and transmitted. Never claim literal zero network bytes.

9.7 Keep per-stage provider options. Do not label a local writing model available until one works; the
   act key stays off until configured.

---

## 10. Verification and release acceptance

10.1 **Corpus.** `Fixtures/real-room/builtin/` holds twenty real dictations with manifests; the WAVs
   are git-ignored, transcripts (Appendix A) and manifests are committed. Expand as needed.

| Check | Required evidence |
|---|---|
| Accuracy | Same recordings through baseline and candidates: WER, entity and number accuracy, false substitutions, first/last-word loss. Real room, names, pauses, actual microphone |
| Preview | Preview WER and first-word latency per candidate on the corpus |
| Refinement default | Useful gain on difficult speech, no clean-speech regression, latency and resources in budget. Sample counts recorded |
| Delivery | Notes, Mail, Brave or Chrome, Slack, VS Code, Terminal, a spreadsheet: empty and existing text, selection, mid-text insertion, repair, focus changes, clipboard. Disposable documents |
| Durability | 50 consecutive dictations plus cancel, quick release, cold start, device change, sleep/wake; no wedges, duplicates, or lost text |
| Performance | 10.2 targets; also endpoint delay, cold start, backlog, peak memory, thermal over 30 min latched |
| UI | Every pill row and window state exercised in the installed app; readable errors; real onboarding landing; mute |
| Install | Fresh install reaches a working first dictation with no model choice; existing installs keep their models; no duplicate download |

10.2 **Latency budgets** (baseline supported Mac, release build)

| Path | Metric | Target |
|---|---|---|
| Preview | first words after speech onset | p50 ≤ 300 ms |
| Parakeet final | pending text after release or endpoint | p50 ≤ 700 ms · p95 ≤ 1200 ms |
| Qwen, final segment | refined text after endpoint, else pass-1 | p95 ≤ 1500 ms deadline |
| Qwen, earlier segments | off the critical path | backlog ≤ 2 segments, else commit pass-1 |

Comparable measurements put Qwen 0.6B CoreML at 2–3 s per utterance. If the deadline is unmeetable in
hold mode, Qwen refines only non-final segments in latch mode and hold stays Parakeet-only. Recorded.

10.3 **Zero-edit rate** counts observable dictations only; report coverage separately. WER needs
   references; never infer it from the absence of edits.

10.4 A packaged app with unresolved gates is a candidate, not a reliability release.

---

## 11. Items, order and gates

```text
R0 DESIGN.md (window/onboarding) ∥ ──────────────────────────────────┐
R1.4 capture defaults ∥  R1.5 preview choice ∥                        │
R2 two surfaces + delivery + Chromium fix ──┬─► R3 latch / coordinator / mute ∥
                                            ├─► R4 context + formatting + learning ∥
                                            └─► R5 Qwen refinement (after R4.1)
R6 one stack + onboarding (after R2)                                  │
R7 one window (after R0, R6)  ◄───────────────────────────────────────┘
R8 ambient + Timeline (after R3, R7)
```

| Release | Items | What the owner gets |
|---|---|---|
| A | R0, R1.4, R1.5, R2, R4.1, R5 (benchmark; flag on only if gated), R6 | Preview that matches what lands, ordered commits, recovery, Chromium fixed, one model stack, short onboarding |
| B | R3, R4.2–R4.3, R7, R8 | Latch, field-role formatting, learning controls, one window, ambient Timeline |

### R0 — `DESIGN.md` for window, settings and onboarding (∥)
Scope: 9.2. Documents the existing pill as-is. Gate: every window and onboarding state specified;
reduced-motion and increased-contrast variants defined. Modules: `DESIGN.md`. Tests: none.

### R1 — Real-audio loop (R1.1–R1.3 done; R1.4 and R1.5 remain)
- **R1.4 Capture defaults.** Measure raw tap, tap + gate, voice-processing + gate on the corpus through
  the real chain; pick by WER; keep the bypass. Then harden: hot-swap, reconnect, sleep/wake, VAD edge
  preservation, distinct readiness / quality / permission states. Modules: `Engine/Audio`. Tests:
  `EngineTests`. Gate: a table of WER per variant; the default set from it; a hardware run of
  unplug-while-listening and sleep/wake.
- **R1.5 Preview choice.** Add per-file scoring against `script.md` to the replay harness. Measure
  preview WER and first-word latency for EOU 120M and polling-TDT on the corpus. Choose by measurement.
  Modules: `Engine/ASRRuntime`, `Lab/Harness`, `Tests/EngineTests`. Gate: the table; the choice
  recorded; both candidates selectable in Benchmark.

### R2 — Two surfaces, ordered commit, delivery outcomes, recovery (P0; Parakeet only)
- **R2.1 `Shared`:** additive `stability` (`provisional` / `committed` / `final`) on `TranscriptSpan`;
  session and segment identity; `DeliveryOutcome`. Nothing removed.
- **R2.2 `Engine`:** segment closure on release (hold) and on endpoint (latch); bounded ring and backlog;
  stale-result rejection by identity.
- **R2.3 `Injection`:** destination snapshot and revalidation; ordered commit queue; append-only writer;
  the readback rule from Section 6 (no second method after a posted one); a Chromium adapter for
  Brave, Chrome, Edge, Arc; `FocusGuard` changed from auto-deliver to held with Insert here / Copy /
  Discard; secure-field refusal; never-inject list; quit warning.
- **R2.4 `App`:** the pill shows the final text on land; unverified variant of landed; held row with
  the three actions; readable error copy. Existing visual language only.
- **R2.5 `Actions`:** scratch that, no <replacement>, put it back, bound to the last committed region.
- Depends on: nothing. Gate: delivery matrix on hardware in the listed apps including Brave; latency
  targets met; 50-dictation durability; zero duplicate insertions in the focus-change fuzz; the Brave
  session from 2.2 re-run with every outcome verified or honestly unverified, none failed.

### R3 — Coordinator, latch, mute (∥ with R4; after R2)
New behaviour, not polish: endpoint-driven segment closure while latched on the R2.2 model; rename
`handsFree` → `latched`; one coordinator over the ranked audio ownership; latch pause on focus change
with named resumption; lock / sleep stop; mute persistence verified across relaunch; speaker-filter
suppression with an honest unavailable state; Escape. Modules: `App/Services`, `App/Core`,
`Engine/Speaker`. Gate: state-machine tests for every Section 8 row; hardware run across three apps
with focus changes and one sleep/wake; mute survives relaunch.

### R4 — Context, formatting, learning (∥ with R3; after R2.1)
- **R4.1** rank and dedupe the four sources; cap 400; prompt builder with instruction stripping;
  per-session discard; gate-check consumer. Fix `wakeVerb` and `adapt.lexicon` provenance.
- **R4.2** field-role detection; terminal-in-editor rule; continuation from text before cursor; code
  identifiers preserved.
- **R4.3** Dictionary UI: learned spelling, heard-as, origin, remove / forget; recall and
  false-insertion counters in Benchmark.
- Modules: `Pipeline`, `Engine/Biasing`, `Engine/Adapt`, `App/Settings`. Gate: recall and
  false-insertion numbers on the corpus with and without the list; formatting goldens for terminal,
  editor, chat, mail; removal provably stops influence; no contract violations in the log.

### R5 — Qwen3-ASR refinement, flagged (after R2, R4.1)
- **R5.1** port the CoreML module into `Engine/ASRRuntime/Qwen3ASR/` with licences; availability gate;
  `RefinementSession` protocol with mock and Qwen 0.6B; weights from the existing cache or
  download-on-enable.
- **R5.2** refine stage: replace text in place, preserve range, re-align timing, provenance; deadline and
  backlog from 10.2; timeout → pass-1.
- **R5.3** gate policy with tunable thresholds; refinement mode Auto / Always / Never in Voice.
- **R5.4** Benchmark: Parakeet vs Qwen vs two-pass on the corpus and fixture suites; latency and memory.
- Gate: default-on only with useful gain on difficult speech, no clean-speech regression, deadline met
  (or the latch-only configuration adopted and recorded), thermal acceptable over 30 min latched.
  Otherwise flag off and recorded. Either is a valid completion.

### R6 — One model stack and onboarding (after R2)
- **R6.1** remove the tier picker; TDT v3 + EOU install on first run; retire the CTC and Whisper entries
  from the UI; Qwen only on enable.
- **R6.2** the 9.5 onboarding with a real mic check and a real landing.
- Gate: fresh install on a clean account reaches a working first dictation with no choice; existing
  installs keep their models; install duration and cold start recorded; onboarding under two minutes.

### R7 — One window, one menu (after R0, R6)
Sidebar + detail per 9.2; fold Data Panel, Lab and enrollment in; glyph and notch open the same menu.
**The pill is not touched.** Gate: every window state exercised on notch and notchless displays; no
standalone windows remain.

### R8 — Ambient and Timeline (after R3, R7)
Separate opt-in; enrolled-speaker-only; seven-day retention with index clearing; search, filters,
delete, delete-all; audio retention separate; indicator tied to ownership. Reuse meeting storage.
Gate: retention and deletion verified; no ambient text reaches an injection path.

---

## 12. Do not build

1. Rescorer improvements. It cannot change words.
2. Destructive re-editing of committed text: backspaces, AX value writes, ⌘Z.
3. An updater or bundled models.
4. Cohere Transcribe or a streaming-model swap for accuracy.
5. Cloud streaming as a default.
6. Wake word, wake verbs that act, autonomous ambient actions.
7. A new action engine, a new sync system, mobile work, a general assistant.
8. Intel work or an advertised Intel fallback.
9. Silent automatic correction; `dualPath` stays off.
10. A second inference runtime or Qwen 1.7B, except under the 5.3 condition.
11. Raising the deployment target to macOS 15.
12. **A new pill, notch, mark, or sound.**

---

## 13. Decisions resolved

| Question | Decision | Reason |
|---|---|---|
| Is the accuracy failure in capture or the model? | Neither. Final recognition is clean on real audio; the preview is what looked wrong | R1 measurement, 2.2 |
| What does the pill show? | Preview while listening; the **final** text on land | The user judges accuracy by the pill |
| Pill and notch design | Keep as they are | They do the job; redesign is cost without a measured problem |
| Chromium readback | Never retry after a posted method; dedicated adapter | Brave session double-fired seven times |
| Qwen route | CoreML 0.6B port, no MLX, no 1.7B | Weights on disk, no new runtime, no 1.7B build exists |
| macOS 15 requirement of that module | Availability gate; target stays 14 | Refinement is optional |
| Qwen misses the hold deadline | Latch-only refinement | Pipeline depth hides it there |
| Bundle models / updater | No | Download bugs already fixed; 700 MB patches at this cadence |
| Intel | Not advertised | arm64 binary; placeholder fallback; no machine |
| Echo cancellation | By R1.4 measurement | Profile names it, engine never enabled it; nobody measured either |
| Focus-return delivery | Hold and ask; never auto-insert | Auto-delivery can land text where the user did not choose |
| Ambient default | Off, transcript-only, enrolled speaker, seven days, no sync | Trust |
| Enrollment in onboarding | Optional | Hold-to-talk never needs it |
| Other speakers while latched | Suppress; discard unless broader capture enabled | Identity is not intent |
| "Zero bytes out" headline | No | Provider traffic and optional checks exist |
| Recordings in the repo | WAVs git-ignored; transcripts and manifests committed | A voice in git history is permanent |
| Two releases | Yes | Fifteen patches in ten days; keep a candidate installable |
| Verification cadence | One owner session per candidate, plus one for R2 | Owner is not the bottleneck |

---

## 14. Rationale

14.1 **Why the preview is the felt accuracy.** The owner watched the notch during twenty dictations
   and saw most of them wrong: pauses, breaks, numbers, commas. The landed text for the same twenty was
   right. The notch shows a 120M streaming model's raw tokens with no punctuation; the field gets the
   0.6B model's formatted output. Showing the final text on land closes that gap without touching the
   model; measuring the preview decides whether the preview model should change too.

14.2 **Why commit at the endpoint rather than on partial agreement.** Committing on agreement lands
   text sooner but commits first-pass text, which forecloses refinement. The pill keeps perceived
   latency low; only the field waits, and sentence-granular arrival reads as deliberate.

14.3 **Why injection is append-only.** Retracting means backspaces or AX writes, which break in
   Electron, web fields and terminals, fight autocorrect, and race the cursor.

14.4 **Why a posted method is never retried.** Readback cannot tell "did not land" from "landed but
   the AX value is stale". The Brave session proved the second case is common. The only safe outcome
   after a posted method is *delivered, unverified*.

14.5 **Why pipeline depth makes a second pass affordable.** Only the final segment is on the critical
   path; the deadline and backlog bound keep that true under throttling.

14.6 **Why the screen needs a new consumer.** The reader exists; the biaser cannot act on it. A
   recognizer that accepts a text context is the first path where the list changes the output.

14.7 **Why two surfaces before any new model.** Most of the felt improvement with zero new inference,
   and the substrate the second pass needs. Shipping R2 with Parakeet alone is a valid outcome.

14.8 **Why neither bundling nor an updater.** Shipped fixes closed the bug class. Without incremental
   updates every patch becomes a ~700 MB manual download. With one user, both are cost without benefit.

14.9 **Why the pill stays.** It works, the owner is used to it, and every accuracy finding pointed at
   what it *shows*, not how it looks. Fix the content, keep the container.

14.10 **Why port a CoreML module rather than add MLX.** One runtime, one dependency, weights already on
   disk, comparison can start today. If 0.6B fails on quality, those numbers justify opening 1.7B.

14.11 **Why ambient is opt-in even as transcript-only.** Another person's words in a screenshot read
   as surveillance whether or not audio was kept.

---

## 15. Owner actions

| # | Action | Status |
|---|---|---|
| 1 | Record the real-room corpus | **Done**, 20 utterances, built-in microphone. One microphone is enough; a second pass is not available on this machine |
| 2 | Allow recordings into the checkout | **Done** (`Fixtures/real-room/`, WAVs git-ignored) |
| 3 | Create an update channel | **Cancelled** with the updater |
| 4 | Hardware verification sessions | **Waits**: one after R2, then one per release candidate, from a numbered checklist the agent supplies |

If another recording session is ever needed: a build with the recorder (1.7.15+), Settings › General ›
Microphone, pick the device explicitly, turn on *Save recordings of what I dictate*, read the script one
dictation per line, copy the folder out before any second pass (only the newest 20 are kept), turn the
switch off.

---

## Appendix A. Real-room recording script

Reference transcripts, scored verbatim after lowercasing and punctuation stripping.

```text
01  The quick brown fox jumps over the lazy dog.
02  Send the deck to Priya before the standup tomorrow at four.
03  Can you book a table for six at Kothari's on Thursday evening?
04  My flight lands at 11:45, so let's meet at the gate around noon.
05  The invoice total is 2,340 rupees, not 2,430.
06  Rename the variable to user session token and push it to the main branch.
07  I think we should, um, wait for the numbers before we decide.
08  Order two of the large ones and one of the small ones.
09  Hey, are you free for a quick call?
10  The results were significant, although the effect size was small.
11  Their new address is 14 Carter Road, Bandra, Mumbai 400050.
12  Remind me to call Dr. Menon on Monday morning.
13  Turn off the recording when you are done.
14  What time does the museum open on Sundays?
15  She said the quarterly report would be ready by Friday, but I doubt it.
16  Please transcribe this exactly as I say it, including the pause... here.
17  Run swift build with the isolated scratch path and send me the output.
18  We have three options: ship now, ship next week, or do not ship at all.
19  The microphone is about an arm's length away and the window is open.
20  Thanks, that is everything for today, talk soon.
```
