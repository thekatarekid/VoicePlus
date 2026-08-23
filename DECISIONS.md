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
landing path, sampling every 5 s). Result: see the "Soak" block appended below by the run.
What this does *not* cover: the ANE/CPU load of the real decoder and the audio tap. A 2 h run
with `VOICEPLUS_LIVE_MODELS=1` on an M1 MacBook Air is **pending manual verification** before
the P1.13 DMG; the script and the app mode are ready for it (`Packaging/soak.sh 120`).

### Left manual

- Live mic → injection latency on hardware (needs TCC: mic + accessibility + input monitoring).
- 2 h soak on fanless hardware (above).
- Real-world fixture suites (`Lab/FIXTURES.md` backlog) before any kill decision is final —
  today's entity/technical numbers are from TTS audio.
