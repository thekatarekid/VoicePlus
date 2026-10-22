# VoicePlus investigation — 2026-10-06: "it doesn't understand context"

**Scope.** The owner dictated "a16z" into ChatGPT Codex at 23:35 IST and got `A sixtien z. `. More generally, the app seems to ignore both the Dictionary and what is on screen, and types things that obviously mean nothing. This document explains why and lists everything that would make it feel magical.

**Status.** Investigation only. No app code was changed. One throwaway test harness was built in the session scratchpad (a 70-line C runner over the app's own `llama.framework` and GGUF). It is not in the repo.

**Evidence.** Code at c07e9b3. Installed app 1.15.4 (pid 46650). `voiceplus.sqlite`, copied and opened read-only (138 turn records, 84 history rows, 1,469 Dictionary rows). The saved recordings under `Recordings/`. `VoicePlus --replay` on the installed binary. Live runs of the on-disk Qwen3.5-2B GGUF.

**Confidence labels.** Same as the 10-03 doc:
- **Confirmed** means the code, the database and a run all agree.
- **Likely** means the mechanism is proven but the exact result has not been run.
- **Hypothesis** means it is not yet shown.

> **Update 2026-10-07.** Three corrections from new evidence. See `VoicePlus_ContextWriter_Plan.md` §0.
> 1. **The CTC booster harms.** It changed text in 6 turns: 4 worse, 2 lost punctuation, 0 better. "Adv this in your analysis" was booster damage (contact "Adv"), not the speech model. Contacts are re-admitted on chat surfaces and leak in: "Code", "Adv", "\*dial".
> 2. **"Polish" runs SpeakoFlow Mini 0.8B** (`cleanupDefault`), never the downloaded Qwen 4B, which serves edit commands only.
> 3. **§3's 2B result stands.** The 4B, with a neutral prompt, fixes 4 of 16 real failures at about 1.0 s. Higher numbers seen in this session came from a prompt that leaked the answers.
>
> **§4 is superseded** for everything after recognition by `VoicePlus_ContextWriter_Plan.md`. A1, A3, C1 and A6 remain inputs to it. A2 (screen terms into CTC boost) is withdrawn: screen terms go to the rewrite model instead.

---

## 0. The short answer

The app has five context systems. Each one is built and tested, and each one is switched off, empty, or forbidden from touching the word that is wrong. Every one of the 84 dictations in the history came out exactly as the speech model heard it: `finalText == rawText`, apart from spacing. The pipeline after the speech model has never changed a single word.

| Context path | Built? | What actually happens on your Mac |
|---|---|---|
| Dictionary → CTC vocabulary boost | Yes | All 1,469 Dictionary rows are Contacts imports, and Contacts are barred from boosting outside chat and email. The a16z turn had **0 boost terms**. Spoken forms you type in Settings are dropped before they reach the booster. |
| Screen terms → CTC boost | Yes | Gated by `screen-terms-lab.json`. That file does not exist, so this is **off**. |
| Screen + Dictionary → LLM cleanup | Yes | `llm.modes` is unset, so the default is "Fast path only" and the model **never loads**. If it were on, its rules forbid changing uncertain words. |
| Context-prompted Qwen3-ASR second pass | Yes | The `qwenRefinement` flag is **off**, and `RefineStage` is not installed in the app's pipeline. |
| H19 near-caret repair | Yes, and **live** | It only reads text *inside the focused input box*, which is empty in a chat composer. It never changes a word the recogniser was confident about. |

Even if all five were switched on, two more walls remain:
- The local 2B model fixed **0 of 6** real failures in a measured run (§3).
- Nothing learns from you. There are 0 captured corrections, 0 edited landings, an empty alias table and empty adaptation folders.

The design principle behind most of this is Bet 9: "never let a model silently smooth a low-confidence span." The implementation turned that rule into **"never touch an uncertain word"**. Those are exactly the words that context exists to fix. Bet 9's own example says the opposite should happen: *"team fuel h e"* should become *"TeamViewer AG"*. Today it would be typed as-is.

---

## 1. What happened to "a16z" (turn A8BE6058, 23:35:07 IST, ChatGPT Codex)

| Step | What it did | Evidence |
|---|---|---|
| Capture | 1.68 s of audio. Quiet input: −46.6 dBFS RMS, −32 dBFS peak. | `Recordings/2026-10-06-233509-411.json` |
| Context read | ~270 terms read off the screen (150 window, 119 near caret, 30 document tail) in 221 ms. | `stage_ms_json`: `ctx_cand_screenWindow 150`, `ctx_terms_nearCaret 119`, `ctx_read_ms 221` |
| Surface | `prose`, fallback "noEvidence". The Codex composer was not recognised as a chat composer. | `surface_signals_json` |
| Boost list | **0 terms, status `notApplied`.** Prose surface, so Contacts were excluded and no other source had anything. | `boost_terms 0`, `boost_status_notApplied 1` |
| ASR (Parakeet TDT 0.6B **v3**, multilingual) | `A sixtien z.` All three words were flagged uncertain. "sixtien" is not an English word. A replay of the same audio gives `A sixti.` | `uncertainSpans [[0,1],[2,9],[10,11]]`; `VoicePlus --replay 2026-10-06-233509-411` |
| H19 repair | Inert. The composer had no text before the caret, so there was no evidence. | — |
| LLM cleanup | Skipped: mode "off" (fast path only). | `defaults read in.adityakatare.voiceplus` has no `llm.modes` |
| Landed | `A sixtien z. ` by keystroke, verified. | `outcome` |

"a16z" is a special case: even a perfect recogniser would write "a sixteen z". Getting "a16z" needs either a vocabulary entry with a spoken form (`a sixteen z → a16z`) or a model with world knowledge. The app has neither on the live path.

---

## 2. Root causes

### R1. Your Dictionary contributes nothing to recognition (confirmed)

- All 1,469 Dictionary rows have origin `contacts` (`dictionary_term_meta`). You have typed in **zero** personal terms.
- N1 bars Contacts rows from the boost list (`App/Services/BoostingWiring.swift:35`, `Engine/Biasing/ContactsPolicy.swift`). The rubric re-admits them only on chat, email and name fields, at reduced weight.
- Result by surface:
  - Prose turns averaged 5.9 boost terms.
  - The a16z turn had 0.
  - Chat composers get 50 contact names, which are not useful in a Codex prompt. They changed the text in 3 of 68 turns.
- The reason for N1 was real: junk contact names such as "Bucket", "Cab", "Code" and "Cleaning" were rewriting ordinary words. The fix threw out the only vocabulary the app had and put nothing in its place.

### R2. Spoken forms are silently dropped, and alphanumerics have no spoken form (confirmed)

- Settings › Dictionary has a "spoken form" field, and the value is saved and synced (`App/Settings/DictionaryAppsEditors.swift:60`).
- `DictionaryOrigins.entries` then builds `DictionaryEntry(term:weight:origin:)` with no spoken forms (`Engine/Biasing/ContactsPolicy.swift:87`). From that point on, neither the booster nor the repair stage ever sees them. **The field does nothing.**
- Auto-derived aliases (`Engine/Biasing/HeardAliases.swift:14`) only split hyphens, underscores, slashes and camelCase.
- There is no number or letter verbalizer. So `a16z`, `k8s`, `S3`, `GPT-4o`, `i18n` and `YC` can never be matched against how they sound.

### R3. Screen context is read every turn and then thrown away (confirmed)

The app reads about 270 screen terms per turn, in about 240 ms on average across 114 turns. Then:

- **Boost:** `ContextRubric.Config.screenTermsInBoost = ScreenTermsDefault.enabled()` (`BoostingWiring.swift:85`). That is true only if a passing `screen-terms-lab.json` exists (`Lab/Harness/ScreenTermsReport.swift:101`). It has never been generated, so it is off.
- **LLM cleanup:** `LLMModes.default` is "Fast path only" (`Pipeline/Cleanup/LLMModes.swift:30-36`). `CleanupStage` returns `skipped:off` before the prompt is built.
- **Qwen3-ASR refinement:** the flag defaults off (`App/Settings/VoiceSettings.swift:42`, "mean word error 0.18 against 0.10"), and nothing in `App/` constructs a `RefineStage`. The 1.2 GB Qwen3-ASR model is on disk (`FluidAudio/Models/qwen3-asr-0.6b`) and unused.
- What the read *is* used for is the learning statistics in `context-learning.json`. Those record that screen terms matched the final text 5 times out of 566 offers. They match rarely precisely because nothing ever uses them to change the text.

### R4. The only live context consumer looks in the wrong place and freezes confident words (confirmed)

`ContextRepairStage` (H19) is the right idea: it swaps uncertain words for nearby terms that sound alike. But:
- **Wrong place.** Its evidence is only the focused field's own text before and after the caret (`App/Services/TurnSurfaceContext.swift:167, 196`). In a chat composer (Claude, Codex, Slack), which is where about half your turns land (68 of 138), the box is empty. The words that matter ("Phase 2", "subagents", "Finish dictation") are in the thread *above* the box.
- **Confident words frozen.** "Confident words are never changed" (`Pipeline/Repair/ContextRepairStage.swift:151`). Parakeet is confidently wrong on real-word homophones: `Finnish`, `surveillance`, `FaZe`.
- **Single-word swaps need close spelling.** A single-word swap also needs a spelling similarity of at least 0.7 (`:179`). "face" → "phase" scores 0.6, so it fails.
- **Replay test.** Replaying the three "phase two" recordings with `--near "...Phase 2..."` still gave `Till face two.`, `L FaZe Two` and `El says two.` You tried that phrase three times in 40 seconds.

### R5. Even with the LLM on, it is forbidden from fixing what is wrong (confirmed)

- **Locked uncertain words.** Uncertain spans become locked phrases that must appear verbatim:
  - the guard rejects any output that drops them (`Pipeline/Cleanup/CleanupGuard.swift:70`);
  - `map` refuses outputs that do not contain them (`Pipeline/Cleanup/CleanupStage.swift:217`);
  - the prompt says "Text inside ⟦ ⟧ is uncertain audio: copy it exactly" (`Pipeline/Cleanup/CleanupPrompt.swift:146`).
- **Overlap and length rules.** Any output with less than 60 % word overlap, or a length ratio outside 0.5–1.5, is rejected (`CleanupGuard.swift:67-68`).
- **Restrictive prompt.** The prompt also says "Keep names, numbers… exactly" and "Invent nothing".
- **The a16z case.** `A sixtien z.` → `a16z` fails three of these rules: locked words, overlap 0 %, and length 0.42.

### R6. The on-device model is not capable enough anyway (confirmed, measured — §3)

Qwen3.5-2B Q4 fixed 0 of 6 real failures, even with few-shot examples and the answer printed in the context. With a permissive prompt it also made new errors:
- it copied the context into the output ("Here is the competitor list.");
- it invented text ("till the end").

The on-device route needs a different model, not just a different prompt.

### R7. Nothing learns (confirmed)

- The `corrections` table is empty. `edited = 0` on all 84 history rows. `context-learning.json` has `"aliases": {}`. `Adapt/Pronunciations` and `Adapt/clips` are empty.
- AX readback cannot see edits inside Electron composers.
- The strongest correction signal you give is **re-dictating**: "phase two" ×3, "fan out sub variance" → "fan out surveillance". None of it is captured.

### Contributing problems

- **Multilingual ASR for an English-only user** (likely). Only English is set (`lang.languages = en`), but the final pass is Parakeet **v3**, the multilingual model. Non-English artefacts appear: `sixtien`, `FaZe`. Parakeet TDT 0.6B **v2** is English-only and scores better on English. This has not been measured on your recordings; replay can do it (§4, D1).
- **Uncertainty offsets are misaligned** (confirmed, a bug). Examples: `P⟦lace ⟧two.` and `It's a⟦ll ⟧r⟦ight.⟧`. The `uncertainSpans` character offsets drift from the text, so any underline, and anything that keys on those ranges, points at the wrong characters.
- **TV and background speech land as dictation** (confirmed in history). Examples: "Sixers bench for three…", "Jalen Brown…", the Roman Reigns paragraph. Separate from context, but part of "it types things that mean nothing".
- **Disk is 99 % full (5.5 GB free).** This blocks the 103 MB CTC model fetch if it is ever evicted, and any larger local model.

---

## 3. Measured: what the on-device 2B model does with your real failures

Runner: the app's `llama.framework` (b11321), `Qwen3.5-2B-Q4_K_M.gguf`, greedy decoding, the app's ChatML with an empty think block. M2 Pro, warm: **300–630 ms per call**.

| Heard (real) | Context given | Current app prompt | Permissive context prompt | Few-shot prompt | Wanted |
|---|---|---|---|---|---|
| `⟦A⟧ ⟦sixtien⟧ ⟦z⟧.` | none | A sixtien z. | A sixteen z. | A sixteen z. | a16z |
| same | "top seed investors…" + Sequoia, Accel on screen | *(echoed the context)* | *(echoed the context)* | A sixteen z. | a16z |
| `till ⟦face⟧ two` | Phase 1, Phase 2 on screen | till face two | **till the end** ✗ | till [[face]] two | till Phase 2 |
| `Is ⟦Finnish⟧ dictation…` | "Finish dictation" on screen | unchanged | unchanged | unchanged | Finish dictation |
| `fan out ⟦surveillance⟧…` | "subagents" on screen | unchanged | unchanged | unchanged | subagents |
| `⟦adv⟧ this in your analysis` | — | This in your analysis | **Here is the competitor list.** ✗ | advise this… | add this… |
| 4 clean controls | — | unchanged ✓ | unchanged ✓ | unchanged ✓ | unchanged |
| "Thursday, no, Friday" | — | Friday ✓ | unchanged | unchanged | Friday |

Conclusion: turning the current model on would add about 0.5 s and fix nothing. These rows should be easy for a frontier-class model given the same inputs, but that was **not measured here**. A cloud-model run is the next experiment. Wispr Flow, which uses cloud post-processing, is installed on this Mac: worth a side-by-side on these exact phrases.

---

## 4. How to make it feel magical

**The reframe.** Uncertain words are *where* context gets applied, not words to protect. Keep the two protections that matter:
- **Confident words stay put**, unless the swap is an exact on-screen term that sounds the same.
- **Every change must be acoustically plausible**, meaning it sounds like what was heard (phonetics, N-best or CTC spotting) **and** is supported by context.

That is Bet 9 as written. "Fluent and wrong" is prevented by the acoustic check, not by freezing.

### Tier A — switch on what is already built (days, no new models)

| # | Change | Fixes | Where |
|---|---|---|---|
| **A1** | Pass Dictionary spoken forms through to the booster and the repair stage. Add an **alphanumeric verbalizer** to `HeardAliases`: digits to words (16 → "sixteen", "one six"), letters to letter names, plus common shapes (`a16z`, `k8s`, `GPT-4o`, `S3`, `YC`). | a16z (once it is in the Dictionary or on screen) | `ContactsPolicy.swift:87`, `HeardAliases.swift` |
| **A2** | Screen terms join the per-turn boost layer by default: top ~50, nearest first. The CTC rescorer already requires an acoustic match, which is the safety. Generate the Lab report on the real-room corpus, or flip the default and watch `context-learning.json`. | Finish dictation, subagents, Phase 2 | `BoostingWiring.swift:85` |
| **A3** | H19 evidence comes from the **visible thread** (screenNear and window terms), not just the box: the last N messages in chat composers and terminals. Allow a confident word to change only for an exact on-screen term with a strong phonetic match (Finnish → Finish). Let multi-word forms ("phase two" → "Phase 2") pass the spelling gate. | Finnish, face two | `TurnSurfaceContext.swift:167`, `ContextRepairStage.swift:151,179` |
| **A4** | **Starter vocabulary**, so day one is not empty: <br>• a bundled tech, startup and AI lexicon with spoken forms (a16z, YC, Sequoia, kubectl, subagents, Claude Code, Codex, LLM, RAG, …); <br>• terms mined locally from your own corpus: identifiers and README terms from repos you dictate into, `~/Documents` titles, your own past dictations. <br>Recency- and frequency-weighted, and capped. | Jargon and names generally | new `Engine/Biasing` source |
| **A5** | Re-admit Contacts as **full names only**, and only people you interact with. This drops the "Bucket" and "Cab" single tokens that caused N1. | Names in prose | `ContactsPolicy` |
| **A6** | Fix the `uncertainSpans` offset drift. | Correct underlines and repair targeting | turn record writer |

**Likely outcome:**
- Finish/Finnish and subagents get fixed by A2 and A3, because both words were on screen.
- "phase two" gets fixed by A3.
- a16z gets fixed by A1 plus A4, or by A1 plus A2 when it is on screen.

All of this stays local, and there is no added latency beyond the CTC pass, which already runs.

### Tier B — a correction step that can actually think (2–4 weeks)

- **B1. Replace the cleanup guard with an acoustic-plausibility guard.** A change to an uncertain span is allowed when the replacement:
  - is phonetically close (G2P phoneme distance; FluidAudio ships G2P), **or** is in the recogniser's N-best or CTC detections, **or** is a context or vocabulary term.

  Confident spans are still protected, and preamble and paraphrase detection stays. Drop the global overlap and length rules in favour of per-span alignment, so `A sixtien z.` → `a16z.` can pass.
- **B2. Give the model the right inputs:**
  - per-word confidence and N-best;
  - the thread text (not only the box);
  - app and surface;
  - the vocabulary;
  - the user's last few dictations in this app.
- **B3. Pick a model that can do it** (the 2B cannot; §3). In order:
  1. **Opt-in "Smart correction" via a cloud model** (Claude Haiku 4.5 class). Only the transcript and capped context terms leave the Mac, shown in the data panel, with a kill switch. This gets the magic immediately. While there, update the stale defaults in `Providers/RoutingTable.swift:124`: `claude-3-5-haiku-latest` → `claude-haiku-4-5`.
  2. **A local error-correction fine-tune** of a 1–2B model on synthetic data: TTS of jargon, then Parakeet errors, then the correct form with screen context. This is the real local-first answer, and the Lab corpus tooling already exists.
  3. **A context-prompted ASR second pass on uncertain segments only.** Qwen3-ASR is already downloaded; Canary-Qwen is an alternative. Judge it on *entity recall on flagged segments*, not overall WER. The 0.18 vs 0.10 verdict measured the wrong thing for this job.
  4. **A bigger local general model** (8B Q4, ~5 GB). Needs disk you do not have, and adds ~1 s.
- **B4. Hide the latency.** Today release-to-text is **p50 455 ms, p90 966 ms** (79 turns). Run correction speculatively on the streaming partial while the key is still held, and re-run only on the changed tail after release. Prewarm already exists. Target: ≤150 ms added after release.

### Tier C — learn from the user (it should get better every day)

- **C1. Re-dictation is a correction.** Same app, within 30 s, previous landing replaced or deleted, phonetically similar: learn the alias `heard → written`. Your session today alone would have taught "a sixteen z", "phase two" and "subagents".
- **C2. Make uncertain words actionable.** Underline uncertain words in the pill and ribbon. Clicking one shows the alternates plus "Always write it as…", which adds a Dictionary entry with its spoken form in one tap.
- **C3. "No, a16z" by voice** (Bet 3 repair) writes a permanent alias.
- **C4.** Show learning visibly, for example "Learned: a16z". People forgive a miss when they can see it will not happen twice.

### Tier D — the acoustic layer

- **D1. Measure v2 against v3 for English-only users** on your 200+ saved recordings with `VoicePlus --replay`, and default to v2 when only English is enabled if it wins.
- **D2. Speaker and background gating** in hands-free mode, so TV commentary never lands. The voiceprint exists (`speaker-profile.voiceprint.json`).
- **D3. Input level check.** The a16z clip was −47 dBFS RMS. Hypothesis: a gain or AGC check in the mic-quality analyser would help marginal words.

---

## 5. How to know it worked

Add a Lab suite, "context-magic", built from your own recordings plus a screen-context fixture for each:

| Clip | Context fixture | Must land as |
|---|---|---|
| 2026-10-06-233509-411 | (none) / investors thread | a16z |
| 2026-10-06-230656-611, -230650-263, -230643-188 | plan with Phase 1–3 | … Phase 2 |
| "Is Finnish dictation…" (10-03) | Finish dictation on screen | Finish dictation |
| "fan out surveillance…", "fan out sub variance" (10-03) | Claude Code with subagents | fan out subagents |
| 20 clean dictations from history | their real screens | unchanged |

Gates:
- **≥ 80 %** of the targets fixed;
- **0** changes to the clean controls;
- **≤ 150 ms** added latency at p50.

Live metric: the share of turns where a context term was offered **and** landed (`context-learning.json`), plus re-dictation rate. Re-dictation rate is your real zero-edit rate in Electron apps.

## 6. Suggested order

1. **Week 1:** A1, A2, A3, A6 and C1. This is all local, uses existing code paths, and fixes most of today's failures.
2. **Week 2:** A4 and A5 (starter vocabulary and sane Contacts), plus the context-magic Lab suite.
3. **Weeks 2–4:** B1 and B2, with B3.1 (opt-in cloud correction) shipped behind a clear privacy toggle, and B4 latency hiding.
4. **In parallel:** B3.2 (local error-correction fine-tune) and D1 (v2 against v3 on your recordings).

## 7. Open questions for the owner

1. Is an **opt-in cloud correction** acceptable as the "magical" tier (B3.1), with on-device as the default? Or must the magic be local only, which makes B3.2 the critical path at 3–6 weeks?
2. Should the starter lexicon (A4) mine your repos and documents locally? It is on-device, but it reads files.
3. Should confident words *ever* change? Proposed: only to an exact on-screen term that sounds the same.
