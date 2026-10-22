# VoicePlus Improvements V5

Date: 2026-10-01 (rev 6) · Baseline: 1.12.12 · Build plan: `VoicePlus_Improvements_V5_Build.md`
Sources: FluidVoice teardown · unbuilt remainder of V4 / Wave 1 build doc §8 / Pending §B / `progress.md` · code re-audit (rev 2) · **`VoicePlus_Investigation_2026-10-01.md`** (16 items, §Q) · public models and datasets researched 1 Oct 2026.

Legend: **[new]** build · **[dark]** built, off or unreachable · **[take]** port from FluidVoice · **[carried]** in V4, never built · **[fix]** wrong today · **[keep]** protect · **[later]** on the cards, not now · **[owner]** needs the owner · **[decide]** open decision · **[resolved] / [approved]** decided by the owner

---

## 0. Standing rules

1. **Market first, train last.** First look for an existing model (incl. third-party fine-tunes). Train or fine-tune only when §V shows nothing off the shelf comes close. Format conversion (→ CoreML/GGUF) is not training.
2. **No owner-recorded datasets.** Never ask the owner to record data. Evaluate on **public datasets** (§V); mixing public noise into public speech is allowed. The owner's 20 real-room recordings are a smoke test only — never a gate.
3. **Gates are market-referenced.** Ship a stage when it does not degrade the published number of the same model on the same public set, and beats what it replaces on that set.
4. **Re-validate.** Every `DECISIONS.md` decision drawn from `Fixtures/real-room/builtin` or the synthetic directed-speech fixtures is provisional until re-run on §V.
5. **Explicit always works.** Every capability stays usable through explicit triggers (key, menu, pill, wake verb) whatever the ambient setting.

---

## R · Corrections log

**Rev 6 — coherence pass**
- HW4 resolved: **minimum macOS is 15** (new J7). `Package.swift` `.macOS(.v15)`, `CLAUDE.md`, installer and the `@available(macOS 15, *)` guards all change together; the "macOS 15+" notes in §HW are no longer exceptions.
- Stale wording fixed: "Tier 3" / "tiers" / "cascade" → the three *layers* of §O-d; the `acceptsLocal` flip moved from CU9 to CU8 where it belongs; N2 now names the *lower-middle* band (the upper-middle band is ask/confirm); HW2 no longer second-guesses §O-d's model choice — Kev is the default, Laya is the HW3 fallback under memory pressure.
- `decision-1.0-lex/kai` removed from §FI (never a candidate in §O-d; Gemma tokenizer terms; 1.9 GB for three graphs).
- Trailing numbered sections renamed to the lettered scheme (CM, SC, FV, CP, DEC); critical path now includes J7, J6 and HW1.

**Rev 5**
- CLM-8B dropped (owner). New §HW: measured sizes for every on-device model, a 16 GB budget, residency rules (HW1–HW5), and the macOS 15 floor question (HW4).
- CU8 default local LLM is now RAM-dependent: Qwen3.5-2B on 16 GB, 4B on ≥ 24 GB. CU9: only one 4B model loaded at a time.

**Rev 4**
- **§O-d reframed.** Rev 3 presented the decision layer as "cheapest first", which misread the owner: the only constraint is off-the-shelf before training; quality decides everything else. Now: explicit rules first (because explicit must win), then one decision model on *every* ambient utterance asking several questions at once — the Toothless/Jev pattern from the X post, read directly this time.
- **Rubric 5** gained an ask/confirm band between act and note.
- **§CU** corrected: a logged-in provider was never required — Ollama/LM Studio already route to `act.planner`. CU8 ships one local instruct model shared by the planner, Ask, notes, Hinglish cleanup and explanations.
- Decisions LR4, M13, J6 resolved.

**Rev 3**
- **A4 removed — it was wrong.** The investigation shows TCC grants carry across builds since 1.6.4 (designated requirement = bundle identifier). Running from the DMG was not a confound. Only a stale LaunchServices record remains (Q16).
- **J4 rationale fixed.** Developer ID is still needed for distribution (Gatekeeper), not for TCC.
- **Training rule softened** (rule 0.1): LoRA (F5) and a trained directed-speech classifier (L9) are back as **[later]**.
- **Audio storage reversed** by owner decision: keep storing all dictation audio (F3).
- Owner decisions applied: ambient modes (L1), noise mixing allowed (rule 0.2), Roman default script (LANG), keep Qwen refinement (D7), meeting recording default **Always** (M5).

**Rev 2** (summary): A2 models are bundled now · 6 of 7 flags off · B1 needs `parakeet-ctc-110m-coreml`, not the catalog's TDT-CTC hybrid · D1 Hindi via wrapper unverified · old K12 was false (meeting never pre-empted; two uncoordinated mic graphs) · 20-recording conclusions withdrawn.

---

## Q · From the 1 Oct investigation (16 items)

Full evidence: `VoicePlus_Investigation_2026-10-01.md`.

**P0 — safety and correctness**
- **Q1 [fix]** Newlines never send: Electron/Cursor type `\n` as ⇧↩; Google Sheets via a spreadsheet path (ties to E2).
- **Q2 [fix]** Expose Electron text fields: set `AXManualAccessibility` at key-down (detect `Electron Framework.framework`, cache per pid); `AXEnhancedUserInterface` for Chromium (on, with a switch). **Also unlocks screen context (E1/B2) in Claude, Slack, VS Code.**
- **Q3 [fix]** Settle before judging: `AXObserver` value/selection-changed, polling fallback ~30 ms up to ~400 ms.
- **Q4 [fix]** Unreadable field → plain "Inserted in <app>" (no ✓), auto-clears; sticky "⚠ Couldn't confirm" only when a settled readback ran and the text is absent. Update DESIGN.md D06, :51, :306, :468 (revives V4.20).
- **Q5 [fix]** Ribbon independent of verification: caret `AXBoundsForRange` → text-marker caret → element frame → window.
- **Q6 [fix]** Pill follows the work: caret's screen → focused window's screen → active screen → mouse; re-chosen every turn.
- **Q7 [fix]** "On screen" = visible on the pill's chosen display; chin suppression uses it.
- **Q8 [fix]** Self-healing pauses: rebuilt from real state at present and every ~100 ms; a cause-less pause >2 s is dropped and logged; focus only via keyboard navigation, cleared each turn.
- **Q9 [fix]** Pill and chin survive "Hide Others" (`canHide = false`); remove `.hiddenApp`.

**P1 — permissions and copy**
- **Q10 [fix]** Live microphone status (re-read on activation, before refusal, on TCC change) — "Later" proven viable.
- **Q11 [fix]** Input Monitoring: re-create the legacy tap on a fresh grant; confirm with `TapLiveness`.
- **Q12 [fix]** Pause lines per "Pause states — simplified"; empty draft → "Nothing was typed."

**P2**
- **Q13 [new]** Persisted diagnostics: pill placement, orderFront/Out reasons, every pause/resume, every landing verdict.
- **Q14 [new]** Opt-in OCR confirmation for canvas editors via `ScreenTextService` (off by default). **Merges with K9** (caret OCR band) — one build.
- **Q15 [fix]** CoreML crash hardening: on `Refinement.withDeadline`, let the in-flight prediction finish before releasing the model.
- **Q16 [owner]** One-time: `lsregister -u` the stale `/Volumes/VoicePlus 1.12.10/VoicePlus.app`, then `-gc`.

---

## O · Orchestration: how every mode works together

**Yes — coordination is not just meeting + dictation.** Dictation, edit/transform, computer use, notes, ask, meetings, ambient and lip input all compete for the same audio, the same user attention and the same destinations. Today each owns its own path (two mic graphs, latch-only ambient, separate act key, no notes). They need one framework.

**O-a · Shape**
```
 Sensors            Perception                 Decide (one per utterance)        Capabilities
 mic ─┐            VAD · ASR · speaker id   ┌─ explicit trigger?  ── yes ──► that capability
 system audio ─┼─► near-field · prosody  ──►│        no
 camera ─┘         lip activity / VSR       └─ ambient mode? ──────── decision model ──► dictate · edit · act (CUA)
                   context (app, FieldRole,                                             · note · ask · ignore
                   meeting active, history)                                     Recorders (always, if on): meeting · timeline
```
- **O1 [new] One capture graph, many subscribers.** Mic (+ system audio + camera when on) opened once; consumers subscribe via `AudioPipeline.Broadcaster`. `SessionCoordinator` changes from *exclusive owner* to *arbiter of intent*. Replaces old K12/M14.
- **O2 [new] Recorders vs capabilities.** Meeting and ambient timeline are *recorders*: they keep everything (if on) and never act. Dictation, edit, act, note, ask are *capabilities*: exactly one owns each utterance. A capability's output is tagged on every running recorder ("dictated", "command", "note").
- **O3 [new] One decision per utterance**, emitted as `{owner, confidence, reason}` and logged (Q13).

**O-b · Rubric (precedence, top wins)**
1. **Stop / cancel / mute** pre-empt everything, always.
2. **Explicit trigger** decides outright: hold key → dictate; act key → act; wake verb (`type`, `send`, `note`, `<app>`) → that; selection + key → edit; pill buttons.
3. **Who spoke**: only the user's voice (speaker id + near-field + lip activity) may start a capability. Other voices may only be *recorded*.
4. **Ambient mode** (L1): Off → nothing inferred · Listen & note → infer, but only to Notes · Listen & act → infer any capability.
5. **Confidence bands** (ambient only): **high → act** · **upper-middle → ask / confirm** (pill shows "Did you mean …? — say yes / tap", one tap or one word; the utterance is held, not lost) · **lower-middle → Note** · **low → ignore** (recorders still keep it). Band edges are calibrated on §V/T1, and "Not for you" corrections move them.
6. **Reversibility** (Bet 7): reversible runs · semi gets an undo toast · irreversible needs a spoken "confirm" or click — an ambient utterance can never confirm itself.
7. **One active capability**; a new utterance during a running agent action goes to Notes unless it is stop/confirm.

**O-c · Concurrency matrix (what happens when…)**

| Already running → / new input ↓ | Meeting recording | Latch session | Agent (CUA) running | Ambient (note/act) |
|---|---|---|---|---|
| Hold key | Dictates; tagged "dictated" in meeting | Takes over that turn | Goes to Notes (unless stop) | Explicit wins |
| Double-tap (latch) | Latch output → Notes, tagged in meeting | — | Notes | Explicit wins |
| Act key | Acts; tagged "command" | Pauses latch for the turn | Replaces only if stop/confirm | Explicit wins |
| Ambient utterance | Recorded; may also act/note per mode | Latch owns it | Notes | Decided per rubric |
| Remote voice (system audio) | Recorded only | Ignored | Ignored | Ignored |

**O-d · The decision layer — best quality first; cost is not the criterion**

Owner's rule: use whatever decides best, on every utterance if that is what decides best. Off-the-shelf before training; nothing else is a constraint. So this is not a cost cascade — it is three layers that each do something the others cannot.

- **Layer 0 — explicit, deterministic.** Explicit triggers, `WakeVerbGrammar`, `ActIntentParser`, existing `GatekeeperStage`. This runs first because rule 0.5 says an explicit instruction must win outright, not because it is cheap. If the user pressed a key or said "type", no model gets a vote.
- **Layer 1 — one decision model on every ambient utterance.** This is the Toothless pattern from the X post (now read): Jev answers *several questions at once* about each utterance — directed at the AI? a continuation of an earlier topic? something an agent or the internet can help with? — and the combination decides. Our version asks the same way, one call per utterance, using whichever model wins on §V/T1:
  - **Kev-0.8B CoreML** (16 typed questions per call, calibrated, ~30 ms GPU) — the direct open equivalent of Jev; **first candidate**.
  - **Intern-Decision-0.8B CoreML** — same shape, 8–16 fields, int8 variant.
  - **Laya CoreML** (multilingual mmBERT) — if Hinglish utterances decide badly on the Qwen-based two.
  - ~~CLM-8B~~ — **dropped** (owner): does not fit a 16 GB Mac alongside ASR (§HW).
  - **Jev (TypeSafe)** — paid cloud; only as a reference to beat.
  The questions, asked together every time: *addressed to the computer? · continuation of the last exchange? · complete, or still speaking? · which capability (dictate / edit / act / note / ask / ignore)? · needs the agent or the internet? · worth keeping as a note even if ignored?* Not a tiny-classifier pre-filter: GLiClass/Laya are only used if §V shows they decide *better*, not because they are faster.
- **Layer 2 — what to do, once we know it is a command.** Retrieval over the 200-entry action catalogue (embed every action once, rank per utterance) → **CUA-S1-4B** picks the element from the AX tree → generative planner only for multi-step goals (§CU8 for the local one).
- **O4 [new]** All three layers behind one protocol so any model swaps by §V result; log every decision with its question-level probabilities (Q13) so misfires are diagnosable.
- **O5 [new]** Context passed on every call: frontmost app, `FieldRole`, focused field y/n, meeting active, last N utterances and the last decision (decide over history — the "continuation" question needs it), other voice heard recently, lip activity, prosody (`DirectedSpeechFeatures`).
- **O6 [later]** Train our own directed-speech model only if none of the above clears the bar (= L9).

---

## X · Implemented but dead / unreachable

- **X1 [fix]** Silero VAD never ships (not in catalog or installer); users get `EnergyVAD`; owner's Mac borrows Silero from another app's cache. → C6.
- **X2 [dark]** R4.1b ranked context (`ContextSession`, `ContextRanker`, `PromptBuilder`, `ContextGate`) never built from `App/`.
- **X3 [dark]** Harvester built every launch; only consumer is the inert biaser.
- **X4 [dark]** `LiveAXFocusedWindowText` superseded, unreferenced.
- **X5 [dark]** Beam/scripted decoders, `ContextRecallProbe` — test/Lab only.
- **X6 [dark]** Per-recipient personas: nothing writes `thread.participants`.
- **X7 [dark]** `IndicASRBackend`: only unavailable + mock.
- **X8 [dark]** `VoiceProcessingCaptureSource` (Apple AEC/NS/AGC): self-test only.
- **X9 [dark]** Neural AEC shells (`DTLNAEC`, `LocalVQEAEC`, …) — weights now exist: `FluidInference/localvqe-coreml` (§FI).
- **X10 [dark]** `Qwen3StreamingManager` unreferenced; refinement behind its flag.
- **X11 [dark]** `EmbeddingLabeler` unreachable (`enrolledUserEmbedding: nil`) → meetings only know You/Others.
- **X12 [dark]** `SessionCoordinator.Requester.meeting` unused → O1.
- **X13 [dark]** Ambient capture switch discards every segment; latch-only.
- **X14 [dark]** Ambient glyph gated on `directedSpeech` (off).
- **X15 [dark]** Meeting notes are extractive only.
- **X16 [dark]** Meetings Ask disabled; providers exist but aren't routed.
- **X17 [keep]** `TrainingPairStore` WAV clips — keep (owner decision), extend per F3; `LoRAAdapterStub` stays a stub until F5.
- **X18 [fix]** `RouteChoice.auto` docs say cloud fallback; app treats Auto as local-only.
- **X19 [dark]** Unreferenced: `ZeroEditMenuView`, `CorrectionPopoverController`, `CorrectionMenuBuilder`, `SectionBannerView`, `PillKeyCap`, `PillMarkTarget`, `PillMarkUnderlines`, `MarkFragments`, `SpoolSilenceTracker`, `RoutedStage`, `CloudASRCopy`, `SNREstimate`, `DeterministicActionLayer`, `RepairCommandCoordinator`.
- **X20 [dark]** Flags off: `contextBiasing`, `dualPath`, `cloudASR`, `directedSpeech`, `previewBackend`, `qwenRefinement`.
- **X21 [dark]** Computer use is built but **off by default** and its planner has no local model (§CU).

---

## BL · Backlog

### A · Hygiene
- **A1 [fix]** Biasing inert on the real path → replace with B1 or delete X3/X5.
- **A2 [fix]** Stale `BundledModel` doc-comment.
- **A3 [fix]** Verdict per X20 flag, measured on §V.

### B · Accuracy — entities
- **B1 [take]** Two-manager CTC boosting; new download `parakeet-ctc-110m-coreml`.
- **B2 [dark]** Feed `RankedContext` into the cleanup prompt (D2).
- **B3 [new]** Real N-best alternates for voice repair.
- **B4 [new]** Error pairs from §V public sets (evaluation).
- **B5 [new]** Evaluate **Parakeet Ultra** (CC-BY-4.0; vendor: English 6.26→5.80, noise 6.72→5.82, FLEURS 11.62→9.55 vs v3) and **Parakeet Redux** (220 MB ternary). Drop-in for v3; needs a FluidAudio bump (`.ultra`/`.redux` not in our pin).

### C · Accuracy — acoustic
- **C1 [carried]** Wire Apple VP-IO (X8); measure on VOiCES.
- **C1b [new]** Alternative: **LocalVQE CoreML** (Apache-2.0, AEC + NS + dereverb, 4.8M params) — fills X9; needs FluidAudio bump (`LocalVqeManager`).
- **C1c [take]** WebRTC AEC3 only if both fail.
- **C3 [new]** Narrowband Bluetooth warning.
- **C4 [new]** Smart Turn endpointing.
- **C5 [new]** EOU 160 → 320 ms.
- **C6 [fix]** Ship Silero: add `FluidInference/silero-vad-coreml` to catalog + installer.

### D · Cleanup layer
- **D1 [new]** Wire NeMo ITN (`FluidAudio.TextNormalizer`); locale from LANG (en-IN lakh/crore).
- **D2 [new]** Cleanup LLM behind the guard (§CM); evaluate via the existing Ollama/LM Studio path first, then ship via the llama.cpp XCFramework (one runtime, shared with CU8).
- **D3 [new]** Output guard.
- **D4 [new]** Delimited templates.
- **D5 [take]** Idle unloader + prewarm.
- **D6 [later]** Speculative decoding.
- **D7 [keep]** Qwen refinement kept (owner). Re-measure on §V to tune when it runs.

### E · Screen context
- **E1 [dark]** Document/thread text (`AXWindowReader`) into the cleanup prompt — now reachable in Electron apps via Q2.
- **E2 [new]** Spreadsheet cell `FieldRole`; Excel/Sheets/Numbers in `AppCategoryTable`; with Q1.
- **E3 [new]** Web form labels.
- **E4 [new]** Extend `AppCategoryTable`.
- **E5 [new]** Browser sub-app routing by URL/title.
- **E6 [fix]** Populate `thread.participants` or delete per-recipient overrides.

### F · On-device personalisation (learns from you; nothing leaves the Mac)
- **F1 [new]** Persona auto-draft updates from accepted/edited output.
- **F2 [new]** Prompt + dictionary + style feeding the chosen models.
- **F3 [new]** Store **all** dictation audio (not only corrections) with transcript + final text; retention setting and disk cap; never synced unless chosen. Reuses `UtteranceRecorder` / `TrainingPairStore`.
- **F4 [fix]** Verify Sync end-to-end.
- **F5 [later]** LoRA adapter on the user's own audio + corrections (`Engine/Adapt` seam exists) — only after off-the-shelf + F2 prove insufficient on §V.

### G · Multilingual
- **G1 [new]** Evaluate third-party Hinglish ASR: Srota `moorlee/qwen3-asr-0.6b-hinglish` (Apache-2.0; fits our Qwen3-ASR port after conversion), `smajji/nemotron-hinglish-v1`, `dkubeio/DKube-asr-hinglish-v1-0.8B`, `Trelis/whisper-hinglish-preview`.
- **G2 [take]** Nemotron 3.5 Streaming Multilingual — CoreML at `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`.
- **G3 [new]** Script handling → §LANG.

### H · Routing and agency
- **H1** → §O / §L.
- **H2 [new]** Measure the live Gatekeeper's confusion matrix.
- **H3** → §CU.
- **H4 [new]** Time-aligned gesture binding for deixis.

### I · Product surface
- **I1 [new]** First-run expectation-setting.
- **I2 [dark]** Surface the zero-edit counter (`ZeroEditMenuView`).
- **I3 [new]** "Why did it write that?" per-stage diff.
- **I4 [keep]** No telemetry.

### J · Engineering
- **J1 [fix]** Timing-flaky suites.
- **J2 [fix]** CI dead.
- **J3 [fix]** Remove unused `.build-*`.
- **J4 [owner]** Developer ID + notarization for distribution.
- **J5 [new]** Updater.
- **J6 [approved]** FluidAudio bump (unlocks B5, C1b) and **FluidUse** dependency (Apache-2.0; unlocks §O, §CU) — approved by owner 1 Oct; record both in `progress.md` when added.
- **J7 [resolved]** **Minimum macOS 15.** `Package.swift` `.macOS(.v15)`, `CLAUDE.md` ("macOS 14+" → 15), `Packaging/make_app.sh` `LSMinimumSystemVersion`, drop the `@available(macOS 15, *)` guards in `Engine/ASRRuntime/Qwen3ASR`. The CLT's `MacOSX15.2.sdk` already builds it. FluidVoice requires 15 too.

### K · Carried from V4
- **K2** Near-field level gate · **K3** speaker-filtering toggle · **K4** turn-anchored voice · **K5** Voice Isolation + AirPods wideband · **K6** analyzer floor hold · **K7** one ITN preview/final (with D1) · **K8** prosody punctuation (eval: LibriSpeech-PC) · **K9** caret OCR band (= Q14) · **K10** context ladder · **K17** Silero in tests (with C6) · **K18** AX own-pid guards (10 sites) · **K19** pill up ~27 s · **K20** last `handsFree` wire key · **K21** Qwen UI copy · **K22** release tags.
- **K16** (AirPods session) and **K23** (hardware-unverified surfaces) → T1.

---

## M · Meetings

**Today:** manual Start recording + opt-in detector (camera, calendar); mic + system audio; You/Others only; extractive notes; Ask disabled; audio not retained.

**M-a · Modes**
- **M1 [new]** Video call — both legs diarized.
- **M2 [new]** In-person — mic diarized.
- **M3 [new]** Hybrid — both legs, cross-leg echo veto.
- **M4 [new]** Auto-pick mode; user override in the panel.
- **M5 [new]** Save meeting recording — **default Always** (owner); options 7 days / Never.

**M-b · Identifying participants (no enrollment phrase)**
- **M6 [new]** The user's voiceprint from dictation turns (passive).
- **M7 [new]** Live labels: **Sortformer CoreML** (`diar-streaming-sortformer-coreml`, v2.1 "more robust in meetings").
- **M8 [new]** Final labels: offline re-diarization after the meeting.
- **M9 [new]** Embeddings: WeSpeaker (shipped) vs **CAM++ CoreML** (192-d, ANE) — pick on §V (VoxConverse / AMI).
- **M10 [new]** Voiceprint library: mapped clusters saved; quality-weighted running mean; auto-match (high = applied, middle = suggested).
- **M11 [new]** Name hints: calendar invitees · active-speaker highlight in Zoom/Meet/Teams (AX/OCR, time-correlated) · addressed names in the transcript ("Thanks, Priya") via **GLiNER2 CoreML** NER · lip activity for people on camera (§LR).
- **M12 [fix]** Wire X11 first.

**M-c · Descriptive labels instead of "Other person N"**
- **M13 [new]** Label = the most distinguishing 2–3 attributes, unique within the meeting, e.g. "Deep voice · near the laptop · 11:02–11:40", "Higher voice · on the call (Zoom) · probably woman", "Soft voice · across the room".
- Attributes (computed, never sent anywhere):
  - **Where**: on the call (system leg) · near the laptop (mic, high level, dry) · across the room (mic, low level, reverberant).
  - **Voice**: pitch band low/mid/high (F0 median) · pace (words/min) · loudness.
  - **Perceived gender** — "probably man / woman", **on by default, switchable in Settings** (owner). It is a guess from pitch and is often wrong; the label always says "probably".
  - **When / where**: time span present · meeting title · app (Zoom, Meet…).
  - **Role in conversation**: talk share % · first or last speaker · asked most questions.
  - **Language**: e.g. "speaks Hindi-English".
  - **Quote**: first distinctive phrase they said.
  - **Candidate name**: from M11, shown as "maybe Priya".
- Hover card shows every attribute + an audio snippet; one click maps to a contact (feeds M10).

**M-d · Detection** — calendar (exists) · camera (exists) · mic used by another process · call app running · browser tab URL/title via AX. Settings: detected-meeting notifications · per-app don't-notify list · reminder at start time · calendars · auto-record calendar meetings (off) · save recording · auto-export folder · post-meeting hook (JSON on stdin).

**M-e · During** — **M14** dictation/act/latch during a meeting per §O matrix · **M15** live transcript (exists) · **M16** live Ask (Aside pattern).

**M-f · After** — **M17** LLM notes + templates · **M18** names, search, audio seek · **M19** chat with a meeting / across meetings (retrieval) · **M20** Markdown export, auto-export.

**M-g · Ask backends — all, default local** — **M21** the CU8 local model + retrieval over transcript chunks · **M22** user's subscription: `claude`/`codex` CLI and ChatGPT OAuth (both already in `Providers/`) · **M23** MCP server exposing meetings + live transcript (Aside) · **M24** BYO key / Ollama / LM Studio (exists).

---

## N · Notes

**Today:** none. `HeldTextStore` is a recovery queue.
- **N1 [new]** Notes section: timestamped list by day/session; source tag; Insert here · Copy · Discard · Insert all · export; search.
- **N2 [new]** Routes into Notes per §O: no focused field · app switch mid-segment · wake verb `note …` · ambient **lower-middle** band, and an ask-band prompt the user declines · Listen & note mode · latch during a meeting · utterance during a running agent action.
- **N3 [new]** Pill "📝 notes · N".
- **N4 [fix]** One store with the ambient timeline.
- **N5 [later]** Note → reminder / calendar / email draft via connectors.

---

## L · Ambient listening

**Today:** unusable (X13, X14, `directedSpeech` off).

- **L1 [new] Three settings** (owner decision), switchable from the menu bar, notch, Settings and by voice ("stop listening", "just take notes"):
  1. **Listen & act** — infer and run any capability (§O rubric).
  2. **Listen & note** — keep listening and noting; never act. Explicit triggers still act.
  3. **Off** — no ambient listening; explicit use only.
  Plus hard mute (exists) and a visible mic/camera state.
- **L2 [fix]** Amend V3 §8 (owner approved). Replace `AmbientNeverInjectsTests` / `AmbientInjectionAudit` with tests proving: inject/act only in Listen & act, only from the user's voice, only above the confidence band, never self-confirm irreversible steps.
- **L3 [fix]** Attach ambient to the always-on capture (O1); carry samples on the seam (X13).
- **L4 [new]** Decision layers per §O-d (Layer 1 runs on every ambient utterance).
- **L5 [new]** Battery: VAD always (ANE); ASR only on speech; decisions only at segment end; camera only when §LR is on.
- **L6 [new]** Eval: no public device-directed dataset — use AMI/NOTSOFAR (people talking to people → should be ignored) + public command corpora (e.g. SLURP-style, verify licence) for directed speech; T1 scripted cases for the rest.
- **L9 [later]** Train a directed-speech classifier only if every §O-d Layer 1 candidate misses on §V/T1 (= O6).

---

## CU · Computer use by voice

**Status: built, hidden.** Phase 4 exists: second key (`ActKeySettings`, **off by default**), **200-entry** deterministic catalogue over 12 `ActionKind`s (AX-driven, no pixels), agentic fallback `NativeAgentBackend` with step chips, consent tiers, stop, compensation; 6 connectors (GitHub, Gmail, Calendar, Linear, Notion, Slack). The planner needs a provider pinned for `act.planner`; nothing is pinned by default, so the agent never plans out of the box. Same shape as Muesli's page (enable planner · account · planner model · timeout).

**Does it need a logged-in provider? No.** `act.planner` routes through the same `RoutingTable` as every stage, and a running **Ollama or LM Studio** is already discovered as a provider (`LocalServerProvider`, ports 11434 / 1234). Pin that and the agent plans fully offline today. What is missing is a planner that works with *nothing installed* — the Settings row even says `acceptsLocal: false`, which only means "no on-device rules tier", not "no local model". CU8 fixes that by shipping one.

- **CU1 [new]** Settings › Computer use page (enable · provider/account · planner model · timeout · consent defaults), like Muesli's.
- **CU2 [new]** Local action chooser: **CUA-S1-4B CoreML** (`FluidInference/cua-s1-4b-coreml`, Apache-2.0, Qwen3.5-4B + LoRA, picks one (element, action) from the **AX tree text** — no screenshots) via FluidUse `CuaS1FourBManager`. Plus `cua-s1-forms` (706K params, ~0.9 ms) for forms.
- **CU3 [new]** Re-assess Cua (`trycua/cua`, MIT; avoid AGPL extras). The 24 Aug rejection (Python-first, screenshot/VM) is outdated: Cua Driver now has a Swift SDK, controls the host with background delivery, and CUA-S1 runs on AX text. Evaluate Cua Driver as the executor for actions our 12 kinds can't express.
- **CU4 [new]** Retrieval over the 200 catalogue phrasings (§O-d Layer 2) before any planner call.
- **CU5 [new]** Lume VMs (Cua) for safe CUA testing.
- **CU6 [new]** Measure the spec's bar — >99% on the 200 actions — never measured.
- **CU7 [new]** Ambient-driven CUA via §O (Listen & act only).
- **CU8 [new] One shipped local instruct model, shared by every generative stage.** Most computer use never needs a planner: Layer 2 (catalogue retrieval + CUA-S1-4B) covers single-step commands with no text generation. For the multi-step tail, ship **one** general instruct model via llama.cpp and point every generative stage at it, so there is one download and one resident process:
  - `act.planner` (step plans as JSON)
  - Meetings Ask and notes (M17, M21)
  - Hinglish / style cleanup where the English-only cleanup model cannot (G3)
  - Note → reminder / draft (N5)
  - "Why did it write that?" explanations (I3)
  Model by RAM (§HW): **16 GB → Qwen3.5-2B** (1.28 GB Q4_K_M, ~1.6 GB with context) · **≥ 24 GB → Qwen3.5-4B** (2.74 GB Q4_K_M, ~3.2 GB with context). Apache-2.0. The 0.8B cleanup model (§CM) stays separate: it is a restraint-tuned specialist, not a planner. The llama.cpp runtime is the same one D2 introduces. Flip `acceptsLocal` to true for `act.planner` once CU8 exists; keep cloud/CLI/OAuth as optional upgrades, never a requirement.
- **CU9 [new] One 4B at a time.** CUA-S1-4B (gptq, ~3.9 GB incl. its embedding table) loads only for an act turn and is unloaded after it (HW1 exclusive tier). On 16 GB it never coexists with a 4B planner or the Qwen refinement pass. Later option: run CUA-S1 as its published LoRA adapter on the **same** Qwen3.5-4B GGUF base as the planner (one base, two adapters) — removes the duplicate 4B on ≥ 24 GB machines.

---

## LR · Lip reading and camera

**Goal:** voice only · lips only · **voice + lips fused (default when camera permission and the mode are on)**.

**What exists:** lipflow (`amywork777/lipflow`, MIT code) uses **Auto-AVSR** (code Apache-2.0; **weights trained on LRS3 — non-commercial research only**). Lips-only 19.1% WER on LRS3; on its own test, lips-only 31.9% → **lips + whispered audio 6.9%**. Face/mouth via MediaPipe; ~1–2 s latency on M4 Pro (CPU beam search). The investigation judged lipflow "not useful" — that was about *insertion*; its *model* is what matters here. lipflow also has local/cloud LLM cleanup, a dictionary and correction capture — VoicePlus already has or plans all of those.

- **LR1 [new]** Camera signals that need **no lip-reading model** (Apple Vision face landmarks, licence-clean):
  - mouth moving in sync with the audio → it is the user speaking (beats TV / other people) → §O rubric 3, L, M11.
  - face toward the screen → likely addressed to the computer → §O-d context.
  - user present / absent at the laptop.
- **LR2 [new]** Fused AVSR (default when on): evaluate Auto-AVSR AV model — strongest gain on whisper/soft speech. Convert to CoreML (Conformer + decoder; beam search on CPU).
- **LR3 [new]** Lips-only mode for silent dictation (library, meetings, privacy).
- **LR4 [resolved]** **Licence:** Auto-AVSR weights are non-commercial research only. Owner: the app is non-commercial, so **use them**. Recorded as the one non-commercial dependency; if that ever changes, this is the case where training (rule 0.1) is justified.
- **LR5 [new]** Privacy: camera only when the mode is on; frames never stored; visible indicator.
- **LR6 [new]** Eval: LRS3 (research licence) for lips; LRS3 + MUSAN for fused-in-noise.

---

## LANG · Languages and scripts

**Decision:** default output script **Roman**; a script dropdown in the notch (Roman · Devanagari · mixed · others per language). FluidVoice also asks for languages in onboarding (it maps language → model route).

- **LANG1 [new]** Onboarding step: preferred languages + script per language; prefilled from `Locale.preferredLanguages` and enabled keyboard input sources.
- **LANG2 [new]** Notch dropdown: per-turn script override, remembered per app.
- How the answers improve results:
  1. **Model routing** — pick and download only the needed ASR (Parakeet v3 for its 25 languages, a Hinglish model for hi+en, Nemotron for others).
  2. **Language constraint** — restrict `LanguageDetector`/code-switch to chosen languages → fewer wrong-language guesses.
  3. **Language hints** — `Qwen3AsrLanguageHint`, Cohere/Nemotron language binding.
  4. **ITN locale** — en-IN lakh/crore grouping (1,00,000), ₹, date order.
  5. **Script** — transliteration to the chosen script (IndicXlit, MIT).
  6. **Cleanup model** — English-only models only for English; multilingual otherwise.
  7. **Spelling variant** — en-US / en-GB / en-IN.
  8. **Punctuation** — e.g. danda (।) only when Devanagari is chosen.
  9. **Dictionaries** — P-series lists per language.
  10. **Per-app language memory** — e.g. WhatsApp Hinglish, Slack English.

---

## HW · Will it run on the user's Mac?

**Target: 16 GB Apple Silicon.** Measured on the owner's 16 GB M2 Pro with normal apps open: 15 GB used, **7.4 GB already in the compressor**, heavy swap history — before VoicePlus loads any large model. So the budget is strict. Project budget (`ModelResearch_V1`): **≤ 1.5 GB resident for dictation, ≤ 4 GB with opt-in modes loaded.**

Sizes are the one variant we would ship, measured from Hugging Face on 1 Oct. CoreML and llama.cpp map weights from disk (macOS can evict them instead of swapping — the cost is reload time), so RAM ≈ weights + working memory.

**Always resident — fine**

| Model | Size | Role |
|---|---|---|
| Parakeet TDT v3 · or Ultra · or Redux | 0.46 · 0.63 · 0.22 GB | final ASR (pick one) |
| Parakeet EOU 120M (160 or 320 ms) | 0.21–0.45 GB | live preview |
| Parakeet CTC 110M | 0.10 GB | B1 boosting |
| Silero VAD · LocalVQE · WeSpeaker · CAM++ | each ≤ 0.02 GB | VAD, echo/noise, voiceprints |
| **Dictation total** | **≈ 1.3–1.5 GB in use** | at budget |

**On demand — fine (load when used, unload when idle)**

| Model | RAM in use | When | Note |
|---|---|---|---|
| SpeakoFlow Mini Q4 (cleanup) | ~0.7 GB | after each dictation | |
| Kev-0.8B CoreML (decisions) | **~2.1 GB** (0.67 peak + 1.45 mapped) | ambient on | GPU, not ANE |
| Intern-Decision-0.8B w8 | ~1.0 GB | alternative to Kev | |
| Laya multilingual e8 | ~0.5 GB | alternative / Hinglish | smallest decision option |
| GLiClass · GLiNER2-small · CUA-S1-forms | ≤ 0.15 GB each | names, forms | use small/w8 builds |
| Sortformer (one variant) | ~0.26 GB | meetings | |
| Nemotron 3.5 multilingual (one chunk size) | ~0.65 GB | non-English | replaces Parakeet, not added |
| Qwen3-ASR 0.6B int8 (refinement, kept) | 1.9 GB peak (measured) | refinement pass | |
| Srota Hinglish (Qwen3-ASR 0.6B) | ~1.9 GB | Hinglish chosen | replaces Parakeet as final ASR |
| Qwen3.5-2B Q4 (shared local LLM, CU8) | ~1.6 GB | planner, Ask, notes | default on 16 GB |
| Auto-AVSR audio-visual | ~1.8 GB | lips mode on | opt-in |

**Tight — allowed only one at a time**

| Model | RAM in use | Rule |
|---|---|---|
| CUA-S1-4B CoreML gptq | ~3.9 GB · 0.7–1.1 s/decision on M5 Pro (slower on M2) | act turns only, then unload (CU9) |
| Qwen3.5-4B Q4 | ~3.2 GB | ≥ 24 GB only |

**Dropped — will not fit or not needed**
- **CLM-8B** (owner) · CUA-S1-4B fp16 (7.2 GB) and multimodal/screenshot builds (3.6–7.4 GB) · Qwen3-ASR f32 · GLiNER2-decide fp16 (0.94 GB; use small) · multiple variants of Nemotron/Sortformer/LS-EEND in one install (ship one) · Kev 4B/9B/27B.

**Worst case on 16 GB** (Listen & act on, during a meeting, at an act turn): dictation 1.5 + Kev 2.1 + Sortformer 0.3 + CUA-S1-4B 3.9 ≈ **7.8 GB** — too much on top of a full desktop. Hence:
- **HW1 [new] Model residency manager:** one budget for the whole app; tiers = always / on demand / exclusive; least-recently-used unload; the exclusive tier evicts on-demand models first. Extends `ModelManager` and the D5 idle unloader.
- **HW2 [new] RAM-aware defaults at first launch** (`ProcessInfo.physicalMemory`): 16 GB → Qwen3.5-2B, Kev on demand, CUA-S1-4B exclusive · ≥ 24 GB → Qwen3.5-4B, Kev resident, CUA-S1 kept warm · 8 GB → dictation + cleanup + Laya only (no ambient act, no lips, no 4B). The decision *model* is still chosen by §O-d; HW2 only sets residency.
- **HW3 [new]** Watch memory pressure (`DispatchSource.makeMemoryPressureSource`); on warning, unload on-demand models; on critical, fall back to the next smaller option (Kev → Laya e8, 4B → 2B) and say so in the pill.
- **HW4 [resolved]** Minimum macOS **15** → J7.
- **HW5 [new]** §V reports latency and peak RAM per model on a 16 GB M-series, not only accuracy.

---

## FI · FluidInference assets worth adopting

All Apache-2.0 unless noted. Most run through **FluidUse** (Swift, Apache-2.0).

| Need | Asset | Fills |
|---|---|---|
| VAD shipped | `silero-vad-coreml` | C6 / X1 |
| Better ASR, same contract | `parakeet-ultra-coreml`, `parakeet-redux-coreml` (CC-BY-4.0) | B5 |
| CTC boosting | `parakeet-ctc-110m-coreml` | B1 |
| Multilingual streaming | `Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` | G2 |
| Neural AEC/NS | `localvqe-coreml` | C1b / X9 |
| Live diarization | `diar-streaming-sortformer-coreml`, `ls-eend-coreml` | M7 |
| Speaker embeddings | `campplus-coreml` | M9 |
| Decisions | `kev-0.8b-coreml`, `intern-decision-0.8b-coreml`, `laya-coreml`, `gliclass-edge-apps-coreml` | §O-d |
| NER for names | `gliner2-5-*-coreml` | M11, P |
| Computer use | `cua-s1-4b-coreml`, `cua-s1-forms-coreml` | CU2 |
| Eval data | datasets `librispeech`, `fleurs`, `ami-corpus-mirror`, `musan`, `aec-challenge-synthetic-mini` | §V |

Skip: TTS models · OpenVINO (`-ov`) builds (Windows/Intel NPU) · `system-one-gemma` / `nanojev` (no weights / non-commercial) · `decision-1.0-lex/kai` (Gemma tokenizer terms, 1.9 GB) · everything in the §HW "dropped" list.

---

## V · Evaluation on public data

- **V1 [new]** Replay harness + Open ASR Leaderboard normaliser; report per condition.
- **V2 [new]** Baselines = published scores of the same model on the same set.
- **V3 [new]** Noise mixing allowed: MUSAN (FluidInference mirror) into clean public speech at fixed SNRs.

| Condition | Set | Licence |
|---|---|---|
| Clean read | LibriSpeech | CC-BY-4.0 |
| Punctuation + casing | LibriSpeech-PC | CC-BY-4.0 |
| Indian-accented English | Svarah (gated) | CC-BY-4.0 |
| Real calls, entities | Earnings-22 | CC-BY-SA-4.0 |
| Far-field + TV/music/babble | VOiCES | CC-BY-4.0 |
| Whisper / soft | CHAINS, wTIMIT | research — verify |
| Noise | MUSAN-mixed LibriSpeech | derived |
| Echo | AEC challenge (mini mirror) | verify |
| Meetings | NOTSOFAR-1, AMI | CC-BY-4.0 |
| Diarization | VoxConverse, AMI, NOTSOFAR-1, Indic DiarBench | CC-BY-4.0 / verify |
| Hinglish | MUCS-2021, HiACC, CoSHE-500, cs-fleurs | CC-BY-4.0 / verify |
| Multilingual | FLEURS, Common Voice | CC-BY-4.0 / CC0 |
| Lips | LRS3 (+ MUSAN) | research |
| Directed speech | none public | L6 + T1 |
| Cleanup raw→clean | none public | proxy + T1 |

- **V4 [new]** Re-run every rule-0.4 decision on V1.

---

## T · Human testing

- **T1 [new]** Write `VoicePlus_HumanTest.md`: per case **ID · preconditions · steps · desired outcome · pass/fail · notes · evidence**; the owner runs it and reports back. Testing, not data collection (rule 0.2). Covers: install/upgrade and every permission (incl. "Later"); every onboarding step (incl. LANG1); every input (hold, latch, act key, wake verbs, repair, edit, deixis box, ambient in all three settings, lips/fused); every destination (TextEdit, Notes, Mail, Slack, WhatsApp, Claude, VS Code + terminal, Terminal, Docs, Sheets, Excel, Figma, web forms, password field); conditions (quiet, TV, nearby person, whisper, loud, AirPods, device switch); the §O concurrency matrix; meetings (each mode, detection, labels, mapping, Ask, export); notes; computer use (deterministic + agent, consent, stop); all 54 indexed settings; the recovery catalogue; accessibility (VoiceOver, keyboard, contrast, motion, external display, notch/no-notch); the 16 §Q fixes.

---

## P · Public dictionaries

Rule: public lists fix casing/formatting of words already recognised; they don't feed decode-time boosting.
- **P1** macOS Text Replacements (`NSSpellChecker.userReplacementsDictionary`).
- **P2** Local names: Contacts, app names, calendar attendees, file/repo names.
- **P3** Brand/tech casing: Wikidata (CC0), npm/PyPI/Homebrew names.
- **P4** CMUdict (BSD) for phoneme-level matching.
- **P5** SCOWL to spot likely entities (out-of-vocabulary → keep casing).
- **P6** IndicXlit (MIT) for scripts (LANG).
- **P7** GLiNER2 CoreML NER to detect entities in context text.

---

## CM · Cleanup model — existing fine-tunes first

| Model | Base | Q4_K_M | Licence |
|---|---|---|---|
| **SpeakoFlow Mini** (restraint 92.6%, edit 48.8%, damage 10.7% — vendor) | Qwen3.5-0.8B | 542 MB | Apache-2.0 |
| Quill | Qwen3.5 0.8B / 2B / 4B | 505 MB / 1.2 GB / 2.6 GB | Apache-2.0 |
| S1-mini | Qwen3-0.6B | 462 MB | Apache-2.0 + naming clause |

Choose on §V restraint and damage; English-only → non-English routes per LANG.

---

## SC · Google Speech Commands
Not a model/eval source. `_background_noise_` clips usable for VAD false-trigger tests (rule 0.2 allows mixing).

## FV · FluidVoice — take / don't
- **Take:** B1 · D5 · G2 · (C1c only as last resort).
- **Don't:** analytics by default · closed models · settings sprawl · unverifiable data claims.
- **Keep:** span contract · `FieldRole` + caret rungs · voice repair · deterministic → gated LLM → guard · no telemetry.

---

## CP · Critical path

> **J7+J6 → Q1 → Q2–Q5 → V1/V2 → C6 → HW1 → O1–O3 → D1+K7 → B1/B5 → D2+D3 → M5–M13 → L1–L4 → CU1–CU2+CU8 → LR1 → LANG1–2 → G1**

- J7+J6 first: the macOS 15 floor and the dependency bump change what every later item may use.
- Q1 next: newlines currently send half-dictated messages.
- Q2–Q5: insertion truth, and Q2 unlocks Electron context.
- V1/V2: no more model decisions without public-set evidence.
- HW1 then O1–O3 before meetings, ambient and CU — they all depend on one memory budget, one capture and one decision.
- T1 runs in parallel throughout. Waves and parallel ownership: `VoicePlus_Improvements_V5_Build.md`.

## DEC · Decisions

**Resolved (1 Oct):** ambient three settings + amend V3 §8 (L1/L2) · noise mixing allowed · Roman default + notch dropdown + onboarding languages (LANG) · keep Qwen refinement (D7) · meeting recording default Always (M5) · keep storing all audio (F3) · LoRA on the cards (F5) · training allowed when nothing off the shelf comes close (rule 0.1).

**Resolved (1 Oct, later):** LR4 — use the non-commercial Auto-AVSR weights (app is non-commercial) · M13 — perceived gender on by default, configurable · J6 — FluidUse + FluidAudio bump approved · O-d — best-quality model on every utterance, not a cost cascade · rubric 5 — ask/confirm band added.

**Resolved (1 Oct, latest):** HW4/J7 — minimum macOS 15 · CLM-8B dropped.

**Open:** none.
