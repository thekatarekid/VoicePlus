# VoicePlus: local model research, V2 — multilingual (English + Hindi + Hinglish)

*20 Sep 2026. Supersedes the language, memory and toolchain assumptions of `VoicePlus_ModelResearch_V1.md`. Local models only. Target hardware widened: Apple M-series laptops from **8 GB** unified memory upward, not just the 16 GB dev Mac.*

**How to read this.**
- Source keys in brackets, e.g. "4.86 ([LB])". §7 lists them. Keys carried over from V1 keep their V1 meaning.
- **est.** = my arithmetic. **vendor** = the maker's own number. **unverified** = I could not confirm it and you should not bet on it.
- **Current** = what VoicePlus ships today.
- Nothing here was run on your Mac. Owner-measured numbers come from `DECISIONS.md`. Toolchain and disk facts in §5 *were* measured on this Mac today.
- **§8 "Check notes" records an independent verification pass.** Every load-bearing claim was re-checked against its cited source and against the repo. Five corrections change a recommendation — most importantly **C1** (MLX does not wire memory by default, so §3.0(ii)'s central argument was wrong), **C2/C3** (the pure-C runtime is bf16-only, but llama.cpp GGUF gives us quantised *and* no-Metal-compiler, so Stack 1 survives on a better runtime) and **C13** (§5.2's install order breaks the build one step earlier than written, and its rollback is not one). Corrections are marked *(corrected)* at the point of use.

**What changed since V1, and why.** V1 optimised for English latency on a 16 GB CLT-only Mac. Three of its premises are now wrong or void:

| V1 premise | V2 status |
|---|---|
| "The Qwen3-ASR 0.6B result stands." (V1 §3.1) | **Struck.** See §1. What R5.4 established is that an abandoned CoreML port of the *small* model is unusable — a fact about a converted artifact, not about Qwen3-ASR. |
| "Hindi/Hinglish possible" — a nice-to-have behind English latency | **Primary requirement.** This disqualifies Parakeet as the general engine: v3's 25 languages are all European and NVIDIA ships no Indic Parakeet ([P3]). |
| "MLX-Swift is blocked … Apple frameworks blocked" — therefore ruled out | **Void as a reason.** But it turns out you may not need either. Two routes (llama.cpp XCFramework, `antirez/qwen-asr` pure C) need no Metal compiler at all. And MLX has a *non*-toolchain problem on 8 GB — see §3.0. |
| 16 GB, "at most 1.5 GB resident" | Now a two-tier budget. 8 GB is the binding constraint on the whole design, and it is tighter than disk by a wide margin. |

---

## 1. Was our Qwen3-ASR test wrong?

**Your doubt is justified. The R5.4 verdict is not safe, and should be treated as inconclusive and superseded — but it is not simply backwards either.**

1. **We tested the wrong model.** R5.4 ran Qwen3-ASR **0.6B**, not 1.7B (`Qwen3Weights.swift:19,94-95`). On the live board 0.6B scores 5.045 — already *behind* Parakeet v3's 4.86. 1.7B scores **4.31**, the best open model there ([LB]). Public praise for "Qwen" is praise for 1.7B, which we never ran.
2. **We tested it through a broken runtime.** The vendored CoreML port came from FluidAudio 0.15.1, a backend upstream **deleted in 0.15.3** — the release note reads "chore(asr): remove experimental Qwen3 ASR backend" ([FA-R]). FluidInference's own card for that exact artifact reports LibriSpeech test-clean **4.4% and RTFx 2.8x**, against **2.11%** for PyTorch and **2.33% at RTF 0.029 (~34x)** for the same weights on MLX ([QCML], [MLXQ]). The port roughly doubles the error and is ~12x slower. Our p50 of 2249 ms was also a **debug** build ([R5.4]). *(Caveat added on re-check: the card lists both a Float32 (~2.5 GB) and an Int8 (~0.7 GB) variant and does **not** say which one the 4.4% belongs to. We ran the **int8** build (`Qwen3WeightsLayout.folderName = "qwen3-asr-0.6b/int8"`), so 4.4% may still flatter what we actually loaded. **Unverified.**)*
3. **The test was asymmetric against Qwen.** The Qwen arm received ~1000 chars of screen terms as a system prompt, deliberately seeded with sound-alike distractors ("Kothary", "Mumbles", "Fridge", "Rupees"); the Parakeet arm received none (`RefinementBenchmarkCorpusTests.swift:306-325`, `GateRecallCorpusTests.swift:67-85`). Context injection is a known hallucination trigger; line 05 scored WER **1.200** — more errors than reference words.
4. **It was under-powered and mis-scored.** n=20, one speaker, one room, **12 of 20 tied**. A sign test on the published 1-better/7-worse split gives **p ≈ 0.070** — not significant. The pooled-error CI touches zero. The scorer (`Scoring.swift:6-19`) has no ITN, so "2,340" → ["2","340"]; a better normaliser already exists in this repo (`RealRoomCorpus.swift:142-152`) and was not used. The shipping-configuration verdict ("strictly harmful") rests on **n = 2** completed refinements.
5. **What survives.** Qwen was equal-or-worse in 10 of 11 segment classes, which a single confound rarely produces; it collapsed on the synthetic noisy suite (0.229 vs 0.022) with no prompt confound; and the public number *for the size we actually tested* agrees with us. So R5.4 correctly measured a bad artifact, and is silent on the question you are now asking.
6. **On Hindi, public data does not flatter Qwen either.** 1.7B FLEURS Hindi is **17.15%** and 0.6B is **19.12%** ([QASRRep]); on Vaani (real spontaneous Hindi) 0.6B ranks 6th at 20.6, behind SraVaani 10.9 and Shrutam-2 17.4 ([Vaani]). *(Corrected: V2 first wrote that the Qwen3-ASR report "calls Hindi out as its weakest language". It does not. Hindi sits inside the report's **long-tail language** group, and the report notes only that performance degrades on the full 30-language setting. The numbers stand; the editorialising did not — Check notes C6.)*
7. **What settles it.** A paired bake-off in each model's *reference* runtime, no deadline, symmetric prompting, one ITN-aware script-blind scorer, ≥100 Hinglish utterances, paired bootstrap CIs, per-utterance hypotheses committed. §4 specifies it. It needs no Xcode and no admin password.

**Verdict:** re-open Qwen. Not because it will win English — Parakeet still earns that on latency and word confidence — but because the only head-to-head we ever ran cannot support ruling it out for the language requirement it was never tested on.

---

## 2. Are Whisper / Qwen / Canary / Granite / Moonshine / SpeechBrain useless?

**Short answer: Whisper, Granite, Canary, Moonshine and SpeechBrain are genuinely not useful for *this* requirement — each for a specific, checkable reason, mostly "no Hindi in the model at all". Qwen is the exception: it is useful and we under-measured it.**

**Why Parakeet kept winning, and whether it still does.** It won on four things: (i) ~121/130 ms p50/p95 on your own audio ([R5.4]); (ii) a shipping, maintained CoreML path in FluidAudio — everything else needed a port; (iii) per-word confidence, which `SpanRewriter` and the `TranscriptSpan` contract depend on and which no autoregressive model provides; (iv) our own head-to-head. Of those, (i)–(iii) still hold and are real. (iv) does not — see §1. **What has changed is that none of those four things is language coverage.** Parakeet has no Hindi and cannot acquire it. So it keeps the English final pass and loses the title of "the engine".

**The benchmark trap you need to know before reading the Hindi column.** Voice Arena Monsoon hi-IN *is* a code-mixed Hinglish benchmark, but its **references are Devanagari** ([GS-Blog]). A model that writes romanised Hinglish — *"mujhe kal office jaana hai"* — scores catastrophically even if that is exactly what you want typed. Measured directly: Bodhan Flex scores **13.40% script-blind vs 43.6% strict** on CoSHE ([BodhanCML]). So the Hindi column below ranks models under a *Devanagari* output policy, which may not be your policy. This is the blocking product decision in §4.

*(Precision correction — Check notes C9. V2 first wrote that Monsoon "QC flagged submissions containing characters outside the target script", implying a scoring-time gate on model submissions. Re-reading [GS-Blog], that sentence describes **annotator** QC during reference creation: "Annotator behaviour was monitored automatically throughout, flagging submissions containing characters outside the target script". There is no model-submission script gate. The Devanagari references alone are sufficient for the argument; the extra claim was not.)*

**One thing the Monsoon column is not.** The "Monsoon" figures in the *English* table below are the **Indian English (en-IN)** subset, which the leaderboard folds into every model's headline English average — "Indian English joins the main leaderboard as `Voice Arena Monsoon`, in the default column set rather than as an opt-in toggle" ([GS-Blog]). The Hindi figures come from the separate hi-IN file ([LB-hi]). They are different datasets and are labelled "en-IN" and "Monsoon" respectively throughout.

### 2.1 Every model from your screenshots and links

Monsoon = live Open ASR Leaderboard multilingual hi-IN OIWER; Vaani = Vaani-Benchmark-V1.0 (spontaneous, 104 districts). Lower is better everywhere. "Live EN" = live English short-form board average.

| Model | Runs locally on Mac? how? | Live EN | Hindi / Hinglish | Speed on Mac | Size / RAM at ship quant | Licence | Verdict, by layer |
|---|---|---|---|---|---|---|---|
| **Parakeet TDT 0.6B v3** *(Current)* | **Yes** — FluidAudio CoreML, ANE, shipping | 4.86 ([LB]) | **None.** 25 European languages ([P3]) | Owner p50/p95 **121/130 ms** ([R5.4]) | 483 MB / ~0.5–0.8 GB peak ([MacP]) | CC-BY-4.0 | **Final ASR: keep, English only.** Cannot serve Hindi at any effort |
| Parakeet TDT 0.6B v2 | Yes — same path | **4.70**, en-IN **3.89** ([LB]) | None | ~90x, 0.55 s cold, M4 Pro ([MacP]) | ~465 MB | CC-BY-4.0 | **Final ASR (EN): A/B against v3, catalog change only** |
| Parakeet Unified EN 0.6B | Yes — FluidAudio 0.15.6 | card 5.91 (old board) | None | ~93x; Mac LS macro **2.38%** ([MacP]) | ~565 MB–1.2 GB int8 | NVIDIA OML | **Preview + final (EN) A/B arm** |
| Parakeet Realtime EOU 120M *(Current)* | Yes — FluidAudio | LS-clean 8.23% @160 ms, **4.88% @320 ms** ([FA-B]) | None | first word p50/p95 712/1210 ms ([R1.5]) | 224 MB | NVIDIA OML | **Preview (EN): move to the 320 ms tier** |
| **Qwen3-ASR 1.7B** | **Yes, three ways** — **llama.cpp GGUF (quantised, no Metal compiler — the best route)**, MLX (needs the Metal toolchain), `antirez/qwen-asr` pure C (**bf16 only**) | **4.31 — best open**; en-IN **3.50** ([LB]) | Monsoon **12.25** ([LB-hi]); FLEURS hi 17.15 ([QASRRep]) | ≈1.0–1.2 s / 10 s clip on M2 Pro (**est., unverified**, from 0.6B fp16 0.30 s on M4 Pro ×1.9 ×~2) | ~1.2–1.5 GB @Q4_K_M; **6.6–7.3 GB measured peak RSS** in the C impl ([QC]) | Apache-2.0 | **Hinglish final pass, 16 GB tier only.** No word confidence; too slow for the EN budget |
| Qwen3-ASR 0.6B *(what we tested)* | Yes — same three ways; `ggml-org/Qwen3-ASR-0.6B-GGUF` is a first-party GGUF (Q8_0 805 MB, BF16 1.51 GB) ([QGGUF]) | 5.05, en-IN 4.23 ([LB]) | Monsoon 18.13 ([LB-hi]); **Vaani 20.6, 6th** ([Vaani]) | MLX 0.30 s/10 s fp16, 0.17 s @4-bit, M4 Pro ([MLXQ]); our CoreML port 2249 ms debug ([R5.4]) | 805 MB @Q8_0; **2.7–3.3 GB measured peak RSS** bf16 C ([QC]) | Apache-2.0 | **Baseline arm + the base Srota fine-tunes.** The *port* failed, not the model |
| **Srota** (`moorlee/qwen3-asr-0.6b-hinglish`) | Expected yes — **confirmed** a full-parameter fine-tune of `Qwen/Qwen3-ASR-0.6B`, no LoRA, safetensors downloadable ([Srota]). GGUF conversion **unverified**, spike it | inherits 0.6B | **HiACC conversational 24.73% → 15.85%**; OpenSLR-104 tutorial 50.66% → 35.06%. Emits **mixed Devanagari + Latin** — "मेरा favourite festival Diwali है" — **not romanised** ([Srota]) | as 0.6B | ~780M (600M LLM + 180M encoder); 805 MB @Q8_0 GGUF for the base | Apache-2.0 (inherited); training data CC-BY-4.0 | **Highest-upside Hinglish candidate — and the only one sized for 8 GB.** Single-vendor. **Ruled out if you choose a fully-romanised script policy** |
| Bodhan Indic-Transcribe-Flex | **Yes — community CoreML port, no Xcode**; encoder 98.8% on ANE. **Fine-tune of `nvidia/canary-1b-v2`** (confirmed) | not listed | CoSHE **13.40% fp16 / 14.04% int8** script-blind, **43.6–43.8% strict**; on **40 of 200 clips, single speaker** (the full 200-clip PyTorch baseline is **15.56%**) | RTF 0.39/0.24 at load average 12; **fixed 30 s input chunks** (480 000 samples, shorter audio silence-padded) ([BodhanCML]) | 1.1 GB int8 / 2.29 GB fp16, **0.97 GB peak RSS** | Indic Open Model Lic. v1.0 — on-device commercial OK, **share-alike**, attribution | **The only model with selectable native / mixed / fully-romanised output.** Latency is the open question |
| AI4Bharat IndicConformer 600M | ONNX / NeMo; no CoreML. **The repo already has the slot** (`IndicASRAvailability` expects `indic-conformer-600m/{Encoder,Decoder,Joint}.mlmodelc`) | — | **Monsoon 8.47 — best open** ([LB-hi]) | leaderboard RTFx **7.68** — slowest open model in that table | ~2.4 GB fp32, ~1.45 GB int8 ONNX | MIT (gated) | **Devanagari-only. Use as the accuracy yardstick** even if never shipped |
| ARTPARK SraVaani-1.0 | PyTorch; ONNX export offered. FastConformer TDT-CTC — the family FluidAudio already converts | own EN sets 14.8 | Monsoon **11.21**, **Vaani 10.9 — best open** | leaderboard RTFx **184** | 0.43B, ~900 MB fp16 | MIT (gated) | **Best accuracy-per-ms of the Indic options.** Cheap insurance arm. Weak English |
| Nemotron 3.5 ASR Streaming 0.6B (multi) | **Yes — FluidAudio CoreML, shipping**, `auto` LID, decode-time vocab biasing (0.15.7) | 7.88, en-IN 7.30 ([LB]) | Monsoon **13.85 — best open streaming** ([LB-hi]). **Hindi untested in FluidAudio's own harness** | 40–73x on M2, 7 non-Hindi langs ([FA-NemoML]) | ~650 MB int8 | OpenMDW-1.1 | **Hindi live preview only.** English 7.88 disqualifies it as a final pass |
| **Whisper large-v3** | Yes — WhisperKit / whisper.cpp, mature | 5.78 ([LB]) | Monsoon **28.17**, **Vaani 26.8 — worst on the board** | ~6x slower than Parakeet | 1.55B, ~3 GB fp16 | MIT | **Not useful.** Hindi far too weak |
| Whisper large-v3-turbo | Yes — WhisperKit | 6.36, en-IN 4.77 | Monsoon **40.79**. Hindi is a documented turbo-degradation language | ~14x, 2.29 s cold, M4 Pro ([MacP]) | 632 MB | MIT | **Not useful** |
| distil-whisper large-v3.5 | Yes — whisper.cpp | 5.40, en-IN 3.60 | **English-only model by construction** | 879 RTFx (GPU) | 0.8B | MIT | **Not useful here** |
| `vasista22/whisper-hindi-large-v2` | Yes — whisper.cpp | — | FLEURS hi 6.8 — but FLEURS is *read* speech, not spontaneous or code-switched | large-v3 class | 1.5B | — | **Not worth it.** Wrong task shape at 1.5B |
| NVIDIA Canary-1b-v2 | **Yes — FluidAudio AED engine [beta, 0.15.6] + CTC-spotter custom vocab** | 5.71, en-IN 4.97 | **25 European languages, no Hindi** (card checked) | ~7x RTF, ~2.1% WER on ANE | 573 MB int4 CoreML | CC-BY-4.0 | **Not useful for Hindi** — but its Swift decode loop is most of the work of a **Bodhan Flex** port, since Flex is a Canary fine-tune |
| Canary-Qwen-2.5B | NeMo only — **no Mac runtime** | 4.43, en-IN 3.60 | **English only.** Gladia's "25 languages" claim is wrong | — | 2.5B | CC-BY-4.0 | **Not useful** |
| IBM Granite Speech 4.1 2B / 3.3 | mlx-audio, llama.cpp GGUF | 4.62 / 5.36 | Card: **en, fr, de, es, pt, ja only. No Hindi** | no Mac numbers | 2–3B | Apache-2.0 | **Not useful for Hindi.** Its keyword biasing + truecasing is the only draw, English-only |
| Granite Speech 5.0 470M TurboCTC | none published | 5.04 | None | — | 0.47B | Apache-2.0 (`-nc` sibling is NC) | Not useful |
| Moonshine v2 S/M | Yes — ONNX + a Swift package, CPU | 7.84 / 6.65 (vendor) | **"English, Spanish, Mandarin, Japanese, Korean, Vietnamese, Ukrainian, and Arabic" — no Hindi** (confirmed verbatim, [Moon]) | 148 / 258 ms on M3 — **unverified**, not on the cited repo | 123M / 245M — **unverified**; the repo lists Tiny 26M and Medium 200M | MIT | **Not useful for Hindi.** Fine as an English CPU fallback if the ANE is contended |
| **SpeechBrain** | PyTorch only — **no Mac ASR deployment path** | — | — | — | toolkit | Apache-2.0 | **Not a model.** It is a research toolkit. Its one asset is ECAPA-TDNN embeddings, which score **0.56% vs WeSpeaker's 0.58%** on CASE — no gain ([CASE]) |
| Voxtral Mini 3B / Small 24B / Mini-4B-RT | MLX / GGUF | 5.54 / 4.99 / 6.46 | Monsoon **22.9 / 23.2 / 24.73**. Claims Hindi, doesn't deliver | RT 66 ms/step, 2.7→4.2 GB over 60 min | 3B / 24B / 4B | Apache-2.0 | **Not useful** |
| VibeVoice-ASR 7B | mlx-audio | 5.58 | Monsoon **39.21**; ~0.1% Hindi training data | **30 GB peak for 1 h of audio** ([Willison]) | 7B | MIT | **Not useful** |
| Cohere Transcribe 2B | Yes — FluidAudio CoreML | 4.67, en-IN 3.44 | None | **73 s cold start, ~11.6 GB peak** ([MacP]) | 2.3 GB q8 | Apache-2.0 gated | **Not useful.** Memory |
| Gemma-4-12B (ASR) / omniASR-1B | — | — | Vaani **24.6 / 25.6** — worse than Qwen 0.6B at 4–20x the size | — | 12B / 1B | Apache-2.0 | Not useful |
| SenseVoice-Small / FireRedASR / Kyutai STT / Phi-4-MM | FluidAudio (SenseVoice) / MLX | Phi-4 5.02 | **None support Hindi** | — | — | various | Not useful |
| Apple SpeechTranscriber (macOS 26) | Needs the macOS 26 SDK to *build*; ships with the OS | 14.0% vs Parakeet v2's 11.7% on an earnings22 subset, competitor-run ([ArgmaxApple]) | **`hi_IN` is absent from `supportedLocales`.** en_IN is present ([SALoc]) | final text median 125–132 ms after speech ends ([DevApple]) | 0 — OS-resident, shared, "does not increase run-time memory" ([WWDC277]) | OS | **Not useful for Hindi. Best-in-class *memory* profile for an English fallback** on the 8 GB tier |
| Apple Foundation Models | macOS 26 SDK to build; user must have Apple Intelligence **on** | — | **No Hindi, and no Indic language announced.** en-IN *is* supported | 846 ms avg polish, M4 Pro ([Envious]) | 0 — OS-resident | OS | **Cannot be the cleanup path.** English-only bonus behind an availability check |
| LiveKit turn detector | ONNX | — | 14 languages incl. hi | — | 281 MB | **No standalone use** | **Ruled out on licence** (unchanged from V1) |

**So: is Parakeet still the right recommendation?** For English, yes, and for reasons that survive scrutiny — not the WER comparison. For the product as a whole, no: the answer is now two engines, and the second one is a Qwen derivative or Bodhan Flex.

---

## 3. Recommended stacks

### 3.0 The two constraints that shape all three

**(i) 8 GB is the binding budget, and it is not disk.** An independent 8 GB-Mac guide budgets macOS at ~1.5–2.0 GB, a browser at 0.5–1.5 GB and background apps at 0.3–0.5 GB, leaving **4–5.5 GB realistically** ([8GB]). That is the budget for an app the user is *staring at*. VoicePlus is a background guest. The failure mode is a cliff, not a slope: the same source measures fully-resident inference at 25–45 tok/s, 1–2 GB of spill at 3–8 tok/s, and 3 GB+ of spill at **under 1 tok/s** — a ~57x drop, because unified memory on the base-tier chips every 8 GB Mac uses runs **~100 GB/s** against an NVMe SSD at ~3–7 GB/s ([8GB]). *(Corrected — V2 first wrote "~400 GB/s", which is Max-tier bandwidth and applies to no 8 GB machine; see Check notes C8.)* There is no graceful degradation to design around.

**(ii) MLX and CoreML do not cost the same memory — but the reason is weaker than V2 first claimed.** *(Corrected — see Check notes C1.)* MLX does **not** wire memory by default: `mlx.core.set_wired_limit`'s documentation says "The wired limit is the total size in bytes of memory that will be kept resident. **The default value is 0**" ([MLXWired]). Wiring is opt-in. `mlx-lm` opts into it (it prints a wired-memory limit at model load), but an embedding app need not, and a host that leaves the limit at 0 gets ordinary pageable Metal allocations. So "MLX weights are an unreclaimable reservation" is a property of *mlx-lm's configuration*, not of the framework, and it is not a reason to rule MLX out.

What survives, and is still real: MLX allocations are counted against Metal's `recommendedMaxWorkingSetSize`, which macOS hard-codes at roughly **two-thirds of unified memory on machines up to 36 GB** (≈5.3–5.7 GB of an 8 GB Mac) and ~75% above that ([WSS]). CoreML/ANE weights are file-backed and pageable and sit outside that ceiling. The practical rule for us is therefore narrower than a ban: **if we ever embed MLX, leave the wired limit at 0 and measure RSS** — do not adopt an upstream runtime that calls `set_wired_limit` on our behalf.

Counter-caveat in the other direction, unchanged: a palettized INT4 CoreML model can decompress toward FP16 at runtime — one documented case has a 332 MB INT4 package allocating ~1.3–1.7 GB ([IvanD]). **Never assume INT4-on-disk means INT4-in-RAM; measure RSS.**

**Budget, therefore:**

| Mode | Resident ceiling |
|---|---|
| Default English dictation | **≤ 1.5 GB** |
| Hinglish mode, 8 GB Mac | **≤ 2.5 GB total**, and the English and Hinglish final-pass models **never both resident** |
| Hinglish + cleanup LLM | 16 GB only, ≤ 4 GB, gated on `physicalMemory ≥ 12 GB` |

### 3.1 The three stacks

| | **Stack 1 · Two Engines** *(recommended)* | **Stack 2 · Qwen Everywhere** | **Stack 3 · CoreML Only** |
|---|---|---|---|
| **Final ASR, English** | Parakeet TDT v2 or v3 (A/B) | Qwen3-ASR 1.7B @4-bit (16 GB) / 0.6B (8 GB) | Parakeet TDT v2 or v3 |
| **Final ASR, Hinglish** | **Srota** as GGUF Q8_0/Q4_K (mixed-script output only); fallback Qwen3-ASR 1.7B Q4_K_M (16 GB only) | same model, LID-routed | **Bodhan Flex int8 (CoreML)**; fallback IndicConformer converted |
| **Runtime for the 2nd engine** | **llama.cpp GGUF** (MIT) — quantised *and* no Metal compiler; `antirez/qwen-asr` demoted to fallback (**bf16-only**, confirmed) | MLX-Swift (**needs the Metal toolchain → Xcode**) or llama.cpp | CoreML via FluidAudio-style loader — **no Xcode, nothing new** |
| **Preview** | EOU 120M **@320 ms** (EN). Hinglish: suppress, or Nemotron 3.5 @1120 ms | Qwen streaming, 2 s chunks | EOU 120M @320 ms (EN); Nemotron 3.5 (HI) |
| **EOU / latch** | Silero + **Smart Turn v3.2** (BSD-2), audio-only, no text veto | same | same |
| **Speaker** | WeSpeaker + community-1 offline, unchanged | unchanged | unchanged |
| **Cleanup** | rules → NeMo ITN (`hi`, `hi_en`) → S1-mini **English-gated** | same | same |
| **Disk** | ~1.2 GB EN + ~1.2 GB HI, HI downloaded on first mode switch | ~3.4 GB (16 GB tier) | ~1.2 GB EN + 1.1 GB HI |
| **RAM, 8 GB Mac** | ~0.9–1.2 GB idle; ~1.2 GB EN turn; **~1.5–2.2 GB HI turn est.** on GGUF Q8_0 (805 MB weights + KV + mel), or **2.7–3.3 GB measured** if the bf16 C runtime is used instead ([QC]) — models never co-resident | **Over budget** with a separate cleanup LLM (~4.0 GB); ~2.0–2.5 GB if cleanup rides the same decoder | **~0.9–1.2 GB idle; 0.97 GB measured peak** for Flex — the safest of the three |
| **RAM, 16 GB Mac** | ~1.7 GB both resident; cleanup LLM +1.3 GB | ~3.4–4.0 GB | ~1.7 GB |
| **Release → text** | EN ~0.15 s (unchanged). HI ~1.0–1.5 s **est., unverified** | EN ~0.7–1.2 s/10 s clip — **misses the 700 ms p50 budget** | EN unchanged. HI **unknown — the fixed 30 s chunk is the risk** |
| **Languages** | EN (25 European) + Hinglish/Hindi | 30 + 22 Chinese dialects | EN + 27 Indic |
| **Licences** | CC-BY-4.0, NVIDIA OML, **Apache-2.0** (Qwen/Srota), **MIT** (runtime), BSD-2 | Apache-2.0 + MIT | CC-BY-4.0, NVIDIA OML, **Indic Open Model Lic. v1.0 (share-alike + attribution)** |
| **Effort** | **M–L** | **L** | **M** |
| **Main risk** | Srota is single-vendor and **mixed-script only**; Srota→GGUF conversion is unproven; llama.cpp has an open long-audio bug ([LCppBug]) | Latency, no word confidence, 8 GB residency ceiling | Flex latency (30 s padding), no streaming, share-alike licence, romanisation not standardised |

**Recommendation: build Stack 1, with Stack 3 as the live fallback if the Srota spike fails — and note that §4.0's script decision can decide this for you.** If you want **fully romanised** Hinglish typed, Stack 1 is out on the spot: Srota emits mixed Devanagari+Latin ("मेरा favourite festival Diwali है", [Srota]) and Bodhan Flex is the only candidate with a selectable romanised mode. If you want **mixed script**, Stack 1 is the better build. Stack 3 is strictly cheaper and needs nothing installed; it loses only on unknown latency and a share-alike licence. Stack 2 is not recommended as a default at any tier — but note its rejection no longer rests on MLX memory (see §3.0(ii) as corrected). It rests on two things that did survive: Qwen3-ASR has **no word confidence**, which `SpanRewriter` and the `TranscriptSpan` contract depend on, and its autoregressive latency grows with output length.

**Why llama.cpp is now the primary runtime, not `antirez/qwen-asr`** *(corrected — Check notes C2/C3)*. §6's open question "does the C runtime support 4-bit?" is resolved: **it does not.** Weights are BF16, the encoder is converted to F32 in heap memory, and measured peak RSS is ~2.7–3.3 GB for 0.6B and ~6.6–7.3 GB for 1.7B ([QC]) — the 0.6B figure alone blows this table's own 2.5 GB Hinglish ceiling on an 8 GB Mac. Meanwhile Qwen3-ASR is first-class in llama.cpp: `ggml-org/Qwen3-ASR-0.6B-GGUF` ships **Q8_0 at 805 MB** and BF16 at 1.51 GB ([QGGUF]), driven by `llama-mtmd-cli -m <model>.gguf --mmproj <mmproj>.gguf --audio x.wav`, with Q4_K_M community builds for 1.7B. Built with `GGML_METAL_EMBED_LIBRARY=ON` the Metal shader library is embedded rather than compiled by `xcrun metal` ([LCppBuild]), so this route is quantised **and** needs no Metal compiler — the combination the C runtime cannot offer. The C route stays as a zero-dependency fallback for a 16 GB-only path.

### 3.2 The exact tier-selection rule

```swift
// Shared/ or App/Services/ — one place, read by ModelCatalog and the engine factory.
let bytes = ProcessInfo.processInfo.physicalMemory
var tier: MemoryTier = bytes >= 12 << 30 ? .full : .lean   // 12 GB catches 8 GB and any 10 GB SKU
```

Then three overrides, in this order:
1. **User override** in Settings (`.lean` / `.full` / `auto`). A 16 GB user running Docker and Chrome may genuinely want `.lean`. Never let a user force `.full` under 12 GB without a warning.
2. **Model availability** — if a tier's model is not downloaded, fall back rather than block dictation.
3. **Live `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`.** On `.warning`, unload every secondary model over 1 GB immediately; on `.critical`, drop to `.lean` for the rest of the session and say so once, quietly. **Non-optional**: physical RAM alone cannot tell you the machine is already under pressure.

**What `.lean` (8 GB) gets:** Parakeet warm at all times (~0.9–1.2 GB with VAD + EOU-320 + Smart Turn). Cleanup is rules + NeMo ITN. Hinglish is an explicit mode switch that loads the second engine on demand and **unloads it after 120 s idle**. The user pays a one-time load on first switch — say so in the UI rather than hide it.

**What `.full` (16 GB+) adds:** both engines warm, so Hinglish is instant; the bundled cleanup LLM stays resident; unload timer goes to 15 minutes and never fires mid-session; speaker embeddings preload.

**What degrades on 8 GB, plainly:** no parallel second-opinion pass; Hindi first word after a mode switch is seconds, not milliseconds; cleanup is rules/ITN only. **Nothing about English dictation quality changes** — that is the whole point of keeping a small CoreML final pass.

### 3.3 Engineering effort, by file

| Work | Files | Effort |
|---|---|---|
| Memory tier + pressure source + Settings override | new `Shared/MemoryTier.swift`; `App/Settings/VoiceSettings.swift`; read in `Engine/ASRRuntime/ModelCatalog.swift` and `App/Services/EngineFactory.swift` | S |
| EOU 160→320 ms tier | `ModelManager.swift:186`; new `ModelCatalog.swift` entry for the repo's `320ms` folder (a new ~224 MB download + migration, not a one-liner) | S |
| Parakeet v2 arm behind a flag | `ModelCatalog.swift`; `BundledModel.swift:57` (`chooseFinal`) | S |
| Second engine as a real backend | replace `UnavailableIndicBackend` in `Engine/CodeSwitch/IndicASRBackend.swift` — **the protocol and on-disk layout check already exist**; wire through `Engine/ASRRuntime/Recognizers.swift` and `RealEngine.swift` | **L** |
| New runtime as a SwiftPM target | `Package.swift` gains one binary/C target (llama.cpp XCFramework, or `antirez/qwen-asr` as a C target). Log in `progress.md` per repo rules; add to the nested-code signing loop in `Packaging/make_app.sh` | M |
| Mode switch + routing | `App/Services/CodeSwitchService.swift` (`setRouter`), `CodeSwitchRouter` in `App/Services/EngineFactory.swift`, `Engine/CodeSwitch/LanguageDetector.swift`. **Explicit toggle first**; today's router keys off romanised-Hindi function words in an *English-only* preview, which is unreliable by construction | M |
| Script policy in output | `Engine/CodeSwitch/ScriptAwareMerger.swift`, `Script.swift`, `ScriptIndicator.swift` | S–M |
| Script-blind scorer + one ITN normaliser | `Lab/Harness/Scoring.swift` — retire the three-scorer situation (`Scoring.swift:6-19`, `RealRoomCorpus.swift:142-152`, `ASRGoldenTranscriptTests.swift:7`) | M |
| Cleanup provider + guard | new `Providers/LlamaCppProvider.swift` conforming to `TextGenerator`; `Providers/RoutingTable.swift` to on-device-first; ITN + guard stages in `Pipeline/Refine` | M |
| Speaker gate hardening | `Engine/Speaker/SpeakerGate.swift` — non-biometric cues, not a new embedder | S |
| Retire the Qwen3 CoreML port | delete `Engine/ASRRuntime/Qwen3ASR/` (11 files, 2701 lines) once a replacement lands; keep `qwenRefinement` off meanwhile | S |

---

## 4. Decision plan

### 4.0 The decision only you can make — and it blocks everything

**What script do you want typed?** Record 30 Hinglish utterances and write each one three ways — full Devanagari, mixed (Devanagari words + Latin English words), fully romanised — then look at them in Slack, Mail and your IDE and pick one. Everything below branches on the answer, and the public Hindi leaderboard actively misleads about it (§2). Under a Devanagari policy IndicConformer "wins" Hindi at 8.47; under a romanised policy it is disqualified and Bodhan Flex is the only native option. **Until this is settled the models cannot be ranked honestly.** Roughly 1 day, mostly yours.

### 4.1 Order of work

| # | Work | Gate: proceed only if | Days |
|---|---|---|---|
| 0 | **Script policy** (above) + make `Lab/Harness/Scoring.swift` script-blind: transliteration-table word equivalence, CER beside WER, one ITN-aware normaliser used by both Swift and the Python harness | A written policy exists. Today's scorer would call a perfect romanised transcript ~44% wrong | 2 |
| 1 | **Spike: Srota + `antirez/qwen-asr`.** Load Srota's weights in the C runtime; measure release-build latency and peak RSS (`footprint -p`, `vmmap --summary`) under an 8 GB-simulated budget | Weights load; p95 ≤ 1.5 s on 5–10 s clips; peak RSS ≤ 2.5 GB. **If it fails → Stack 3** | 1–2 |
| 2 | **Spike: Bodhan Flex CoreML int8 latency.** True release→text on **5-second** utterances with the fixed 30 s padding — the port does not state whether RTF was computed against true or padded duration | p95 ≤ 1.5 s. Over that, it is a background re-transcription model, not a dictation model | 1 |
| 3 | **Record R2**: 100+ Hinglish utterances (20 pure Hindi, 50 code-mixed, 20 Indian English with Hindi names, 10 long-form), **two references each** (mixed-script and fully romanised), you mark the preferred script per item. **The long pole — nothing else can finish without it** | — | 0.5 (yours) |
| 4 | **Python bake-off harness**, every arm in its *reference* runtime (MLX-Python / transformers / ONNX / the C impl), per-utterance hypotheses dumped to JSON and **committed** (they were not for R5.4, which is why §1 had to reconstruct statistics). `uv` and Python 3.14 are present; MLX-Python ships prebuilt Metal kernels — **no Xcode, no password** | Harness reproduces the R5.4 Parakeet number within noise | 1 |
| 5 | **R2 bake-off**: Srota · Qwen3-ASR 0.6B · Qwen3-ASR 1.7B · Bodhan Flex · IndicConformer 600M · SraVaani-1.0. Script-blind scoring, paired bootstrap (10 000 resamples) + Wilcoxon, CIs reported | Winner ≥ 50% relative better than the English stack on R2; you accept its output script on ≥ 80% of items; p95 ≤ 1500 ms; RAM ≤ +2 GB on 16 GB / ≤ +1.5 GB on 8 GB; **R1 English unchanged with the mode off** | 2 |
| 6 | **Fair Qwen re-test on R1** (English), same harness, symmetric prompting, both sizes, fp16 *and* 4-bit so quantisation is a separate variable | Informational. Ship an English change only under V1 §5.4's gates | 1 |
| 7 | **Port only the winner.** This is the only step where the toolchain question can bite — and only if an MLX-Swift model won | — | 5–10 |
| 8 | English A/B (v2 vs v3 vs Unified), preview 160 vs 320 ms, latch sweep, cleanup bake-off — all as specified in V1 §5.3, unchanged | V1 §5.4 gates, unchanged | — |

### 4.2 Gates that changed from V1

- **Ship a Hinglish route** — V1's gate stands, plus: **script acceptance ≥ 80%** measured against *your* policy, and **peak RSS measured with `footprint`/`vmmap`, not `phys_footprint`** (which excludes mapped weights and has been understating us; `DECISIONS.md:332-334` says so — *corrected from `:368-374`, C12*).
- **Cleanup on Hinglish** — new hard gate: **0 silent translations** on a 30-item Hinglish adversarial set. Indi-RomCoM ("Indi-RomCoM: Code-Mixed Benchmark for Evaluating LLMs on Romanized Indic-English Instructions") defines **Register Defection Rate** as "the proportion of responses written in English when the input is in CM register". Table 7: **LLaMA-3.1-8B 99.7%, Qwen2.5-1.5B 99.8%, Qwen3-4B 98.8%, Qwen3-14B 92.0%**, against Indic-trained **Airavata-7B 16.5%** and **Sarvam-30B 26.1%** ([RomCoM]). **Therefore: no general small LLM on Hinglish by default.** Rules + NeMo ITN only; any polish is opt-in behind a token-level script-preservation guard (tokenise the ASR output, mark every non-English-dictionary token, reject the LLM output if any marked token changed).
  - *Two corrections on re-check (C7).* (a) V2 wrote ">98% for Qwen variants" — true of the small ones but **not** of Qwen3-14B at 92.0%. The size trend runs the right way for our conclusion (the smaller the model, the worse the defection), so the gate is unaffected, but the blanket claim was wrong. (b) RDR is measured on **instruction-following responses**, not on ASR-transcript cleanup. Applying it to a cleanup pass is an **extrapolation** — a defensible one, since a cleanup prompt is an instruction over code-mixed input, but the paper does not measure our task. The 30-item adversarial set is what actually settles it for us; treat RomCoM as the reason to build the gate, not as the measurement.
- **Two-pass refinement (`qwenRefinement`) stays off** — but for a better reason than R5.4 gave. The n=2 verdict is worthless. The defensible reasons are architectural: an autoregressive second pass has no word confidence, cannot meet 1500 ms p95 on this hardware, and duplicates the formatter. If a Qwen arm wins the language bake-off it should **replace** the final pass for that language, not bolt on as a second pass.

---

## 5. Toolchain: what you install, and what your users install

### 5.1 Verified on this Mac, today

`xcode-select -p` → `/Library/Developer/CommandLineTools`. `xcrun --show-sdk-version` → **15.2** (no macOS 26 SDK; `FoundationModels.framework` absent from every installed SDK). No `metal` compiler anywhere in the CLT. `hw.memsize` 16 GB, `Mac14,9` (M2 Pro), macOS 26.6.2. **Free disk: 25 GB.** `.build-*` scratch paths total **13.2 GB**.

`xcodebuild -downloadComponent MetalToolchain` was run and returned: *"tool 'xcodebuild' requires Xcode, but active developer directory … is a command line tools instance"*. **This settles it: the Metal toolchain cannot be fetched without Xcode.app** — it is downloaded *by* `xcodebuild`, and Apple ships no standalone installer ([Std803174]).

### 5.2 Your checklist — in this order, and stop early if you can

| # | Step | Command | Password? | Time |
|---|---|---|---|---|
| 0 | **Free disk first** (need ≥ 45 GB before step 2) | `rm -rf /Users/adityakatare/Documents/VoiceInput/.build-*` (13.2 GB), then clear `~/Library/Caches/{Codex,com.openai.codex,swiftpm-testing-helper}` (~4.2 GB) and browser caches (~4.9 GB) → ≈ 47 GB | no | 5 min |
| 1 | **Nothing.** Run steps 0–4 of §4.1 first | — | **no** | — |
| 2 | *Only if you want the Apple English fallback:* **Command Line Tools for Xcode 26** (~2–3 GB) | `sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install`, or the installer from developer.apple.com/download/all | **yes** | 15–25 min |
| **2a** | **Retire the CLT workaround — do this at step 2, not step 4** *(corrected, C13)* | delete the three env vars from `.claude/settings.json`; `rm -rf ~/Library/Developer/VoicePlus-{toolchain,swiftpm-libs}`; re-run `eval "$(Scripts/bootstrap-toolchain.sh)"` only if the stock CLT 26 still fails | no | 1 min |
| 2b | Verify | `xcrun --show-sdk-version` → 26.x; `ls $(xcrun --show-sdk-path)/System/Library/Frameworks \| grep FoundationModels` — **whether CLT 26's SDK actually ships `FoundationModels.framework` is unverified; this step is the test, not a formality** | no | 1 min |
| 3 | *Only if an MLX-Swift model wins step 5 of §4.1:* **Xcode 26** — the `.xip` from developer.apple.com/download/all, not the App Store (needs more headroom). Expand on the internal disk; delete the `.xip` immediately | — | **yes** (first launch) | 60–120 min |
| 4 | Switch the active developer dir | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` | **yes** | 10 s |
| 5 | Metal toolchain (~700 MB) | `xcodebuild -downloadComponent MetalToolchain` | maybe | 5–10 min |
| 6 | *(moved to step 2a — the env vars must go the moment CLT changes, not when Xcode arrives)* | — | — | — |
| 7 | Verify the package | `swift build --scratch-path .build-tc` then `swift test --no-parallel` | no | 15–30 min |
| 8 | Rollback if 7 fails | `sudo xcode-select -s /Library/Developer/CommandLineTools` — **note this returns you to CLT 26, not CLT 15.2, which step 2 deleted.** There is no rollback to today's state after step 2; take the risk knowingly or skip step 2 | **yes** | 2 min |

**The one thing that will bite you is not Xcode — it is step 2a, and it bites at step 2, not step 4.** *(Corrected, C13.)* `.claude/settings.json` exports three **absolute paths** into `~/Library/Developer/VoicePlus-toolchain`. Reading `Scripts/bootstrap-toolchain.sh:39-57`, the precise mechanism is: `$TC/usr/bin/swiftc` is a 148-byte wrapper that `exec`s **`/Library/Developer/CommandLineTools/usr/bin/swiftc`** with `-resource-dir` pointing at `$TC/usr/lib/swift`, which is a *symlink* into the CLT (so it follows an upgrade), while `SWIFTPM_CUSTOM_LIBS_DIR` holds a **physical copy** of the old CLT's `ManifestAPI`/`PluginAPI` with the stale `.private.swiftinterface` files deleted. That copy is what goes stale against CLT 26's SwiftPM, and the script is cached — it rebuilds only when the files are missing. So:

```
SWIFTPM_CUSTOM_LIBS_DIR=/Users/adityakatare/Library/Developer/VoicePlus-swiftpm-libs
SWIFT_EXEC=/Users/adityakatare/Library/Developer/VoicePlus-toolchain/usr/bin/swiftc
SWIFT_EXEC_MANIFEST=/Users/adityakatare/Library/Developer/VoicePlus-toolchain/usr/bin/swiftc
```

Leave those exported after **either** step 2 (CLT 26) **or** step 4 (`xcode-select -s`) and you get a **mixed toolchain** — a new SwiftPM driving a wrapper whose `PackageDescription` copy predates it — which fails in ways that look like compiler bugs, or worse, half-works. The upgrade also invalidates the wrapper's premise: `bootstrap-toolchain.sh` exists to route around *stale 2023/2024 leftovers in this particular CLT install*, and a clean CLT 26 should not have them, so the correct move after step 2 is to **delete the vars and try a stock build first**, re-running the script only if it genuinely still fails. Also expect Swift 6.0.3 → 6.3/6.4, so **every `.build-*` must be wiped**, and `XCTest.framework` finally appearing (harmless; the suite is Swift Testing and stays that way). `Package.swift` pins `swiftLanguageVersions: [.v5]`, so no strict-concurrency churn. Installing Xcode also *fixes the root cause* of the workaround — a stock `XcodeDefault.xctoolchain` has none of the stale 2023/2024 leftovers `Scripts/bootstrap-toolchain.sh` patches around. Keep the script in-repo as documented rollback; CLT stays installed alongside Xcode, so rollback is one command.

**Disk warning:** Xcode 26's `.xip` is ~12–13 GB and expands to ~35 GB, with both present during expansion — community figures, **the exact Xcode 26 number is unverified**; Apple publishes none. 25 GB free will fail mid-install. Do step 0 first.

**The honest framing correction.** V1 said MLX and the Apple frameworks were "blocked", and I let that read as "therefore ruled out". Two corrections: (i) Apple's frameworks were blocked only by a **stale CLT**, not by the absence of Xcode — CLT 26 alone unblocks them; (ii) the entire fair re-test in §4.1 runs in **Python**, where MLX ships prebuilt Metal kernels in its wheel, so **the bake-off needs no install and no password at all**. Install for the winner, not for the experiment. And if the winner is Bodhan Flex (CoreML) or the `antirez/qwen-asr` C route, you may never need Xcode.

### 5.3 What an END USER installs: nothing

| Runtime we might adopt | What the user installs | Minimum macOS | Notes |
|---|---|---|---|
| **CoreML** (Parakeet, Nemotron 3.5, Bodhan Flex) | **Nothing** | 14+ | `.mlmodelc` ships in-bundle or downloads precompiled. The CoreML runtime is part of macOS |
| **llama.cpp XCFramework** (GGUF) | **Nothing** | 14+ | Built with `GGML_METAL_EMBED_LIBRARY=ON` the Metal library is embedded in the binary rather than produced by `xcrun metal`; with it **off**, CMake invokes the Metal compiler. **So this is the no-Metal-compiler route only with the flag on** ([LCppBuild]) |
| **`antirez/qwen-asr`** (pure C) | **Nothing** | 14+ | "zero external dependencies beyond the C standard library and a BLAS implementation (Accelerate on macOS)"; NEON, no MPS, no Python, no PyTorch. **BF16 weights only — no quantisation** ([QC]) |
| **MLX-Swift** | **Nothing** | 14+ | `default.metallib` is compiled at *our* build time into `mlx-swift_Cmlx.bundle` inside the `.app`, so users need nothing — but PR #430 **does not remove the build-time Metal compiler requirement**, it only automates the step ([MLXSwift430]) |
| **ONNX Runtime** | **Nothing** | 14+ | Linked into the app |
| Apple SpeechTranscriber | Nothing, but a one-time per-locale OS asset download on first use | **26+** | **Does NOT require Apple Intelligence.** On-device only, assets OS-managed and shared between apps. **Query `SpeechTranscriber.supportedLocale(equivalentTo:)` at runtime — never hardcode a locale list.** The published list is ar_SA, da_DK, de_{AT,CH,DE}, en_{AU,CA,GB,IE,**IN**,NZ,SG,US,ZA}, es_{CL,ES,MX,US}, fi_FI, fr_{BE,CA,CH,FR}, he_IL, it_{CH,IT}, ja_JP, ko_KR, ms_MY, nb_NO, nl_{BE,NL}, pt_BR, ru_RU, sv_SE, th_TH, tr_TR, vi_VN, yue_CN, zh_{CN,HK,TW} — **no `hi_IN`** ([SALoc], [SAGuide]) |
| Apple FoundationModels | Nothing, but the user **must switch Apple Intelligence on**, with device language = Siri language = a supported language | **26+** | en-IN supported since Mar 2025; **Hindi is not, and no Indic language has been announced**. If off, `SystemLanguageModel.default.availability` returns `.unavailable(.appleIntelligenceNotEnabled)` — "Apple Intelligence is available, but not enabled on this device" ([FM]) |
| Rosetta | **Never** | — | Everything is arm64-native |

**Plainly: no. Your users will never install Xcode, Command Line Tools, Python, MLX, or anything else.** VoicePlus ships every runtime and shader it needs. The only user-facing requirement in the whole set is **macOS 26**, and that applies *only* to the optional Apple paths — which you should not depend on anyway, because Apple ships no Hindi. Both must sit behind `@available(macOS 26, *)` with the app still running on 14/15.

**Signing/Gatekeeper, unchanged:** `default.metallib` is a *resource*, sealed by the app's `CodeResources` — no separate `codesign` call. Embedded frameworks *are* code and must join the existing inside-out loop in `Packaging/make_app.sh` (nested first, no entitlements on nested binaries, outer app last, explicitly **not** `--deep`). Hardened runtime stays fine; no new entitlement unless a runtime introduces real JIT. Gatekeeper does not get worse — ad-hoc signing is already the binding problem and the `xattr -dr com.apple.quarantine` step stays. Note that installing Xcode also gives you `notarytool`, so it is a step *toward* fixing that, not away from it.

---

## 6. Open risks and what stays unverified

1. **Srota is single-vendor.** *(Refined, C11.)* The weights, the licence and the numbers are all real and on a full model card — not only the forum post ([Srota]) — but every number is the author's own. No independent evaluation, no leaderboard entry, no Vaani/Monsoon score. Two further facts to plan around: its output is **mixed Devanagari + Latin, never romanised**, so a romanised script policy eliminates it outright; and **no GGUF of it exists** — we would have to convert the safetensors ourselves and confirm the audio encoder survives. **Spike it before it enters any plan** — §4.1 step 1.
2. **RESOLVED, against the C route: `antirez/qwen-asr` is bf16-only.** *(C2.)* The card states BF16 weights with the encoder converted to F32 in heap memory, and measured peak RSS of **~2.7–3.3 GB for 0.6B and ~6.6–7.3 GB for 1.7B** ([QC]). There is no 4-bit path. The 0.6B figure alone exceeds §3.0's 2.5 GB Hinglish ceiling, so the C runtime cannot serve the 8 GB tier and is demoted to a 16 GB fallback. **llama.cpp GGUF is the primary second-engine runtime** (Q8_0 805 MB for 0.6B, [QGGUF]), still with no Metal compiler required. *New risk in its place:* llama.cpp has an open **"No content for Qwen3-ASR using longer audio files"** bug ([LCppBug]) — dictation clips are short, but verify at the long end of the corpus.
3. **Bodhan Flex latency is the biggest single unknown in Stack 3.** The port requires a **fixed 30 s input** (480 000 samples; shorter audio silence-padded), so a 5-second dictation pays for a 30 s encoder pass, and the card does not state whether RTF was computed against true or padded duration. Its RTF 0.24–0.39 was measured at load average 12, on **40 of 200 clips, single-speaker**, for the fp16 headline — the full 200-clip PyTorch baseline is **15.56%**, against the 13.40% headline ([BodhanCML]). Treat as provisional and expect the headline to regress on a full set.
4. **Qwen3-ASR 1.7B on an M2 Pro is unmeasured.** My ~1.0–1.2 s per 10 s clip is extrapolation (0.6B fp16 0.30 s on M4 Pro × 1.9 for size × ~2 for chip). If right, it misses the 700 ms p50 English budget — which is a reason to keep Parakeet for English, not a reason to drop Qwen for Hinglish.
5. **Nemotron 3.5's Hindi is on the leaderboard but not in FluidAudio's own harness** — their FLEURS table covers only en/fr/de/es/ja/it/pt. Its CoreML Hindi behaviour on a Mac is unverified.
6. **No public benchmark scores Hindi *and* English *and* code-switching on one axis with script-blind scoring.** Monsoon is Devanagari-only, Vaani is Hindi-only, HiACC is Hinglish-only, FLEURS is read speech. There is no substitute for R2.
7. **INT4 CoreML runtime expansion** is documented in one case at ~4x ([IvanD]) and Apple's palettization docs are silent on it. Measure real RSS for every quantised CoreML model before shipping.
8. **The R5.4 per-utterance hypotheses were never committed,** so §1's statistics are reconstructions from the class table in `DECISIONS.md`. They cannot be tightened without re-running. Commit hypotheses for every future arm.
9. **Speaker replay remains unfixed and unfixable by model choice.** WeSpeaker goes 0.58% EER clean → **8.57% on playback** ([CASE]), and I found no deployable lightweight open replay detector in 2026 — the AASIST/ASVspoof line is research code with known generalisation problems. Fix it with non-biometric cues (speech onset while the latch is active, level/proximity gate, exclude the system-audio loopback path from the gate entirely, mid-band re-check on long segments), not a new embedder. Language is close to a non-issue here; embeddings transfer.
10. **The Indic Open Model License v1.0 (Bodhan) has a share-alike clause on derivatives** and requires written approval for hosted-API use. On-device commercial use with attribution is allowed. Read it properly before Stack 3 becomes the plan.
11. **Xcode 26's exact size is unverified.** Apple publishes no figure; §5.2 uses community numbers.
12. **Smart Turn's Hindi gain is small.** eot-bench: 6.5% vs 7.4% false cut-offs at 600 ms on 952 spans ([EOTHi]). Budget for roughly a wash in Hindi and lean on timing. And **do not add a text veto for romanised Hindi** — a 2026 study found text made end-of-turn detection worse while prosody helped, and romanised Hindi function words are exactly what a stop-word list gets wrong ([TextEOT]).

---

## 7. Sources

**Measured on this Mac, 20 Sep 2026** — `xcode-select -p`, `xcrun --show-sdk-version`, `xcodebuild -downloadComponent` (error text quoted in §5.1), `df -h`, `du -sh .build-*`, `sysctl hw.memsize hw.model`, `cat .claude/settings.json`.

**VoicePlus repo** (read, not modified)
- `R5.4`, `R1.5`, `Bias`, `Golden` — `DECISIONS.md:221-388, 390-431, 41-57, 93-117`
- `Engine/ASRRuntime/Qwen3ASR/Qwen3Weights.swift:19,22-47,94-95` · `Qwen3AsrManager.swift:177-226,260-269,442,482` · `Qwen3RefinementSession.swift:204,242-256` · `Qwen3AsrModels.swift:248-281` · `Qwen3AsrConfig.swift:27,78` · `WhisperMelSpectrogram.swift:124-135`
- `Lab/Harness/Scoring.swift:6-19` · `Tests/EngineTests/RealRoomCorpus.swift:142-152` · `Tests/EngineTests/ASRGoldenTranscriptTests.swift:7` (three WER scorers)
- `Tests/AppTests/RefinementBenchmarkCorpusTests.swift:306-325` · `GateRecallCorpusTests.swift:40-85` · `RealRoomDigitsClassTests.swift:25,100-160` · `Engine/Biasing/PromptBuilder.swift:32,70`
- `Pipeline/Refine/RefineStage.swift:75` · `Engine/CodeSwitch/IndicASRBackend.swift` · `App/Services/CodeSwitchService.swift` · `App/Services/EngineFactory.swift` · `Package.resolved` (FluidAudio 0.15.6) · `.claude/settings.json` · `Scripts/bootstrap-toolchain.sh`
- git commits `f52255a`, `324e635`, `c6c8887`, `415f10a`, `1b1e9d5`, `45f4ec2`/`c903352`

**Leaderboards and benchmarks**
- `LB` https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results/resolve/main/english_short_latest.csv
- `LB-hi` https://huggingface.co/datasets/hf-audio/multilingual_evals/resolve/main/multilingual_hi.csv
- `GS-Blog` https://huggingface.co/blog/open-asr-leaderboard-global-south (Monsoon hi is Devanagari-scored)
- `Vaani` https://benchmarklist.com/benchmarks/vaani_benchmark_v1/
- `HiACC` https://www.sciencedirect.com/science/article/pii/S2352340925006109
- `EOT` / `EOTHi` https://github.com/livekit/eot-bench · `TextEOT` https://arxiv.org/html/2608.08235
- `CASE` speaker-embedding robustness benchmark (single author) · `RomCoM` https://arxiv.org/html/2606.30790

**Models and runtimes**
- `QASRRep` https://arxiv.org/html/2601.21337v1 · https://huggingface.co/Qwen/Qwen3-ASR-1.7B · https://github.com/QwenLM/Qwen3-ASR
- `QCML` https://huggingface.co/FluidInference/qwen3-asr-0.6b-coreml (4.4% LS-clean, RTFx 2.8x)
- `MLXQ` https://github.com/moona3k/mlx-qwen3-asr (2.33% LS-clean, RTF 0.029)
- `QC` https://github.com/antirez/qwen-asr (MIT, pure C + Accelerate, streaming, **bf16 only**)
- `QGGUF` https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF (Q8_0 805 MB, BF16 1.51 GB) · https://huggingface.co/foryoung365/Qwen3-ASR-1.7B-Q4_K_M-GGUF · https://github.com/shershah1024/qwen3-asr-llamacpp
- `LCppBug` https://github.com/ggml-org/llama.cpp/issues/21847 (no content on longer Qwen3-ASR audio)
- `Srota` https://discuss.huggingface.co/t/open-source-hinglish-asr-fine-tuned-from-qwen3-asr-0-6b-15-85-wer-on-conversational-test/176416 · https://huggingface.co/moorlee/qwen3-asr-0.6b-hinglish
- `Bodhan` https://huggingface.co/bodhan-ai/indic-transcribe-flex · `BodhanCML` https://huggingface.co/sookie90/indic-transcribe-flex-coreml · licence https://github.com/Bodhan-AI/bodhan-model-info/blob/main/v1/Indic_Open_Model_License.md
- `Indic` https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual · `SraV` ARTPARK SraVaani-1.0
- `P3` https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 · `MacP` https://github.com/moona3k/macparakeet/tree/main/benchmarks/asr
- `FA-R` https://github.com/FluidInference/FluidAudio/releases (Qwen3 backend removed in 0.15.3) · `FA-B` https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md · `FA-NemoML` .../ASR/NemotronMultilingual.md
- `Nemo35CML` https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML
- `Canary2` https://huggingface.co/nvidia/canary-1b-v2 · `Gran41` https://huggingface.co/ibm-granite/granite-speech-4.1-2b · `Moon` https://github.com/moonshine-ai/moonshine-v2 · `SB` https://github.com/speechbrain/speechbrain
- `Smart` https://www.daily.co/blog/smart-turn-v3-2-handling-noisy-environments-and-short-responses/
- `Willison` VibeVoice-ASR Mac memory write-up

**Memory, Metal and Apple frameworks**
- `8GB` https://localllmsetup.com/blog/8gb-mac-local-ai-survival-guide
- `MLXWired` https://ml-explore.github.io/mlx/build/html/python/_autosummary/mlx.core.set_wired_limit.html — **"The default value is 0."** Wiring is opt-in
- `WSS` https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize · https://github.com/ivanopcode/devnote-override-macos-metal-vram-cap (~2/3 of RAM ≤36 GB, ~75% above; `iogpu.wired_limit_mb` default 0 = system default)
- ~~`Stencel`~~ — **dead link, removed.** The URL in the V2 draft 404s (the live page has an encoded space: `.../apple-silicon-limitations-with-usage-on-local-llm%20.html`). Its claim is replaced by `WSS`
- `IvanD` https://blog.ivan.digital/mlx-vs-coreml-on-apple-silicon-a-practical-guide-to-picking-the-right-backend-and-why-you-should-f77ddea7b27a
- `WWDC277` https://developer.apple.com/videos/play/wwdc2025/277/ · `SAGuide` https://developer.apple.com/documentation/Speech/bringing-advanced-speech-to-text-capabilities-to-your-app
- `SALoc` https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales · https://medium.com/@itsuki.enjoy/swift-speechtranscriber-support-multi-language-without-manual-locale-switching-b626b547bd74 (published locale list; `en_IN` present, no `hi_IN`)
- ~~`LTM172`~~ https://github.com/tomqwu/ListenToMe/issues/172 — **retained but downgraded: it does not support the claim.** It is a third-party app's feature request about that app hard-coding ~10 locales; it quotes no Apple locale list. Replaced by `SALoc`
- `FM` https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/supportedlanguages

**Toolchain**
- `FM` https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum (`.unavailable(.appleIntelligenceNotEnabled)`)
- `MLXSwift430` https://github.com/ml-explore/mlx-swift/pull/430 · https://github.com/ml-explore/mlx-swift
- `Std803174` https://developer.apple.com/forums/thread/803174 · `RunnerImg13080` https://github.com/actions/runner-images/issues/13080
- `LCppBuild` https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md · `ggml/src/ggml-metal/CMakeLists.txt` · build-xcframework.sh (`GGML_METAL_EMBED_LIBRARY=ON`)
- ~~`LCppMetal`~~ https://github.com/ggml-org/llama.cpp/discussions/2493 — **wrong citation, removed.** That thread is about locating `ggml-metal.metal` at runtime and never mentions the embed flag
- `CLTDoc` https://developer.apple.com/documentation/xcode/installing-the-command-line-tools · `TN2206` https://developer.apple.com/library/archive/technotes/tn2206/_index.html

---

## 8. Check notes — independent verification pass, 20 Sep 2026

A second agent re-checked every load-bearing claim against the cited source (or a better one) and against the repo. **Nothing in the report was fabricated**; the numbers are overwhelmingly exact. What follows is everything that changed. Corrections are marked in place at the point of use.

### Corrections that change a recommendation

**C1 — MLX does not wire memory by default. §3.0(ii) was wrong, and Stack 2's rejection loses a leg.**
V2 said MLX "holds weights in an unreclaimable wired residency set" and called this "the strongest argument against MLX for an always-on background app". The cited page says the opposite: *"The wired limit is the total size in bytes of memory that will be kept resident. **The default value is 0.**"* ([MLXWired]). Wiring is opt-in. `mlx-lm` opts in; an embedding app need not. What survives is the residency **ceiling** (`recommendedMaxWorkingSetSize` ≈ 2/3 of RAM up to 36 GB, ~75% above — ≈5.3–5.7 GB on an 8 GB Mac, [WSS]), which is a budget, not a confiscation. §3.0(ii) rewritten. Stack 2 is still not recommended, but on latency and the missing word confidence, not on memory. **The `[Stencel]` URL also 404s and has been dropped.**

**C2 — `antirez/qwen-asr` is BF16-only. This is now a fact, not an open risk, and it breaks Stack 1 as originally written.**
§6 risk 2 asked whether the C runtime supports 4-bit. It does not: BF16 weights, encoder converted to F32 in heap, measured peak RSS **~2.7–3.3 GB (0.6B)** and **~6.6–7.3 GB (1.7B)** ([QC]). V2's Stack 1 row said "Srota @4-bit … `antirez/qwen-asr` — no Xcode", which cannot both be true. The 0.6B peak alone exceeds §3.0's own 2.5 GB Hinglish ceiling on an 8 GB Mac.

**C3 — but the route V2 wanted does exist, via llama.cpp. Stack 1 survives and gets cheaper.**
Qwen3-ASR is first-class in llama.cpp: `ggml-org/Qwen3-ASR-0.6B-GGUF` ships **Q8_0 at 805 MB** and BF16 at 1.51 GB ([QGGUF]), run as `llama-mtmd-cli -m <model>.gguf --mmproj <mmproj>.gguf --audio x.wav`, with Q4_K_M community builds for 1.7B. With `GGML_METAL_EMBED_LIBRARY=ON` the Metal library is embedded instead of produced by `xcrun metal` ([LCppBuild]), so this is quantised **and** needs no Metal compiler — exactly the combination V2 thought it had to choose between. **llama.cpp is promoted to Stack 1's primary second-engine runtime; the C impl is demoted to a 16 GB fallback.** New risk logged: llama.cpp issue #21847, no content on longer Qwen3-ASR audio ([LCppBug]).

**C11 — Srota is mixed-script, never romanised, and this can decide §4.0 for you.**
Confirmed real: full-parameter fine-tune of `Qwen/Qwen3-ASR-0.6B`, Apache-2.0, safetensors downloadable, HiACC conversational 24.73% → 15.85%, plus OpenSLR-104 tutorial 50.66% → 35.06% ([Srota]). But its output is mixed **Devanagari + Latin** — the card's own example is *"मेरा favourite festival Diwali है"*. If your §4.0 script decision is **fully romanised**, Srota is disqualified and Bodhan Flex (selectable native/mixed/romanised) is the only candidate — i.e. the script decision, not the spike, picks Stack 3. Also: **no GGUF of Srota exists**; conversion is ours to do and to verify. V2's "single-source / one forum post" understated it slightly — there is a full model card — but it remains single-vendor with no independent eval.

**C13 — §5.2's install order has a real defect, and step 8 is not a rollback.**
Reading `Scripts/bootstrap-toolchain.sh:39-57` and the wrapper on disk: `$TC/usr/bin/swiftc` is a 148-byte script that `exec`s `/Library/Developer/CommandLineTools/usr/bin/swiftc`; `$TC/usr/lib/swift` is a *symlink* into the CLT (so it follows an upgrade), while `SWIFTPM_CUSTOM_LIBS_DIR` is a **physical copy** of the old CLT's `ManifestAPI`/`PluginAPI`. So the env vars break at **step 2** (CLT 26), not step 4 (Xcode) — V2 scheduled their removal at step 6. Added as **step 2a**. Worse, step 2 runs `sudo rm -rf /Library/Developer/CommandLineTools`, so step 8's "rollback" restores CLT **26**, not today's CLT 15.2, which is gone. Flagged in place.

### Corrections that tighten a claim without changing the plan

**C6** — "the Qwen3-ASR report calls Hindi out as its weakest language" is **not in the report**. Hindi sits in its long-tail group; the report notes only that performance degrades on the full 30-language setting. FLEURS hi 1.7B **17.15%** ✓, and 0.6B is **19.12%** (added) ([QASRRep]).

**C7** — Indi-RomCoM's ">98% for Qwen variants" overstates. Table 7: LLaMA-3.1-8B **99.7%**, Qwen2.5-1.5B **99.8%**, Qwen3-4B **98.8%**, but **Qwen3-14B 92.0%**; Airavata-7B **16.5%**, Sarvam-30B **26.1%** ([RomCoM]). The size trend runs the right way for the gate. Separately, RDR is measured on **instruction-following responses**, not ASR cleanup — applying it to our cleanup pass is a labelled extrapolation, and the 30-item adversarial set is what actually settles it.

**C8** — "unified memory runs ~400 GB/s" is wrong for every machine in scope. [8GB] says "up to 100 GB/s" on M2, and every 8 GB Mac is base-tier. The ~57x cliff is the source's own ratio and survives; the bandwidth figure did not.

**C9** — Monsoon's script QC is **annotator** QC during reference creation ("Annotator behaviour was monitored automatically throughout, flagging submissions containing characters outside the target script"), not a scoring-time gate on model submissions ([GS-Blog]). The Devanagari references alone carry the argument.

**C12** — the `phys_footprint` caveat is at `DECISIONS.md:332-334`, not `:368-374`.

**Citation fixes.** `[LCppMetal]` (llama.cpp discussion 2493) never mentions `GGML_METAL_EMBED_LIBRARY` — it is about locating `ggml-metal.metal` at runtime; replaced by `[LCppBuild]`. `[LTM172]` does not establish the `supportedLocales` claim — it is a third-party app's feature request about that app hard-coding ~10 locales; replaced by `[SALoc]`, which does (published list has `en_IN`, no `hi_IN`). `[QCML]`'s 4.4% does **not** say whether it is the Float32 or the Int8 variant; we ran int8, so the comparison may still flatter what we loaded — marked unverified.

### Still unverified after this pass

- Whether **CLT 26 alone** ships `FoundationModels.framework` (step 2b is the test, not a formality). No installed SDK here has it: all 8 SDKs under `/Library/Developer/CommandLineTools/SDKs/` return zero matches.
- **Xcode 26's exact download/expanded size** — unchanged from §6.11; Apple publishes none.
- **Moonshine v2's 123M/245M sizes and 148/258 ms M3 latencies** — not on the cited repo, which lists Tiny 26M and Medium 200M and no Apple-silicon figures. Verdict ("no Hindi") is unaffected and the language list was confirmed verbatim.
- **Srota → GGUF conversion**, and whether the audio encoder survives it.
- Everything §6 already lists.

### Confirmed exactly as written (spot-check record)

All English leaderboard averages (Qwen 0.6B 5.045 / 1.7B 4.31125, Parakeet v3 4.85875 / v2 4.7025, Whisper large-v3 5.78 / turbo 6.3575, Canary-1b-v2 5.70625, Canary-Qwen 4.4275, Granite 4.1-2b 4.615, Nemotron 3.5 7.8775) and their en-IN/Monsoon columns; all Monsoon hi-IN figures (IndicConformer 8.47, SraVaani 11.21, Qwen 1.7B 12.25, Nemotron 13.85, Qwen 0.6B 18.13, Voxtral 22.9/23.2/24.73, Whisper 28.17/40.79, VibeVoice 39.21); all Vaani figures (SraVaani 10.9 #1, Shrutam-2 17.4, Qwen 0.6B 20.6 #6, Gemma-4-12B 24.6, omniASR 25.6, Whisper large-v3 26.8 and last of 11); Parakeet v3's 25 European languages with no Hindi; Canary-1b-v2's identical 25; Granite Speech 4.1's "English, French, German, Spanish, Portuguese, Japanese"; Moonshine v2's eight languages; FluidAudio 0.15.3's *"chore(asr): remove experimental Qwen3 ASR backend"*; the FluidInference card's 4.4% / RTFx 2.8x against PyTorch 2.11%; every Bodhan Flex number; Srota's headline numbers and licence; `.unavailable(.appleIntelligenceNotEnabled)` for FoundationModels; and the machine facts (CLT at `/Library/Developer/CommandLineTools`, SDK 15.2, no `metal` binary, `xcodebuild` refusing on a CLT instance, Mac14,9, 16 GB, macOS 26.6.2, ~24 GB free).

**Repo evidence for §1 re-read and confirmed**: the prompt asymmetry is real — only the `.qwen` arm passes `prompt` (`RefinementBenchmarkCorpusTests.swift:303,316-318`), and `GateRecallCorpusTests.swift:67-85` does seed "Kothary", "Mumbles", "Fridge", "Rupees" as sound-alike distractors. The 1-better/7-worse split with 12 ties, line 05's WER 1.200, the n=2 completed refinements behind "strictly harmful", the noisy-suite collapse (0.229 vs 0.022), the 2249 ms debug p50, and Qwen being equal-or-worse in 10 of 11 classes (the exception being `number words`, 0.044 vs 0.045) are all as stated. `Qwen3Weights.swift` confirms the tested artifact is `qwen3-asr-0.6b/int8` from `FluidInference/qwen3-asr-0.6b-coreml`, and `IndicASRBackend.swift:15-17` confirms the `indic-conformer-600m` slot already exists. **§1's verdict stands unchanged.**
