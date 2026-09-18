# VoicePlus — Improvements V4

Investigation and fix plan · 18 September 2026 · against `main` @ `d79cc98` (1.10.0 candidate)

**Scope.** Ten field reports from real use (Google Docs in Brave, the Claude desktop app, a TV in the room)
plus five notch screenshots. Every cause below was traced to a file and line in the repo; nothing here is
a guess from the symptom. Section 0 answers "why is this in the notch, and is it a bug". Sections 1–10
follow the report numbering. Section 11 is the ordered fix list.

**Grades of evidence used:** `code-verified` (read the path) · `measured` (a number in `progress.md` /
`DECISIONS.md`) · `hypothesis` (a proposal not yet tried on real audio).

---

## 0. The notch messages in the screenshots

| # | Message | Where it comes from | Why it appeared | Bug? |
|---|---|---|---|---|
| 1 | **Noisy mic — 4 dB SNR** / Check your input device | `MicQualityAnalyzer.analyze` → `PillState.warningHeadline` | "SNR" is p90/p10 frame RMS over the **first 300 ms of speech**, not speech over noise (§6) | **Yes** — wrong measurement |
| 2 | **Mic level is very low** ("low decibel") | same analyzer, 1.5 s deadline branch | Nothing crossed −40 dBFS within 1.5 s of key-down → it grades 300 ms of *silence* (§6) | **Yes** — grades the pause |
| 3 | **Landed · not confirmed** / Weird. | `ChromiumAdapter.verifyReadback` → `LandedPillInfo(verified: false)` | Google Docs is a canvas editor; Chromium's `AXValue`/caret don't reflect the insert, so readback is *unavailable*, never *confirmed* (§6) | No — honest, but noisy copy for a site that can never confirm |
| 4 | **engine start failed: start timed out after 3.0s** | `PipelineAudioSource.start` 3 s semaphore | The whole CoreAudio graph is torn down on every key-up and rebuilt on every key-down; a slow HAL (Bluetooth, Continuity mic, device change) blows the budget (§2) | **Yes** — design |
| 5 | **audio format mismatch: hardware 48000 Hz vs client 44100 Hz** | `CoreAudioCaptureSource.verifyFormats` | One long-lived `AVAudioEngine` keeps a stale 44.1 k client format; the resync only runs after a *pin*, which is skipped when the target is already the system default (§2) | **Yes** — ours |
| 6 | **Trying to connect…** (title bar and bottom-left toast) | not in this repo | Google Docs' own offline banner | Not ours |
| 7 | **EN** chip | `ScriptIndicator` | Detected script for code-switching; informational | Not a bug |
| 8 | **Nothing was typed — press the key again** | `PillState.errorSubtitle` | Subtitle of every `.error`; correct for 4 and 5 | Not a bug |

```
key-down ──► PipelineAudioSource.start (3 s budget)
               │  enumerate devices → pin → read formats → verifyFormats ──► #5
               │  installTap → AVAudioEngine.start ─────────────────────► #4 on timeout
               ▼
             AudioPipeline.process ──► MicQualityAnalyzer (one verdict/utterance) ──► #1 / #2
               ▼
key-up ──►   RealEngine.stop → final TDT pass → UtteranceLander → TextInjector
                                                     └─ readback ─────────────────► #3
```

---

## 1. Punctuation and capitalisation ignore where the caret is

**Symptom.** Caret in the middle of a sentence, say one word → `Word.` (capital, full stop).

**Root causes** (`code-verified`)
1. **The model punctuates.** Parakeet TDT 0.6B v3 emits casing and punctuation itself; the decoder passes
   tokens through untouched (`Engine/Decoder/FluidAudioTDTDecoder.swift:60-67`). Every utterance is decoded
   in isolation, so every utterance looks like a sentence.
2. **Our suppressors treat model punctuation as user-dictated.**
   - `FieldRoleFormatter.stripAddedTrailingPeriod` bails on `guard !spokenHere.hasSuffix(".")` (`:64`).
   - `applyFirstWordCase` only lowercases when the *spoken* first letter was lowercase (`:95`) — never
     true after Parakeet.
3. **Caret falls back to end-of-field.** `FieldContextReader.swift:60`:
   `let caret = … range?.lowerBound ?? count` — no `kAXSelectedTextRange` ⇒ caret assumed at the end ⇒
   `textAfterCursor == ""` ⇒ `FieldRules` sets `trailingPeriod: true`, `capitalizeFirstWord: true`.
   This is exactly the Google Docs / Electron case.
4. **No field context at all ⇒ StyleStage at full strength.** `FieldRolePipeline.write` runs only when a
   `FieldContext` exists (`UtteranceLander.swift:127-128`); otherwise the cold-start profile
   (`capitalizationRate: 1, terminalPeriodRate: 1`, `StyleProfile.swift:43-44`) capitalises and appends `.`.
5. **Accessibility is used, but shallowly.** The landing path reads only `kAXValue` +
   `kAXSelectedTextRange` on the focused element. The deep reader that can fetch text around a caret in
   web views (`kAXStringForRange`, `Injection/AXReader/*`) feeds **biasing and deixis only**, never the
   continuation plan.

```
              what is read                     what decides format
focused AX ──► role/subrole/hints ───────────► FieldRole → FieldRules (terminal/code/prose)
           ──► kAXValue + kAXSelectedTextRange ► textBefore / textAfter → Continuation (space, cap, period)
                     │
                     └─ range missing ─────────► caret := end of value   ◄── the bug
AXWindowReader (kAXStringForRange, web trees) ─► ContextHarvester (bias), DeixisService     (never the lander)
```

**Fixes**
- [ ] **V4.1 Treat ASR punctuation as provisional.** Give every span a `punctuationOrigin: .model | .spoken`.
      Spoken = the user said "full stop"/"comma" (already detected by `SpokenPunctuation`). Model
      punctuation is stripped when the caret context says mid-sentence, kept when it says end of sentence.
- [ ] **V4.2 Caret state is three-valued:** `known(before, after)` · `endOfField` · `unknown`. Never map
      `unknown` to `endOfField`. `unknown` ⇒ no capital, no period, no leading space (§5), and the pill
      shows the short "placed as spoken" hint once per app.
- [ ] **V4.3 Read the real caret where the value is not honest.** Order: `AXSelectedTextRange` →
      `AXSelectedTextMarkerRange` + `AXStringForTextMarkerRange` (WebKit/Chromium expose these) →
      `kAXStringForRange` around the caret via `AXWindowReader` → `unknown`. Wire the existing reader into
      `FieldContextReader`, not a new one.
- [ ] **V4.4 Continuation rules on the known case:** after `[.!?]` + space ⇒ capital; after a word ⇒
      lowercase, leading space, no period; before a word ⇒ trailing space, no period; inside a word ⇒ no
      spaces; at empty field ⇒ capital, period only if the utterance is a full clause (≥ 4 words or ends
      with a verb phrase — cheap check, `hypothesis`).
- [ ] **V4.5 Per-app memory.** If an app never exposed a caret in N landings, skip the AX round-trip and
      go straight to `unknown` (saves ~30 ms) — same table `MethodRouter` already keeps for methods.

---

## 2. 2–5 s warm-up after launch

**Root causes** (`code-verified`)
1. **The hotkey is armed after the whole container build.** `AppDelegate.applicationDidFinishLaunching`
   awaits `AppContainer.build`, which awaits `EngineFactory.make` → Silero VAD load on the ANE
   (`SileroVAD.swift:31-34`) → synchronous `ModelManager.runMaintenance` under a file lock
   (`ModelManager.swift:91-124`). `CapabilityWatcher` (the key tap) is constructed in `wire()`, i.e. after.
   Presses before that do nothing.
2. **Model preload is fire-and-forget at `.utility` QoS** (`AppContainer.swift:324-329`), so a cold first
   press still races it and shows "Warming up…" (`RealEngine.start(prewarm:)` → `.prewarming`).
3. **Audio is never prewarmed at launch and the graph is destroyed on every key-up.** `engine.prewarm()`
   has zero callers in `App/`; `RealEngine.stop/cancel` → `audio.stop()` → tap removed, engine stopped,
   `prewarmed = false`. Every press rebuilds AUHAL + installs a tap + `AVAudioEngine.start()`.
4. First launch after install or an OS update also pays CoreML load + ANE specialisation (cached by the
   OS afterwards). This part is not ours to remove.

```
now:      launch ──[container build: VAD ANE + maintenance]──[wire: hotkey armed]──► press ──[HAL graph 0.3–3 s]──[model if not yet loaded]──► listening
proposed: launch ──[hotkey armed + pill "Warming up…"]
                 ├─[models @ userInitiated] ─────────────┐
                 └─[audio graph prepared, mic closed] ───┴──► press ──[engine.start ≈ 50–100 ms]──► listening
```

**Fixes**
- [ ] **V4.6 Arm the hotkey first.** Construct `CapabilityWatcher` before `AppContainer.build`; queue one
      press and show `.prewarming` while the container lands.
- [ ] **V4.7 Preload at `.userInitiated`,** and preload the audio graph too: call `engine.prewarm()` at
      launch and after every device change. Keep `AVAudioEngine` *prepared* between turns (tap installed,
      engine stopped) so the mic indicator stays off but `start()` is cheap. Measure key-down→first-buffer
      before/after (`measured` gate: p95 < 150 ms on built-in mic).
- [ ] **V4.8 Move `runMaintenance` off the build path** (detached, after wiring).
- [ ] **V4.9 Fix the 44.1 k/48 k mismatch:** call `syncClientFormat(unit:)` unconditionally in
      `buildGraph`, and recreate the `AVAudioEngine` when `inputFormat != outputFormat` after the sync.
      Add the route monitor to the *stopped* state so a device change between turns is observed.
- [ ] **V4.10 Raise the start budget adaptively:** 3 s built-in, 8 s Bluetooth/Continuity (the self-test
      already uses 15 s), and say *which* device is slow in the error sentence.

---

## 3. The TV eight feet away gets transcribed

**What is actually on the live path** (`code-verified`): a raw omnidirectional tap.

| Component | Exists | Live? | Where |
|---|---|---|---|
| Apple voice-processing IO (AEC + NS + AGC) | yes | **no** — only `--mic-selftest-vp` | `VoiceProcessingCaptureSource.swift`, `MicSelfTest.swift:91` |
| Spectral-gate noise suppressor | yes | **no** — lost 0/7 points on the SNR sweep (`measured`) | `AcousticStage.swift:46-59` |
| Neural AEC slots | shells | no (no weights) | `AEC.swift` |
| Silero VAD | yes | runs, **output discarded** (`PipelineAudioSource.swift:117 default: break`) | `AudioPipeline.swift:296` |
| Directed-speech classifier (level, voiced ratio, SNR…) | yes | **no** — only reachable via `LatchController.handle`, which has no callers; flag off | `Engine/DirectedSpeech/*` |
| Speaker gate / enrollment | yes | **no** — `speakerFilteringEnabled = false`; enrolling arms nothing; `LatchRuntime.speakerGuard` never assigned; MFCC fallback reports `identifiesSpeakers == false` | `LatchController.swift:37,119-126` |

So the decoder receives **every 50 ms block from key-down to key-up**, TV included
(`RealEngine.swift:379-380, 436`).

```
now:       mic ──► (empty chain) ──► buffer ──► TDT ──► text        (TV + you, one transcript)

proposed:  mic ──► VP-IO (AEC/NS/AGC) ──► VAD ──► level/near-field gate ──► speaker gate ──► TDT ──► confidence gate ──► text
                   [A]                   [C]        [B]                     [D]                    [G]
```

**All the ways, ordered by expected payoff ÷ cost**
- [ ] **[A] Apple voice-processing IO behind a flag, measured.** It is the one on-device stage that
      attenuates far-field and loudspeaker energy. The source exists; wire it as `RobustnessProfile
      .voiceProcessing` and run the real-room corpus + a TV-on corpus (`hypothesis`: −10–20 dB on the TV).
      Watch for its known cost: aggressive AGC and a 1–2 s adaptation at start.
- [ ] **[B] Near-field level gate.** Inverse square: 1 ft vs 8–10 ft ≈ 18–20 dB. Track the loudest
      sustained speech level in the first second as *you*; drop VAD segments whose mean level is
      > 12 dB below it. `DirectedSpeechFeatures.meanLevelDB` already computes this. Cheap, deterministic,
      works in hold mode.
- [ ] **[C] Decode only VAD-speech regions.** Subscribe to `.vad` events; feed the decoder speech spans
      (+100 ms padding), not the whole buffer. Also fixes §7.
- [ ] **[D] Speaker verification, opt-in after enrollment.** Ship the WeSpeaker weights FluidAudio already
      exposes (`FluidSpeakerEmbedder`), turn enrollment into `speakerFilteringEnabled = true`, assign
      `LatchRuntime.speakerGuard`, gate per segment at cosine 0.6. Show "another voice — ignored" once
      per session; "Not you" correction (`NotYouCorrection`) learns the threshold.
- [ ] **[E] Echo reference when the TV audio comes from the Mac** (AirPlay/HDMI): `SystemAudioRecorder`
      already captures system output for meetings; feed it as the AEC far-end reference. Only helps when
      the sound originates on the Mac.
- [ ] **[F] Directed-speech classifier in latch mode.** Wire `LatchController.handle`; flag on when the
      harness clears the 1 false trigger/day bar (`Detector.swift:13-14`).
- [ ] **[G] Post-ASR confidence gate.** Far-field speech decodes with low token confidence;
      `WordConfidence` exists. In latch mode drop spans with mean confidence < τ (measure τ on the
      TV-on corpus); in hold mode grey them in the preview instead.
- [ ] **[H] Product-level:** "Voice isolation" preset that turns on A+B+C together; recommend AirPods /
      a headset in the mic self-test when the room noise floor is > −45 dBFS.
- Not viable on device today: target-speaker ASR conditioning (no such Parakeet/Qwen variant),
  multi-channel beamforming (macOS exposes one input channel).

---

## 4. Numbers

**Symptoms.** "1234" → `one, two, three, four.` · "five thousand one hundred and fifty" → `5100    and fifty.`

**Root causes** (`code-verified`)
1. **The ITN never sees clean tokens.** `ProseFormatter.Numbers` looks up `Tok.lower` with the model's
   punctuation still attached (`"fifty."`, `"one,"`). The tokenizer splits on whitespace only (`:100`).
   - The `and` bridge (`:339`) requires the next token to be a bare tens/units word → `"fifty."` fails →
     `parse` returns `(5100, 4)` and `and fifty.` is left as-is.
   - `"one,"` misses every table → `sawAny` stays false → nothing converts. The commas are the model's.
2. **No digit-sequence rule.** `:329` breaks between consecutive units ("five six" are separate) and
   `:413` keeps single values < 10 spelled out. "one two three four" can never become `1234`.
3. **The stray spaces** come from `TranscriptSpan.joinedText` (`Shared/Types/TranscriptSpan.swift:163`)
   joining *empty* spans: the assembler writes `5100` into the first consumed span and blanks the other
   three. `renderedText` (skips empties, documented "for injection") exists and is never used by the lander.
4. **Two divergent digitisers:** the preview one (`PreviewFormatter.swift:42-157`) has no `hundred` scale
   and no `and`; the final one does. What you watch and what lands differ.
5. **Measured weakness upstream:** the digits segment class is the worst in the corpus (WER 0.405,
   `DECISIONS.md`), so ITN must be tolerant of model errors, not just of punctuation.

**Fixes**
- [ ] **V4.11 Punctuation-tolerant ITN.** Strip trailing `[,.;:!?]` before lookup, carry it on the last
      consumed token, re-attach after. Fixes both symptoms with ~15 lines.
- [ ] **V4.12 Digit-sequence rule using span timing.** ≥ 3 consecutive single digits with inter-span gaps
      < 250 ms (we have `audioRange` per span) ⇒ concatenate (`1234`, phone numbers, PINs, years); with
      long gaps or spoken "comma" ⇒ list `1, 2, 3, 4`.
- [ ] **V4.13 Use `renderedText` at every `joinedText` site in `UtteranceLander`** (`:132,154,167,178,191,201`)
      and in `LatchRuntime.swift:406`.
- [ ] **V4.14 One ITN for preview and final** (move `Numbers` into `Shared`, preview calls it).
- [ ] **V4.15 Coverage:** decimals ("point"), fractions, ranges ("five to ten"), units (kg, km, %),
      `x.y.z` versions, "at/dot" for emails, "dash/slash". Field-role aware: never digitise in a code
      field, always in a spreadsheet cell, currency by locale.

---

## 5. Dictation always starts with a space

**Root causes** (`code-verified`) — either is sufficient
1. `Continuation.swift:104` sets `leading = " "` whenever `textBeforeCursor` is non-empty and not
   whitespace-terminated. With the end-of-field fallback (§1 cause 3), any app that exposes a non-empty
   `kAXValue` but no caret gets `textBefore` = tail of the whole value ⇒ space, always — even in an empty
   input on a populated page.
2. A leading filler ("um") removed by the formatter leaves an empty first span, and `joinedText` turns it
   into a leading `" "` (§4 cause 3).

**Fixes**
- [ ] V4.2 (`unknown` ⇒ no leading space) + V4.13 (`renderedText`).
- [ ] **V4.16 Remember our own last landing.** If the previous VoicePlus insertion into the same element
      ended < 30 s ago and no click/arrow/typing event was seen since (the event monitors exist), the caret
      is where we left it: join with one space or nothing depending on how *our* text ended. Reset on any
      user input.
- [ ] **V4.17 Setting:** Spacing — Automatic (default) · Always add · Never add. Lives in Voice settings.

---

## 6. Odd notch statuses (Landed · not confirmed / 3 dB / Noisy mic)

**Mic quality** (`MicQualityAnalyzer.swift`) — `code-verified`

```
key-down ─┬─ silence ─────────────┬─ first sample ≥ −40 dBFS ─┬── 300 ms window ──┬─ rest of utterance
          │  (>1.5 s → "Mic level  │   (a key click, a cough,  │  30 frames × 10 ms │  verdict is sticky,
          │   is very low")        │    or your first syllable) │  snr = p90/p10     │  covers the waveform
```

- The 300 ms window sits **inside speech**. p90/p10 over thirty consecutive speech frames is the
  syllabic modulation depth of one word (3–6 dB for continuous voicing), not signal-to-noise. Clean close
  speech trips `snr < 6 ⇒ .poor` and prints "Noisy mic — 4 dB SNR". A quieter room makes the number
  *lower*, because the floor never enters the statistic.
- "Mic level is very low" = the 1.5 s deadline branch analysing 300 ms of the pause itself.
- The verdict is sticky for the utterance (`PillStateReducer`), and `flush()` can post one after key-up.

**Landed · not confirmed** — `ChromiumAdapter.verifyReadback` returns `.unavailable` for Google Docs'
canvas editor; the copy is honest but alarms on every Docs landing.

**Fixes**
- [ ] **V4.18 Measure SNR properly:** noise floor = p10 of frame RMS over the *pre-speech* window (key-down
      → VAD onset, min 200 ms, else the running 4 s minimum the energy VAD already keeps); signal = p90 of
      frame RMS over VAD-speech frames of the first 1 s. Emit once, after both exist. Thresholds: poor < 10 dB,
      bad < 5 dB (`hypothesis`, verify on the corpus). Never grade a pause; "very low" requires speech that
      peaks < −40 dBFS.
- [ ] ~~**V4.19**~~ *Superseded by the verified design's warning state (C5), see the Wave 1 build document.* **Warning is a chip, not a takeover:** small icon beside the waveform, full sentence only in
      the menu; clears itself when the next 1 s of speech is fine.
- [ ] ~~**V4.20**~~ *Withdrawn: the verified design shows "⚠ Inserted · not confirmed" whenever readback does not confirm.* **Readback copy per capability:** `unavailable` ⇒ plain "Landed" with a hollow tick and the
      committed text; `unconfirmed` (readback ran and showed nothing) keeps "Landed · not confirmed". Remember
      per bundle + AX role that readback is never available and skip the AX round-trip.

---

## 7. Text typed when nothing was said

**Root causes** (`code-verified`)
1. The only precondition for a decode is `duration ≥ 0.3 s` (`RealEngine.swift:155, 446-458`). A silent
   hold sends room tone to Parakeet, which emits filler ("you", "Thank you.", "Bye.").
2. No VAD gating, no minimum *speech* duration, no filler denylist, no repetition filter, no energy floor.
3. `UtteranceLander.swift:132` rejects only the empty string.
4. The 0.5 s pre-roll (`AcousticCaptureSource.swift:133-139`) can push a near-zero press over 0.3 s.

**Fixes**
- [ ] **V4.21 Decode only if the VAD saw ≥ 300 ms of speech** (`Endpointer.speechHeard` is already
      computed and unused). No speech ⇒ `.landed` is skipped and the pill shows "No speech detected — Try again"
      (copy exists).
- [ ] **V4.22 Hallucination guard on the final text:** drop if (speech ratio < 20 % **and** text ∈ known
      filler set) or (a token repeats ≥ 4× consecutively) or (mean token confidence < 0.3 with speech < 1 s).
      Log every drop with the audio id so the corpus can grow.
- [ ] **V4.23 Pre-roll only when the graph was already running** (V4.7); never pad a press that opened the mic.

---

## 8. Punctuation and capitalisation from tone (second pass)

**Feasible, and cheaper than it sounds.** The final pass already sees the whole utterance and every span
carries `audioRange`; prosody is a feature extraction, not a new model.

```
utterance audio ─► F0 contour (YIN, 10 ms) ─┐
                 ─► energy envelope ────────┼─► per-boundary features ─► punctuator ─► [TranscriptSpan] (confidence kept)
span timings ────► pause at each boundary ──┘        │
Parakeet text (lexical punctuation, provisional) ────┘
```

- [ ] **V4.24 Phase 1 — pauses (deterministic, no model).** Pause ≥ 600 ms between spans ⇒ sentence
      boundary; 250–600 ms ⇒ comma unless the model already punctuated; utterance-final ⇒ keep the model's
      mark. Combine with §1 caret rules. (`hypothesis`; test on the 20-utterance corpus + 20 new
      multi-clause recordings.)
- [ ] **V4.25 Phase 2 — F0 for questions and emphasis.** Rising terminal F0 over the last 300 ms
      (+ ≥ 3 semitones vs. the utterance median) **and** a lexical cue (wh-word, auxiliary-first, "right",
      "okay") ⇒ `?`; falling ⇒ `.`; large energy peak on a short final clause ⇒ `!` only when the words
      allow it. Tone alone never overrides words.
- [ ] **V4.26 Phase 3 — a small lexical+prosodic punctuator** (a CoreML token classifier, ≤ 50 MB,
      inputs: word pieces + pause + F0 slope per boundary), replacing the rules if it wins on the corpus.
      Qwen3 refinement lost (`measured`: 0 segments improved, p95 1816 ms) — do not route this through it.
- Constraints already fixed by V3 §4.1: runs before landing, never revises landed text; hold mode may skip
  Phase 2/3 under the 1500 ms budget; latch mode always gets them.

---

## 9. The orange lines → a box, a screenshot, and the thing under it

**What they are** (`code-verified`): our deixis **draw-to-point** ink (`PRODUCT-SPEC.md:517,525`), drawn on a
transparent full-screen `OverlayWindow` that is ordered in front of everything while capture is on. A plain
left-drag with no modifier paints a stroke (`EventTapRecorder.swift:100-111`); the stroke region is hit-tested
against the AX tree (`AXHitTesting.swift`) so "this / that / there" binds to an element, and the binding
rides into the pipeline as a text line (`this = button "Send" @display 1`). Only the element's title or the
first 80 characters of its value are captured — **no screenshot, no surrounding text**.

**Why only in latch.** The overlay is shown on every `.startCapture` — hold *and* latch — and hidden on
`.finalize`. During a hold you rarely drag, so you never noticed. In latch, `.enterLatch` is a no-op
(`AppDelegate.swift:206-208`), so the overlay and the event tap stay armed for the whole session and every
ordinary drag (select text, move a window, scrub a slider) paints ink. The behaviour is right; the trigger
is wrong.

**Redesign (owner decision, 18 September)**

```
drag with the dictation key held ─► rectangle (orange, 1 px, hand-drawn corners optional)
        │
        ├─► screenshot of the rectangle (ScreenCaptureKit, this display only)
        ├─► AX hit-test of the rectangle: element role/title, and the *text* inside it
        │      (kAXStringForRange over the element's visible range; OCR of the screenshot as fallback)
        ▼
   notch shows a thumbnail chip  [▣ 320×90 · "Send the deck…"]  next to the preview
        ▼
   context line for the pipeline / LLM:  region 1 = <role> "<title>" text: "<…>" image: <id>
```

- [ ] **V4.27 Rectangle, not free-form.** Drag = box; box is the unit of deixis. Multiple boxes per
      utterance bundle as today (`RegionBundleCounter`).
- [ ] **V4.28 Same trigger in both modes: drag while the dictation key is physically down.** Hold mode is
      unchanged (the key is down anyway). In latch the key is *not* down, so a bare drag does nothing;
      press-and-hold the key while dragging draws the box (the state machine treats a press that overlaps
      a drag as "point", not as "stop"). Optional setting: "In Latch, draw without a key" for users who
      want the old behaviour.
- [ ] **V4.29 Capture the box.** Screenshot via ScreenCaptureKit (needs the **Screen Recording**
      permission — a new row in `PermissionMatrix`, optional, asked the first time a box is drawn); AX
      text inside the rectangle; OCR (`VNRecognizeTextRequest`) when AX returns nothing (Docs, canvas apps).
      Image and text are kept for the utterance only, never stored, never synced.
- [ ] **V4.30 Thumbnail in the notch.** A chip with the crop and the first words; click = enlarge;
      it retracts with the pill. Consumed by the act router, the repair grammar and (when a model prompt
      is built) the pipeline context.
- [ ] **V4.31 "Overlay" hygiene.** The `OverlayWindow` is only ordered front while the key is down;
      the event tap is listen-only and released on `.enterLatch`, re-armed on key-down.

---

## 10. Latch / always-on

**Observed:** nothing lands until the stopping tap; then everything at once; TV mixed in.

**Root causes** (`code-verified`) — the runtime is built, the wiring is missing
1. `LatchRuntime.tick / noteVAD / noteEndpoint` have **zero call sites** in `App/`.
2. `AudioPipeline.Options.latched` is **never set true** outside the mic self-test, so the pipeline's own
   endpointer never emits `.endpoint`; and nothing subscribes to `.endpoint` anyway.
3. Therefore `RealEngine` keeps one open segment; the only close is `.keyRelease` on the stopping tap,
   which `DictationCoordinator.finalize()` lands in one shot.
4. The latch endpointer is hardcoded `trailingSilence: 1.2, noSpeechTimeout: 8, maxUtterance: 60`
   (`LatchRuntime.swift:102`) — no setting reads it.
5. The latch hold path injects `spans.joinedText` raw with **no field context** (`LatchRuntime.swift:406`).
6. Speaker guard never assigned (§3) ⇒ the TV lands too.
7. Ambient discards everything (gap G11): the transcript seam carries no audio.

```
now:       tap-tap ─► [ ……………… one 3-minute segment ……………… ] ─► tap ─► land once (raw join, stale focus)

proposed:  tap-tap ─► ▐speech▌─2 s─► land ─► ▐speech▌─2 s─► land ─► (caret moved) ▐speech▌─2 s─► land there
                       │ each segment: focus snapshot → field context → continuation → inject (or Notes)
                       └ speaker/level gate per segment; "another voice — ignored" chip
           no caret ─► Notes row in the pill  ─► Notes section in the window (Insert here / Copy / Discard)
```

**Fixes**
- [ ] **V4.32 Wire the endpoint loop.** Set `options.latched` on enter; subscribe to `.vad` and `.endpoint`
      in `PipelineAudioSource`; call `LatchRuntime.noteVAD/noteEndpoint`; close segments at endpoints
      (`closeSegmentAtEndpoint`) and land each through `UtteranceLander` with a **fresh focus snapshot per
      segment**, never the key-release one.
- [ ] **V4.33 Setting: "Insert after a pause of" 1.0–5.0 s, default 2.0 s** (bound to
      `Endpointer.trailingSilence`); `maxUtterance` 30 s so a long monologue still lands in pieces.
- [ ] **V4.34 Caret moves while latched are the routing signal.** Click/arrow/⌘-Tab between segments ⇒ the
      next segment lands at the new caret (via V4.2/V4.3). App switch mid-segment ⇒ that segment goes to
      Notes, not to the new app (V3 §8 "pause delivery, hold, require explicit resumption").
- [ ] **V4.35 Notes mode.** No focused text field ⇒ segment goes to a Notes row (`HeldTextStore` already
      exists with Insert here / Copy / Discard); a **Notes** section in the main window lists the session
      as a running transcript with timestamps; "Insert all" places it at the current caret. The pill shows
      `📝 notes · 3` while in this state. Ambient (§10.7) writes to the same store, transcript-only.
- [ ] **V4.36 Speaker + level gate per segment** (§3 B and D) before delivery in latch; segments that fail
      go to Notes greyed, never to the field.
- [ ] **V4.37 Field context in the latch hold path** (replace `joinedText` raw injection with the lander's
      continuation, V4.13).
- [ ] **V4.38 Visible state:** latched pill shows the design's timer (the pause countdown ring is withdrawn to match the verified design), so the user
      learns the rhythm. Escape cancels the pending segment only (V3 §4.3).
- Future (voice computer-use, cf. infina.so): the latch loop above is the always-on channel; segments
  that parse as commands route to `ActRouter` instead of the lander. Nothing in V4.32–V4.38 needs to change
  for that.

---

## 11. Fix list, ordered

| Pri | Items | What the user sees fixed | Gate (evidence) |
|---|---|---|---|
| **P0** | V4.9, V4.10 | No more "audio format mismatch" / "start timed out" | 200 presses across built-in, AirPods, Continuity: 0 start failures (`hardware-verified`) |
| **P0** | V4.32, V4.33, V4.28 | Latch lands every 2 s; no ink on bare drags | 5-minute latched session in Docs + Claude: ≥ 95 % segments land at the right caret |
| **P0** | V4.21, V4.22 | No phantom text | 50 silent holds: 0 landings |
| **P1** | V4.1–V4.4, V4.13, V4.16 | Mid-sentence words land lowercase, no period, correct spacing | 30 placements × 5 apps, ≤ 2 wrong |
| **P1** | V4.18 (V4.19–V4.20 superseded by the design) | Notch stops crying wolf | 0 warnings on the quiet-room corpus |
| **P1** | V4.11–V4.13 | `5150`, `1234` | digits class WER < 0.20 on the corpus |
| **P1** | V4.6–V4.8 | First press works < 1 s after the menu icon appears | cold launch → first landing p95 < 2.5 s incl. model load |
| **P2** | §3 A, B, C, then D | TV ignored | TV-on corpus (record 20 utterances): inserted TV words = 0, user WER unchanged ± 0.02 |
| **P2** | V4.35, V4.34, V4.36 | Notes mode; caret routing; other voices held | manual session script |
| **P2** | V4.24–V4.25 | Questions get `?`, clauses get commas | 40-utterance prosody corpus, ≤ 10 % wrong marks |
| **P2** | V4.53–V4.56 (§13) | Docs / canvas apps get caret context; deixis box carries a screenshot | 30 placements in Docs, Sheets, Figma: ≤ 3 wrong spacing/case; box OCR matches AX text where both exist |
| **P3** | V4.14, V4.15, V4.26, §3 E–G, V4.5, V4.17, V4.29–V4.31, V4.52, §12 items | Coverage and polish | per item |

**Rules carried from V3.** Real recordings first; every gate labelled implemented / fixture-verified /
hardware-verified; flags never deleted, defaults set by measurement; nothing revises text after it lands.

### 11.1 Owner actions (cannot be done on the build machine)
See §12.7 for the step-by-step procedures.
- [ ] Record the corpora: **real-room v2** (the existing 20-line script, again), **TV-on** (20), **prosody** (40).
- [ ] One AirPods session for V4.9/V4.10.
- [ ] Set the 🌐/fn system action to "Do Nothing" before switching the default key (§12.6).

---

## 12. Answers and additions from the owner review (18 September)

### 12.1 Is the accessibility (AX) context helping us today?

| Use of AX | Today | After V4 |
|---|---|---|
| **Field role** (terminal / code / password / URL / spreadsheet / prose) → which formatter runs, secure-field refusal, submit rule | **Yes, works** — roles are exposed by native apps and by Chromium form controls | unchanged |
| **Text around the caret** → spacing, capital, period | Works in Cocoa text views (Notes, Mail, TextEdit, Xcode, Messages) and WebKit; **wrong** in Chromium/Electron editors (stale value, missing range ⇒ "end of field"); **nothing** in canvas editors (Docs, Sheets, Figma) | V4.2/V4.3 make it *correct or honestly unknown* everywhere; *known* in more apps (marker ranges in WebKit/Chromium); still unknown in canvas editors → §12.2 |
| **Window text** → vocabulary biasing (`ContextHarvester`) | **Not helping at all**: `contextBiasing` is off and the shipped biaser cannot change a word (V3 §2.3). The harvest is pure cost today | out of V4 scope; only worth keeping when a decoder that consumes it exists |
| **Deixis** (this/that → element) | Wired, untested on hardware | §9 |

So the permission is earning its keep on *what kind of field* and, in native apps, on *where the caret is*. It
was never able to deliver "the surrounding text" in Docs, and V4 does not pretend it will.

### 12.2 Google Docs and other canvas editors: are we in the dark?

**Mostly, yes.** Docs draws the page on a `<canvas>`; the DOM holds no page text. The focused element is a
hidden contenteditable iframe that receives keystrokes; its AX value is empty or stale. `AXWindowReader`
gets the outline sidebar, comments and toolbar — not the document. The same is true of Sheets, Slides, Figma,
Miro, and partially of Monaco/VS Code (hidden textarea with the current line only).

Three ways to get context back, in the order we should try them:

```
                 cost   caret?   text around caret?   whole doc?   works offline?
1 landing memory  low    yes*    yes* (only what we typed) no        yes       * until the user moves the caret
2 screen OCR      med    maybe   yes (visible lines)  visible page  yes
3 Docs API        med    no      no                   yes           no (OAuth)
4 Docs a11y mode  low    yes     current line         no            yes       (needs "screen reader support" on in Docs)
```

1. **Landing memory (V4.16)** — we know exactly what we typed last and how it ended. While no click,
   arrow key or ⌘-Tab has been seen, the caret is where we left it, and spacing/case follow from our own
   text. Covers the common "dictate several sentences in a row" case in *any* app.
2. **Screen OCR around the caret** (design in §13) — ScreenCaptureKit crop of the focused window, Vision text
   recognition, caret found by the blink (two frames 300 ms apart) or by the last landed text (we OCR
   for the string we just typed). Gives the previous and next line verbatim. Shares the Screen Recording
   permission and the code path with the deixis box (§9 V4.29). `hypothesis`; 150–300 ms on M-series.
3. **Google Docs API connector** (OAuth, like the Gmail/Calendar connectors) — full document text,
   vocabulary and style, no caret. Combined with 1 it tells us the sentence we are extending. Docs-only.
4. **Docs' own screen-reader mode** exposes the current line in a live region; if the user turns it on
   (⌘⌥Z) we can read it via AX. Worth a one-day probe before building 2.

- [ ] **V4.39 Context ladder.** `FieldContextReader` tries AX → landing memory → OCR (if permitted) →
      unknown, and records which rung answered, per app, so the ladder gets shorter over time.
- [ ] **V4.40 The Claude desktop app is not in `ElectronAdapter`** (`Injection/AppAdapter.swift:125`),
      so it falls to `DefaultAdapter` with `.ax` first — the AX write path the Electron comment says
      desyncs ProseMirror. Add `com.anthropic.claudefordesktop` (verify the id with
      `osascript -e 'id of app "Claude"'`).

### 12.3 Direction, distance, and the person sitting 2–3 ft away

**Direction: no.** macOS exposes the MacBook's three microphones as **one** beamformed channel; the
direction-of-arrival maths happens in Apple's DSP and is not accessible. AirPods likewise. No app on macOS
can tell which way a voice came from.

**Distance: partly, from one channel.** Cues, strongest first:
1. **Level** — −6 dB per doubling of distance. 1 ft vs 8 ft ≈ −18 dB (easy); 1 ft vs 2–3 ft ≈ −6 to −10 dB
   (borderline: a loud neighbour beats a quiet user).
2. **Direct-to-reverberant ratio** — far voices carry more room; measurable from the decay after each
   syllable. Weak indoors at 2–3 ft.
3. **Spectral tilt** — high frequencies fall off with distance; confounded by voice and mic.
4. **Modulation depth** — close speech has deeper syllabic energy swings (this is what the current
   "SNR" accidentally measures, §6).
Physics alone will not separate a neighbour at 2–3 ft. What will:

- [ ] **V4.41 Turn-anchored voice, no enrollment needed.** The user pressed the key, so the voice in
      the first 300–500 ms after key-down *is* the user for this turn. Take a speaker embedding of that
      window and reject later segments that do not match it (cosine < 0.6). Works for hold and for the
      first segment of a latch; for a latch the anchor is re-taken at each segment the user *confirms*
      (lands without "Not you").
- [ ] **V4.42 Diarize, then keep one cluster.** FluidAudio's diarizer is already wired for meetings
      (`Engine/Meeting/Diarization.swift`). In latch, run it on each segment; keep the cluster that matches
      the anchor / the enrolled voice; the other cluster goes to Notes greyed ("another voice").
- [ ] **V4.43 Enrolled voice (the strongest signal)** — §3 D, now in onboarding (§12.5).
- [ ] **V4.44 Apple "Voice Isolation" mic mode.** Available to any app that uses voice-processing IO
      (§3 A); the user picks it in Control Center, or we call
      `AVCaptureDevice.showSystemUserInterface(.microphoneModes)`. It suppresses other voices as well as
      noise. Free once A is wired.
- [ ] **V4.45 AirPods as the near-field mic** — beamforming and bone-conduction sensors reject other
      talkers better than any software here. Note: `InputSelectionPolicy` currently *avoids* AirPods when
      the link is narrowband (HFP 8/16 k), because narrowband hurts ASR more than the room does. Re-measure
      on AirPods Pro 2 with macOS 14+ (wideband mSBC) before changing that.
- [ ] Far future, opt-in only: **camera active-speaker detection** (mouth motion correlated with the
      audio envelope, Vision framework). Privacy-heavy; listed for completeness, not planned.

### 12.4 Meetings

**What happens today** (`code-verified`, `Engine/Meeting/*`, `App/Services/MeetingCoordinator.swift`)
- Meeting mode captures **two legs**: the mic and the system audio (`DualCapture`; system leg via a process
  tap with a ScreenCaptureKit fallback).
- **Video meeting:** mic = "You", system audio = "Others" (`ChannelLabeler`). Correct without enrollment.
- **In-person meeting in front of the laptop:** both people are on the mic leg. With an enrolled voice the
  diarizer splits You / Others (`EmbeddingLabeler`, cosine 0.6). **Without enrollment the fallback labels
  everything the mic hears as "You"** — so yes, it records both, and it attributes both to you. Another
  reason for §12.5.
- **Dictation during a meeting:** the microphone has one owner. `SessionCoordinator` ranks hotkey (3) >
  menu (2) > meeting (1), so holding the key **pre-empts the meeting capture** for that utterance and the
  meeting loses those seconds. Latch and meeting cannot run together today.

**Proposed** — one capture, many consumers:

```
            ┌─ mic leg ──► diarize ──► "You" ──┬─► meeting notes (always)
DualCapture ┤                                  ├─► dictation segment while the key is held / latched
            └─ system leg ────► "Others" ──────┴─► meeting notes
```
- [ ] **V4.46 Meeting owns the mic; dictation subscribes.** Hold/latch during a meeting marks a span of
      the You-leg as a dictation segment (lands at the caret via the lander) *and* it stays in the notes,
      tagged "dictated". The meeting never loses audio. Video meetings: the other app keeps reading the mic
      as before (macOS allows multiple readers).
- [ ] **V4.47 Latch inside a meeting** = the ambient/notes channel (§10 V4.35): everything you say goes to
      Notes; hold-to-talk inside it lands at the caret. Computer-use commands route the same way.
- [ ] Untested on hardware: in-person meeting, video meeting with system audio, the process-tap path.
      Add all three to the owner session (§12.7).

### 12.5 Speaker enrollment in onboarding

- [ ] **V4.48 New onboarding step `voice`** after `firstDictation`: "Read these four lines so VoicePlus
      knows your voice" (~30 s), reusing `SpeakerEnrollmentWindow`. Skippable; the Voice section keeps the
      re-enroll button. Enrollment sets `speakerFilteringEnabled = true` and assigns the latch guard.
- [ ] **V4.49 Passive enrollment as the fallback:** if skipped, the first ten hold-to-talk utterances
      (the user pressed the key — it is them) build the embedding silently; the pill says "voice learned"
      once.
- [ ] **V4.50 Ship the embedding weights** (FluidAudio speaker model) with the model download, so the
      MFCC fallback (`identifiesSpeakers == false`) is never what a real user gets.
- Default after V4.48: filtering **on** once enrolled, "Not you" visible in the pill for the first week.

### 12.6 Default key: fn / 🌐

- `.fn` already exists in `HotkeyStateMachine.Kind` (key code 63, `maskSecondaryFn`), so the change is
  the default binding in `HotkeyService`, onboarding copy, and tests. Existing users keep their stored
  binding; only fresh installs get fn.
- [ ] **V4.51 Default = fn; double-tap fn = Latch; hold fn = dictate.**
- **Caveat the onboarding must handle:** macOS gives the 🌐/fn key its own action (System Settings ›
  Keyboard › *Press 🌐 key to*: Show Emoji & Symbols / Change Input Source / Start Dictation / Do Nothing).
  A double-tap would open the emoji picker or Apple Dictation on top of our latch. Read
  `defaults read com.apple.HIToolbox AppleFnUsageType` (0 = Do Nothing); if it is not 0, show a one-line
  prompt with a button that opens that pane. Also: external non-Apple keyboards often handle fn inside the
  keyboard and never report it — offer Right ⌥ as the automatic fallback when no fn event is ever seen.

### 12.7 Owner procedures

**A. AirPods session for V4.9 / V4.10** (a "Continuity mic" is an iPhone used as a microphone via
Continuity Camera — not needed; AirPods exercise the same paths). 15 minutes:
1. Turn on **Save recordings** and open Console.app filtered on `subsystem:in.adityakatare.voiceplus`
   (or `/usr/bin/log stream --predicate 'subsystem CONTAINS "voiceplus"'`).
2. Built-in mic: 10 dictations. Note any start failure.
3. Put AirPods in mid-sentence (while holding the key). Then 10 dictations on AirPods.
4. In System Settings › Sound › Input switch back to the built-in mic *while latched*.
5. Take the AirPods out of the case, connect, disconnect (lid) three times between dictations.
6. Play music through the AirPods, then dictate (forces the HFP narrowband switch).
7. Leave the app idle 10 minutes, then dictate once (cold graph).
Send the log and the Recordings folder. Pass = zero "format mismatch" / "timed out" and every start
< 1 s on the built-in mic.

**B. Recording a corpus.** The mechanism already exists: **Settings › Privacy › Save recordings of what I
dictate** writes `<stamp>-raw.wav`, `<stamp>-processed.wav`, `<stamp>.json` to
`~/Library/Application Support/VoicePlus/Recordings/`. The app keeps only the newest **20** (`UtteranceRecorder.retainedUtterances`); see **V4.52** —
the limit becomes 100 by default with a "keep all" option, so a corpus session no longer needs copying every 20.
1. Real-room **v2**: read `Fixtures/real-room/script.md` again on the built-in mic → copy to
   `Fixtures/real-room/builtin-v2/`. Keep the old pass; never overwrite. Re-recording is right: the
   1.10.0 capture graph differs from the 1.7 one the first pass was made on.
2. **TV-on**: same 20 lines, TV at normal volume 8–10 ft away, you 1 ft from the mic → `Fixtures/real-room/tv-on/`.
   Add a 30-second clip of the TV alone (hold the key, say nothing) as `tv-only-*.wav`.
3. **Prosody**: a new `Fixtures/prosody/script.md` (I will write it: 15 questions, 15 two-clause
   sentences with a pause, 10 exclamations, punctuation omitted from what you read) → `Fixtures/prosody/builtin/`.
4. **Neighbour** (for §12.3): 10 lines with someone speaking 2–3 ft away at the same time → `Fixtures/real-room/neighbour/`.
Only the `.json` manifests and scripts are committed; the `.wav` files stay on your Mac (git-ignored).
Replay: `VOICEPLUS_REPLAY=$PWD/Fixtures/real-room/<pass> swift test --filter replaySavedRecordings`.

---

## 13. Screen OCR: reading the caret context and the deixis box from pixels

**No separate model.** macOS ships an on-device text recognizer in the Vision framework (the engine
behind Live Text). Zero download, runs on the Neural Engine, returns per-line text with bounding boxes
and confidence. ScreenCaptureKit is already linked for the meeting audio fallback, so the capture side
is not new either. One permission (Screen Recording, optional, V4.29), one code path, two consumers.

### 13.1 One service, two consumers

```
                 ┌──────────────────────────────────────────────┐
                 │  ScreenCapture service  (ScreenCaptureKit)   │   one permission row
                 │  OCR service            (Vision text recog.) │   one code path
                 └───────────┬──────────────────────┬───────────┘
                             │                      │
        deixis box (§9)      │                      │      caret context (§1, §12.2)
        crop = the user's rectangle                 crop = 3-line band around the caret
        caret finding: not needed                   caret finding: the fragile step (13.3)
        AX: hit-test the rect → role, title, value   AX: selected range → before / after
        OCR: text inside the rect when AX is empty   OCR: line text when AX is empty
        output: image + text + element →            output: FieldContext → Continuation rules
                act router, repair grammar,                 (unchanged; OCR is just another way
                model prompt, notch chip                     to fill textBefore / textAfter)
```

Build order: the shared service and permission row first; the **deixis box** as the first consumer
(the crop is given, the payoff is visible in the notch chip); **caret OCR** second, adding only the
caret ladder on top. Capture must be asynchronous: the deixis screenshot happens while the key is held
and the user is dragging, and must never block audio or the overlay.

### 13.2 Caret context, end to end

```
key-down ──► snapshot the focused window (SCK window filter; works when partly covered)
               │   ~10–30 ms, pixels in memory only, at the display's backing scale
               ▼
           find the caret ── first rung that answers (13.3)
               ▼
           crop a band: 3 text lines high × window width, around the caret
               ▼
           Vision text recognition on the crop ──► lines + per-character boxes
               │   fast level ~30–60 ms · accurate ~100–300 ms · runs in parallel with the final ASR pass
               ▼
           line under the caret, split at caret x ──► textBefore / textAfter (+ previous and next line)
               ▼
           FieldContext (the struct the AX path fills) ──► Continuation rules, unchanged
```

| Item | Detail |
|---|---|
| Permission | Screen Recording, optional row in `PermissionMatrix`; macOS 15 re-prompts periodically, so it is opt-in and explained |
| Latency | hidden behind the final decode when capture starts at key-down; crop the band, never the whole window |
| Retina | screenshot is pixels, AX and mouse are points — multiply by the display scale factor |
| Privacy | frame lives in memory for one utterance; never written, never synced, never in the Timeline |

### 13.3 Caret position — the ladder

Cheapest and most certain first; take the first rung that answers. Two rungs that disagree by more
than one line ⇒ `unknown` (V4.2 handles it safely).

1. **AX bounds for the selected range** (`kAXBoundsForRangeParameterizedAttribute`) — the caret
   rectangle directly, in native apps and most WebKit views. Zero cost when it works.
2. **Text-marker attributes in Chromium and WebKit** — browsers expose marker ranges and their bounds
   even when the plain selected-range attribute is empty. Probe on Docs specifically.
3. **Landing memory** — OCR the band for the exact string we last landed; the caret is at its end. The
   most reliable rung in Docs: we know the string and it was typed seconds ago.
4. **Last click** — mouse-down point from the event monitor, snapped to the nearest OCR line and
   character box. Valid until any key event or scroll.
5. **Blink diff** — three frames ~150 ms apart; the caret is the only 1–2 px column, one line tall,
   that toggles between frames. Reject if keys or mouse moved during the window, or if more than one
   candidate toggles.

```
   frame 1     frame 2     frame 3        diff(1,2) ∧ diff(2,3)
   abc|de      abc de      abc|de   ──►   a 1–2 px column, line-height tall, inside the text band ──► caret
```

6. **Selection highlight** — a solid colour block in the band; its right edge is the insertion point,
   and it tells us to *replace* rather than insert.
7. **Arrow-key tracking between rungs** — needs key events, i.e. the Input Monitoring escape hatch the
   app already has; stays optional.

Target: rungs 1–4 answer in nearly every real case; blink diff exists only for the first placement
after a click in a canvas app.

### 13.4 Character-level accuracy

1. **Native pixels.** Capture at backing scale, not points: 11 pt Docs text on Retina is ~30 px tall,
   which Vision reads well. Downsampled captures are the usual cause of bad OCR.
2. **Crop tight, upscale small text.** A 3-line band is cheap enough for the accurate level; under
   20 px line height, scale the crop 2× first.
3. **Language and correction by field role.** Language correction helps prose and hurts code and
   identifiers; `FieldRole` already says which.
4. **Custom words.** The request accepts a vocabulary: feed the learned lexicon and the harvested
   on-screen vocabulary — the one place the biasing harvest (§12.1) becomes useful.
5. **Punctuation by geometry, not glyph.** Period vs comma is the confusion that matters: the
   per-character box shows a comma descending below the baseline, a period sitting on it. Same for
   colon vs semicolon.
6. **Verify against what we know.** When landing memory has the last typed text, OCR must find it in
   the band; the edit distance is a live accuracy check, and a miss ⇒ `unknown`.
7. **Ask only coarse questions.** The continuation rules need three facts: a non-space character right
   before the caret? does the previous run end with a sentence mark? a character right after? Each is a
   yes/no, so a wrong letter elsewhere does not matter.
8. **Normalise the image.** Grayscale; invert in dark mode so text is dark-on-light (fewer errors on
   thin light-on-dark fonts).

### 13.5 macOS 14 lines vs macOS 26 document structure

| Use | macOS 14 (lines + boxes) | macOS 26 (paragraphs, lists, tables, typed data) | Verdict |
|---|---|---|---|
| Caret context | line under the caret + neighbours; enough for spacing and case | adds "last line of a paragraph" and reading order in two-column layouts | small gain |
| Deixis box | text inside the box as lines | a box over a table cell resolves to the cell; a URL/email inside comes out typed, so "send this" knows it is an address | real gain |

Character accuracy is the same generation of recognizer either way; the gain is structure, not glyphs.
Build on the macOS 14 API behind a small protocol (lines + boxes); add the macOS 26 request as a second
implementation chosen by OS version, for the deixis box only. Do not gate the feature on macOS 26.
Verify on hardware whether the newer recognizer adds Devanagari — that would matter more than structure.

### 13.6 What none of this fixes
- A caret scrolled out of view or in a collapsed window.
- Apps that draw no caret until the user types (some terminals) — field role routes those elsewhere.
- Wrapped-line boundaries where two rungs disagree on the "current" line — treat as `unknown`.

### 13.7 Items
- [ ] **V4.53 Shared capture + OCR service** behind `protocol ScreenTextReader { lines(in: rect) -> [Line] }`;
      ScreenCaptureKit window capture at backing scale; Vision text recognition; macOS 26 document
      request as the second implementation for the box.
- [ ] **V4.54 Caret ladder** (13.3) inside `FieldContextReader`, recording which rung answered per app.
- [ ] **V4.55 Accuracy measures** (13.4): native pixels, band crop + upscale, role-driven language and
      correction, custom words, geometry-based punctuation, landing-memory verification, dark-mode invert.
- [ ] **V4.56 Consumers in order:** deixis box (§9), then caret context; the same `FieldContext` struct,
      so the continuation rules never learn where the text came from.

---

## 14. Recording limit, and sequencing the work without the corpora

### 14.1 Recording limit
- [ ] **V4.52 Retention: 100 by default, "keep all" as an option.** `UtteranceRecorder.retainedUtterances`
      is a constant of 20 (`Engine/Audio/UtteranceRecorder.swift:27`). Make it a setting beside "Save
      recordings": *Keep the last 100* (default) · *Keep all* — with the folder size shown and a
      "Reveal in Finder / Delete all" pair. Each utterance is ~1 MB (raw + processed at 16 kHz), so 100
      ≈ 100 MB and "keep all" for a 200-utterance corpus session ≈ 200 MB. Add a `corpus` label field
      to the JSON manifest so passes can be tagged from the app instead of by folder.

### 14.2 Implement first, record later — yes, for almost everything

```
Wave 1 — no corpus needed                   Wave 2 — you alone, quiet room         Wave 3 — needs a TV / a neighbour
(wiring bugs, verified by code reading)     (measure & set defaults)               (thresholds only; code already built)
────────────────────────────────────────    ────────────────────────────────────   ───────────────────────────────────────
V4.9/10  audio format + start budget        real-room v2 (same 20 lines)           TV-on corpus  → §3 A/B/C thresholds
V4.32/33 latch endpoint loop + setting      prosody corpus (40 lines)              neighbour     → V4.41/42 anchor τ
V4.21/22 no-speech / hallucination guard    AirPods session (§12.7 A)              flags stay off / conservative until then
V4.1–4  caret model + continuation          V4.18 SNR thresholds
V4.11–13 numbers + renderedText             V4.24/25 prosody rules
V4.6–8  warm-up                             enrollment (§12.5) — your own voice
V4.27–31 deixis box + screenshot            V4.53–56 OCR in Docs / Sheets / Figma
V4.48–50 enrollment step + weights
V4.51  fn default
```

- The P0/P1 items are wiring and formatting defects found by reading the code; their acceptance is
  fixtures, unit tests and your ordinary daily use. **Nothing in Wave 1 waits for a corpus.**
- The corpus-dependent items (§3 A–D, §12.3 anchor threshold, §6 SNR thresholds, §8 prosody) are built
  **once**, behind flags, in Wave 1–2. The corpora only decide defaults and thresholds later. There is
  no second implementation — a flag flip and a number in `DECISIONS.md`.
- Recording on the *new* app is the right order anyway: the 1.10 capture graph already differs from the
  one the first 20 were recorded on, and Wave 1 changes it again (V4.7, V4.9). Recording before that
  would give numbers for a graph that no longer ships.

### 14.3 Stand-ins until you have a TV or a second person
- **TV-on:** any loudspeaker at 8–10 ft playing a news clip or a podcast from a phone. A TV *is* a
  loudspeaker; this is a faithful stand-in. Also record 30 s of the speaker alone.
- **Neighbour:** a phone playing a recorded voice 2–3 ft away is a *weak* stand-in (no real second
  human directivity) but good enough to set the level-gate and anchor thresholds; mark the pass
  `neighbour-synthetic` in the manifest and re-record with a person when one is around.
- Nothing in Wave 3 ships on stand-in numbers alone; the flags stay off until a real pass confirms.
