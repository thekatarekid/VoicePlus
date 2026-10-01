# DECISIONS.md — flag defaults and kill-criteria readings

Every release gate (Build doc §12) appends a dated entry. Rule of the house: flagged code
paths are never deleted; kill criteria (PRODUCT-SPEC Part 5) only flip `defaultOn`.

---

## 2026-08-23 — P1.12 T2/T3, Phase 1 integration

Hardware: Apple M2 Pro, 16 GB, macOS 26.6.2. Debug builds (`swift build`, no `-O`), so every
latency below is an upper bound for the release binary.

### Flag defaults after this review

| Flag | Bet | Default | Change |
|---|---|---|---|
| `contextBiasing` | 2 | **off** | flipped on → off (kill criterion hit on the real decoder — see below) |
| `voiceRepair` | 3 | **on** | unchanged |
| `dualPath` | 4 | **off** | unchanged (Phase 1.5 feature; nothing to enable yet) |
| `cloudASR` | — | **off** | unchanged (privacy default) |

### Bet 2 — context biasing (`contextBiasing`)

Two sets of numbers, deliberately kept apart.

**Synthetic (scripted top-K logit decoder, `Tests/EngineTests/BiasingFusionTests`):** 5
utterances with confusable entities, bias list of 7 terms.

| | entity recall | false insertion | added latency |
|---|---|---|---|
| biasing off | 33.3% | — | — |
| biasing on (greedy + shallow fusion) | 100% | 0.0% | 0.02 ms / utt, 1.9 µs per boost call |
| biasing on (narrow beam 3) | 100% | 0.0% | — |

Relative recall gain +200%, well past the ≥30% target. The algorithm works when it sits inside
the decode loop.

**Real model (Parakeet TDT 0.6B v3 through `LabWiring` "engine" transcriber, `entity` suite,
10 synthetic-TTS fixtures, bias list = the suite's 18 proper nouns fed as `ParticipantsSource`):**

| | WER | entity recall | false-entity | p50 final pass |
|---|---|---|---|---|
| biasing off | 20.8% | 31.6% | 3.7% | 569 ms |
| biasing on | 24.5% | 31.6% | 6.5% | 576 ms |

Entity recall did not move at all. The reason is structural, not statistical: the frozen
`FluidAudioTDTDecoder` wraps upstream's greedy TDT, and the only hook we have is
`BiasRescorer`, which re-scores log-probs of tokens *after* greedy already chose them. It cannot
change the path. The WER/false-entity differences between the two rows are run-to-run decoder
noise (the same file decodes differently across runs on ANE — e.g. "Quebec will get the pods" vs
"cubectal get pods"), not an effect of the flag. Worse, the rescorer inflates confidence on
bias hits, which weakens Bet 9's repair flagging.

**Decision:** kill criterion ("biasing doesn't move entity recall materially") is met on the
real path → `contextBiasing` goes **default-off**. Bet 1 (acoustic robustness) is the Phase 1
accuracy story. The code path stays, the Lab can still A/B it (menu flag), and the flag flips
back the moment the decoder fork exposes per-step logits (the synthetic numbers say it will pay
off). Tracked as the first item for the Engine workstream in Phase 1.5.

### Bet 3 — voice repair (`voiceRepair`)

**Alternate usefulness** (synthetic mangled set, 30 low-confidence errors mirroring the
confusions Parakeet makes on our fixtures, `Tests/EngineTests/RepairUsefulnessTests`):

| alternates offered | truth in top-3 |
|---|---|
| beam alternates only | 4 / 30 (13%) |
| beam + metaphone enricher over bias vocab + user dictionary | **26 / 30 (87%)** |

Target ≥60%, kill <40%: comfortably above target; the two honest misses are names absent from
every vocabulary. Grammar routing: 80 scripted commands, 100% (P1.6 tests).

**Lab, `commands` suite, real pipeline stage, degraded transcriber:**

| | WER | predicted zero-edit |
|---|---|---|
| voiceRepair on | 27.6% | 30% |
| voiceRepair off | 34.5% | 20% |

(The degraded transcriber corrupts every 5th word to "um"; with repair off the gatekeeper
treats "undo um" as dictation and types it.) **Decision: stays default-on.** Caveat, honestly:
the 87% is measured on a synthetic mangling set and on the real decoder the alternates come
from the confidence/WCN layer whose live top-3 hit rate has **not** been measured on human
speech yet. Re-read at the Phase 1.5 gate with the real-world suites from `Lab/FIXTURES.md`.

### Bet 4 — dual path (`dualPath`)

Not implemented in Phase 1 (P1.5.x). Stays off. No reading.

### Real-model accuracy baseline (for §12 regression tracking)

Parakeet TDT 0.6B v3, `VOICEPLUS_LIVE_MODELS=1`, model already cached under
`~/Library/Application Support/FluidAudio/Models`:

- Golden test (`ASRGoldenTranscriptTests`), 12 clean fixtures: **mean WER 2.9%**, max
  final-pass latency **146 ms** for 3–5 s utterances; EOU preview final partial WER 7.7%;
  RealEngine end-to-end on fixture: 10 previews, final 130 ms, WER 0.
- Lab harness, engine + full pipeline stage, all five suites (61 items):

| suite | WER | entity recall | p50 / p95 (ASR + pipeline) |
|---|---|---|---|
| clean | 3.5% | 66.7% | 514 / 828 ms |
| noisy (10 dB / 0 dB, far-field) | 9.7% | 100% | 538 / 622 ms |
| entity | 20.8% | 42.1% | 572 / 609 ms |
| technical (spoken code) | 30.9% | 36.4% | 496 / 610 ms |
| commands | 3.4% | 100% | 159 / 304 ms |
| **all** | **13.3%** | 50.0% | 525 / 610 ms |

The p50 here includes model prewarm on first item per run; the per-utterance final pass is
~110–150 ms. The `technical` suite is the weak spot (spoken symbols: "dash dash", "tilde
slash") — that is a formatter/register problem as much as an ASR one, and the CodeFormatter
only runs when the register is `code` (the fixtures have no app context). All numbers are on
macOS `say` TTS audio — an upper bound (see `Lab/FIXTURES.md`).

### Latency budget (T1)

`Tests/AppTests/IntegrationLatencyTests`: 10 s / 30-span utterance, MockEngine (instant final)
→ gatekeeper → prose formatter → style → mock injector, 20 runs after one warm-up:
**end-to-end p50 53 ms, p95 53 ms; pipeline-only p50 52 ms** (budget 700 / 1200 / 250 ms).
Add the real final pass (~150 ms for 10 s audio on M2 Pro) and the live AX write (~5–30 ms):
≈ 250 ms p50 expected on hardware; real-hardware measurement with a mic remains a manual step.

Hardening found during the 10k-word chaos run: `ConfidenceContract.verify` (O(n²) span scans)
and `EditDistance.levenshtein` (O(chars²)) stalled a single 10k-word utterance for >90 s. Both
are now near-linear (coverage index + prefix/suffix trimming + 4M-cell cap); 10k words take
~150 ms, a 100-utterance × 100-word session 0.6 ms per utterance. Also: the gatekeeper's Bayes
route model saturated on long narration and routed 1,000-word dictations as `question`; routes
other than dictate are now only considered for utterances ≤ 40 words.

### Thermal / battery soak (T3)

Spec asks for 2 h on fanless hardware; this machine has fans and the run here is 3 minutes via
`Packaging/soak.sh 3` (headless `VoicePlusApp --soak`, mock engine at 4× fixture pace → full
landing path, sampling every 5 s). Result (`Packaging/soak/20260823-235321.tsv`):

| t | thermal | process CPU | RSS | dictations | landed p50 | p95 |
|---|---|---|---|---|---|---|
| 5 s | nominal | 99.7% | 44 MB | 3,550 | 1.4 ms | 1.7 ms |
| 60 s | nominal | 99.5% | 144 MB | 23,399 | 3.5 ms | 6.2 ms |
| 120 s | nominal | 99.9% | 190 MB | 40,596 | 2.9 ms | 5.1 ms |
| 175 s | nominal | 99.7% | 301 MB | 57,282 | 2.8 ms | 5.3 ms |

Thermal state never left `nominal` at a deliberately saturated 100% core (the loop never
idles — ~330 dictations/s, ~1,000× a human rate); landing latency is flat, so no per-dictation
accumulation on the hot path. RSS grows ≈4.5 KB per dictation: the in-memory SQLite history
(dictation + injection-outcome rows) plus `ZeroEditTracker.outcomes`; at human rates that is
~2 MB/day and the production DB is on disk. First run of the script found a harness artifact —
the mock field grew without bound, making AX readback O(document) (latency 6 → 60 ms, RSS
516 MB over 5.7k) — the soak now gives each dictation a fresh field. Idle drain is not
measurable from this mode (no audio tap, no model); `pmset -g batt` is sampled to the
`.system.log` for the real run.
What this does *not* cover: the ANE/CPU load of the real decoder and the audio tap. A 2 h run
with `VOICEPLUS_LIVE_MODELS=1` on an M1 MacBook Air is **pending manual verification** before
the P1.13 DMG; the script and the app mode are ready for it (`Packaging/soak.sh 120`).

### Left manual

- Live mic → injection latency on hardware (needs TCC: mic + accessibility + input monitoring).
- 2 h soak on fanless hardware (above).
- Real-world fixture suites (`Lab/FIXTURES.md` backlog) before any kill decision is final —
  today's entity/technical numbers are from TTS audio.

---

## 2026-08-24 — Phases 3–6 integration (composition root)

One code agent wired the already-unit-tested modules into the app, one phase per commit
(P3 de94fc4, P4 cae24d4, P5 93f5369, P6 below). 930 → 959 tests, all green per phase;
`swift run VoicePlusApp` verified after each.

### Flag defaults after this review

| Flag | Default | Change |
|---|---|---|
| `contextBiasing` | **off** | unchanged (kill criterion stands; `LearnedLexiconSource` now feeds the ranker when it flips on) |
| `voiceRepair` | **on** | unchanged |
| `dualPath` | **off** | unchanged |
| `cloudASR` | **off** | unchanged |
| `directedSpeech` | **off** (new, experimental) | added for P5.1 hands-free |

### P3 — deixis
Timeline recorder + ink overlay + deixis/referent resolvers wired: `contextLine` lands in
`StageContext.extra`; ambiguity runs reverse elicitation (rings → clarifying pill text).
Acceptance: "move this over there" resolves both referents across two displays in the
scripted suite (Phase3AcceptanceTests). Live AX hit-testing/tap remain manual (TCC).

### P4 — act domain
Second key (default Right ⌘, own defaults key) holds the act domain open; deterministic
catalogue (200 entries, bundled into the .app) → consent → executor; agent fallback is the
native AX-only loop over a Providers-backed planner (unparseable plans give up, never
guess). Fuzz result: 200 random irreversible submissions, zero unconfirmed executions;
"open the PR tab and scroll to the failing check" passes over the mock action system.
Consent policy stays code-only (no user config). Connector OAuth needs client IDs via
environment; GitHub PAT path works without one.

### P5 — hands-free
**Harness reading (synthetic fixture corpus):** 12 addressed / 22 ambient clips →
0 false triggers (0.0/day, ship bar < 1/day PASS), 1 missed address (8.3%).
**Decision:** the ship bar is technically met but only on the synthetic corpus the
classifier was hand-tuned against — the spec's bar requires the recorded home+office
corpus. `directedSpeech` therefore ships **opt-in experimental (default off)**; flip only
after a real-corpus soak holds < 1 false trigger/day. Speaker gate rejects fixture
TV/noise audio at 100% in the acceptance suite; meeting capture produces diarized
("You"/"Others") transcripts + extractive notes fully locally. Unmute is never automatic.
Live always-on capture, Calendar/Screen-Recording usage strings and the notch prompt on
real hardware remain manual.

### P6 — adaptation, code-switch, sync
Corrections + post-dictation edits (zero-edit tracker now carries original/final text) →
`TrainingPairStore` → bias-list retrain (LoRA reports infeasible on-device, as designed) →
regression-guard stage + ranker source. Acceptance: day-30 personal WER < day-1 through
the wired loop; the corrected word is never re-mis-heard; Hinglish fixture lands as one
mixed-script string with the `EN·हि` pill badge; profile round-trips export→import and QR
pairing derives one shared key on both ends (key in Keychain, payload audited: no audio).
Indic RNNT weights are not shipped: `CodeSwitchRouter` is wired with the
`UnavailableIndicBackend` (routing reports why) until a backend lands — the merger/
indicator/injection path works with the primary recognizer today.

---

## 2026-09-11 — R5.4, the Qwen refinement benchmark (V3 §5.4, §10.1, §10.2)

Hardware: Apple M2 Pro, 16 GB, macOS 26.6.2 (build 25G83). **Debug** builds (`swift build`, no `-O`),
so every latency below is an upper bound for the release binary. Corpus:
`Fixtures/real-room/builtin` — 20 real dictations, references in `Fixtures/real-room/script.md`
(V3 Appendix A). Real weights: Parakeet TDT 0.6B v3 via `ModelManager`, Qwen3-ASR 0.6B int8 from
`~/Library/Application Support/FluidAudio/Models/qwen3-asr-0.6b/int8`. Nothing here is simulated or
estimated; the harness is `Tests/AppTests/RefinementBenchmarkCorpusTests.swift`
(`VOICEPLUS_REFINE_BENCH=1`), scored by `Lab/Harness/RefinementBenchmark.swift` and classified by
`Lab/Harness/SegmentClass.swift`.

### Flag defaults after this review

| Flag | Default | Change |
|---|---|---|
| `qwenRefinement` | **off** | unchanged — confirmed by the breakdown below; R5 is closed |

R5.3 (`45f4ec2`, `c903352`) switched the flag off on the corpus **means**. R5.4 owed the part of V3
§10.1 that a mean cannot answer: *is there a segment class on which the second pass wins?* If there
were, the honest outcome would be a narrowed gate, not a dead flag. There is not one, and the
paragraphs after the table say why the one cell that looks like a win is not one.

### WER by segment class — real-room corpus, 20 utterances

Arms: **parakeet only** (the shipping recognizer, and the baseline every better/worse count is
measured against) · **qwen only** (the second model as the *sole* recognizer, with the R4.1b context
prompt — not a shipping configuration, it answers "is this model better at recognition at all") ·
**two-pass (gated)** (the shipping arrangement: Parakeet, then the real `RefineStage` on the segments
`RefinementGate(mode: .auto)` selects, under the real 1500 ms deadline) · **two-pass (deadline
waived)** (identical with the deadline lifted — a diagnostic arm, so that "the pass has nothing to
offer" can be told apart from "the pass never finished in time").

| Segment class | n | parakeet | qwen | two-pass (gated) | two-pass (waived) | qwen better/worse | gated better/worse | waived better/worse |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **all** | 20 | **0.099** | 0.178 | 0.112 | 0.108 | 1/7 | 0/2 | 1/2 |
| < 5 s | 1 | 0.000 | 0.000 | 0.000 | 0.000 | 0/0 | 0/0 | 0/0 |
| 5–7 s | 11 | 0.048 | 0.081 | 0.059 | 0.051 | 1/3 | 0/1 | 1/1 |
| ≥ 7 s | 8 | 0.182 | 0.335 | 0.200 | 0.200 | 0/4 | 0/1 | 0/1 |
| entities | 7 | 0.081 | 0.197 | 0.102 | 0.089 | 1/4 | 0/1 | 1/1 |
| no entities | 13 | 0.109 | 0.168 | 0.118 | 0.118 | 0/3 | 0/1 | 0/1 |
| digits | 3 | 0.405 | 0.738 | 0.405 | 0.405 | 0/2 | 0/0 | 0/0 |
| number words | 4 | 0.045 | 0.044 | 0.045 | **0.023** | 1/1 | 0/0 | 1/0 |
| disfluency | 1 | 0.000 | 0.000 | 0.000 | 0.000 | 0/0 | 0/0 | 0/0 |
| explicit pause | 1 | 0.167 | 0.167 | 0.167 | 0.167 | 0/0 | 0/0 | 0/0 |
| technical | 2 | 0.038 | 0.077 | 0.038 | 0.038 | 0/1 | 0/0 | 0/0 |

WER is the mean of per-utterance WERs (R5.3's statistic, so the numbers compare directly). Pooled WER
(errors ÷ reference words) over the whole corpus: parakeet 0.099, qwen 0.171, gated 0.113, waived
0.108. Classes **overlap**: an eight-second sentence with a name and a digit is counted in three rows.
Per-utterance detail is in the harness output; the classification itself is pinned by
`Tests/LabTests/RefinementBenchmarkTests.swift`.

**How the classes are defined** (from the reference transcript and the audio duration only — never
from any arm's output, so no arm can influence which class it is judged in):
- **Duration** `< 5 s` / `5–7 s` / `≥ 7 s`. Corpus-fitted boundaries that cut 3.7–9.4 s into three
  non-empty parts. They are not product thresholds: the gate's own `longSegmentSeconds` is 12 s and
  **no utterance in this corpus reaches it**, so "≥ 7 s" here means "the long end of one dictated
  sentence", not long-form speech.
- **entities / no entities** — `EntityScorer.detectEntities` on the reference. Seven of twenty:
  02 Priya · 03 Kothari's, Thursday · 11 Carter, Road, Bandra, Mumbai · 12 Monday · 14 Sundays ·
  15 Friday · 17 swift. The heuristic counts day names and misses "Menon" in line 12 (because `Dr.`
  ends in a full stop, so the next token reads as sentence-initial). So this axis is
  "capitalised-token-bearing speech", not a curated name list, and is reported as such.
- **digits** — a decimal digit in the reference (04 11:45 · 05 2,340/2,430 · 11 400050): recognition
  *and* number formatting. **number words** — a spelled quantity (03 six · 02 four · 08 two/one ·
  18 three). Kept apart on purpose: the reference is verbatim, so a model that helpfully digitises
  "two" is scored wrong.
- **disfluency** — a hesitation token (only line 07, "um"). **explicit pause** — a marked mid-sentence
  pause (only line 16). **technical** — code/terminal vocabulary from a hand-written list in
  `SegmentClassRules` (lines 06 and 17); the list is in the source, but it is a human's list and not a
  property of the audio.

### There is no winning class. The one cell that looks like one

`number words` with the deadline waived (0.023 vs 0.045, n=4, 1 better / 0 worse) is the only cell in
the table where a second pass beats Parakeet. It is not a class win:
1. **It is one utterance** — line 02, where pass 1 heard "stand-up" and the prompt-primed second pass
   got "standup" (0.182 → 0.091). That is the *same single improvable segment* R5.3 already found, and
   its mechanism is a context near-miss, not number handling. It lands in this class only because
   "four" happens to be in the same sentence.
2. **It does not survive the deadline.** Under the real 1500 ms budget the same class is 0.045 —
   identical to Parakeet — because the pass that produces the gain does not finish in time.
3. **The class that actually tests number formatting is the worst one for the second pass**: `digits`,
   0.738 vs 0.405 (line 05 WER 1.200, line 11 0.800).

Everywhere else the second pass is equal or worse, and it is worse in exactly the classes R5 hoped it
would rescue: `entities` 0.197 vs 0.081, `≥ 7 s` 0.335 vs 0.182, `technical` 0.077 vs 0.038. `disfluency`
and `explicit pause` are ties at n=1 each and carry no information either way.

**Under the shipping deadline the two-pass configuration is strictly harmful on this corpus: 0 segments
improved, 2 made worse.** The gate fired on 6 of 20; of those six, 4 timed out at 1500 ms (pass-1 text
stood, as designed) and 2 completed — and both completions were regressions (line 15 0.000 → 0.143,
line 20 0.000 → 0.125). With the deadline waived the same six become 5 refined + 1 unchanged: 1 better,
2 worse. `RefineStage`'s fallbacks all behaved: every timeout kept pass-1 text and no committed span
was rewritten.

### Latency and peak memory (V3 §10.2)

| Arm | latency p50 | latency p95 | §10.2 budget | verdict | peak footprint |
|---|---:|---:|---|---|---:|
| parakeet only | 121 ms | 130 ms | final p50 ≤ 700 · p95 ≤ 1200 ms | **pass** | 90 MB (own process) |
| qwen only | 2249 ms | 3792 ms | (not a shipping path) | — | 1866 MB (own process) |
| two-pass (gated) | 128 ms | 1816 ms | refined p95 ≤ 1500 ms | **fail** | 1883 MB (both resident) |
| two-pass (deadline waived) | 128 ms | 1420 ms | refined p95 ≤ 1500 ms | n/a (diagnostic) | 2003 MB (both resident) |

Latency is per utterance, end to end for that arm (the two-pass arms include pass 1 plus the stage).
The two-pass p50 is Parakeet's number because the gate declines 14 of 20 segments; the p95 is what a
gated segment costs, and at 1816 ms it misses the 1500 ms budget even though the stage's own watchdog
fires at 1500 — the deadline bounds the second pass, not the total. In a separate isolated process the
Qwen arm measured p50 2387 ms / p95 4029 ms, i.e. 1.9–4.2 s per utterance, matching R5.3.

**Peak memory was measured, not estimated**: sampled `phys_footprint` (`PeakFootprint`, one sample per
utterance), with each arm's figure taken in a process where the models named beside it were resident;
the baseline before any model loaded was 25–26 MB. Two caveats, both real: `phys_footprint` does not
count memory-mapped `.mlmodelc` weights or ANE-resident buffers, so 90 MB is not "Parakeet costs
90 MB" (its weights are 461 MB on disk) — it is the footprint the process reports; and V3 §10.2 sets
**no numeric memory budget**, so these figures are recorded as §10.1 evidence rather than judged
against a target. The number that matters for the decision is the shape: enabling refinement takes the
resident footprint from ~90 MB to ~1.9–2.0 GB on a 16 GB machine, for the accuracy result above.

### Synthetic fixture suites (`Fixtures/audio`, 61 files) — and why they do not change the decision

| Suite | n | parakeet | qwen |
|---|---:|---:|---:|
| clean | 12 | 0.029 | **0.015** |
| commands | 10 | 0.000 | 0.067 |
| entity | 10 | 0.110 | **0.088** |
| noisy | 19 | 0.022 | 0.229 |
| technical | 10 | 0.179 | 0.325 |

Qwen is ahead on two of the five suites (overall it is still behind: 0.153 vs 0.060 mean, 0.161 vs
0.064 pooled, 8 files better / 21 worse). Those two are the *least* real conditions in the set — TTS
speech with no room, no noise and no disfluency — and `Lab/FIXTURES.md` says in writing that
kill-criteria decisions must not be taken on synthetic data. The real corpus contradicts the `entity`
result directly (entities class 0.197 vs 0.081), and the suite that simulates a real room at all,
`noisy`, is where Qwen collapses (0.229 vs 0.022) — the same direction as the real recordings. Recorded
as a signal to re-test if a future model changes, not as evidence for enabling anything.

### Decision

`qwenRefinement` **stays default-off, and R5 is closed.** All three of R5's gate conditions fail, now
with the breakdown behind each: no useful gain on difficult speech (no segment class wins; the classes
meant to be rescued lose), a clean-speech regression (`no entities` 0.118 vs 0.109, and both completed
refinements in the shipping configuration damaged previously perfect text), and the deadline unmet
(p95 1816 ms against 1500 ms; 4 of 6 gated segments timed out). The latch-only fallback V3 §10.2 offers
is **not** adopted either: it would only move a pass that is less accurate off the critical path, and
accuracy, not latency, is what fails here. No narrowed gate is proposed, so there is nothing for the
owner's 30-minute thermal check to decide — it is not required to close this item and was not run.

The code stays, per the rule of the house: `RefineStage`, `RefinementGate`, the Voice-tab Auto /
Always / Never picker and the Lab arms are all live and re-runnable (`VOICEPLUS_REFINE_BENCH=1`, one
arm per process via `VOICEPLUS_REFINE_BENCH_ARMS`). What would reopen the flag is a *measurement*, not
an opinion: a second pass that wins a segment class on real recordings by more than one utterance,
without a clean-speech regression, inside 1500 ms. V3 §5.3's MLX 1.7B route is the candidate that
would have to clear that bar on this same corpus.

### Caveats, stated plainly

- **n = 20, one speaker, one room, one microphone, one session, all English, one dictated sentence
  each (3.7–9.4 s).** Per class n is 1–13. No row in the class table carries statistical weight on its
  own; the decision rests on the direction being consistent across every class rather than on any cell.
- The corpus contains **no long-form speech** (nothing reaches the gate's 12 s threshold), **no
  non-English speech**, and **no second speaker**, so two of the gate's four conditions could not fire
  and the classes that would exercise them do not exist here.
- Debug build; all latencies are upper bounds. The accuracy figures are unaffected by that.
- Verified on one Mac (M2 Pro, 16 GB). The thermal behaviour of a 30-minute latched session with both
  models resident is **not measured** — it was not needed to close R5, and it must be measured before
  anyone reconsiders enabling refinement.

## R1.5 — the preview choice, measured (11 Sep 2026)

Recorded late: the agent that built the R1.5 harness was killed by a usage limit before it wrote this
section, so its commit (`74bd335`) landed the measurement code without the decision. Numbers below are
from re-running `previewCandidateComparison` on `Fixtures/real-room/builtin` (20 utterances, 220
reference words, real weights, 100 ms feed as `RealEngine` feeds live capture).

| candidate | WER | WER + light formatting | first word p50 | p95 | CPU s per audio s |
|---|---|---|---|---|---|
| A · EOU 120M stream (today's default) | 0.268 | 0.241 | 712 ms | 1210 ms | 0.14 |
| B · polling TDT v3, 1 s interval | **0.118** | **0.118** | 807 ms | 1989 ms | **0.08** |
| — final TDT v3 (reference, whole utterance) | 0.100 | 0.100 | — | — | 0.01 |

Neither candidate ever failed to produce a word (A 0, B 0 silent utterances).

**Two findings contradict the `previewBackend` flag's own doc comment**, which said A "is the measured
winner" and that B "misses the 300 ms first-word budget" as though A met it:

1. **Both candidates miss V3 §10.2's 300 ms preview budget, by a wide margin** — 712 ms and 807 ms p50.
   The 95 ms that separates them is small against the >400 ms by which both overshoot. Latency is
   therefore not a discriminator between these two; it is a shared, unmet target.
2. **B is less than half A's WER (0.118 vs 0.268) and costs less CPU (0.08 vs 0.14).** B lands within
   0.018 of the final recognizer, so what the pill shows while listening would nearly match what lands.
   A's 0.268 means roughly one word in four is wrong in the text the user is watching — which is
   precisely the "felt accuracy" complaint that opened V3 (§2.2, §14.1).

**What argues for keeping A anyway,** and why this is not a pure numbers call:
- B's tail is worse: p95 1989 ms against A's 1210 ms.
- B polls on a 1 s interval, so its preview arrives in chunks rather than streaming word by word. WER
  does not capture that difference in how responsive the pill feels, and no measurement here does.
- R2.4 now shows the **committed** text on land, which addresses the accuracy-perception gap by a
  different route than making the preview itself more accurate.

**Status: flag default unchanged (A) pending the owner's call.** Both paths stay in the build per
build-doc rule 5. The measurement is recorded here so the decision is made on evidence rather than on
the flag comment's incorrect premise; an interval shorter than 1 s (0.4 s was started and abandoned by
the killed agent) is the obvious third arm and is not yet measured.

## 2026-09-19 — F1, mic-quality thresholds (V4.18) · status: hypothesis

`MicQualityAnalyzer` v2 (commit `06dc150`) grades a real signal-to-noise ratio instead of v1's
syllabic modulation depth inside 300 ms of speech:

- **Noise floor** = p10 of 10 ms frame RMS over the pre-speech window (capture start → first VAD
  `speechStart`), when that window holds at least 200 ms (`minimumPreSpeech`,
  `Engine/Audio/MicQualityAnalyzer.swift:40`); otherwise the running minimum over the last 4 s
  (`runningFloorWindow`, `:42`). Frames below −100 dBFS are digital silence and never count.
- **Signal** = p90 of frame RMS over the VAD-speech frames of the first 1 s of speech
  (`signalWindow`, `:44`).
- **Emitted once**, as soon as both exist; `flush()` at stop grades only if speech was seen, so a
  pause is never graded. `lowLevel` only when speech peaks below −40 dBFS.
- **Verdict:** poor < 10 dB (`poorBelowSNR`, `:46`), bad < 5 dB (`badBelowSNR`, `:48`). The clipping
  bounds are kept from v1 (> 0.2 % poor, > 2 % bad).

**Status: hypothesis.** The 10 dB / 5 dB bounds are reasoned, not measured: they separate the
`Fixtures/audio/clean` set (every file ≥ 20 dB, `.good`) from `Fixtures/audio/noisy` (< 10 dB) in
`MicQualityV2Tests`, but no real-room recording has been graded against them. They are to be
calibrated on the `Fixtures/real-room` corpus in Wave 2 (per built-in / headset / far-field device,
the SNR at which WER starts to climb), and this entry updated with the measured bounds.

## 2026-09-19 — V4 Wave 1 + Spool design (1.11.0)

Build doc: `VoicePlus_ImplementationBuild_V4_Wave1+Design.md`. Five decisions this release rests on.

- **Default key is fn / 🌐 (I1, owner decision).** Was Right Control (and the verified design's
  copy says so). Why: fn is the one key every Mac keyboard has that no app binds. How: new installs
  get `.fn`; a stored binding always wins; every hint renders the configured key label. When macOS
  owns fn (`AppleFnUsageType` ≠ 0) onboarding and Settings › Shortcuts show the system-action prompt;
  no fn event in 3 onboarding presses offers Right ⌥. Revisit if the §5 item 12 fresh-account run
  shows the prompt confusing people or fn events missing on external keyboards.
- **Unknown caret is its own state (D1/D3).** `CaretState` = `known` · `endOfField` · `unknown`; a
  missing range is never read as end of field (the old `?? count` fallback is gone). With `unknown`:
  no leading space, ≥ 3 words keep the model's casing and punctuation, 1–2 words are stripped,
  StyleStage is off; landing memory (30 s, invalidated by any click/key/scroll/app switch) can
  upgrade it to `known`. Setting `formatting.unknownCaretStyle` = `sentence` (default) | `asSpoken`.
  Why: a guessed "end of field" added spaces and capitals mid-sentence. Revisit on §5 item 5 counts
  (> 2 wrong placements in 30 per app).
- **SNR thresholds are a hypothesis.** Poor < 10 dB, bad < 5 dB (entry above, F1). The replay of
  `Fixtures/real-room/builtin` failed the "0 warnings" gate 2 / 20 — not because of the bounds:
  the energy VAD opened at capture start and the analyzer graded the room as speech. Fixed by the
  F1 fix below (20 / 20 good, bounds unchanged; shipped in 1.11.1); calibrate per device class next
  and update the F1 entry.
- **Energy VAD floor hold; mic-quality verdict fed in VAD lockstep (F1 fix, 2026-09-19).** The
  built-in mic dips 10–20 dB below the room for 30–45 ms right after capture starts; `EnergyVAD`'s
  plain 4 s minimum took that dip as its floor and called the room speech from 0.01–0.15 s (18 / 20
  recordings). A level now has to last `floorHold` = 3 frames (60 ms) to become the floor — the
  minimum of each frame's 3-frame maximum. Cost: in a real room the steady floor reads ≈ 2–3 dB
  higher (white noise ≈ 0.3 dB), so onset needs that much more; fixture F1 0.983 → 0.986. Separately
  the analyzer took its verdict at the end of whatever block the ring handed over (same file: 26 dB
  serial, 8 dB parallel); `AudioPipeline` now feeds it one VAD frame at a time, just before the VAD
  hears that frame, and it takes the verdict at the exact 10 ms frame. Still open: the analyzer's own
  floors (pre-speech p10 over a short window, running minimum) have no hold, so on 9 / 20 files the
  dip is the floor and the SNR reads 6–26 dB high (never a warning) — settle before Wave 2
  calibrates the bounds. Revisit the hold if a device's start-up transient outlasts 60 ms.
- **Pill geometry follows the design (S2).** The pre-V4 ceiling of 560 × 96 (`absoluteMaximumSize`)
  is replaced by idle chin 64 × 14, hover hint 360 × 38 (≥ 190), active 560 × 164, actionable
  560 × 204, compact ceiling `min(560, usable − 32) × 204`, narrow < 460 with an 84 pt cameo bay;
  132 pt character bay, never text under Spool; floating 8 pt below the menu bar on external
  displays. Why: the design needs a tape lane, marks and an action row the 96 pt pill could not
  hold. Revisit if §5 item 7 shows the pill covering content on 13" displays.
- **Preview before insert (S3).** The final payload is shown for a dwell before any write: 900 ms
  default, 1800 ms when a span is low-confidence, 600 / 900 / 1500 / manual in Settings; hover,
  keyboard/VoiceOver focus or Review pause it; Escape during the preview inserts nothing; the
  destination is revalidated before the write (changed → held, D01). Manual waits for Insert /
  Replace text. Why: the user sees exactly what will be typed and can stop it; costs ~0.9 s per
  turn. Revisit with the §5 item 8 timings — if owners find 900 ms slow, lower the default before
  removing the preview.

## 2026-10-01 — A3, verdicts for the six dark flags (V5 §X20) · status: criteria written, V1 re-measure pending

The V1 public-set harness (lane 2a) was being built in parallel, so no flag below was re-measured on public
sets yet. Each verdict uses the evidence already in this file and writes a **kill criterion that a V1 run
decides mechanically**. Defaults are unchanged (all off). The text lives in each `FeatureFlag.description`
(shown in Privacy › Diagnostics) and `FeatureFlag.x20` lists the six.

| flag | verdict | evidence so far | kill criterion (decided by V1) |
|---|---|---|---|
| `contextBiasing` | **delete** | Bet 2: 0 entity-recall gain on the real decoder (post-hoc rescorer) | removed by A1 once B1 CTC boosting lands |
| `dualPath` | off | Bet 4: built, never measured | delete unless LibriSpeech test-other + Earnings-22 show ≥0.5 abs WER gain, no test-clean regression, ≤1.5 s added p95 |
| `cloudASR` | ship opt-in, off | privacy choice, not an accuracy bet | delete if still unused when RoutingTable routes ASR elsewhere (W8) |
| `directedSpeech` | off | P5: 0 false triggers on synthetic only | delete when O2/O3 ships unless V1 decide-stage replay (AMI/NOTSOFAR ambient) holds <1 false trigger/day |
| `previewBackend` | off pending V1 | R1.5: B WER 0.118 vs A 0.268; both miss 300 ms | flip on + delete EOU path if B ≥0.05 abs WER better with first-word p95 ≤1.5 s; else delete B |
| `qwenRefinement` | off | R5.4: pass-2 WER 0.178 vs 0.099, 1.9–4.2 s | delete in W8 unless a segment class gains ≥1.0 abs WER at ≤2.5 s p95 |
