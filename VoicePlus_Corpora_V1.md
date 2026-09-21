# VoicePlus corpora, V1 — what the public sets can and cannot buy us

**Question asked:** is there an existing public corpus we can use instead of, or alongside, recording 60–100 of the owner's own Hinglish dictations?

**Scope:** five needs, in the priority order set by `VoicePlus_ModelResearch_V2_Multilingual.md` §4.1 — Hinglish ASR engine selection, English dictation A/B, endpointing/latch, speaker gate vs replay audio, and text-only cleanup. Everything here is checked against the dataset's own card, Zenodo/HF API record, OpenSLR index or paper. **No account was created, no gate accepted, no terms agreed, nothing downloaded.** Sizes come from dataset cards, the HF size API and HTTP response headers.

Written 21 Sep 2026; **licence-checked the same day — see §7, which corrected ten entries and changed the starter pack.** Companion to `VoicePlus_ModelResearch_V2_Multilingual.md` (which models) and `Lab/FIXTURES.md` (how a suite is added).

---

## 1. Answer

1. Public corpora **replace the elimination round, not the ship gate.** They can rank the five candidate Hinglish engines cheaply, reproducibly and on the same axis as the published leaderboard — which is the slow, expensive part of §4.1 step 5.
2. They **cannot** replace the owner's voice for: the speaker gate, his switching rate, his app vocabulary, his self-corrections, his mic and room, and his latch operating point. Every public corpus measures a different person.
3. **No public corpus is dictation-shaped.** Everything at scale is read speech, oratory monologue, or multi-party conversation. VoiceCodeBench's 5.59 h is the entire public supply of "one person dictating at a close mic", and it is English and test-only by design.
4. **No public corpus ships a fully-romanised Hindi reference.** Three independent human-annotated sets converge on *mixed* script. This makes §4.0's script decision asymmetric in cost, and that is the single most plan-changing finding in this document. **Survived an adversarial re-check in §7** — the largest aggregate (`agarwalayushi/hinglish`, 242.9 GB) is mixed-script too.
5. **Starter pack: 8 sets, ~10 GB, only two gates, both self-serve.** eot-bench(hi,en) → VoiceCodeBench → text-cleanup bundle → Vaani-Benchmark → ReMASC sample → ASVspoof 2021 PA (one part) → Svarah → Kathbath(hi). **HiACC and ASVspoof 2017 were demoted in the §7 licence check** — both are CC BY-NC per their own authoritative source, and VoicePlus ships commercially.
6. **Net effect on §4.1 step 3:** the owner's recording drops from 60–100 utterances to **~40** (30 floor), because the public sets do the 6-way elimination and his set only has to arbitrate a 2–3 way final and hold the ship gate.
7. He cannot skip recording. He can stop at roughly a third of what was planned.

---

## 2. Per need

Read every table with three columns in mind: **is the audio actually downloadable**, **what script are the references in**, and **may a derived fixture go into a public GitHub repo**. Those are our three binding constraints, and they eliminate more candidates than hours or WER ever do.

### 2.1 Hindi + Hinglish code-switched speech → second-engine bake-off

| Corpus | Hours (Hindi) | Style / mic | Script of references | Licence | Download route | Size | Verdict |
|---|---|---|---|---|---|---|---|
| **Vaani-Benchmark-V1.0** (ARTPARK–IISc) | 10.9 h, 5,050 segments, 1,103 speakers (the public 50%; the paper's full set is 20.64 h / 3,252 speakers / 104 districts) | Spontaneous, image-prompted; field/phone | **Mixed — confirmed.** The paper: "Code-switched content is transcribed in both the native script and the original script." The specific `{EnglishWord}` brace convention is **unverified** (card is behind the gate) | **CC BY 4.0 — confirmed twice** (HF `cardData.license: cc-by-4.0` + the paper) | HF, **gated** (`gated: auto` — self-serve) | 1.88 GB (card-reported; the size API is gated so this is unverified) | **Take.** The corpus behind §1.6's own numbers. Puts us on the published axis; 3 independent transcriptions per clip give a WER noise floor. Only 50% public; rest is a closed eval set. |
| **HiACC** (Hinglish Adult & Children CS, 2025) | 5.24 h (3.22 adult / 2.04 child), 44 speakers | **Read + spontaneous**, phone voice recorder, **16 kHz mono WAV, close mic, one speaker per file** | **Mixed** — paper: Devanagari for Hindi words, Latin for English words | **Resolved against us — CC BY-NC 4.0.** The paper states it verbatim ("Open access for academic/research use under a CC BY-NC 4.0 license"); the Zenodo metadata field says `cc-by-4.0`. The authors' own prose is the stronger statement | **Zenodo, direct, no login** (`Corpus.zip`, 531.6 MB — size read from the Zenodo API) | 531.6 MB | **Demoted from "take first".** Still the closest acoustic match to dictation in existence, but NC blocks a shipping product, and the paper says the transcripts came from **Whisper** while the Zenodo description says "manually transcribed" — reference quality is itself unresolved. **Do not anchor the pack on it.** Ask the authors to confirm CC BY before any use |
| **Kathbath / IndicSUPERB** (AI4Bharat) | 137 h (42 M / 95 F), 101 Hindi speakers | **Read** IndicCorp sentences, participants' own phones (Karya app), recorded at night | **Devanagari** (source is native-script; charset alphanumeric-only) | **Conflicted.** Card body says CC0 with an explicit waiver; the HF record's `cardData.license` and its licence tag both say **`cc-by-4.0`**. Treat as CC BY 4.0 + attribution | HF, **gated** (`gated: auto` — self-serve) | Hindi config ~16.3 GB / 94,903 examples, m4a | **Take the valid split**, but it is **not** the zero-obligation source this doc previously claimed. Monolingual-Hindi control arm: too clean, no code-switching |
| **IndicVoices** (AI4Bharat) | ~65 h labelled Hindi train, 287 speakers | 8% read / 76% extempore / 15% conversational; deliberate device diversity | Native script; Roman-vs-Devanagari rule for English words **not stated — unverified** | CC BY 4.0 | HF, gated | 745 GB total — streaming only | Right *content* (real code-mixing, extempore), wrong mic. Hard-case set, not primary. |
| **MUCS 2021 sub-task 2 Hi-En** (OpenSLR 104) | 89.86 h train + **5.18 h test** | Read/lecture — IIT Bombay Spoken Tutorial, CS tech lectures, 16 kHz | **Mixed (inferred, not stated)** — the MUCS lexicon rule presupposes non-Devanagari words in the same transcript | **CC BY-SA 4.0** | **openslr.org, direct tar.gz, no login** | test **443 MB** | Optional. Real CS, ungated, and the *software-tutorial* domain is the nearest public match to the owner's IDE vocabulary. **ShareAlike propagates to committed fixtures.** |
| **Svarah** (AI4Bharat) | 9.6 h Indian-**English**, 117 speakers, 65 locations / 19 states | Read + spontaneous; payments / govt services / grocery (entity-heavy) | English, Latin (not stated on card — unverified) | **Unverified — no licence anywhere reachable.** The HF record carries **no** `license` field and no licence tag; the GitHub repo has no LICENSE; the paper says only "publicly available". Third-party blurbs assert CC BY 4.0 but no primary source confirms it | HF, gated (`gated: auto`) | 1.1 GB (card-reported, gated) | **Take for local eval** — but **do not commit fixtures** until the licence is read on the card behind the gate. Belongs to need 2.2, not here. |
| **FLEURS `hi_in`** (Google) | ~12 h | Read FLoRes sentences, clean | Devanagari | CC-BY-4.0 | HF, per-language config | small | Cheap harness sanity check — reproduces §1.6's cited 17.15% / 19.12%. No CS, no dictation signal. |
| **Gramvaani / 1111-h** (OpenSLR 118) | 100 h labelled | Spontaneous **8 kHz telephone** | Devanagari (implied — unverified) | **Academic only**; commercial use needs written permission | openslr.org direct | 2.0 GB | **Blocked.** VoicePlus ships. Wrong band anyway. **Do not use, do not commit.** |
| **agarwalayushi/hinglish** | 2,264 h, 815k clips, 6,304 speakers | Compilation of **14 corpora** (NPTEL, Kathbath, IndicTTS, CV17, Mann Ki Baat, Orpheus TTS…) | **Mixed, tagged** — CS utterances carry `<hi-en>` | Aggregate CC BY 4.0, but constituent rows say only "See source" | HF, **not gated** | ~243 GB | **A map, not a source.** Exceeds disk. Never commit without tracing a clip's upstream. |
| **Shrutilipi** / **IndicVoices-R** / **Vaani (full)** | 6,400 h / 1,704 h / 14,924 h | AIR news / restored TTS corpus / spontaneous | unverified / unverified / mixed | CC BY 4.0 | HF, gated | 271 GB / 1.05 TB / 7.21 TB | **Skip.** Wrong register, restoration-processed, or reachable only by streaming. |
| **ULCA / Bhashini / Vakyansh** | 2,398.76 h labelled Hindi | YouTube creators, radio, news | unverified | **Corrected:** the GitHub repo *does* carry a **CC-BY-4.0** LICENSE file — but the README makes no statement about the audio's own terms, and the repo holds only the index and the GCS URLs, not the recordings. A repo licence over a list of links does not clear third-party YouTube/radio audio | Direct login-free GCS URLs | varies | **Ungated ≠ licensed.** Local eval at most, never commit. |
| **SPRING-INX** (IIT Madras) | ~2,000 h / 10 langs; Hindi split unverified | unstated | unstated | CC BY 4.0 | GitHub ESPnet recipe; **no working data URL found** | unverified | **Unverified — do not plan around it.** |

**Checked and does not exist / unavailable:** Fisher English–Hindi (no such LDC corpus), IISc-MILE Hindi (OpenSLR has MILE Kannada SLR126 and Tamil SLR127 only), Google/CMU crowdsourced Hindi multi-speaker TTS (Google's OpenSLR multi-speaker sets are gu/kn/ml/mr/ta/te — no Hindi), CoSHE (not found under that name anywhere), MSR 50 h Hi-En conversational (cited in surveys; no release page, licence or download; Microsoft's public Indian-language release is Telugu/Tamil/Gujarati), IITG-HingCoS (~25 h CS, 101 speakers, 8 kHz toll-free; paper states no licence, no download, "collection still in progress"), CS-FLEURS Hindi (**XTTS-generated synthetic**, licence reads "CC BY 4.0 for Non-Commercial use"). **Common Voice's route changed**: "Effective October 2025, Mozilla Common Voice datasets are now exclusively available through Mozilla Data Collective" — the HF `mozilla-foundation/*` mirrors are frozen at older versions.

> **Recommendation (revised after §7).** **Vaani-Benchmark** (1.88 GB, CC BY 4.0 confirmed from two sources, triple human transcription) is now the primary Hinglish arm and the only one that is both confirmed-licensed and on the published leaderboard axis. Its three independent transcriptions supply the WER noise floor R5.4 never had.
> **HiACC is demoted, not dropped.** It remains the only close-mic single-speaker Hinglish audio in existence, but its own paper says CC BY-NC 4.0 and we ship. Mail the authors; until they answer, it cannot be the fixture source and should not gate the bake-off.
> Add **Kathbath Hindi** as the monolingual control — but under **CC BY 4.0 + attribution**, not the CC0 "zero obligation" this doc previously claimed. There is now **no** source in this document we may commit clips from with no obligation at all.
> **Gramvaani, ULCA and `agarwalayushi/hinglish` are licence-blocked for a shipping product in a public repo** — evaluate locally at most, and not at all in Gramvaani's case.

### 2.2 English dictation-shaped speech → Parakeet v2 vs v3 vs Unified

| Corpus | Dictation-shaped? | Hours / size | Licence | Gate | Error classes it covers | Commit? |
|---|---|---|---|---|---|---|
| **VoiceCodeBench** (`besimple-ai/voice-code-bench`) | **Closest that exists.** 300 real-human English workplace segments, 85 speakers, single-speaker, tiers light→stress | 5.59 h / **1.96 GB — confirmed**, not extrapolated (HF `usedStorage`); 300 rows, single `test` split | **LICENSE read verbatim and confirmed.** MIT for everything outside `data/audio/`; the audio "may be used, copied, modified, and distributed" provided it is **not used, directly or indirectly, for Voice Cloning** and the notice travels with any copy — and permission **terminates automatically on breach**. Strictly stronger than the paper header's CC BY 4.0; the LICENSE binds | **None**. Test-only by design | **1,482 targets, 26 types**: numbers, currency, dates, times, phone numbers + extensions, versions, ports, IPs, env vars, file paths, CLI flags, commands, code symbols, URLs, emails, addresses, acronyms, spelled sequences, person/team names. Per-entity exact match on raw audio | **Yes**, with attribution + carry the no-cloning clause in a per-directory LICENSE |
| **Earnings-21** (`revdotcom/speech-datasets`) | Oratory monologue, close mic, long-form (44 calls) | 39 h; transcripts tiny, audio via Git LFS (size unverified) | **CC BY-SA 4.0** | None | **The best-annotated error-class schema found.** Token-level `.nlp`: punctuation, 4-way casing, and entity tags `MONEY PERCENT DATE TIME YEAR CARDINAL ORDINAL QUANTITY ALPHANUMERIC ABBREVIATION WEBSITE CONTRACTION PERSON ORG GPE PRODUCT` + **`FALLBACK` = partially-spoken words ("th-", "lo-")**, the self-correction signal | Yes — **share-alike**; needs its own LICENSE.md in the fixture dir |
| **Earnings-22** | Same shape, 125 calls, **27 countries / 7 language regions** incl. Indian-accented English | 119 h = 25.9 GB full; **Open-ASR 5 h subset = 1.10 GB** | CC BY-SA 4.0 | None | Same `.nlp` format; E22 card does not advertise E21's entity tags | Yes, share-alike |
| **Rev16** | 16 podcast episodes (the Whisper paper's set) | 16 h | CC BY-SA 4.0 transcripts; **Rev does not own the recordings** | None | **Paired verbatim ↔ non-verbatim transcripts of the same audio.** Verbatim keeps fillers, stutters, repetitions; non-verbatim is lightly edited. That pair *is* ground truth for what cleanup should delete | Transcripts yes. **Audio no** |
| **rev `multireferences` + `fstalign`** | n/a — a scoring fix | small | CC BY-SA 4.0 | None | Two independent human transcripts per audio; style-agnostic WER via FST references. **Feeds §4.1 step 0 directly** | Yes |
| **Svarah** | Indian English, 117 speakers, 19 states, read + spontaneous, entity-heavy domains | 9.6 h / **1.1 GB** (card-reported) | **Unverified — no licence on the HF record, the GitHub repo or the paper** (§7) | **HF gated** (`gated: auto`) | Indian-accented English with proper nouns — the failure mode Parakeet v3 actually has on this owner | **Not until the licence is read.** Local eval yes |
| **LibriSpeech** (OpenSLR 12) | Read audiobooks. Wrong shape | test-clean 346 MB + test-other 328 MB | **CC BY 4.0** | None | Essentially none of our classes — upper-case, unpunctuated, no numerals, no disfluencies | Yes — cleanest licence in the set |
| **LibriSpeech-PC** (OpenSLR 145) | Manifests only | **25 MB, text** | CC BY 4.0 | None | Punctuation + casing ground truth, and the **Punctuation Error Rate (PER)** metric. Cheapest high-value item in this whole document | Yes |
| **VoxPopuli (en)** | EP oratory, accented L2 | Open-ASR subset 0.94 GB | **CC0** | None | `raw_text` vs `normalized_text` pair. Few of our numbers/entities | **Yes** — no attribution obligation at all |
| **SPGISpeech** | Financial calls, **5–15 s utterances, ~50k speakers, fully formatted** — on paper the best ITN ground truth that exists | 5,000 h / 781 GB; Open-ASR subset 11.38 GB | Proprietary: "academic research and internal use only"; may not "publish, display, transfer or redistribute" | Registration + Terms + auth token | Professionally denormalised non-standard words + casing + punctuation + transcribed disfluencies | **Never.** And note `hf-audio/esb-datasets-test-only-sorted` serves `spgispeech/` **ungated** — that is a licence trap, not permission |
| **GigaSpeech** | Audiobooks + podcasts + YouTube | subset 4.03 GB | Card says Apache-2.0; agreement says non-commercial research only, and **SpeechColab does not own the copyrights** | Google Form + signed agreement | Punctuation as tags; upper-case | **No** |
| **TED-LIUM 3** | TED talks | 452 h | **CC BY-NC-ND 3.0** (corroborated by two secondary sources; the card itself stays unreadable) | Re-checked: `openslr.org/51` returns **HTTP 200 with a body reading "Resource not found: 51"** — delisted, not a 404; `LIUM/tedlium` on HF still **401** | Disfluencies marked | **Hard no.** `ND` means a clipped fixture is a derivative. Note it is the one short-form set *absent* from the ESB mirror |
| **AMI / ICSI** | Multi-party meetings — **anti-dictation** | AMI subset 1.30 GB | **CC BY 4.0** both; ICSI now downloads **directly from Edinburgh**, LDC is no longer the only route | None | Spontaneous disfluency, dialogue acts | Yes — but pick them up for §2.3, not here |
| **CORAAL / SLURP / PodcastFillers** | Interviews / assistant commands / podcasts | 62 h / 58 h / 145 h | **NC** (CC BY-NC-SA 4.0 / CC BY-NC 4.0 / NC annotations) | Free | PodcastFillers is the only large *audio* set with fillers and repetitions labelled at event level (~35k `uh`/`um`, ~50k non-filler incl. repeated words) | **No** — NC and we ship |
| **ContextASR-Bench** (MIT) / **ProfASR-Bench** (Apache-2.0) | 41,329 rows, 300k+ entities / 3.2k rows, typed entities | small | MIT / Apache-2.0 | None | Entity-dense lexical stress | Yes — but **both are TTS audio** (ProfASR from 4 Kokoro voices). Label every number from them synthetic |
| **Switchboard / Fisher / Mixer 6 / Speech Accessibility** | Telephone conversation / dysarthric | — | LDC agreement + fee; SAP needs an institutional DUA **plus a reviewed one-page research proposal** | Paid / institutional | Canonical self-correction annotation (reparandum/repair) | **No** |

**The Open ASR Leaderboard already answers the checkpoint question — do not re-run it.** Parakeet v2 **4.70** (en-IN 3.89) vs v3 **4.86** vs Qwen3-ASR 1.7B **4.31** (en-IN 3.50), plus all of Whisper / Canary / Granite / Voxtral, over 11 datasets and 60+ systems. What it *cannot* answer, and why a local harness is still required:
1. **Its normalizer deletes exactly what VoicePlus sells** — "removes punctuation, casing, filler words, applies number normalization and spelling standardization". Leaderboard WER is **structurally blind to ITN, casing, punctuation and disfluency removal**, i.e. the three jobs of §3.1's cleanup layer.
2. It scores **reference runtimes**, not a FluidAudio CoreML conversion or a GGUF quantisation. §1's whole lesson was that the *port* failed, not the model — the board cannot catch that class of failure.
3. It reports RTFx on server GPUs, not p50/p95 on an M2 Pro. The 700 ms / 1500 ms budgets in §3 are unmeasurable there.
4. Off the board entirely: Srota, Bodhan Indic-Transcribe-Flex, SraVaani (EN), Apple SpeechTranscriber.

> **Recommendation.** **VoiceCodeBench** is the English arm: ungated, dictation-shaped, and annotated for our exact 26 token types. **Svarah** is the accent arm the owner actually needs. **LibriSpeech-PC's PER** is the metric that sees formatting when leaderboard WER cannot.
> Steal **Earnings-21's `.nlp` schema before recording anything** — annotate R1/R2 in that format so the owner's set and the public sets are scored by one harness. `FALLBACK` is the self-correction marker; Rev16's verbatim/non-verbatim pair defines what cleanup should delete.
> Read the v2/v3/Qwen ranking off the leaderboard; spend the day on formatting metrics it is blind to.

### 2.3 Endpointing / turn-taking (latch-mode pause detection, incl. Hindi)

| Corpus | What it measures | Hindi? | Licence | Gate | Size | Commit? |
|---|---|---|---|---|---|---|
| **LiveKit eot-bench-data** | False-cutoff rate vs latency **Pareto frontier at every pause ≥ 100 ms**. Ships `silence_spans`, word timings, conversational `messages`. Repo has a VAP baseline adapter | **Yes — dedicated `hi` config, 400 rows / 132.8 MB, both confirmed via the size API.** Script resolved: the `words` field is **Devanagari** | **CC-BY-4.0 — confirmed** (HF record + card front-matter; benchmark code Apache-2.0) | **None** | `all` 5,454 rows / 1,892.9 MB; **`hi` 132.8 MB + `en` 162.4 MB**. Only a **`validation`** split exists | **Yes**, with attribution |
| **Pipecat smart-turn-data v3.1** | Binary `endpoint_bool` + `midfiller`/`endfiller` flags — closest label schema to our latch question | **Nominally yes, effectively no — confirmed by row inspection.** 1,295 rows at `language='hin'` (not `'hi'`), **every one `synthetic=true`, every one `dataset=chirp3_1`** (Google TTS), and **`spoken_text` is null throughout** — there are no transcripts at all | **None declared — confirmed.** HF API returns `license: null` on both repos; the code repo's BSD-2 does not cover the data | None | test 4.30 GB; **train 36.8 GB — exceeds disk** | **No** — no licence to rely on |
| **TurnBench** (Sesame) | End-of-turn **and interruption**, 6 domains, 30 h eval (154 dialogues, 106 actors) | **No — "TurnBench is English-only"** | Custom **non-commercial**, prohibits voice cloning | HF licence acceptance | 30 h + 104 h | **No** |
| **VAP / multilingual VAP** | Continuous 2 s-lookahead turn-shift and backchannel prediction | No Indian language (EN/ZH/JA) | Code public; corpora third-party & LDC-gated | — | — | Model only — **use it through eot-bench's VAP adapter** and skip the corpora entirely |
| **Switchboard / Fisher** | Turn boundaries, 260 h | No | LDC agreement + fee | Paid | — | **No** |
| **AMI / ICSI** | Spontaneous turn-taking, dialogue-act annotation, far-field + headset | No | CC BY 4.0 | None | AMI ~100 h, ICSI ~70 h | Yes — but conversational, a negative control at best |
| **CANDOR** | 1,656 naturalistic English conversations, multimodal | No | Data-request agreement | Registration form | **>1 TB** | **No** — size alone disqualifies |
| **HCRC MapTask** | 128 task-oriented dialogues, NITE XML + audio | No | GPL reported for the distribution (audio **unverified**); also sold as LDC93S12 | None on the Edinburgh page | Small | Low value — 1991 telephone audio |

**The structural gap:** every public endpointing corpus is *conversational* — dyadic or human-to-agent. **There is no public corpus of single-speaker dictation labelled "paused mid-thought vs finished."** This is the one place the owner's recordings are genuinely irreplaceable rather than merely convenient. A further mismatch: eot-bench rows carry a `messages` field of prior conversational context and its headline models consume it; our latch has no such context, so **evaluate audio-only on eot-bench** or the numbers will not transfer.

**New trap found while resolving the script question (§7).** eot-bench's `hi` `words` field is Devanagari, which settles §4.0's evidence question — but it is a **word-timing annotation, not a gold transcript**. The first Hindi row reads `नमस्ते और्जूंजी मेरा नाम पष्डी न्ट्र बजाज है`, in which `और्जूंजी` and `पष्डी न्ट्र` are not Hindi words; the field is plainly ASR-derived. **Use eot-bench for `silence_spans` and word boundaries only. Never score WER against it.**

> **Recommendation.** **eot-bench `hi` + `en`, 295 MB, CC BY 4.0, ungated** is the entire Hindi endpointing budget and it is redistributable. Take it.
> **Drop smart-turn** despite its reputation: its Hindi is 100% TTS and it has no licence at all. Anything we measured there would tell us how our detector handles *synthetic Hindi prosody*.
> Public sets calibrate the *mechanism* (threshold sweeps, false-cutoff-vs-latency curves). Only the owner's recordings can set the dictation *operating point*, where pauses are longer and a false cutoff costs far more than in a voice agent.

### 2.4 Speaker verification + REPLAY / PLAYBACK audio

| Corpus | What it measures | Licence | Gate | Size | Commit? |
|---|---|---|---|---|---|
| **ASVspoof 2017 v2.0** | **Replay rejection on real physical replay** — 179 sessions, **61 unique room × playback-device × recording-device configs**, 42 speakers | **RESOLVED — CC BY-NC 4.0.** The item's `dc.rights` field reads verbatim: "You are free to use this database under Creative Commons Attribution-NonCommercial License (CC-BY-NC)… CC BY-NC 4.0 International" | Download buttons present, no registration — **but NC is the binding term** | train 200.77 MB + dev 133.75 MB + eval 1.07 GB ≈ **1.4 GB** (sizes confirmed on the item page) | **BLOCKED. Drop it.** VoicePlus ships commercially, so NC rules out both the fixture and the evaluation. Superseded by ASVspoof 2021 PA |
| **ASVspoof 2021 PA** | Replay rejection, real rooms, varying replay-device quality | **ODC-By — re-confirmed** (Zenodo record 4834716, `license.id: odc-by`) | **None** (the eval-plan form is for challenge entry, not the Zenodo download) | **45.4 GB in 7 parts, sizes now read from the Zenodo API: part00–05 are 5.93–7.08 GB, `part06` is the smallest at 4.15 GB** → pull **part06 only** | **Yes**, with attribution — **now the replay arm of the starter pack**, and the only real-room replay set we may ship fixtures from |
| **ASVspoof 2019** | PA = **simulated** replay (acoustic simulation, less realistic); LA = TTS/VC | **ODC-By — re-confirmed**; the DataShare item's `dc.rights` reads "Open Data Commons Attribution License" | None visible | PA.zip 16.45 GB | Yes |
| **ReMASC** | **Exactly our failure mode** — genuine + replay-source + replayed, 4 mic arrays, 50 subjects; **Indoor 2 = lounge with music and TV in the background**; also outdoor and in-vehicle | **Use grant confirmed, redistribution still silent.** README verbatim: "The ReMASC corpus remains **free for academic and commercial use**, and we no longer require a verification process". No LICENSE file in the repo and no word on redistributing clips | Full set needs a **free IEEE DataPort account**; the **~10 MB sample is on Google Drive, ungated** | Full **92.3 GB**; sample ~10 MB | **Evaluate freely** (commercial use is expressly granted); **still do not commit** — redistribution is unaddressed, not permitted |
| **VoxCeleb1** | **EER on VoxCeleb1-O/-E/-H** — the standard speaker-gate yardstick | CC BY 4.0 "for research purposes"; copyright retained by video owners | Official audio **withdrawn** ("no longer available from this website"); key-request form at `cn01.mmai.io/keyreq/voxceleb`. All 6 trial lists are **directly downloadable text** | Ungated HF mirror carries `vox1_test_wav.zip` = **1.07 GB** (size read from HTTP headers) | **No** — YouTube-derived, research-purposes |
| **Kathbath / IndicSUPERB** | **Speaker ID and speaker verification for 12 Indian languages**, 1,218 speakers, 203 districts | **Conflicted (§7).** Card body: "AI4Bharat has waived all copyright and related or neighboring rights" (CC0). HF record: `cardData.license: cc-by-4.0` + a `license:cc-by-4.0` tag. **Take the stricter reading: CC BY 4.0 + attribution** | HF gated, `gated: auto` (self-serve) | Hindi config ~16.3 GB; full ~165 GB | **Yes, with attribution** — no longer "zero obligation" |
| **CN-Celeb** (OpenSLR 82) | Multi-genre EER, 11 genres incl. broadcast/movie | "Freely available for researchers" — wording **unverified** | None | 22 GB + ~75 GB | Unverified, low priority, Mandarin |
| **ASVspoof 5** | Crowdsourced, ~2,000 speakers, 32 attacks | LICENSE.txt on record — unverified | None stated | Large | **Wrong target** — LA/deepfake focused, no physical-replay partition |
| **RedDots Replayed** | Re-recorded text-dependent SV, 15 playback × 16 recording devices | Described as Creative Commons | **No live download URL found** | — | **Availability unverified** |

The distinction that matters for us: **ASVspoof's PA scenario is an attacker deliberately replaying at a microphone. Ours is incidental** — a TV or phone speaker in the room while the owner dictates. ReMASC's "Indoor 2" is literally that. Note also that our existing `Fixtures/directed/manifest.json` already encodes the right shape for this (`{file, label, scene, textFieldFocused, addressedRecently}`) — a replay suite is a third `label` value, not a new harness.

> **Recommendation (revised after §7).** Pull the **ReMASC ~10 MB sample first** — highest information per byte in this whole document, ungated, and its README expressly grants commercial *use*, so evaluating on it is clean. It tells us whether the 92.3 GB full set is worth a free IEEE account.
> **ASVspoof 2017 is out.** Its `dc.rights` is CC BY-NC 4.0, and we ship. The replay arm is now **ASVspoof 2021 PA `part06`, 4.15 GB, ODC-By** — the smallest of its seven parts, real rooms, and the only real-room replay set whose licence lets a fixture be committed. It costs ~2.7 GB more disk than the blocked 2017 set; that is the price of a licence we can actually rely on.
> **VoxCeleb1-O only** from the 1.07 GB test zip (E and H draw trials from the *training* partition — do not promise those numbers on that download), and **Kathbath** for Indian-speaker EER — **with attribution**, since the CC0 claim did not survive §7.

### 2.5 Text-only sets for the cleanup layer

| Set | For what | Size | Licence | Script | Commit? |
|---|---|---|---|---|---|
| **NeMo-text-processing ITN test cases** (`tests/nemo_text_processing/{en,hi,hi_en}/…`) | ITN ground truth as `spoken~written` pairs per semiotic class. **Covers lakh/crore/₹**: `एक लाख रुपये~₹१०००००`, `ढाई करोड़ रुपये~₹२५००००००`, `सवा दो लाख रुपये~₹२२५०००` | ~70 KB (`hi_en` 13 files, `hi` 12, `en` 22) | **Apache-2.0** | Hindi rows: **Devanagari words → Devanagari digits `०-९`**. English rows ASCII. `hi_en` mixes both | **Yes** |
| **Disfl-QA** | Paired `{original (fluent), disfluent}` English questions. **>90% are corrections and restarts** — our self-correction class, not just "um" removal | 11.8k pairs, few MB | **CC BY 4.0** | Latin | **Yes** |
| **Hinglish-TOP** (Google Research) | Short **spoken-command** Hinglish with English parallels: `mere timer ko roko`, `Kya hawaii me raining ho rahi hai?`, `Mere liye reminder set karo to wake up at 6:30 am tomorrow.` | human test 6,512 rows / 1.9 MB | **Apache-2.0** | **Fully romanised Latin Hinglish** (`cs_query`) + English parallel | **Yes** |
| **PHINC** | 13,738 romanised Hinglish sentences with **manual English translations** — the ideal "must NOT translate this" probe, because we hold the forbidden output | 2.1 MB | **CC BY 4.0** (verified via Zenodo API) | Romanised → English | **Yes** |
| **Dakshina** (Google Research) | **The set that settles §4.0.** Hindi: 25,000 native-script word types + 2,500 dev + 2,500 test with *human-attested* romanizations, ~10k romanized sentences. Validated by back-transcription | tens of MB (tar size unverified) | **CC BY-SA 4.0** | **Both, parallel — Devanagari ↔ attested Latin** | Yes, but **share-alike** — decide deliberately |
| **Aksharantar** (AI4Bharat) | 26M Indic↔Latin transliteration pairs; test 103k word pairs. **Feeds the transliteration-equivalence table §4.1 item 0 needs** | Hindi subset small | Manual CC-BY; mined CC0 | Devanagari ↔ Latin | Yes |
| **Bhasha-Abhijnaanam** | Native-script **and romanised** LID test set, 22 Indic languages — validates the "is this romanised Hindi or English?" router | MB | Manual data **CC0** | Both, labelled | Yes |
| **LibriSpeech-PC manifests** | Punctuation + capitalisation restoration; the **PER** metric | 25 MB | CC BY 4.0 | Latin | Yes |
| **Earnings-21 `.nlp` + `wer_tags`** | Entities, casing, punctuation, **partial words (`FALLBACK`)** — usable as pure text even if the audio is never downloaded | few MB | CC BY-SA 4.0 | Latin | Yes, share-alike |
| **Rev16 verbatim ↔ non-verbatim** | The cleanup layer's **target function**, written down | few MB | CC BY-SA 4.0 | Latin | Yes, share-alike |
| **MultiTurnCleanup** (EMNLP 2023) | The closest published **transcript-cleanup** task: 5 discontinuity classes — Acknowledgment/Confirmation, Repetition/Paraphrase, **Think Aloud**, **Incomplete Sentences**, Other. Token-level keep/delete, 81k turns, ~143k labels | 3 TSVs | **"licensed under LDC"** (built on Switchboard) | Latin | **No — evaluate locally, never commit** |
| **HyPoradise-v0** | ASR **N-best → true transcript**: `{instruction, input:[5 hypotheses], output}` | test files 0.4–2.0 MB each | Card says MIT, **but that does not survive the upstream** | Latin, lower-cased, unpunctuated | **Only `ls_clean`, `ls_other` (LibriSpeech CC BY 4.0) and `cv` (CommonVoice CC0).** Hard-exclude `swbd`/`wsj_score`/`atis`/`chime4` (LDC), `td3` (NC-ND), `lrs2` (signed BBC agreement), `coraal` |
| **Switchboard disfluency layer** (Treebank-3 / NXT) | The canonical reparandum→repair gold standard | — | LDC agreement + fee | Latin | **No** |
| **Google Text Normalization Challenge** | 1.1B words, token-aligned `before`→`after` with semiotic-class labels | multi-GB | **Unverified** | **English / Russian only — no Indic, no lakh/crore** | Unverified |
| **SponSpeech** | Punctuation **and casing** on spontaneous informal speech + a "challenging" 60 h subset | 665 h audio (skip it); transcripts small | **CC BY-NC 4.0** | Latin | **No** — we ship |
| **GLUECoS / LinCE / HinGE / L3Cube-HingCorpus** | Code-switched NLP benchmarks | — | GLUECoS ships **no data** (needs a Twitter developer account); LinCE host refused connection; HinGE has no licence found; L3Cube is Twitter-scraped | Romanised | **No / unverified** |
| **S1-mini** (superwhisper) / **Wispr Canto** | Not corpora — the only published **dictation-cleanup eval designs**. S1-mini: 7,519 English cases / 104 transcripts over numbers, self-corrections, lists, email, adversarial; scored as **token accuracy 94.8% + text-edit error rate 11.6%**. Canto: 10 h real dictations, 2,300+ speakers | **Held out, not released** | — | English only in v1 | n/a — **copy the taxonomy and the metric pair, not the data** |
| **Indi-RomCoM** | Defines **Register Defection Rate** over 7 tasks × 4 Indic langs × 25/50/75% CM intensity — the template for §4.2's adversarial gate | unknown | **Data release URL unverified** | Romanised | Unverified |

> **Recommendation.** Five permissive text sets (~6 MB total: NeMo ITN + Disfl-QA + Hinglish-TOP + PHINC + LibriSpeech-PC) give us an ITN arm, a self-correction arm, a script-preservation arm and a punctuation arm for nothing.
> **Hinglish-TOP and PHINC together automate §4.2's "0 silent translations" gate**: Hinglish-TOP's `cs_query` is romanised imperative Hinglish that tempts a cleanup LLM to *obey*; PHINC hands us the exact English translation the model must not produce, turning "did it silently translate?" into a cheap automatic check.
> **Copy S1-mini's metric pair** (token accuracy + text-edit error rate) rather than WER — and use their published 94.8% / 11.6% as a sanity check that our harness is not miscalibrated.

---

## 3. Starter pack

Eight items, in acquisition order. Sizes are from cards / APIs / HTTP headers, not downloads. **Re-ordered and re-scoped by the §7 licence check** — the two items that previously led the pack (HiACC, ASVspoof 2017) are both CC BY-NC per their own authoritative source and are out.

> **Disk check:** `df -h /` on this machine reports **20 GB available**, not the ~29 GB the brief assumed. The pack below is sized to fit in 20 GB with room to spare. Verify before step 7.

| # | Dataset | Route | Size | What it decides | Commit to the public repo? |
|---|---|---|---|---|---|
| 1 | **LiveKit eot-bench-data**, configs `hi` + `en` | HF `livekit/eot-bench-data` — **no gate** | **132.8 MB + 162.4 MB = 295 MB** (size API) | Latch thresholds: false-cutoff vs latency at every pause ≥ 100 ms, **including Hindi**. The entire Hindi endpointing budget | **Yes** — CC-BY-4.0 confirmed, attribution. Ships `silence_spans` only; **its `words` are ASR-derived, never a WER reference** |
| 2 | **VoiceCodeBench** | HF `besimple-ai/voice-code-bench` — **no gate** | **1.96 GB, confirmed** (300 rows, `test` split) | Parakeet v2/v3/Unified on 26 structured-token types with per-entity exact match. The English dictation arm | **Yes** — LICENSE read verbatim: MIT outside `data/audio/`; audio redistributable, **no Voice Cloning**, notice must travel, permission terminates on breach |
| 3 | **Text-cleanup bundle** — NeMo ITN (`en`,`hi`,`hi_en`) + Disfl-QA test + Hinglish-TOP human test + PHINC + LibriSpeech-PC manifests | GitHub / HF / Zenodo — **no gates** | **~30 MB** | ITN incl. lakh/crore/₹; self-correction removal; script preservation; "0 silent translations"; punctuation via PER | **Yes, all five — every licence re-confirmed at source**: Apache-2.0 (NeMo, Hinglish-TOP) / CC BY 4.0 (Disfl-QA README, PHINC Zenodo, OpenSLR 145) |
| 4 | **Vaani-Benchmark-V1.0** | HF `ARTPARK-IISc/Vaani-Benchmark-V1.0` — **owner must accept the HF gate** (`gated: auto`) | **1.88 GB** (card-reported; gated, so unverified) | Ranks Srota / Qwen3-ASR 1.7B / Bodhan Flex / IndicConformer / SraVaani **on the same axis as the published leaderboard §1.6 already quotes**. Triple human transcription = WER noise floor | **Yes** — CC BY 4.0 confirmed from the HF record *and* the paper, attribution. **Now the primary Hinglish arm** |
| 5 | **ReMASC sample** | Google Drive link from `github.com/YuanGongND/ReMASC` — **no gate** | ~10 MB | Whether the 92.3 GB full set (and a free IEEE account) is worth it. "Indoor 2" is a lounge with music and TV — our literal failure mode | **No.** Commercial *use* is expressly granted by the README; redistribution is simply not addressed |
| 6 | **ASVspoof 2021 PA, `part06` only** | `zenodo.org/records/4834716` — **no gate** | **4.15 GB** (smallest of 7 parts; the others are 5.93–7.08 GB) | Whether the speaker gate rejects a voice coming out of a TV, in real rooms across varying replay-device quality | **Yes** — ODC-By, attribution. **Replaces ASVspoof 2017, which §7 found is CC BY-NC and therefore blocked for us** |
| 7 | **Svarah** | HF `ai4bharat/Svarah` — **owner must accept the HF gate** (`gated: auto`) | **1.1 GB** (card-reported) | Whether Parakeet v3's regression on this owner is an Indian-accent + proper-noun problem. 117 speakers, 19 states | **NOT YET — licence unverified.** No licence on the HF record, the GitHub repo or the paper. Read the card once through the gate, then decide |
| 8 | **Kathbath Hindi, `valid` split** | HF `ai4bharat/Kathbath` — **same gate as #4** | est. 1–2 GB (**unverified**; full Hindi config 16.3 GB) | Monolingual-Hindi control: does the candidate engine work on Hindi *at all*, separate from code-switching. Also Indian-speaker EER | **Yes, with attribution.** Card body says CC0; the HF record says `cc-by-4.0`. Take the stricter reading |
| — | **HiACC** *(deferred, not in the pack)* | `zenodo.org/records/15551669` — **direct, no login** | 531.6 MB | Would have been the only close-mic single-speaker Hinglish audio | **No, and do not evaluate on it yet.** The paper states **CC BY-NC 4.0** verbatim; we ship. Mail the authors; if they confirm CC BY it re-enters at position 1 |

**Total: ~9.8 GB** (~7.8 GB if Kathbath is skipped). Two gates, both self-serve HF click-throughs (`gated: auto` on all three AI4Bharat/ARTPARK sets — auto-approval on accepting the conditions) that the owner does in a minute each. Fits the 20 GB actually free with ~10 GB to spare.

**What changed vs. the pre-check pack:** dropping HiACC costs us the single best-shaped Hinglish audio and leaves Vaani-Benchmark carrying need 2.1 alone; swapping ASVspoof 2017 for 2021 PA `part06` costs ~2.7 GB of disk and buys a licence we can rely on. Net +2.7 GB, −1 corpus, and nothing left in the pack whose terms are both binding and unread.

### 3.1 Exact routes

```bash
# 1, 2, 4, 7, 8 — Hugging Face. Per-config / per-split so we never pay the repo's headline size.
pip install -U "huggingface_hub[cli]"
hf download livekit/eot-bench-data --repo-type dataset --include "*/hi/*" "*/en/*" --local-dir corpora/eot-bench
hf download besimple-ai/voice-code-bench --repo-type dataset --local-dir corpora/voicecodebench
# The three gated ones (all `gated: auto`): accept on the dataset page in a browser first, then `hf auth login`.
hf download ARTPARK-IISc/Vaani-Benchmark-V1.0 --repo-type dataset --local-dir corpora/vaani-benchmark
hf download ai4bharat/Svarah   --repo-type dataset --local-dir corpora/svarah          # read the LICENCE on the card while you are there
hf download ai4bharat/Kathbath --repo-type dataset --include "*hindi*valid*" --local-dir corpora/kathbath-hi

# 3 — text-only, all ungated, all licences re-confirmed at source.
git clone --depth 1 https://github.com/NVIDIA/NeMo-text-processing                  corpora/nemo-itn        # Apache-2.0
git clone --depth 1 https://github.com/google-research-datasets/Disfl-QA            corpora/disfl-qa        # CC BY 4.0 (README)
git clone --depth 1 https://github.com/google-research-datasets/Hinglish-TOP-Dataset corpora/hinglish-top   # Apache-2.0
curl -L -o corpora/phinc.csv "https://zenodo.org/records/3605597/files/English-Hindi%20code-mixed%20parallel%20corpus.csv?download=1"   # CC BY 4.0, 2.13 MB
curl -L -O https://www.openslr.org/resources/145/manifests.tar.gz                                          # LibriSpeech-PC, CC BY 4.0, 25 MB

# 5 — ReMASC sample. Follow the "Sample data" link in the repo README (Google Drive, no gate).
#     README grants academic AND commercial use; it says nothing about redistribution, so evaluate only.
open https://github.com/YuanGongND/ReMASC

# 6 — ASVspoof 2021 PA. part06 is the smallest (4.15 GB); parts 00-05 are 5.93-7.08 GB. ODC-By.
curl -L -O "https://zenodo.org/records/4834716/files/ASVspoof2021_PA_eval_part06.tar.gz?download=1"

# Re-verify a licence before committing any fixture derived from it:
curl -s https://zenodo.org/api/records/<id> | python3 -c "import sys,json;print(json.load(sys.stdin)['metadata'].get('license'))"
curl -s "https://huggingface.co/api/datasets/<owner>/<name>" | python3 -c "import sys,json;j=json.load(sys.stdin);print((j.get('cardData') or {}).get('license'), j.get('gated'))"
# NB: do NOT pass ?expand[]=usedStorage on that second call - it suppresses cardData and every licence reads as null.

# DEFERRED — HiACC. Do not download until the authors confirm CC BY rather than the paper's CC BY-NC 4.0.
# open https://zenodo.org/records/15551669
```


### 3.2 Redistribution ledger

| May be committed (with attribution) | Evaluate locally, **NEVER commit** |
|---|---|
| **Kathbath / IndicSUPERB — CC BY 4.0 + attribution.** (Card body claims CC0; the HF record says `cc-by-4.0`. Stricter reading wins) | **Gramvaani / OpenSLR 118** — academic only; commercial use needs written permission from `contact@gramvaani.org`. **Wording re-confirmed verbatim on the OpenSLR page** |
| **eot-bench-data** — CC-BY-4.0, confirmed | **smart-turn v3.1** — no licence declared at all (`license: null` on both repos, confirmed), and its 1,295 Hindi rows are 100% `chirp3_1` TTS with no transcripts |
| **Vaani-Benchmark, FLEURS, LibriSpeech, LibriSpeech-PC, AMI, ICSI, IndicVoices** — CC BY 4.0, each re-confirmed at source | **SPGISpeech** — redistribution explicitly prohibited (HF record: `license: other`, `gated: auto`). Ignore the ungated `hf-audio` mirror |
| **VoxPopuli — CC0** | **GigaSpeech** — non-commercial agreement, and SpeechColab does not own the copyrights |
| **VoiceCodeBench** — MIT non-audio; audio redistributable **+ no-voice-cloning clause must travel with it** | **TED-LIUM 3 — CC BY-NC-ND.** `ND` means a clipped fixture is a derivative. Never, in any repo |
| **NeMo ITN, Hinglish-TOP — Apache-2.0, both re-confirmed via the GitHub licence object** | **CORAAL, SLURP, PodcastFillers, SponSpeech, TurnBench, CS-FLEURS** — non-commercial (`byan/cs-fleurs` carries the tag `cc-by-nc-4.0`) |
| **Disfl-QA, PHINC — CC BY 4.0** | **MultiTurnCleanup, Switchboard, Fisher, Mixer 6, Treebank-3, Speech Accessibility** — LDC / institutional agreement |
| **ASVspoof 2019, ASVspoof 2021 PA — ODC-By, both re-confirmed** (DataShare `dc.rights`; Zenodo `license.id`) | **VoxCeleb1/2** — YouTube-derived, "research purposes" |
| **Earnings-21/22, Rev16, MUCS SLR104, Dakshina — CC BY-SA**, *if* we accept share-alike on that fixture directory. (SLR104 CC BY-SA 4.0 re-confirmed on OpenSLR; Dakshina CC BY-SA 4.0 re-confirmed in its README) | **ASVspoof 2017 — CC BY-NC 4.0, now confirmed, so blocked outright.** **HiACC — CC BY-NC 4.0 per its own paper.** **Svarah — no licence anywhere reachable.** **ReMASC** (use granted, redistribution unaddressed). **ULCA/Vakyansh** (repo LICENSE is CC-BY-4.0 but covers only the link index, not third-party audio), **`agarwalayushi/hinglish`** (aggregate `cc-by-4.0` over "See source" rows), **MUCS SLR103** (Microsoft Open Data Agreement, not a named open licence) |

**What we commit instead of the blocked sets:** (a) **derived metrics only** — a JSON of per-utterance WER / PER / entity-exact-match keyed by the upstream's own file id, which reproduces our table without shipping a byte of their audio; (b) **the download+convert script**, so anyone can rebuild the fixture locally from the original source; (c) **our own recordings**, under the existing `Fixtures/real-room/**/*.wav` git-ignore pattern. This is already the pattern `Lab/FIXTURES.md` rule 4 sets out — the published artifact is *harness code + synthetic suites + pointers*.

---

## 4. Conversion plan

### 4.1 What the harness already expects

Three fixture shapes exist and a new corpus should reuse one of them rather than invent a fourth.

| Shape | Path | Schema | Consumed by |
|---|---|---|---|
| **Scored audio suite** | `Fixtures/audio/<suite>/` + `manifest.json` | `[{file, transcript, suite, speaker?, notes?, source?, entities?}]` (`FixtureItem`, `Lab/Harness/FixtureSuite.swift`) | `FixtureSuite.load(named:)`; every dir with a manifest is auto-discovered by `FixtureSuite.available()`. Default scored set is `["clean","noisy","entity","technical","commands"]` |
| **Span/label sidecar** | `Fixtures/audio/vad/labels.json` | `{sample_rate, format, spans: {file: [[start_s, end_s], …]}}` | VAD tests |
| **Directed-speech manifest** | `Fixtures/directed/manifest.json` | `[{file, label, preview, scene, textFieldFocused, addressedRecently}]` | `DirectedSpeechHarnessTests` |
| **Owner recordings** | `Fixtures/real-room/<pass>/` | per utterance `<stamp>-raw.wav`, `<stamp>-processed.wav`, `<stamp>.json` (`UtteranceRecorder.Manifest`: device, transport, rates, seconds, raw/processed RMS+peak dBFS, NS, AEC, capture graph) + `script.md` | `RealRoomCorpus.items(pass:)`, `RecordingReplayTests` |

Audio contract everywhere: **16 kHz, mono, 16-bit PCM WAV**. `gen_fixtures.py` already normalises with `afconvert -f WAVE -d LEI16@16000 -c 1`, trims silence and RMS-normalises to ≈ −20 dBFS — reuse exactly that so a public clip and a synthetic clip are level-comparable.

### 4.2 Per-corpus conversion

| Source | Native format | Becomes | Conversion |
|---|---|---|---|
| **HiACC** *(deferred — do not convert yet)* | 16 kHz mono WAV | `Fixtures/audio/hinglish_hiacc/` — **not created until the authors answer** | Already conformant, and it stays on the shelf. If they confirm CC BY: copy + build `manifest.json`, `transcript` = the mixed-script reference verbatim, `source` = "HiACC, Zenodo 15551669, CC BY 4.0 per author confirmation of YYYY-MM-DD". Also spot-check the references by ear first — the paper says Whisper produced them |
| **Vaani-Benchmark** | HF Parquet/audio, field/phone rates | `Fixtures/audio/hinglish_vaani/` | Decode → `afconvert` to 16k mono. **Keep the `{EnglishWord}` braces in a second field**, strip them for `transcript`. Take one of the three human transcripts as `transcript` and store the other two for the noise floor |
| **Kathbath** | **m4a** | `Fixtures/audio/hindi_kathbath/` | `afconvert -f WAVE -d LEI16@16000 -c 1 in.m4a out.wav`. Devanagari references, `source` = "Kathbath/IndicSUPERB (AI4Bharat), CC BY 4.0 (card body says CC0; HF record says cc-by-4.0 — attributing under the stricter reading)" |
| **Svarah** | HF audio | `Fixtures/audio/accent_indic/` — **git-ignored until the licence is read on the gated card** | Straight resample. Fill `entities` **explicitly** — the heuristic in `EntityScorer.detectEntities` will mis-fire on Indian proper nouns and on lowercase product names (`Lab/FIXTURES.md` rule 2 already says so) |
| **VoiceCodeBench** | WAV + per-entity JSON | `Fixtures/audio/dictation_vcb/` | Resample; map the 26 token types into `entities` per row so `EntityScorer` scores them. Ship the per-directory LICENSE carrying the no-voice-cloning clause |
| **eot-bench `hi`/`en`** | HF rows with `silence_spans`, word timings, `messages`; single `validation` split | `Fixtures/eou/<lang>/` + `labels.json` | **Reuse the `vad/labels.json` shape**: `{sample_rate, format, spans: {file: [[start_s, end_s], …]}}`, plus a parallel `endpoints.json` = `{file: [{pauseStart, pauseEnd, isEndpoint}]}`. **Drop the `messages` field** — our latch has no conversational context and including it would inflate the numbers. **Also drop `words` from `transcript`** — it is ASR output, not a reference (§2.3) |
| **ASVspoof 2021 PA `part06` / ReMASC** | FLAC / WAV, varied rates | `Fixtures/directed/` gains rows with `label: "replay"` (ASVspoof 2021 PA clips may be committed under ODC-By; ReMASC clips stay git-ignored) | **No new harness.** Extend the directed manifest with `label: "replay"` and two optional fields `playbackDevice`, `room`. The existing addressed/not-addressed harness already reads this file |
| **Text sets (5)** | TSV / CSV / JSON / `spoken~written` | `Fixtures/cleanup/<set>.json` | New flat shape: `[{id, input, expected, class, script, source}]`. `class` ∈ `{itn, disfluency, punctuation, script_preservation, no_translate}`. `script` ∈ `{devanagari, latin, mixed}` |

### 4.3 Reference normalisation — the blocking piece

**There are three WER scorers in this repo today and none of them can score a Hinglish hypothesis.**

| Scorer | Location | Normalisation | Problem |
|---|---|---|---|
| `TextNormalizer.words` + `WERScorer` | `Lab/Harness/Scoring.swift:6-19` | lowercase; letters, digits, inner apostrophes | No ITN, **no digit grouping** — `"2,340"` → `["2","340"]` |
| `RealRoomCorpus.normalizedWords` | `Tests/EngineTests/RealRoomCorpus.swift:142-152` | same **plus** digit grouping (`"2,340"` → `"2340"`) | The better one, and the Lab harness does not use it |
| local `words(_:)` | `Tests/EngineTests/ASRGoldenTranscriptTests.swift:7` | `CharacterSet.alphanumerics` split | A third variant |

None does transliteration equivalence. **A perfect romanised transcript scored against a Devanagari reference is ~100% wrong; §1 already puts the mixed-script case at ~44% wrong.** Until this is fixed, every Hinglish number the bake-off produces is meaningless.

**Plan (this is §4.1 item 0, made concrete):**

1. **Move the normaliser into `Shared/`, not `Lab/`.** `Package.swift` gives `EngineTests` a dependency on `Engine` only — it cannot import `Lab`, which is exactly why `RealRoomCorpus` had to grow its own copy and `GateRecallCorpusTests.swift:88` had to copy it again. Every target depends on `Shared`, so `Shared/TextScoring.swift` is the only location where one scorer can serve all three call sites. **This is the plan's one required `Shared/` change** — minimal and additive (new file, nothing edited), and it must be called out per `CLAUDE.md`.
2. `Lab/Harness/Scoring.swift` keeps its public API and forwards to `Shared`. `RealRoomCorpus` and `ASRGoldenTranscriptTests` delete their private copies.
3. **Add, in this order:**
   - digit grouping (promote `RealRoomCorpus`'s existing rule — it is already correct);
   - an **ITN-aware pass** so `"eleven forty five"`, `"11:45"` and `"११:४५"` compare equal; drive it from the NeMo `en`/`hi`/`hi_en` `spoken~written` pairs so the rule set is a data file, not code;
   - **Devanagari digit folding** `०-९ → 0-9` (see the trap in §6.4);
   - **transliteration equivalence**: a word is a match if the hypothesis token is an attested romanisation of the reference token. Build the table from **Dakshina**'s 25,000 attested Hindi romanizations + **Aksharantar**'s test pairs, ship it as `Fixtures/scoring/translit_hi.tsv`;
   - **CER beside WER** — a romanisation that differs by one vowel should not cost a whole word;
   - **multi-reference FST scoring** for the dual-reference Hinglish set, following rev's `multireferences` + `fstalign` / `sbs2fst.py`.
4. **Acceptance for the scorer itself**, before it is trusted: it must score a hand-written perfect romanised transcript of a Devanagari reference at **WER ≈ 0**, and it must reproduce the existing `real-room/builtin` Parakeet number (0.099) within noise. Without the second check, a "script-blind" scorer that is merely lenient looks like a win.

### 4.4 Naming and file paths

```
Fixtures/
  audio/
    hinglish_hiacc/      DEFERRED - not created; HiACC is CC BY-NC per its paper
    hinglish_vaani/      manifest.json + wavs          CC BY 4.0
    hindi_kathbath/      manifest.json + wavs          CC BY 4.0 + attribution
    accent_indic/        manifest.json (wavs git-ignored; Svarah licence unverified)
    dictation_vcb/       manifest.json + wavs + LICENSE  (no-voice-cloning clause)
  eou/
    hi/  en/             labels.json, endpoints.json, wavs   CC BY 4.0 (eot-bench)
  directed/
    manifest.json        + label:"replay" rows (ASVspoof 2021 PA, ODC-By, wavs OK;
                         ReMASC wavs git-ignored)
  cleanup/
    itn_nemo.json  disfluency_disflqa.json  hinglish_top.json
    phinc_no_translate.json  punctuation_lspc.json
  scoring/
    translit_hi.tsv      Dakshina + Aksharantar equivalence table
  personal/
    hinglish/            script.md + <pass>/ (owner's voice; wavs git-ignored)
  tools/
    gen_fixtures.py      (existing, unchanged)
    import_corpus.py     (new — download, resample, emit manifest, stamp `source`)
```

Code changes, by file:
- `Shared/TextScoring.swift` — **new.** The single normaliser + WER/CER. *(the one `Shared/` edit)*
- `Lab/Harness/Scoring.swift` — forward to `Shared`; keep `EntityScorer`, `Percentile`.
- `Lab/Harness/FixtureSuite.swift` — add four **optional** fields to `FixtureItem`: `referenceRomanised: String?`, `script: String?`, `licence: String?`, `redistributable: Bool?`. All optional, so every existing manifest keeps decoding.
- `Lab/Harness/FixtureSuite.swift` — leave `defaultNames` alone; new suites are opt-in via `--suites`, so `swift test` cost does not change for anyone.
- `Tests/EngineTests/RealRoomCorpus.swift` — delete `normalizedWords` / `werCounts`, import `Shared`.
- `Tests/EngineTests/ASRGoldenTranscriptTests.swift:7` — delete the local `words(_:)`.
- `Fixtures/tools/import_corpus.py` — **new**, sibling to `gen_fixtures.py`, same `afconvert` invocation.
- `Lab/FIXTURES.md` — replace the T2 backlog table (which already names Earnings-22, Svarah, Common Voice, AMI and DEMAND) with the verified table from §2 here.

`git add` scope for the eventual implementation: `Shared/TextScoring.swift`, `Lab/Harness/`, `Fixtures/`, `Tests/EngineTests/`, `Lab/FIXTURES.md`. Nothing in `Package.swift`.

---

## 5. What still needs the owner's own voice

Blunt version: **the public sets buy the elimination round. They cannot buy the ship gate.** Six things appear in no public corpus, and five of them are the things §4.2's gates actually measure.

1. **His voice.** The speaker gate, the enrolment embedding, every per-speaker adaptation. A 5-hour corpus of strangers says nothing about whether WeSpeaker + community-1 accepts *him* and rejects *his* TV. `Fixtures/directed/` exists precisely because this is unanswerable from public data.
2. **His accent and his switching rate.** Vaani's speakers switch at district-typical rates on image prompts; HiACC's read story switches where an author decided. Neither is his rate when dictating a Slack message about a Swift build failure.
3. **His applications' vocabulary.** `SpanRewriter`, `TranscriptSpan`, `AppPaths`, `hdiutil`, `swift build --scratch-path`, his colleagues' and repos' names. This is where the WER that matters lives and it is in no public set. MUCS SLR104's CS-tutorial domain is the nearest public approximation and it is still generic computer science.
4. **His self-corrections.** Read corpora have none. Public spontaneous corpora elicit them against image prompts, not against a text field the speaker is watching fill up.
5. **His latch behaviour.** Where he pauses mid-thought versus where he stops is a personal, task-specific timing signature. No public corpus is dictation-shaped; §2.3 could not find one.
6. **His preferred output script, item by item** — §4.0's actual deliverable, and something only he can produce.

### 5.1 How few utterances

The binding statistic is the one §1 had to reconstruct after the fact: R5.4 ran **n = 20, 12 of them ties**, leaving 8 discordant pairs at 1-better / 7-worse, and a sign test gives **p ≈ 0.070**. Under-powered, and the pooled-error CI touched zero.

- A sign test needs **≥ 6 discordant pairs, all one way**, to clear p < 0.05 (2 × 2⁻⁶ = 0.031).
- R5.4's discordance rate was 8/20 = **40%**.
- So **n = 30** yields ≈ 12 discordant pairs — enough to call a 10:2 split at p = 0.039, and enough to reject the "one confound flipped it" objection.
- **n = 40** yields ≈ 16 discordant, calls a 12:4 split at p = 0.038, and gives ≈ 500 reference words for a paired bootstrap on pooled WER.

**Recommendation: 40 utterances. 30 is the floor.** Not 60–100. The reason the number can drop is division of labour: the public sets run the **6-way elimination** (§4.1 step 5's full candidate list), and his set only has to arbitrate a **2–3 way final** and hold §4.2's gates — "script acceptance ≥ 80%" and "0 silent translations". Those two gates are *proportions on his own preference*, not WER contrasts; 40 items gives a ±13 pt CI on an 80% acceptance rate, which is enough to distinguish 80% from 50% and is what the gate actually asks.

Composition for 40 (scaled from §4.1 step 3's 100):
- **8 pure Hindi** — the monolingual control (Kathbath covers the generic case; these cover *his* Hindi).
- **20 code-mixed at his natural rate** — the arm nothing public substitutes for.
- **8 Indian English with Hindi names and his app vocabulary** — the class Svarah approximates but does not contain.
- **4 long-form** (≥ 15 s) with at least two self-corrections each.
- Every item gets **two references — mixed-script and fully romanised** — and he marks the preferred script per item. That per-item mark *is* §4.0's deliverable.

### 5.2 How to record them

The app already does this and `Fixtures/prosody/` is the working precedent — a 40-utterance owner-recorded script with `Read text` and `Target` columns.

1. Settings › General › Microphone › **"Save recordings of what I dictate"**. `UtteranceRecorder` writes `<stamp>-raw.wav`, `<stamp>-processed.wav` and `<stamp>.json` (device, transport, sample rates, seconds, raw/processed RMS+peak dBFS, noise suppression, AEC, capture graph) per utterance.
2. Write `Fixtures/personal/hinglish/script.md` as a table: `# | Read (Hinglish) | Ref-mixed | Ref-romanised | Preferred`. Read only the first column, natural pace, one take per utterance, in order.
3. **The app keeps only the newest 20 utterances.** 40 items is therefore **two passes** with a copy to `Fixtures/personal/hinglish/<pass>/` in between. This is an operational constraint, not a detail — it is exactly how `Fixtures/real-room/README.md` says the 20-line corpus had to be captured.
4. **Do not rely on timestamp-order matching.** `RealRoomCorpus.items(pass:)` pairs the *n*-th recording with the *n*-th script line and returns `nil` if the counts disagree — a skipped or re-read line silently shifts everything after it, and with two passes and dual references that failure is likely and hard to see. Write the line number into the sidecar at record time, or record in batches of 5 and verify each batch before continuing.
5. Recordings go under the existing `Fixtures/real-room/**/*.wav` ignore pattern (extend it to `Fixtures/personal/**/*.wav`). **The script and the manifests are committed; the audio never is.** A voice recording in git history is permanent.
6. **Annotate in Earnings-21's `.nlp` schema** — token, timings, punctuation, 4-way case, entity tag, with `FALLBACK` for partial words. That makes his 40 utterances scoreable by the *same* harness as the public sets, which is the single biggest gap §1 identified in R5.4.

**Half a day of his time.** It is still the long pole, and nothing downstream finishes without it.

---

## 6. Gaps and risks

### 6.1 Gates, named exactly

- **HF gated** (Vaani-Benchmark, Kathbath, Svarah, IndicVoices, Shrutilipi, IndicVoices-R, Vaani) = an HF account, clicking a conditions notice, and **agreeing to share your contact information with the dataset authors**, then a token. **Nobody has signed up, logged in, or accepted anything.** The owner must do this himself; it is a few clicks per dataset, not an institutional agreement.
- **No gate**: eot-bench, VoiceCodeBench, OpenSLR 103/104/118/12/145, ReMASC sample, ASVspoof 2021 PA (Zenodo), HiACC (Zenodo), all five text sets. **ASVspoof 2017 is also ungated — and that turned out to be the point: the absence of a gate told us nothing, and the licence in `dc.rights` blocks us anyway.**
- **Hard gates not to attempt**: LDC (Switchboard, Fisher, Mixer 6, Treebank-3, SEAME — membership or per-corpus fee, fees hidden behind a login); Mozilla Data Collective (new registration platform since Oct 2025); GigaSpeech (Google Form + signed agreement); SPGISpeech (registration + Terms + auth token); Speech Accessibility Project (institutional DUA **plus a one-page research proposal reviewed by a UIUC committee** — effectively unavailable to an individual, and it is dysarthric speech, not a dictation question); CANDOR (registration form, >1 TB anyway); Gramvaani (commercial use by written permission).
- **Medical dictation**: essentially nothing public. HIPAA/GDPR de-anonymisation risk is the stated reason; the good corpora are proprietary vendor sets.

### 6.2 Licence traps

1. **ShareAlike is viral for a fixture directory.** Earnings-21/22, Rev16, MUCS SLR104 and Dakshina are all `-SA`. A clipped fixture from them makes that fixture share-alike. Keep them under their own directory with their own `LICENSE.md` and attribution, and out of any directory whose licence should stay permissive.
2. **An ungated mirror is not a licence.** `hf-audio/esb-datasets-test-only-sorted` serves `spgispeech/` at 11.38 GB with no gate while Kensho's terms forbid redistribution. Same download, opposite legal status.
3. **`ND` is worse than `NC`.** TED-LIUM 3 is CC BY-NC-**ND** — a clipped fixture *is* a derivative, so it is not redistributable in any repo, commercial or not. It is conspicuously the one short-form set *absent* from the ESB mirror; the maintainers made the same call.
4. **HiACC's licence dispute is now resolved against us.** The paper states verbatim: "Open access for academic/research use under a CC BY-NC 4.0 license." The Zenodo *metadata field* says `cc-by-4.0`, but a dropdown value does not outrank the authors' own prose. We ship commercially, so HiACC is out of the pack — and **local evaluation is no longer obviously fine either**, because evaluating a commercial product's engine choice is not a non-commercial use. Ask the authors before touching it.
4b. **A Zenodo/HF metadata field is not a licence.** HiACC and Kathbath both fail the same way: a permissive value in the structured field, a stricter statement in the prose. Read both, take the stricter, and record which one you read in the fixture's `source` string.
5. **Aggregate licences do not clear constituents.** `agarwalayushi/hinglish` is CC BY 4.0 at the aggregate level while several of its 14 constituent rows say only "See source". Never commit a clip from it without tracing that clip's upstream. Use it as a map of what exists, then pull the upstream directly.
6. **Ungated ≠ licensed.** ULCA/Vakyansh publishes 2,398.76 h of Hindi behind direct login-free GCS URLs with **no licence statement found**, sourced from YouTube creators, radio and news channels.
7. **No licence at all** is its own category: smart-turn v3.1 returns `license: null` on both HF repos, and the code repo's BSD-2 does not cover the data.

### 6.3 Benchmark-vs-product mismatch — the script question

**This is the finding that changes §4.0's cost model.**

Three independent, published, human-annotated corpora have converged on **mixed script**:
- **Vaani-Benchmark**: Devanagari, with romanised code-switched words wrapped `{EnglishWord}`.
- **HiACC**: "Devanagari script for Hindi words and Latin script for English words" (stated verbatim in the paper).
- **MUCS SLR104**: mixed, *inferred* from its lexicon rule ("if the word is a Devanagari/Bengali script word…", which presupposes Roman words in the same transcript) — **not stated outright, mark as inferred**.

**No public corpus ships a fully-romanised Hindi reference.** Consequence for §4.0:

| Policy | Cost |
|---|---|
| **Mixed script** | References already exist. Stack 1 (Srota) is directly measurable. The bake-off starts as soon as the downloads land. |
| **Fully romanised** (the Bodhan Flex / Stack 3 path) | **Every reference must be hand-written by the owner**, because nothing public provides one. Roughly doubles §4.1 step 3 and makes step 0 the expensive branch. |

Tell him this *before* he picks. §4.0 currently presents the choice as symmetric; it is not.

### 6.4 The digits decision §4.0 does not currently ask about

NeMo's Hindi ITN emits **Devanagari digits**. The verified test cases read `एक लाख रुपये~₹१०००००` and `ढाई करोड़ रुपये~₹२५००००००` — the right-hand side uses `०-९`, not `0-9`. Wire NeMo `hi` ITN in as-is and a dictated "ढाई करोड़ रुपये" types as `₹२५००००००` into Slack, Mail and the IDE. The `hi_en` file mixes both conventions (Devanagari digits for Hindi rows, ASCII for English rows), so the choice is ours to make explicitly. **This is the same decision as §4.0, applied to numerals, and §4.0 only asks about words.** It also needs a folding rule in the scorer (§4.3), or every ITN test will fail for the wrong reason.

### 6.5 Other mismatches

- **The Open ASR Leaderboard's normalizer strips exactly what we sell** (punctuation, casing, fillers, number normalization, spelling standardization). Any claim that "model X formats better" is unfalsifiable from the board. Read checkpoint *rankings* off it; measure formatting with LibriSpeech-PC's PER and VoiceCodeBench's entity exact match.
- **TTS sets are not acoustic evidence.** ContextASR-Bench (MIT) and ProfASR-Bench (Apache-2.0, 4 Kokoro voices) are synthesised. They stress a decoder's lexical priors; they prove nothing about acoustics, mic, endpointing or the speaker gate. Same for smart-turn's Hindi and CS-FLEURS's Hindi. Label every number from them synthetic.
- **Conversational endpointing ≠ dictation endpointing.** eot-bench's models consume prior conversational context; ours has none. Evaluate audio-only.
- **Replay ≠ attack.** ASVspoof's PA is a deliberate attacker at the mic. Ours is a TV in the room. ReMASC "Indoor 2" is the only public condition that is actually ours.
- **Disk.** `df -h /` reports **20 GB available on this machine** (re-checked), not ~29 GB. The revised pack is ~9.8 GB, so this is comfortable — but re-check before pulling ASVspoof 2021 PA, which is a single 4.15 GB file and the largest item in the pack.
- **`EngineTests` cannot import `Lab`** (`Package.swift`: `.testTarget(name: "EngineTests", dependencies: ["Engine"])`). Any plan that puts the one true scorer in `Lab/` will fail and produce a fourth copy. Hence the `Shared/` placement in §4.3.

### 6.6 Explicitly unverified

Not guessed at, and not to be planned around until checked:

- SPRING-INX: per-language Hindi hours, transcript script, and any working download URL.
- Transcript script for: Shrutilipi, IndicVoices-R, Gramvaani, IITG-HingCoS, Svarah (Latin assumed for an English corpus but the card does not say), Kathbath (Devanagari expected per AI4Bharat convention, not confirmed in this pass). **eot-bench `hi` is now RESOLVED — Devanagari** (§7), though its `words` are ASR-derived and unusable as a reference.
- IndicVoices' Roman-vs-Devanagari rule for English words.
- MUCS SLR104's script — inferred from the lexicon rule, not stated on the card.
- **RESOLVED (§7):** HiACC's binding licence (CC BY-NC 4.0 per the paper); ASVspoof 2017's terms (CC BY-NC 4.0 in `dc.rights` — there was no separate agreement to read); ReMASC's use grant (academic *and* commercial, per the README).
- **Still unverified:** ASVspoof 5's LICENSE.txt; CN-Celeb's licence wording; **ReMASC's redistribution clause** (the README grants use, never redistribution); RedDots Replayed's availability; MapTask's audio licence.
- **Newly unverified:** Svarah's licence — the HF record carries no `license` field or tag, the GitHub repo has no LICENSE, and the paper says only "publicly available". Read it on the gated card.
- **Newly conflicted:** Kathbath — card body CC0 vs HF record `cc-by-4.0`.
- Vaani-Benchmark's `{EnglishWord}` brace convention — the paper confirms mixed script but not that notation.
- Kathbath Hindi `valid` split size (full Hindi config is 16.3 GB; the split is estimated at 1–2 GB).
- **RESOLVED (§7):** VoiceCodeBench total size is **1.96 GB** (HF `usedStorage`), which validates the earlier 50-file extrapolation.
- Earnings-21 audio size via Git LFS.
- Licences for: Google Text Normalization Challenge, HinGE, IWSLT punctuation benchmark, SEPP-NLG (its task page states none), L3Cube-HingCorpus download path.
- SPACER's dataset release URL and whether its repair annotations ship independently of Switchboard.
- Indi-RomCoM's data release URL; whether the EACL 2026 Hindi post-ASR correction paper releases data.
- TED-LIUM 3's current availability — re-checked: `openslr.org/51` returns **HTTP 200 with a "Resource not found: 51" body** (delisted, not a 404); `huggingface.co/api/datasets/LIUM/tedlium` still **401**. Licence corroborated by two independent sources; the card itself remains unreadable. Verdict unchanged either way, since `ND` blocks us regardless.
- LinCE — host refused connection (ECONNREFUSED).
- LDC pricing for Switchboard-1 R2, Treebank-3, Fisher, Mixer 6 (fees are behind a login that was not used).
- Dakshina tar size.

---

## 7. Licence check notes

Second pass, 21 Sep 2026. Every starter-pack entry and the shortlist heads were re-opened at their **own** card, repository, API record or paper — no blogs, no aggregators. **Nothing was downloaded, no account was created, no gate was accepted, no terms were agreed.** Where a set sits behind a gate, that is recorded as a limit on what could be checked, not worked around.

### 7.1 Findings that changed the plan

| # | Set | Claim as written | What the source says | Effect |
|---|---|---|---|---|
| 1 | **ASVspoof 2017 v2.0** | "Depositor Agreement — terms not shown → unverified. Hold." | The item's `dc.rights` field reads: *"You are free to use this database under Creative Commons Attribution-NonCommercial License (CC-BY-NC)… CC BY-NC 4.0 International"* | **Blocked.** There was no agreement to read; the terms were in a metadata field the first pass did not query. **Dropped from the pack**, replaced by ASVspoof 2021 PA `part06` (4.15 GB, ODC-By) |
| 2 | **HiACC** | "Disputed: Zenodo `cc-by-4.0` vs paper CC BY-NC. Take first, local eval only." | The paper states verbatim: *"Open access for academic/research use under a CC BY-NC 4.0 license."* Zenodo's metadata field still returns `cc-by-4.0` | **Demoted out of the pack.** The authors' prose outranks a dropdown. We ship, so NC blocks the fixture — and arguably the evaluation too. Mail the authors |
| 3 | **HiACC references** | (not raised) | The paper: transcripts were produced *"using the Whisper ASR model"*; the Zenodo description says *"manually transcribed"* | Reference quality is itself unresolved. Even if the licence clears, spot-check by ear before trusting any WER from it |
| 4 | **Kathbath** | "**CC0** — the only source we may commit outright with zero obligation" | Card body does say CC0 with an explicit waiver. But the HF record's `cardData.license` is **`cc-by-4.0`** and it carries a `license:cc-by-4.0` tag | Downgraded to **CC BY 4.0 + attribution**. **There is now no set in this document we may commit from with no obligation at all** — §3.2's first row changes meaning |
| 5 | **Svarah** | "CC BY 4.0 — commit, attribution only" | The HF record carries **no `license` field and no licence tag**; the GitHub repo has no LICENSE; the paper says only *"publicly available"*. Only third-party blurbs assert CC BY 4.0 | **Unverified.** Local eval yes, commit no, until the card is read once through the gate |
| 6 | **eot-bench `hi`** | script unknown — "a one-command check, do it early" | `words` are **Devanagari**. Config sizes confirmed exactly: `hi` 400 rows / 132.8 MB, `en` 400 rows / 162.4 MB, `all` 5,454 / 1,892.9 MB. Only a `validation` split exists | Resolved, and it is a **third** independent mixed/native-script data point for §6.3. **New trap:** the first `hi` row contains `और्जूंजी` and `पष्डी न्ट्र`, which are not words — the field is ASR output. Timings only, never a WER reference |
| 7 | **ULCA / Vakyansh** | "No licence statement found" | The GitHub repo **does** carry a CC-BY-4.0 LICENSE file. The README says nothing about the audio, and the repo holds only the index and GCS URLs | Correction, same verdict: a licence over a list of links does not clear third-party YouTube and radio audio |
| 8 | **ReMASC** | "Redistribution clause unverified. Hold." | README verbatim: *"free for academic and commercial use, and we no longer require a verification process"*. No LICENSE file; redistribution never mentioned | **Use** is expressly granted, so evaluate freely. **Redistribution is unaddressed, which is not permission** — still never commit |
| 9 | **TED-LIUM 3** | "`openslr.org/51` 404" | It returns **HTTP 200** with a body reading `Resource not found: 51`; HF `LIUM/tedlium` still 401 | Cosmetic. `ND` blocks us regardless |
| 10 | **"No fully-romanised Hindi reference"** | The document's single most plan-changing claim | Survived an adversarial search. The best candidate — `agarwalayushi/hinglish`, 242.9 GB, `cc-by-4.0`, ungated — is **mixed script** with `<hi-en>` tags. Vaani's paper: *"Code-switched content is transcribed in both the native script and the original script."* MUCS SLR104's card still does not state a script, so the doc's "inferred" label is correct | **Claim stands.** §6.3's asymmetry holds and should still be put to the owner before he picks |

### 7.2 Confirmed exactly as written

VoiceCodeBench's LICENSE read verbatim — MIT outside `data/audio/`, audio redistributable subject to a no-Voice-Cloning condition that **terminates automatically on breach**; repo storage **1.96 GB**, which validates the first pass's 50-file extrapolation. smart-turn v3.1 — `license: null` on both repos, and **1,295 rows at `language='hin'`, every one `synthetic=true`, every one `dataset=chirp3_1`, `spoken_text` null throughout** (note the code is `hin`, not `hi`). Vaani-Benchmark — CC BY 4.0 from the HF record *and* the paper, three independent transcribers per clip, 50% public. ASVspoof 2021 PA — ODC-By, 7 parts, `part06` smallest at 4.15 GB. ASVspoof 2019 — ODC-By. Gramvaani/SLR118 — commercial-permission wording verbatim on OpenSLR. MUCS SLR104 — CC BY-SA 4.0, test 443 MB. LibriSpeech SLR12 — CC BY 4.0. LibriSpeech-PC SLR145 — CC BY 4.0, 25 MB. Disfl-QA — CC BY 4.0 (README). Hinglish-TOP, NeMo-text-processing — Apache-2.0 (GitHub licence object). PHINC — CC BY 4.0, 2.13 MB (Zenodo API). Dakshina — CC BY-SA 4.0 (README). FLEURS `cc-by-4.0`; VoxPopuli `cc0-1.0`; IndicVoices `cc-by-4.0` gated; Bhasha-Abhijnaanam `cc0-1.0`; SPGISpeech `other` + gated; GigaSpeech `apache-2.0` + gated; ContextASR-Bench MIT; ProfASR-Bench Apache-2.0; CS-FLEURS `cc-by-nc-4.0`. All three AI4Bharat/ARTPARK gates are `gated: auto`, i.e. auto-approval on accepting the conditions — the doc's "self-serve, a minute each" is right.

### 7.3 Method notes for whoever checks next

- **Query the structured record, not just the page.** ASVspoof 2017's terms were never rendered in the HTML; they live in `dc.rights`, reachable at `datashare.ed.ac.uk/server/api/discover/search/objects?query=<handle>&dsoType=item`. The first pass read the page and concluded "unverified".
- **`?expand[]=usedStorage` on the HF dataset API suppresses `cardData` and `gated`.** Every licence then reads `null`. This produced a round of false "no licence" findings mid-check. Query size and licence in **separate** calls.
- **Read the prose and the metadata field, and take the stricter.** Two of the ten findings (HiACC, Kathbath) are exactly this mismatch, in opposite directions.
- **A missing licence is a finding, not a gap to fill from memory.** Svarah has confident third-party claims of CC BY 4.0 and no primary source; it is recorded as unverified rather than assumed.
- **Ungated is not licensed, and gated is not restrictive.** ASVspoof 2017 is ungated and NC; Vaani-Benchmark is gated and CC BY 4.0. The gate and the licence are independent facts and both must be read.

---

## 8. Sources

**Hindi / Hinglish speech**
`huggingface.co/datasets/ARTPARK-IISc/Vaani-Benchmark-V1.0` · `zenodo.org/records/15551669` (HiACC) · `pmc.ncbi.nlm.nih.gov/articles/PMC12329218/` · `huggingface.co/datasets/ai4bharat/Kathbath` · `arxiv.org/abs/2208.11761` (IndicSUPERB) · `huggingface.co/datasets/ai4bharat/IndicVoices` · `arxiv.org/abs/2403.01926` · `huggingface.co/datasets/ai4bharat/indicvoices_r` · `huggingface.co/datasets/ARTPARK-IISc/Vaani` · `huggingface.co/datasets/ai4bharat/Shrutilipi` · `openslr.org/103/` · `openslr.org/104/` · `openslr.org/118/` · `openslr.org/resources.php` · `navana-tech.github.io/MUCS2021/data.html` · `navana-tech.github.io/IS21SS-indicASRchallenge/MUCS2021_Paper.pdf` · `huggingface.co/datasets/google/fleurs` · `arxiv.org/abs/1810.00662` (IITG-HingCoS) · `arxiv.org/abs/2509.14161` · `huggingface.co/datasets/byan/cs-fleurs` · `huggingface.co/datasets/agarwalayushi/hinglish` · `github.com/ayushi-agarwall/hinglish-audio-dataset` · `github.com/Open-Speech-EkStep/ULCA-asr-dataset-corpus` · `community.mozilladatacollective.com/common-voice-23-0-live-on-mozilla-data-collective/` · `news.microsoft.com/en-in/microsoft-releases-speech-corpus-for-three-indian-languages-to-aid-researchers/` · `openslr.org/126/` · `openslr.org/78/`

**English dictation / error classes**
`huggingface.co/datasets/besimple-ai/voice-code-bench` (+ `/raw/main/LICENSE`) · `arxiv.org/html/2608.28916` · `github.com/revdotcom/speech-datasets` (earnings21 / earnings22 / rev16 / multireferences READMEs) · `arxiv.org/abs/2412.07937` · `huggingface.co/datasets/hf-audio/esb-datasets-test-only-sorted` · `arxiv.org/html/2510.06961v4` (Open ASR Leaderboard) · `openslr.org/12` · `openslr.org/145/` · `huggingface.co/datasets/kensho/spgispeech` · `huggingface.co/datasets/speechcolab/gigaspeech` · `huggingface.co/datasets/distil-whisper/earnings22` · `huggingface.co/datasets/facebook/voxpopuli` · `huggingface.co/datasets/MLCommons/peoples_speech` · `huggingface.co/datasets/ai4bharat/Svarah` · `groups.inf.ed.ac.uk/ami/corpus/` · `groups.inf.ed.ac.uk/ami/icsi/` · `lingtools.uoregon.edu/coraal/` · `github.com/pswietojanski/slurp` · `podcastfillers.github.io/dataset/` · `huggingface.co/datasets/MrSupW/ContextASR-Bench` · `huggingface.co/datasets/prdeepakbabu/ProfASR-Bench` · `huggingface.co/datasets/LIUM/tedlium` · `catalog.ldc.upenn.edu/LDC97S62` · `speechaccessibilityproject.beckman.illinois.edu/conduct-research-through-the-project` · `arxiv.org/abs/2409.11241` (SponSpeech)

**Endpointing / turn-taking**
`huggingface.co/datasets/livekit/eot-bench-data` · `github.com/livekit/eot-bench` · `livekit.com/benchmarks/eot-bench` · `huggingface.co/datasets/pipecat-ai/smart-turn-data-v3.1-test` · `.../smart-turn-data-v3.1-train` · `github.com/pipecat-ai/smart-turn` · `sesame.com/blog/turnbench` · `github.com/SesameAILabs/turnbench` · `arxiv.org/abs/2608.25218` · `github.com/ErikEkstedt/VoiceActivityProjection` · `arxiv.org/html/2403.06487v1` · `groups.inf.ed.ac.uk/maptask/maptasknxt.html` · `betterup.com/research/candor-research`

**Speaker verification / replay**
`datashare.ed.ac.uk/handle/10283/3055` (ASVspoof 2017 v2.0) · `datashare.ed.ac.uk/handle/10283/3336` (2019) · `zenodo.org/records/4834716` (2021 PA) · `asvspoof.org/index2021.html` · `zenodo.org/records/14498691` (ASVspoof 5) · `github.com/YuanGongND/ReMASC` · `arxiv.org/html/1904.03365` · `ieee-dataport.org/open-access/remasc-realistic-replay-attack-corpus-voice-controlled-systems` · `ieeexplore.ieee.org/document/7953187/` (RedDots Replayed) · `robots.ox.ac.uk/~vgg/data/voxceleb/vox1.html` · `mm.kaist.ac.kr/datasets/voxceleb/` · `huggingface.co/datasets/ProgramComputer/voxceleb` · `openslr.org/82/` · `github.com/AI4Bharat/IndicSUPERB`

**Text-only cleanup**
`github.com/NVIDIA/NeMo-text-processing` (+ `tests/nemo_text_processing/hi_en/data_inverse_text_normalization/`) · `github.com/google-research-datasets/Disfl-QA` · `arxiv.org/abs/2106.04016` · `github.com/google-research-datasets/Hinglish-TOP-Dataset` · `arxiv.org/pdf/2211.07514` · `doi.org/10.5281/zenodo.3605597` (PHINC) · `aclanthology.org/2020.wnut-1.7/` · `github.com/google-research-datasets/dakshina` · `aclanthology.org/2020.lrec-1.294/` · `huggingface.co/datasets/ai4bharat/Aksharantar` · `huggingface.co/datasets/ai4bharat/Bhasha-Abhijnaanam` · `github.com/huashen218/MultiTurnCleanup` · `aclanthology.org/2023.emnlp-main.613/` · `catalog.ldc.upenn.edu/LDC99T42` · `catalog.ldc.upenn.edu/LDC2009T26` · `github.com/vickyzayats/switchboard_corrected_reannotated` · `zenodo.org/records/6451984` (LARD) · `huggingface.co/datasets/PeacefulData/HyPoradise-v0` · `huggingface.co/datasets/PeacefulData/Robust-HyPoradise` · `arxiv.org/abs/2309.15701` · `github.com/rwsproat/text-normalization-data` · `github.com/microsoft/GLUECoS` · `ritual.uh.edu/lince/home` · `aclanthology.org/2021.eval4nlp-1.20/` (HinGE) · `github.com/l3cube-pune/code-mixed-nlp` · `huggingface.co/superwhisper/s1-mini` · `superwhisper.com/blog/s1` · `wisprflow.ai/canto` · `arxiv.org/abs/2606.30790` (Indi-RomCoM) · `aclanthology.org/2026.eacl-short.45/` · `arxiv.org/pdf/2503.16745` (SPACER)

**Licence-check pass (§7), sources opened directly**
`zenodo.org/api/records/15551669` (HiACC metadata) · `pmc.ncbi.nlm.nih.gov/articles/PMC12329218/` (HiACC paper, CC BY-NC statement) · `datashare.ed.ac.uk/server/api/discover/search/objects?query=10283/3055` (ASVspoof 2017 `dc.rights`) · `datashare.ed.ac.uk/server/api/discover/search/objects?query=10283/3336` (ASVspoof 2019) · `zenodo.org/api/records/4834716` (ASVspoof 2021 PA, part sizes) · `huggingface.co/datasets/besimple-ai/voice-code-bench/raw/main/LICENSE` · `huggingface.co/api/datasets/*` (licence, gate and `usedStorage` records) · `datasets-server.huggingface.co/{size,first-rows,filter}` (eot-bench `hi` script + sizes; smart-turn `hin` rows; `agarwalayushi/hinglish` rows) · `raw.githubusercontent.com/YuanGongND/ReMASC/master/README.md` · `openslr.org/{12,51,103,104,118,145}/` · `api.github.com/repos/{NVIDIA/NeMo-text-processing,google-research-datasets/Disfl-QA,google-research-datasets/Hinglish-TOP-Dataset,google-research-datasets/dakshina,Open-Speech-EkStep/ULCA-asr-dataset-corpus,YuanGongND/ReMASC,AI4Bharat/Svarah,AI4Bharat/IndicSUPERB}` · `zenodo.org/api/records/3605597` (PHINC) · `arxiv.org/html/2606.21408` (Vaani Benchmark paper) · `arxiv.org/abs/2305.15760` (Svarah paper)

**This repo**
`VoicePlus_ModelResearch_V2_Multilingual.md` §1, §3.1, §4.0, §4.1, §4.2 · `Lab/FIXTURES.md` · `Lab/Harness/Scoring.swift` · `Lab/Harness/FixtureSuite.swift` · `Tests/EngineTests/RealRoomCorpus.swift` · `Tests/EngineTests/RecordingReplayTests.swift` · `Tests/AppTests/RefinementBenchmarkCorpusTests.swift` · `Fixtures/audio/README.md` · `Fixtures/real-room/README.md` · `Fixtures/prosody/script.md` · `Fixtures/directed/manifest.json` · `Package.swift`
