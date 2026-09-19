# VoicePlus: local model research, V1

*20 Sep 2026. Written for the owner. Covers speech recognition (ASR), streaming preview, end-of-utterance (EOU) detection, speaker embedding and diarization, and post-dictation cleanup. Local models only, on the owner's Mac: Apple M2 Pro, 16 GB, macOS 26.*

**How to read this.**
- Every number carries a short source key in brackets, for example "4.86 ([LB])". The key is a link, and §7 lists all of them.
- **est.** marks my own estimate, and the working is shown next to it.
- **vendor** means the model's maker measured the number.
- **Current** marks what VoicePlus ships today.
- Nothing here was run on the owner's Mac. The owner-measured numbers come from `DECISIONS.md`.

---

## 1. Summary

**Keep Parakeet on FluidAudio/CoreML as the engine.** Several open models now score better than Parakeet on the live English leaderboard (Qwen3-ASR-1.7B 4.31, ARK-ASR-0.6B 4.56, v2 4.70, v3 4.86 ([LB])). But almost all of those that beat v2 are autoregressive (LLM or encoder–decoder) models of 1–5B parameters. The only one with a CoreML port in the pinned FluidAudio is Cohere Transcribe, which peaked at ~11.6 GB on a Mac ([MacP]). The non-autoregressive Granite Speech 4.1 2B-NAR (4.68 ([LB])) has no Mac port that I found. The one the owner tested, Qwen3-ASR 0.6B, lost on owner audio (WER 0.178 vs 0.099 ([R5.4])). The gains available now are cheap changes around Parakeet, plus two layers the app does not have yet:
1. **English final pass.** Run an A/B of Parakeet **v2** and **Parakeet Unified** against v3. v3's extra languages are all European, and v2 beats it on every independent English number found, for example the live leaderboard average of 4.70 vs 4.86 ([LB]).
2. **Preview.** Move EOU 120M from the 160 ms tier to the 320 ms tier: on FluidAudio's own test, WER falls from 8.23% to 4.88% ([FA-B]). Also trial Unified's 320 ms stream, which the CoreML card reports at 2.37% on a 150-file LibriSpeech subset ([UniCML]).
3. **Latch mode.** Add **Smart Turn v3.2** (BSD-2, 8 MB, covers Hindi ([Smart])) on top of Silero, instead of the fixed 1.2 s silence rule ([EP]).
4. **Cleanup** (new layer): rules, then NeMo inverse text normalization (ITN), then **Superwhisper S1-mini**, called only when needed and run through a llama.cpp binary. The ITN engine is already linked through FluidAudio 0.15.6 ([Resolved]). **Qwen3.5-2B** handles Hinglish and style requests.
5. **Speaker.** Keep WeSpeaker. The gate's real failure mode is TV and playback audio (EER 0.58% clean vs 8.57% on playback ([CASE])), and changing the model will not fix it. For meetings, move to FluidAudio's offline diarizer. Today's meeting labels come from VoicePlus's own greedy clustering of WeSpeaker embeddings, which has never been measured ([Diar]).
6. **Hindi/Hinglish** (new layer): nothing in today's stack transcribes Hindi. Run a bake-off of IndicConformer, Qwen3-ASR-1.7B and Nemotron 3.5 on the owner's own Hinglish before porting any of them. Bodhan Flex (mixed-script output, with a community CoreML port) is a fourth candidate, but its licence has to be checked first ([Muesli], [Bodhan]).

**Benchmark these three first:**
- **(a)** English final and preview A/B. Every arm is already in the pinned FluidAudio 0.15.6 ([Resolved]).
- **(b)** Cleanup bake-off: rules vs S1-mini vs Qwen3.5-2B, including an adversarial set.
- **(c)** Record 60–100 Hinglish dictations and score the three Hindi candidates in their reference runtimes.

---

## 2. What VoicePlus needs from models

| Need | Today | What it implies for models |
|---|---|---|
| Push-to-talk dictation | Key-down to first buffer < 150 ms. Final text within ~1 s of release. Final pass budget: p50 ≤ 700 ms, p95 ≤ 1200 ms. Preview first word ≤ 300 ms (V3 §10.2). | The final pass should be a fast transducer on the Neural Engine (ANE). Any LLM cleanup has to be called only when needed, or it eats the 1 s. |
| Hands-free "latch" mode | `Endpointer` commits after 1.2 s of trailing silence ([EP]). | The expensive error is a cut in the middle of a clause, not slowness. |
| Meetings | 3–5 s chunks per channel. Mic chunks are labelled "You" when their WeSpeaker embedding matches the enrolled one at cosine ≥ 0.6. System-audio chunks are grouped by VoicePlus's own greedy cosine clustering (threshold 0.7). FluidAudio's `DiarizerManager` is used only to extract the embeddings, not to diarize ([Diar]). | Needs long-form accuracy plus offline diarization. |
| Post-dictation cleanup | Deterministic rules. No on-device LLM. The only default models are cloud ones ([Pend]). Refined-pass budget: p95 ≤ 1500 ms. Pipeline budget: ≤ 250 ms. | Needs a small local model with a strict guard. Cleanup needs its own budget line; I propose p95 ≤ 500 ms. |
| Memory | 16 GB, shared with the owner's apps. No numeric budget. | **Proposal:** at most 1.5 GB resident for the default dictation stack, and at most 4 GB with opt-in modes (Hinglish, style LLM) loaded. |
| Languages | Indian-accented English. Hindi/Hinglish possible. | Parakeet v3 has no Hindi ([P3]). The output script (Devanagari, Roman or mixed) is a product decision. |
| Licences | — | MIT, Apache and BSD are fine. CC-BY needs attribution. NVIDIA Open Model License and OpenMDW allow commercial use but are custom licences. Flag NC, GPL/AGPL, revenue caps and "framework-only" terms. |
| Pipeline contract | Stages keep confidence, audio range and provenance. `SpanRewriter` never rewrites low-confidence spans. | A model without word confidence (Qwen3-ASR, every LLM) needs a wrapper that carries spans through unchanged. |
| **Toolchain** (checked on this Mac) | Command Line Tools only: Swift 6.0.3, **macOS 15.2 SDK**, no Xcode. | **CoreML through FluidAudio** is easiest. **Prebuilt XCFramework binary targets** should work: FluidAudio 0.15.6 already pulls one (`NemoTextProcessing.xcframework`) and builds here ([Resolved]), and llama.cpp publishes a `llama-<build>-xcframework.zip` with every release ([LCppRel]). ONNX Runtime and llama.cpp have not been built here. Building the llama.cpp XCFramework locally would need Xcode ([LCppXC]). **MLX-Swift is blocked**, because SwiftPM on the command line cannot build its Metal shaders ([MLXSwift]). The fix PR is still open, and the maintainer would rather wait for native support in Swift 6.4 toolchains ([MLXSwift430]). **Apple SpeechAnalyzer and FoundationModels are blocked** until a CLT with the macOS 26 SDK is installed, which needs admin rights. |

---

## 3. Findings by category

### 3.0 Three traps that apply to every table

1. **There are two leaderboard versions.** Model cards quote the old Open ASR Leaderboard: Parakeet v3 6.34, Cohere 5.42, Canary-Qwen 5.63 ([P3], [Cohere], [CanQwen]). The live board (CSV modified 14 Sep 2026) cleaned its test sets and replaced TED-LIUM with Voice Arena Monsoon (Indian English), so its averages run lower by between 0.75 points (Cohere, 5.42 → 4.67) and 1.5 points (v3, 6.34 → 4.86) ([LB]). This report uses only live-board numbers unless it says otherwise.
2. **RTFx is not Mac latency.** Leaderboard RTFx is batched throughput on a datacenter GPU. For single streams on a Mac:
   - Parakeet runs at ~81–93x and WhisperKit turbo at ~14x on an M4 Pro ([MacP]).
   - The owner's own `phys_footprint` excludes memory-mapped weights, so "90 MB" understates real residency ([R5.4]).
3. **Hindi scores don't reveal output script.** The public Hindi track is code-mixed conversational speech from 468 speakers ([GS]). It is scored with OIWER against a lattice of written forms: variants are taken from several ASR transcripts, and linguists keep the ones that fit the audio, such as alternative spellings of English-origin words and joined vs split compounds ([GS]). So a good score does not tell you how a model writes English words inside Hindi speech. The blog does not say whether fully romanized Hindi is accepted, so treat "a romanizing model scores well" as **unverified**.

### 3.1 ASR: final pass

"Indian English" is the Voice Arena Monsoon en-IN column, and "Hindi" is Monsoon Hindi OIWER. Lower is better in both.

| Model | Size | Licence | Open ASR avg (live) | Indian English | Hindi | Speed on Mac | Mac runtime here | Languages | Fit |
|---|---|---|---|---|---|---|---|---|---|
| **Current: Parakeet TDT 0.6B v3** | 0.6B, 483 MB ([Catalog]) | CC-BY-4.0 | 4.86 ([LB]) | 4.14 ([LB]) | none | Owner: p50/p95 121/130 ms ([R5.4]). ~81x, 0.38 s cold start, M4 Pro ([MacP]) | FluidAudio CoreML (in use) | 25 European ([P3]) | Baseline |
| Parakeet TDT 0.6B v2 | 0.6B, ~465 MB ([MacP]) | CC-BY-4.0 ([P2]) | **4.70** ([LB]) | **3.89** ([LB]) | none | ~90x, 0.55 s cold, M4 Pro. Mac LibriSpeech macro WER 2.57% vs v3 3.22% ([MacP]) | FluidAudio CoreML | English | **Test now.** Drop-in |
| Parakeet Unified EN 0.6B | 0.6B, ~565 MB ([MacP]) | NVIDIA Open Model License ([Uni]). The FluidInference CoreML card says CC-BY-4.0, but the upstream terms govern ([UniCML]) | Not listed. Card: 5.91, old board ([Uni]) | — | none | ~93x, 0.93 s cold. Mac LibriSpeech macro WER **2.38%** ([MacP]) | FluidAudio CoreML, in pinned 0.15.6. CTC-spotter vocabulary boosting since 0.15.6 ([FA-R]) | English | **Test now.** One model for preview and final |
| Qwen3-ASR 1.7B | ~2B, ~1.8 GB at 8-bit (est. from params) | Apache-2.0 | **4.31**, best open ([LB]) | 3.50 ([LB]) | 12.25 ([LB-hi]) | 0.73 s per 10 s clip, fp16, M4 Pro ([MLXQ]). M2 Pro unmeasured | MLX (blocked here). VoicePlus's CoreML port (vendored from FluidAudio 0.15.1 via Muesli) is 0.6B only, and FluidAudio removed its Qwen3-ASR backend in 0.15.3 ([FA-R]) | 30 incl. Hindi, plus 22 Chinese dialects ([QASR17]) | **Test for Hinglish only** |
| Qwen3-ASR 0.6B (already tested) | 0.78B. Peak 1.9 GB ([R5.4]) | Apache-2.0 | 5.05 ([LB]) | 4.23 ([LB]) | 18.13 ([LB-hi]) | Owner, CoreML port: p50/p95 2249/3792 ms ([R5.4]) | CoreML port in repo | as above | **No.** Lost 0.178 vs 0.099 ([R5.4]) |
| AI4Bharat IndicConformer 600M | 0.6B, ~2.4 GB ([CSR]) | MIT. Gated on HF (accept terms) ([Indic]) | — | — | **8.47**, best open ([LB-hi]) | No Mac numbers. Leaderboard RTFx only 7.68 ([LB-hi]) | ONNX and NeMo. Community sherpa-onnx ports ([IndicSherpa]). No CoreML | 22 Indian languages. Needs a language code. Native-script (Devanagari) output is assumed from its training data; the card does not state it (**unverified**) ([Indic]) | **Hindi bake-off** |
| ARTPARK SraVaani-1.0 | 0.43B, ~900 MB FP16 ([SraV]) | MIT. Gated on HF ([SraV]) | Not listed (own English sets: 14.8 ([SraV])) | — | 11.21 ([LB-hi]) | No Mac numbers | PyTorch (`trust_remote_code`). ONNX export offered via an external link. Same FastConformer TDT-CTC family that FluidAudio converts | 65 Indian languages and English | **Hindi bake-off** (released Aug 2026, unproven) |
| NVIDIA Nemotron 3.5 ASR Streaming 0.6B | 0.64B, ~650 MB int8 ([Nemo35Sherpa]) | OpenMDW-1.1 | 7.88 ([LB]) | 7.30 ([LB]) | 13.85 ([LB-hi]) | English FLEURS RTFx 40–73x on M2 ([FA-NemoML]). Hindi untested on Mac | FluidAudio CoreML ([Nemo35CML]) | 40 locales incl. hi-IN ([Nemo35]) | Hindi **preview** (§3.2) |
| Trelis Whisper-Hinglish-Preview | 1.55B, ~3 GB fp16 | Apache-2.0 | Not listed | — | Not listed. Vendor: Hinglish CoSHE 13.67 ([Trelis]) | Unmeasured. Large-v3 class is slow (turbo alone ~14x on M4 Pro ([MacP])) | WhisperKit, whisper.cpp | hi and en, **mixed-script output** | Only if mixed script matters |
| Cohere Transcribe 2B | 2B, 2.3 GB q8 ([MacP]) | Apache-2.0, gated | 4.67 ([LB]) | **3.44**, second-best open after ARK-ASR-0.6B's 3.43 ([LB]) | none | ~11x, **73 s cold start, ~11.6 GB peak RSS**, M4 Pro ([MacP]) | FluidAudio CoreML ([FA-Cohere]) | 14, no Hindi | **No.** Memory |
| IBM Granite Speech 4.1 2B | 2B, ~4 GB bf16 (est.) | Apache-2.0 | 4.62 ([LB]) | 4.12 ([LB]) | none | No Mac numbers | mlx-audio, llama.cpp GGUF ([Gran41]) | 6, no Hindi | Later (keyword biasing) |
| IBM Granite Speech 5.0 470M TurboCTC | 0.47B | Apache-2.0. The `-nc` sibling is CC-BY-NC-SA | 5.04 ([LB]) | 4.76 ([LB]) | none | No Mac numbers | None published | English | No. Worse than v2. Punctuation undocumented ([Gran50]) |
| NVIDIA Canary-Qwen 2.5B | 2.5B | CC-BY-4.0 | 4.43 ([LB]) | 3.60 ([LB]) | none | No Mac numbers | NeMo only | English ([CanQwen]) | No. No Mac runtime |
| Whisper large-v3 / v3-turbo | 1.55B / 0.81B. Turbo 632 MB ([MacP]) | MIT | 5.78 / 6.36 ([LB]) | turbo 4.77 ([LB]) | 28.17 / 40.79 ([LB-hi]) | Turbo ~14x, 2.29 s cold, M4 Pro ([MacP]) | WhisperKit, whisper.cpp | 99 | No. Poor Hindi and ~6x slower than Parakeet |
| Apple SpeechTranscriber | System asset | OS framework | Not listed. 14.0% vs Parakeet v2 11.7% on an earnings22 subset (competitor-run ([ArgmaxApple])) | — | Unconfirmed ([LTM172]) | ~70x, M4 Mac mini ([ArgmaxApple]) | Needs the macOS 26 SDK (not on this Mac) | ~10 at launch | Later. Zero-download fallback |
| Microsoft VibeVoice-ASR 7B | 7B. 5.71 GB at 4-bit MLX ([Willison]) | MIT ([VV]) | 5.58 ([LB]) | — | 39.21 ([LB-hi]) | 1 h of audio in 525 s, but **30.44 GB peak** as the tool reported it (Activity Monitor showed 61.5 GB during prefill), on a 128 GB M5 Max ([Willison]) | mlx-audio (blocked here) | 50+ | **No.** Memory |
| Mistral Voxtral Mini 3B | 3B | Apache-2.0 | 5.54 ([LB]) | — | 22.9 ([LB-hi]) | No Mac numbers | MLX or GGUF (community) | 8 incl. Hindi ([Voxtral]) | No |

Considered and not shortlisted:
- Moonshine v2: English only; covered under streaming.
- Kyutai STT: no Hindi, MLX only.
- Phi-4-multimodal: 5.6B, no Hindi audio.
- SenseVoice: focused on zh/en/ja/ko.
- MOSS-Transcribe-Diarize 0.9B: live-board average 4.64 ([LB]); worth a later look for meetings, Hindi not stated.
- Parakeet 1.1B: the open TDT-1.1B outputs lowercase with no punctuation.
- AutoArk ARK-ASR-0.6B: Apache-2.0, 1.15B in total (Whisper encoder plus Qwen2 decoder), 19 languages, no Hindi. Live average **4.56**, beating v2, and en-IN **3.43**, the best open score ([LB]). It is autoregressive, and I found no Mac port (not searched exhaustively). Worth a later look if an MLX or CoreML port appears.
- bosonai higgs-audio-v3-stt (2.7B, English, 4.39) and HojoAI Hojo-ASR-V1 (5.2B, zh/en, 4.33) ([LB]): too big and autoregressive for a 1 s release→text budget.
- Bodhan Indic Transcribe Core / Flex (Hindi route only): fine-tunes of Canary-1B-v2 for 25–27 Indic languages plus English, released Aug 2026. Flex writes mixed script (Indic words in native script, English words in Latin). Muesli ships both, and community CoreML encoder conversions exist, but Muesli's decoder runs on MLX-Swift, which is blocked here ([Muesli]). Gated, and under a custom "indic-open-model-license-v1" whose terms I have not checked. Not on the Monsoon Hindi board ([Bodhan]).

**Verdict.**
- **English:** Parakeet stays.
  - v2 and Unified are the only upgrades that are both better on independent English numbers and already runnable in the pinned FluidAudio.
  - Vocabulary boosting: VoicePlus's own `BiasRescorer` left entity recall at 31.6% with biasing on or off ([Bias]). FluidAudio's boosting is different. A separate Parakeet CTC 110M keyword spotter rescores the decoded text and can replace words. It is available for TDT (vendor: 85.2% vocabulary recall on Earnings22 with v2 ([FA-B])) and, since 0.15.6, for Unified, where it rescores about every 15 s in streaming ([FA-R]). It is **not** decode-time biasing, and it is not unique to Unified. True decode-time biasing arrived only for Nemotron, in FluidAudio 0.15.7, which is not pinned ([FA-R]).
- **Hindi:** the ranking on real Indian code-mixed speech is IndicConformer (8.47), SraVaani (11.21), Qwen3-ASR-1.7B (12.25), then Nemotron 3.5 (13.85) ([LB-hi]).
  - Of these four, only Nemotron 3.5 has a ready CoreML port.
  - Qwen3-ASR-1.7B is the only one that is also top-tier in English, but it is an autoregressive decoder, so latency grows with output length.
- **Ruled out on memory:** Cohere and VibeVoice. **Ruled out on Hindi and speed:** Whisper.
- The Qwen3-ASR 0.6B result stands. Its board average (5.05) was already behind v3 (4.86), and on Hindi it scores 18.13 ([LB], [LB-hi]).

### 3.2 Streaming: the preview while the key is held, and latch segmentation

**First, a point about the budget.** "First word" is measured from speech onset ([PRT]). A model can only emit a word after it has heard most of it, so part of any first-word figure is the length of the word itself.

Both measured candidates miss the 300 ms budget by more than 400 ms ([R1.5]). No model below has a Mac-measured first partial that would change that picture, except Apple's, which is not buildable here. Expect a model swap to fix **accuracy**, not the 300 ms target. Consider redefining the budget (for example, "time from the end of the first word") or relaxing it.

| Model | Size | Licence | Accuracy | First partial / speed on Mac | Runtime | Languages | Fit |
|---|---|---|---|---|---|---|---|
| **Current: Parakeet Realtime EOU 120M, 160 ms tier** | 120M, 224 MB ([Catalog]) | NVIDIA Open Model License ([NVOML]) | Owner preview WER **0.268** ([R1.5]). LS-clean 8.23% on FluidAudio CoreML ([FA-B]) | Owner first word p50/p95 712/1210 ms after onset ([R1.5]). RTFx 5.78x on M2 ([FA-B]) | FluidAudio `.ms160` ([MM] line 186) | English, no punctuation | Change tier |
| Same model, 320 ms tier | Separate `320ms` folder in the same HF repo, ~224 MB of required files (est., same layout as 160 ms) ([EOUCML]) | same | LS-clean **4.88%** ([FA-B]) | +160 ms per chunk. RTFx 19.25x on M2 ([FA-B]) | FluidAudio `.ms320` | same | **Test now.** Small change: a new catalog entry and download, plus `.ms320` |
| TDT v3 polled every 1 s (R1.5 arm B) | Nothing extra | CC-BY-4.0 | Owner preview WER **0.118** ([R1.5]) | Owner 807/1989 ms ([R1.5]). A 0.4 s interval is not measured | Already built | 25 European | **Test** at a 0.4 s interval |
| Parakeet Unified EN 0.6B, 320 ms | ~590 MB int8 per streaming tier ([UniCML]) | NVIDIA Open Model License | LS-clean **2.37%** at 320 ms, aggregate WER on a 150-file subset ([UniCML]). Vendor avg 6.92 at 0.32 s ([Uni]) | RTFx ~10x at 320 ms ([UniCML]). The 320 ms includes 160 ms of look-ahead. FluidAudio's default tier is 2.08 s ([FA-M]) | FluidAudio `StreamingUnifiedAsrManager`, `.parakeetUnified320ms` in 0.15.6 | English, punctuation and caps | **Test now** |
| Nemotron Speech Streaming EN 0.6B | ~600–630 MB per tier ([FA-Nemo]) | NVIDIA Open Model License ([NemoEN]) | Live board 5.25, en-IN 4.44 ([LB]). LS-clean 2.71% at 560 ms on CoreML ([FA-B]) | At least 560 ms, because the CoreML tiers start at 560 ms ([FA-Nemo]). RTFx 40.7x, Apple Silicon, chip not stated ([FA-B]) | FluidAudio | English, punctuation and caps | Latch-mode option |
| Nemotron 3.5 ASR Streaming 0.6B | ~650 MB int8. CoreML repo is 5.1 GB across all tiers ([Nemo35CML]) | OpenMDW-1.1 | Hindi **13.85**, best open streaming model ([LB-hi]). English 7.88 ([LB]) | At least 560 ms. The card advises the 2 s tier for full vocabulary ([Nemo35CML]) | FluidAudio. NeMo-Speech.cpp offers the true 80–320 ms modes, but has no Mac numbers ([NemoCpp]) | 40 locales incl. hi-IN | **Hindi preview only** |
| Moonshine v2 Small / Medium | 123M / 245M | MIT | Vendor Open ASR 7.84 / 6.65. Not on the live board ([Moon]) | Vendor response 148 / 258 ms on M3 ([Moon]) | ONNX Runtime on CPU, plus a Swift package ([MoonGH]) | English and 7 others, no Hindi | CPU fallback if the ANE is contended |
| Apple SpeechTranscriber (volatile results) | System | OS | LS-clean 1.98%, but on only 607 reference words, by an author whose product ships Apple's recogniser ([DevApple]) | Final text a median 125–132 ms after speech ends, M5 Max ([DevApple]). Volatile text flickers | Needs the macOS 26 SDK | No Hindi reported ([LTM172]) | Control arm later |
| Voxtral Mini 4B Realtime | 3.13 GB at 4-bit. Resident memory 2.7 → 4.2 GB over 60 min ([VoxRTSwift]) | Apache-2.0 | 6.46, en-IN 8.86 ([LB]). Hindi 24.73 ([LB-hi]) | 66 ms per step ([VoxRTSwift]) | MLX (blocked) | 13 incl. Hindi | No |
| Kyutai STT 1B (en/fr) | 2.36 GB MLX bf16 ([Kyutai]) | CC-BY-4.0 | Not on the board | Fixed 0.5 s delay ([KyutaiSTT]) | MLX (blocked) | en, fr | No |
| Qwen3-ASR streaming mode | as §3.1 | Apache-2.0 | 1.7B chunked: 10.45% vs 5.90% in batch ([MSFT]). Community MLX port, vendor figures: 11.4% streaming vs 9.5% offline ([MLXQ]) | At least 2 s to first text (2 s chunks) ([QASRRep]) | Official streaming needs vLLM (not on a Mac) ([QASR17]). mlx-qwen3-asr streams on a Mac (MLX, blocked here) ([MLXQ]) | 52 | No |
| WhisperKit open-source streaming (turbo) | ~0.6 GB | MIT. The optimized streaming is in the paid Pro SDK ([ArgmaxPro]) | Hindi 40.79 ([LB-hi]) | Interim 0.94 s, confirmed 2.51 s, M2 Ultra, vendor ([OpenBench]) | CoreML | 99 | No |
| Vosk / sherpa-onnx Zipformer | 40 MB – 1.8 GB | Apache. Some sherpa models are CC-BY-NC or CC-BY-SA | Vendor: Vosk hi 14.85 on Common Voice ([Vosk]) | CPU | C / ONNX | Includes hi (Vosk) | No. A generation behind |
| VibeVoice-ASR-Streaming 1.5B / 7B | Multi-GB | MIT | No Hindi | CUDA only ([VV]) | None on Mac | 10 | No |

**Verdict.**
1. **Move to the 320 ms tier first.** Per FluidAudio's own benchmark it cuts the preview model's error by about 40% (8.23% → 4.88%) for +160 ms ([FA-B]).
2. **Then test Unified at 320 ms.** It gives near-final accuracy with punctuation. Its offline path could also replace TDT, one model family for both jobs.
   - None of Unified, Nemotron EN or Nemotron 3.5 has an EOU token, so keep Silero plus Smart Turn for end-of-utterance.
3. **Nemotron EN's 560 ms floor** is fine for latch segments but slow for a push-to-talk preview.
4. **Hindi:** Nemotron 3.5 is the only credible live preview.
5. **Plan the UI for the jump from preview to final.** Transducer previews are append-only, so they never flicker. Apple's, Moonshine's and Whisper's previews do revise.

### 3.3 End-of-utterance and turn detection

**Dictation is not a voice agent.** In push-to-talk, key-up is the end, so no turn model is needed. The VAD only trims silence and rejects empty takes. In latch mode, a cut at a finished clause costs almost nothing because the next segment is appended. A cut mid-clause ("I think that | we should") is the error to minimise.

**Evidence caveat.** The only shared multilingual benchmark, eot-bench, is run by LiveKit, whose own models top it ([EOT]).

| Model | Size | Licence | Evidence | Latency on Mac | Runtime | Languages | Fit |
|---|---|---|---|---|---|---|---|
| **Current: Silero VAD v6.2** | ~2 MB | MIT ([Silero]) | Vendor ROC-AUC 0.97 ([SileroQ]). Silence-only false cut-offs on eot-bench: **55.6% at a 300 ms wait, 21.7% at 600 ms** ([EOT]) | 1077.9x real time on M1. FluidAudio reports in 256 ms windows ([FA-B]) | FluidAudio CoreML | Any | Keep as the base signal |
| **Current: Parakeet EOU token** | Inside EOU 120M | NVIDIA Open Model License | Vendor EOU latency p50 160 / p95 320 ms, measured on TTS audio with 3 s of silence appended ([EOU]) | FluidAudio waits `eouDebounceMs` = 1280 ms by default ([FA-Stream]) | FluidAudio | English | Keep as a third signal |
| **Current: `Endpointer` rule** | — | — | Fixed 1.2 s trailing silence ([EP]) | 1.2 s | Swift | Any | Replace with the rule below |
| Pipecat **Smart Turn v3.2** | 8M params. 8 MB int8 ONNX / 16.8 MB CoreML ([SoniqoTurn]) | **BSD-2** ([Smart]) | eot-bench, English: 35.2% / 14.8% false cut-offs at 300 / 600 ms, vs 55.6% / 21.7% for silence-only ([EOT]). Hindi (952 spans): 42.6% / 6.5% vs 49.5% / 7.4% ([EOTHi]). Vendor Hindi accuracy 93.44%, measured on v3.0, not v3.2 ([SmartDaily]) | 3.5 ms per 8 s window, CoreML, M5 Pro ([SoniqoTurn]) | ONNX Runtime, or the Soniqo CoreML export. That export ships inside Soniqo's `SpeechVAD` framework, not as its own package, and the framework's licence is **unverified**. Alternative: convert the BSD-2 weights yourself ([SoniqoTurn]) | 23 incl. Hindi and Marathi ([SmartCard]) | **Add for latch mode** |
| VideoSDK Namo Turn Detector v1 | ~135 MB (EN) / ~295 MB (multilingual) | Apache-2.0 | Vendor only: EN 90.86%, Hindi 93.98% ([Namo]) | Vendor: under 19 / 29 ms | ONNX | 23 incl. Hindi | Optional text veto. Must beat a stop-word rule list |
| FireRedVAD | 588K params, 2.2 MB | Apache-2.0 | Vendor: F1 97.57% and false-alarm rate 2.69%, vs Silero 95.95% / 9.41% ([FireVAD]) | No Mac runtime | PyTorch / NCNN | 100+ | Watch |
| TEN VAD | 731 KB | Apache with an **anti-competition clause** ([TENVAD]) | Silero's own comparison: 0.93 vs 0.97 ([SileroQ]) | Vendor RTF 0.016 on M1 | C library | Any | No (licence) |
| WebRTC VAD | Tens of KB | BSD | F1 52.30%, miss rate 64.15% ([FireVAD]) | Microseconds | C | Any | No |
| LiveKit turn detector | ~281 MB | **LiveKit Model License: no standalone use** ([LKLicense]) | Leads eot-bench ([EOT]) | — | ONNX | 14 incl. Hindi | **No** (licence) |
| Turnsense | 135M | Apache-2.0 | Vendor 97.5% on its own 2,000-sample set ([Turnsense]) | — | ONNX | English | No |
| Streaming Sortformer v2.1 | 117M | NVIDIA Open Model License | Not an EOU model. Minimum latency 1.04 s ([Sortf]) | FluidAudio | CoreML | Mostly English | Only as speaker-aware VAD (§3.4) |
| TEN Turn Detection / ultraVAD | 8B | Restricted / — | — | — | — | — | No (size) |

**Verdict.** Test this commit rule in latch mode:

> commit when **(silence ≥ T_short ≈ 400–600 ms AND Smart Turn p ≥ θ AND no text veto) OR silence ≥ T_long ≈ 1.5–2.5 s**

- The streaming preview stays on screen, so a late commit costs little.
- In Hindi, eot-bench found only a small gain from Smart Turn: 6.5% vs 7.4% false cut-offs at 600 ms, and 639 vs 700 ms mean delay at a 5% cut-off budget, on 952 spans ([EOTHi]). So lean mostly on timing there.
- A 2026 study found that adding text made end-of-turn detection worse, while prosody helped ([TextEOT]). That supports audio first, with text used only as a veto.

### 3.4 Speaker embedding (the latch "only my voice" gate) and diarization (meetings)

**Embeddings**

| Model | Size | Licence | Accuracy (EER, lower is better) | Speed | Runtime | Fit |
|---|---|---|---|---|---|---|
| **Current: WeSpeaker ResNet34-LM (`wespeaker_v2`)** | ~6.7M. 8.0 MB CoreML plus 5.8 MB segmentation ([DiarCML]) | CC-BY-4.0 weights ([WeSpkPre]) | Vox1-O 0.723% ([WeSpkPaper]). Single-author CASE benchmark: **0.58% clean, 3.01% degraded, 8.57% on playback** ([CASE]). Most robust of the 5 third-party models tested; the author's own model degraded slightly less. Whether CASE used the LM variant is not stated | Full FluidAudio pipeline runs at 323x on M5 Pro ([FA-B]) | FluidAudio CoreML/ANE | **Keep.** Recalibrate the 0.6 threshold ([Gate]) |
| CAM++ | 7.18M. 14.8 MB CoreML ([CAMCML]) | CoreML repo licence is "other" (FunASR). **The CoreML build is the Mandarin model** | Vox1-O 0.654% (English WeSpeaker checkpoint ([WeSpkPre])) | CPU RTF 0.013, ~2.5x cheaper than ResNet34 ([CAMpp]) | FluidAudio 0.15.6 beta `CampPlusEmbedder`. May not run on the ANE ([FACAM]) | Cheap A/B. Also convert the English ONNX ([SherpaSpk]) |
| ReDimNet2 B2 / B3 | 3.6M / 4.1M | MIT code. VoxCeleb2-only weights are CC-BY-4.0; **VoxBlink2 weights are NC-SA** | Vox1-O 0.57% / 0.42% ([ReDim2Paper]) | 0.95 / 2.70 GMACs ([ReDim2Paper]) | PyTorch only. Needs a conversion spike ([ReDim2]) | Later challenger |
| WeSpeaker ResNet293-LM | 28.6M. 114 MB ONNX ([SherpaSpk]) | CC-BY-4.0 | Vox1-O 0.447% ([WeSpkPaper]) | ~4x ResNet34's compute ([ReDim2Paper]) | ONNX | Offline re-clustering only |
| SpeechBrain ECAPA-TDNN | ~15–21M | Apache-2.0 | CASE 0.56% clean, 3.05% degraded ([CASE]) | CPU RTF 0.033 ([CAMpp]) | PyTorch | No gain over current |
| NVIDIA TitaNet-L | 25.3M | CC-BY-4.0 | CASE 0.66% clean → 4.05% degraded, the largest drop among the strong models (Resemblyzer drops more) ([CASE]) | — | ONNX | No |

**Diarization (meetings)**

| Model | Size | Licence | DER (never compare across sources) | Speed on Mac | Runtime | Fit |
|---|---|---|---|---|---|---|
| **Current: VoicePlus `EmbeddingLabeler`**: WeSpeaker embeddings from `DiarizerManager.extractSpeakerEmbedding` on 3–5 s chunks, then its own greedy cosine clustering (0.7) ([Diar]) | ~14 MB | CC-BY-4.0 | **Unmeasured.** For reference, FluidAudio's full online `DiarizerManager` pipeline scores AMI-SDM **38.2%** (10 s chunks, collar 0.25 s, overlap ignored) ([FA-B]), but VoicePlus does not run that pipeline | — | CoreML | Replace for saved transcripts |
| pyannote **community-1** via FluidAudio `OfflineDiarizerManager` (VBx) | ~14 MB ([DiarCML]) | CC-BY-4.0 (upstream is gated; FluidAudio's copy is not) | pyannote, no collar: AMI-SDM 19.9, VoxConverse 11.2 ([Comm1Blog]). FluidAudio, lenient scoring (collar 0.25 s, overlap ignored): AMI-SDM 10.6% ([FA-B]) | 323x on M5 Pro ([FA-B]) | FluidAudio (pinned 0.15.6; threshold semantics changed in 0.15.6 ([FA-R])) | **Adopt** as the post-meeting pass |
| Streaming Sortformer v2.1 | 117M, ~241–255 MB | NVIDIA Open Model License ([Sortf]) | AMI-SDM 20.6% in the balanced config (FluidAudio). **Hard cap of 4 speakers** ([FASortf]) | 1.04 s latency ([Sortf]) | FluidAudio | Live labels only |
| LS-EEND | ~89 MB | CoreML port says MIT, but upstream has **no licence file** ([FSEEND]) | AMI-SDM 20.7% ([FA-B]) | 74.5x on CPU, M4 Max ([FA-B]) | FluidAudio | After the licence is confirmed |
| DiariZen | 63.3M | **CC-BY-NC-4.0** | AMI 14.0 vs pyannote 3.1's 22.4 ([DiariZen]) | — | PyTorch | Lab reference only |
| VibeVoice-ASR | 7B | MIT | Independent Japanese test beat pyannote on 2 of 3 clips ([Neos]) | 30.44 GB peak for 1 h ([Willison]) | MLX | No |

**Verdict.**
- **The gate:**
  - The model is not the weak point; playback audio is. EER rises from 0.58% to 8.57% on playback ([CASE]).
  - Build an owner trial set and recalibrate the threshold per microphone.
  - Add cues that are not about speaker identity: level or proximity, speech must start while the latch is active, and a mid-band similarity rule for long segments.
  - Test CAM++ only because FluidAudio already ships it.
- **Meetings:** VoicePlus clusters system-audio chunks itself with a greedy cosine rule, and no DER has ever been measured for it ([Diar]). FluidAudio's offline community-1 pipeline scores 10.6% on AMI under the same lenient scoring that gives its own online pipeline 38.2% ([FA-B]). So run the offline pass after the meeting ends, keep the live labels only for the live view, and measure both on R6.

### 3.5 Post-dictation cleanup

This layer covers punctuation, casing, fillers, self-corrections, lists and ITN (numbers, dates, emails).

**How the speed column is estimated.** M4 Max decode rates ([JR]) × 0.456, which is the M2 Pro / M4 Max llama.cpp decode ratio (37.87 / 83.06 tok/s ([LC4167])). The figure is the time to decode 60 output tokens and excludes prompt prefill and model load. **llama.cpp is the route buildable today**, because MLX is blocked (§2).

| Model | Disk / RAM | Licence | Evidence | 60 tokens on M2 Pro (est.): MLX / llama.cpp | Runtime here | Languages | Fit |
|---|---|---|---|---|---|---|---|
| **Current: `LocalRulesProvider`** | 0 | — | Deterministic | ~0 | Swift | Any | Keep as the floor and fallback |
| NeMo WFST ITN, via FluidInference `text-processing-rs` | MB-scale (49 MB zipped XCFramework ([TPRS])) | Apache-2.0 | Passes 1,200 of 1,217 NeMo tests (vendor) ([TPRS]). NeMo has hi and hi_en grammars ([NeMoTP]) | ms (est.) | **Already linked**: FluidAudio 0.15.6 depends on `NemoTextProcessing.xcframework` v0.3.0 and exposes it as `FluidAudio.TextNormalizer` ([Resolved]). Hindi through FluidAudio's wrapper is **unverified**; the underlying library takes a language code ([TPRS]) | en, fr, es, de, zh, hi, ja ([TPRS]) | **Adopt** |
| xlm-roberta punctuation + truecase | ~280M. 1.11 GB fp32 ONNX | Apache-2.0 | Vendor English punctuation F1 97.6% ([XLMRPC]) | Tens of ms (est.) | ONNX Runtime | 47 incl. Hindi | Only for punctuating the EOU preview |
| **Superwhisper S1-mini** (Qwen3-0.6B fine-tune) | 462 MiB Q4_K_M ([S1GGUF]). ~0.66 GB RAM (Qwen3-0.6B proxy ([JR])) | Apache-2.0 **plus a naming clause** ([S1]) | Vendor: 94.8% token accuracy on 7,519 English cases ([S1GGUF]). A trade write-up relays further vendor figures: 11.6% text-edit error rate and 98.6% empty output on filler-only input. These are not on the current model card ([MTP]). No independent test | 0.23 s / ~0.45 s (assumes llama.cpp runs at about half MLX speed, as measured for Qwen3.5 ([JR])) | llama.cpp XCFramework ([LCppXC]). Muesli ships it ([Muesli]) | **English only** | **Adopt**, called only when needed |
| Qwen3.5-2B, non-thinking | ~1.2–1.3 GB RAM at 4-bit ([JR]) | Apache-2.0 | Vendor IFEval 61.2 in non-thinking mode ([Q35-2B]) | 0.44 s / **0.88 s** | llama.cpp | 201 claimed, incl. Hindi ([Q35-2B]) | **Hinglish and style modes** |
| Qwen3.5-0.8B | ~0.5–0.7 GB | Apache-2.0 | IFEval 52.1 ([Q35-08]) | 0.31 s / 0.65 s | llama.cpp | as above | Base for a LoRA fine-tune |
| Qwen3-1.7B | 1.27 GB peak ([JR]) | Apache-2.0 | — | 0.41 s / — | llama.cpp | Multilingual | Backup |
| Qwen3-4B-Instruct-2507 | 2.5 GB peak ([JR]) | Apache-2.0 | IFEval 83.4 ([Q3-4B]) | 0.81 s / — | llama.cpp | Multilingual | Over budget |
| Gemma 4 E2B | 2.8–3.2 GB peak ([JR]) | Apache-2.0 ([Gemma4]) | No published IFEval. Muesli marks it "experimental" ([Muesli]) | 0.71 s / 1.1 s | llama.cpp | 35+ | No (slower, heavier) |
| Llama 3.2 3B | 2.1 GB peak ([JR]) | Llama Community License: attribution and naming rules ([Llama32]) | IFEval 77.4 ([Llama32]) | 0.63 s / — | llama.cpp | Official Hindi | Alternative for Hindi |
| Phi-4-mini / SmolLM3-3B | ~2.4 GB | MIT / Apache-2.0 | SmolLM3 IFEval 76.7 ([Smol3]) | 0.78 / 0.67 s MLX | llama.cpp | No Hindi | No |
| Liquid LFM2.5-1.2B | < 1 GB | **LFM licence: free only below $10M revenue** ([LFMLic]) | IFEval 86.23, averaged across strict and loose ([LFM]) | Unmeasured | llama.cpp | No Hindi | No (licence) |
| IBM Granite 4.0 H 1B | ~1 GB | Apache-2.0 | IFEval 78.5 (vendor) ([GraniteNano]) | ~0.48 s MLX | llama.cpp | Hindi unknown | Backup |
| Apple Foundation Models | 0 (system) | OS | Stock model resolved spoken self-corrections in **13%** of cases, but on only 15 held-out cases, run by the maker of a competing dictation app ([Envious]). One project removed it for silently swapping words ([Pladder]) | 846 ms average polish on M4 Pro ([Envious]). TTFT 0.21 s warm, 94 tok/s on M4 Pro ([FMBench]) | Needs the macOS 26 SDK | No Hindi on macOS 26 ([Rudrank]) | Later, optional |
| GECToR tagger | 0.5–1.4 GB | Public checkpoints are **non-commercial** | Essay GEC, not dictation | — | — | English | No |

**Verdict.** The two real risks of a general LLM are **invented words** and **answering or obeying the dictated text**. Another dictation app hit exactly this and fixed it with delimited templates ([FV277]), and OWASP notes that no fix is foolproof ([OWASP]). So:
1. Put deterministic layers first.
2. Use a specialist model (S1-mini, which is not a chat model).
3. Call it only when the rules see a cue: a self-correction phrase, a list, a number or an email.
4. Always run an **output guard**, and fall back to the rules output if the guard fails.
   - Length ratio between 0.5 and 1.5.
   - At least 60% word overlap.
   - No assistant preamble.
   - No dropped custom-vocabulary terms.
   - Never rewrite low-confidence spans.

Ollama and LM Studio stay available as "bring your own" options. Don't make the app depend on them:
- They unload the model after 5 idle minutes ([OllamaFAQ]).
- Ollama's MLX backend needs more than 32 GB of memory ([OllamaMLX]).
- The app can't pin the chat template, which S1-mini needs.

---

## 4. Approaches: end-to-end model stacks

Disk and RAM figures are sums of the component figures above, and every RAM figure is an estimate. The "today" baseline is 721 MB of downloads ([Catalog]), with the final pass at p50/p95 121/130 ms and owner WER 0.099 ([R5.4]). The meetings layer is the same in every stack: Parakeet for long-form, plus community-1 offline. On the long-form board TDT v3 averages 10.72. That is the best Parakeet score and beats Whisper large-v3 (11.23) and Canary-Qwen (11.20), but Cohere Transcribe is the best open model at 9.73, and it is ruled out on memory ([LBlong]).

| | **A · Lean English** (recommended now) | **B · Accuracy-first English** | **C · English + Hinglish** | **D · Qwen everywhere** | **E · Apple zero-download** |
|---|---|---|---|---|---|
| Final ASR | TDT v2 (if it wins) or v3 | Unified offline (or v2) | A or B for English, plus a Hindi model (bake-off winner) | Qwen3-ASR-1.7B | SpeechTranscriber |
| Preview | EOU 120M, **320 ms** | Unified stream, 320 ms | English as in A or B. Hindi: Nemotron 3.5 (1–2 s tier) or none | EOU 120M (English only) | SpeechTranscriber volatile results |
| EOU (latch) | Silero + Smart Turn + EOU token | Silero + Smart Turn | as A or B | as A | SpeechDetector + timeout |
| Speaker / meetings | WeSpeaker (recalibrated). community-1 offline | same (+ CAM++ A/B) | same | same | same (FluidAudio) |
| Cleanup | Rules → ITN → S1-mini (gated) → guard | A + optional Qwen3.5-2B for style | A for English. Qwen3.5-2B for Hinglish | Qwen3.5-2B | Foundation Models → guard → rules |
| **Disk (est.)** | ~1.2 GB (721 MB + 462 MiB + ~17 MB) | ~1.7 GB (~1.2 GB Unified int8 ([UniCML]) + S1-mini + small) | A/B + 0.9–2.4 GB Hindi ASR + 0.65–1.5 GB Nemotron 3.5 + 1.3 GB LLM ≈ 3–6.5 GB, **downloaded only when Hinglish is on** | ~3.4 GB | 0 |
| **Peak RAM (est.)** | ~1.3–1.5 GB | ~1.9–2.3 GB | +1.5–3.5 GB while the Hindi route is loaded | ≥ 3.5 GB (0.6B alone peaked at 1.9 GB ([R5.4])) | Small in-process. System-managed |
| **Release → text (est.)** | ~0.15 s with no cleanup. ~0.4–0.65 s with S1-mini | Similar to A | English as A. Hindi ~1–1.5 s, unmeasured; must stay ≤ 1.5 s p95 | 0.6B already measured p50/p95 2.2 / 3.8 s ([R5.4]). 1.7B is slower | ~0.13 s final ([DevApple]) + ~0.85–1 s cleanup ([Envious]) |
| English accuracy vs today | Same or better (v2 4.70 vs 4.86 ([LB])). Preview error falls ~40% on LibriSpeech ([FA-B]) | Likely better (Mac LibriSpeech 2.38% vs 3.22% ([MacP])). Preview near-final | as A or B | **Risky.** 0.6B lost on owner audio despite a close board score | Worse (14.0% vs 11.7% ([ArgmaxApple])) |
| Hindi | None | None | **Yes.** Monsoon 8.5–13.9 depending on the model ([LB-hi]) | Yes (12.25 ([LB-hi])) | Unconfirmed |
| Licences | CC-BY-4.0, NVIDIA Open Model License, BSD-2, Apache + naming clause | Adds NVIDIA Open Model License for Unified | Adds MIT, Apache, OpenMDW | Apache | OS |
| **Effort** | **S** (days) | **M** | **L** | **L** | **M**, plus a toolchain upgrade |
| Main risk | S1-mini evidence is vendor-only. Still English-only. First-word budget still missed | Unified is not on an independent board. More ANE load | No Mac port for the top Hindi models. Script policy. RAM. The Qwen3-ASR port has no upstream maintainer ([FA-R]) | Latency tail, hallucination, no word confidence | Accuracy. No custom vocabulary. Blocked by the SDK |

### A · Lean English (today plus fixes). Recommended now.
- **Changes:**
  - EOU tier: `.ms160` → `.ms320` at `Engine/ASRRuntime/ModelManager.swift:186`, plus a `ModelCatalog.swift` entry for the repo's `320ms` folder. The catalog pins `hfSubdirectory: "160ms"`, so this is a new download (~224 MB, est.) with a migration, not a one-line change.
  - v2 catalog entry behind a flag: `ModelCatalog.swift`, plus `BundledModel.swift:57` (`chooseFinal`).
  - Smart Turn gate inside `Engine/Audio/Endpointer.swift`, as a new CoreML wrapper in `Engine/VAD/`. The CoreML export avoids adding ONNX Runtime.
  - New `Providers/LlamaCppProvider.swift` conforming to `TextGenerator`, with `RoutingTable` switched to on-device-first.
  - ITN plus guard stages in `Pipeline/Formatters` or `Pipeline/Refine`. ITN calls `FluidAudio.TextNormalizer`, which is already in the dependency graph ([Resolved]).
  - `Package.swift` gains one **binary target**: the prebuilt llama.cpp XCFramework from the release page ([LCppRel]), built with its Metal library embedded ([LCppXC]). Log it in `progress.md` per the repo rules.
  - `SpeakerGate` threshold recalibration.
  - Meetings: `Engine/Meeting/Diarization.swift` gains an `OfflineDiarizerManager` pass after the meeting.
- **Risks:**
  - S1-mini's naming clause governs UI and attribution text.
  - Its quality claims are vendor-only; the bake-off decides.
  - No Hindi.

### B · Accuracy-first English (the Parakeet Unified family)
- One checkpoint family serves the preview (streaming) and the final (offline).
- Drop EOU 120M and end latch segments with Silero plus Smart Turn. Or keep EOU 120M only as a detector, at +224 MB and extra ANE work.
- **Changes:** `Engine/ASRRuntime/PreviewBackend.swift`, `Recognizers.swift`, `RealEngine.swift`, `BundledModel.swift`, `ModelCatalog.swift`, and the `Endpointer` input.
- FluidAudio's CTC-spotter vocabulary boosting could move entity recall, which is stuck at 31.6% under VoicePlus's own rescorer ([Bias]). It post-processes the transcript rather than biasing the decode, and it exists for TDT too, so it is not a reason to pick B on its own ([FA-B], [FA-R]).
- **Variant B′:** use Nemotron Speech Streaming EN (560 ms) in latch mode only, and commit its punctuated segments directly with no second pass.
- **Risks:**
  - Unified's accuracy numbers come from NVIDIA and FluidAudio only.
  - At 320 ms it uses more compute (RTFx ~10x ([FA-M])).
  - Two resident encoders compete for the ANE.

### C · English + Hinglish (bilingual routing)
- **Routing:**
  - Start with an **explicit "Hinglish" mode** (menu toggle or a second hotkey).
  - Today's `CodeSwitchRouter` routes only when the *English-only* preview contains romanized-Hindi function words ([CS]). That is unreliable, because an English model rewrites Hindi into English-looking words.
  - Add audio language ID later: Nemotron 3.5's `auto` tag ([Nemo35]) or Qwen3-ASR's built-in LID ([QASR17]).
- **Hindi final**, whichever wins the bake-off:
  - IndicConformer: ONNX, or a CoreML conversion with the MIT Muesli/FluidAudio recipe.
  - Qwen3-ASR-1.7B: extend the vendored CoreML pipeline in `Engine/ASRRuntime/Qwen3ASR/`, currently 0.6B only. It would need its own 1.7B conversion, because FluidAudio dropped Qwen3-ASR in 0.15.3 ([FA-R]).
  - SraVaani: conversion in the FluidAudio TDT-CTC style.
  - Bodhan Flex, only if its custom licence allows it: community CoreML encoder, but the decoder in Muesli's port runs on MLX-Swift, which is blocked here ([Muesli], [Bodhan]).
- **Script policy.** Decide Devanagari vs Roman vs mixed before choosing a model:
  - IndicConformer writes Devanagari ([Indic]).
  - Trelis writes mixed script ([Trelis]).
  - Otherwise Qwen3.5-2B can transliterate in the cleanup pass.
- **Changes:**
  - A real `IndicASRBackend` to replace `UnavailableIndicBackend`, plus `ScriptAwareMerger`.
  - A settings toggle in `App/Settings/VoiceSettings.swift`.
  - A conversion script under `Scripts/` (offline Python).
  - Catalog entries marked download-on-demand.
  - A mixed-script scorer in `Lab/Harness/Scoring.swift`.
- **Risks:**
  - Code-switched quality is unmeasured everywhere; even a Hinglish fine-tune reports ~28.6% WER on Hinglish ([NemoHinglish]).
  - Memory, if the Hindi and English stacks are resident together, so unload after idle.

### D · Qwen everywhere (Muesli-like: Qwen3-ASR plus a Qwen LLM)
- One model for English and Hindi. On paper it is the best open English model on the live board (4.31 ([LB])).
- **The owner's data says otherwise.** The 0.6B had a near-identical board score to v3 (5.05 vs 4.86) and still lost 0.178 vs 0.099 on owner audio. On the synthetic `noisy` fixture suite (TTS audio, not owner audio) it collapsed, 0.229 vs 0.022 ([R5.4]).
- **Latency.** Mac runtimes differ widely. mlx-qwen3-asr reports 0.30 s per 10 s clip for 0.6B fp16 on an M4 Pro ([MLXQ]). The owner's CoreML port, in a debug build on an M2 Pro, took 2.2 s p50 on 3.7–9.4 s clips ([R5.4]). Runtime choice is therefore half the story, but MLX is blocked here.
- **No native word confidence,** which conflicts with the span contract.
- Keep Qwen3-ASR as a **candidate for C's Hindi route**, not as the default. This matches pending decision #2 ([Pend]).

### E · Apple zero-download
- SpeechTranscriber, SpeechDetector and Foundation Models. Nothing to download.
- **Use it as** the fallback when models aren't downloaded yet, replacing today's legacy `AppleSpeechRecognizer` (SFSpeechRecognizer) path, and as a benchmark control.
- **Blocked** until the CLT or SDK is upgraded to macOS 26, which needs admin rights.
- **Weak points:**
  - No custom vocabulary ([DevAppleLive]).
  - Guardrail refusals.
  - 13% on self-corrections ([Envious]).
  - Hindi unconfirmed.

---

## 5. Recommendation and benchmark plan

**Recommendation:**
- **Build A now.** It is days of work. Every model in it runs through FluidAudio or llama.cpp, so the only new dependency is the prebuilt llama.cpp binary target, which has not yet been built here.
- **Measure B and C in parallel**, using the same corpus.
- **Do not pursue D as the default.**
- **Queue E for when the toolchain is upgraded.**
- **Bundling (pending #1):** A adds ~0.5 GB to the ~721 MB download, so keep download-on-first-run. Never bundle Hindi models; download them when Hinglish mode is turned on.

### 5.1 Fix the harness first (1–2 days)
1. **Measure latency on release builds.** R5.4 was a debug build ([R5.4]).
2. **Normalise numbers on both sides before scoring.** Today's scorer has none, so "twenty five" vs "25" counts as an error. Some of the digits-class WER (0.405 ([R5.4])) may be formatting rather than recognition. Reuse the ITN grammars in reverse, or a Whisper-style English normaliser.
3. **Add a mixed-script scorer** in the OIWER style: accept a Devanagari or romanized spelling per word, via a transliteration table. Report CER as well.
4. **Measure real memory.** Record resident memory including mapped weights (`footprint -p <pid>` or `vmmap --summary`, both present on this Mac) next to `phys_footprint`.
5. **New `SegmentClass` values:** `hinglish`, `hindi`, `long ≥ 15 s`, `noisy`, `numbers`.

### 5.2 Record the corpus

Record on the owner's Mac with the built-in mic, plus AirPods for a subset.

| Set | Count | Content | Harness |
|---|---|---|---|
| R1 English dictation | 20 existing + 60 new | 20 with numbers, dates, currency and emails. 15 with names and entities. 10 technical. 10 long (15–40 s). 5 noisy (fan or café) | `RecordingReplayTests` (`VOICEPLUS_REPLAY`), `RefinementBenchmarkCorpusTests` (one arm per model) |
| R2 Hindi / Hinglish | 60–100 | 20 pure Hindi. 50 code-mixed. 20 Indian English with Hindi names. Two references each: mixed script and fully romanized. The owner marks the preferred script | Same harness, plus the new scorer. Candidates in their reference runtimes first |
| R3 Latch pauses | 15–20 min | Natural hands-free dictation, English and Hinglish. Label every pause ≥ 150 ms as *continue* or *segment* | Replay through `Endpointer`. The eot-bench harness (Apache-2.0) can be reused ([EOT]) |
| R4 Speaker trials | Enrollment of 5 / 10 / 30 s. Tests of 1 / 1.5 / 3 s windows | Owner in English, Hindi and cross-language. Impostors: TV/YouTube Indian speakers, family, the owner's own voice replayed through speakers. Three mics | New gate test (EER, FAR at FRR ≤ 5%) |
| R5 Cleanup | ~300 items | ASR output of R1/R2. 50 self-corrections. 30 lists. 50 numbers/dates/emails. 30 already-clean sentences. 30 Hinglish. **50 adversarial** (questions, "ignore previous instructions", "translate this", profanity and medical text) | New `RefinementBenchmark` arm per cleanup system |
| R6 Meetings | 5–10 | 2–6 speakers, including Hindi. Hand-label 2–3 in RTTM | Strict DER (collar 0, overlap scored) |

### 5.3 Runs, in order
1. **English final:** v3 vs v2 vs Unified-offline on R1 plus the golden set.
2. **Preview:** EOU-160 vs EOU-320 vs Unified-320 vs TDT polled at 0.4 s on R1 (`PreviewReplayTests`).
3. **Latch:** a sweep over T_short, θ and T_long on R3, for silence-only vs silence + Smart Turn vs + stop-word veto.
4. **Cleanup:** rules vs rules+ITN vs S1-mini vs Qwen3.5-0.8B / 2B vs Llama 3.2 3B on R5, timed from key-up alongside the ASR stack.
5. **Hindi:** IndicConformer vs SraVaani vs Qwen3-ASR-1.7B vs Nemotron 3.5 on R2, plus Bodhan Flex if its licence clears. Run each in its reference runtime (ONNX, PyTorch or MLX CLI, all local) and **port only the winner**.
6. **Speaker and meetings:** WeSpeaker vs CAM++ on R4. Online `DiarizerManager` vs `OfflineDiarizerManager` on R6.

### 5.4 Pass/fail gates (proposed)

| Decision | Ship only if all of these hold |
|---|---|
| Switch the English final model | R1 mean WER at least 10% lower (relative) than v3. No segment class worse by more than 0.02 absolute. Golden set ≤ 2.9% ([Golden]). Release-build p95 release→final ≤ 700 ms. Resident memory at most +300 MB |
| Change the preview | R1 preview WER ≤ 0.15. First word p50/p95 no worse than 712/1210 ms ([R1.5]). Append-only output |
| New latch rule | Mid-clause cuts ≤ 5% of pauses labelled *continue*, **and** median commit delay ≤ 1.2 s (today's fixed wait ([EP])) |
| Cleanup default | 0 answered or obeyed on the adversarial set. Invented content words in ≤ 1% of items. Self-corrections resolved ≥ 80%. Clean sentences changed ≤ 5%. p95 ≤ 500 ms. Guard fallbacks ≤ 5% |
| Ship a Hinglish route | R2 error at least 50% lower (relative) than the English stack. Owner accepts the output script on ≥ 80% of items. p95 ≤ 1500 ms. RAM at most +2 GB. **No change to R1** with the mode off |
| Speaker gate | FRR ≤ 5% on 1.5 s windows and FAR ≤ 2% for live impostors. Report playback FAR separately |
| Swap the speaker embedder | At least 25% lower FAR (relative) at the same FRR on R4. Runs on the ANE or takes ≤ 10 ms per window |

### 5.5 Decision rules
1. **v2 passes and Unified doesn't beat it by 5% or more** → ship v2 (catalog change only), and stay on A.
2. **Unified passes both the final and the preview gates** → move to B and retire EOU 120M, unless Smart Turn fails the latch gate without it.
3. **Smart Turn doesn't beat silence-only at equal delay on R3** → keep the silence rule and tune T_long only. eot-bench already shows no gain in Hindi ([EOT]).
4. **S1-mini fails the cleanup gate** → ship rules + ITN as the default, and run the LLM only on an explicit "polish" command.
5. **No Hindi candidate passes** → ship nothing for Hindi and say so in the UI. If one passes, port it and ship C as opt-in.
6. **Qwen3-ASR 0.6B** stays off. Reopen the flag only if 1.7B wins the R2 class, per the pending doc's rule ([Pend]).

---

## 6. What the owner's links and screenshots got right and wrong

**Right**
- Parakeet is fast and strong in English. The live board and the Mac benchmarks agree ([LB], [MacP]).
- Qwen3-ASR does cover Hindi ([QASR17]).
- Smart Turn is a real, permissively licensed EOU option that works in Hindi ([Smart]).
- Using small Qwen3.5 models for cleanup, with a strict "output only the cleaned text" prompt, is sound.
- AssemblyAI's advice to test names and numbers, not just average WER, is right.

**Wrong or misleading**
- **"Parakeet TDT is for low-latency streaming"** (Northflank, AI Overview). TDT is an offline model. The streaming models are EOU 120M, Nemotron and Unified. Northflank also calls TDT "CTC-based" (it is a transducer), and quotes numbers "as of late 2026" in a January 2026 post ([Northflank]).
- **"Parakeet v3 is multilingual."** Its 25 languages are all European. There is no Hindi ([P3]).
- **"1.1B = higher accuracy."** The open TDT-1.1B is English-only and outputs lowercase with no punctuation. The multilingual, Indic 1.1B details describe NVIDIA's server products.
- **Gladia** says Canary-Qwen covers 25 languages. It is English only ([CanQwen]).
- **AssemblyAI** calls Canary-Qwen 2.5B the English-accuracy leader among open models. On the live board Qwen3-ASR-1.7B leads (4.31 vs 4.43) ([LB], [Assembly]). An earlier draft said AssemblyAI calls Parakeet and Canary "proprietary". The current post does not say that; if a screenshot did, it is **unverified**. Both are CC-BY-4.0.
- **"Qwen3-ASR multilingual streaming."** The official package streams only through its vLLM backend, which does not run on a Mac ([QASR17]). The community mlx-qwen3-asr does stream on a Mac, but MLX is blocked here ([MLXQ]). Chunked streaming is also less accurate: 10.45% vs 5.90% for 1.7B ([MSFT]).
- **LiveKit turn detector.** Its licence forbids standalone use ([LKLicense]).
- **"Qwen 3.5 32B / 27B for Apple Silicon."** There is no 32B. A 27B model is too big for 16 GB next to the ASR stack.
- **All three blogs** restate GPU-server leaderboard numbers. None measures Mac latency, streaming or Hindi ([Gladia], [Northflank], [Assembly]).
- **VibeVoice** looks impressive for meetings, but:
  - It is 7B and its setup assumes CUDA.
  - Hindi is ~0.1% of its training data. That figure is read off a chart, so treat it as **unverified** ([VVDoc]).
  - It scores 39.21 on Monsoon Hindi ([LB-hi]).
  - It peaked at 30 GB for an hour of audio on a Mac, as its tool reported it (61.5 GB in Activity Monitor during prefill) ([Willison]).
- **audapolis** is an AGPL-3.0 Electron transcript editor built on Vosk ([Audapolis]). It is not a source of models; use it as a UX reference only and don't copy its code.
- **The Reddit threads could not be read,** because reddit.com is blocked for every tool available here ([Reddit1], [Reddit2]). Thread 1 dates from October 2024, so it is probably stale anyway. Paste the text if it matters.

---

## 7. Sources

**VoicePlus repo** (read, not modified)
- `R5.4`, `R1.5`, `Bias`, `Golden`: `DECISIONS.md` (lines 221–388, 390–431, 41–57, 93–117)
- `Catalog`: `Engine/ASRRuntime/ModelCatalog.swift`. `MM`: `Engine/ASRRuntime/ModelManager.swift`. `EP`: `Engine/Audio/Endpointer.swift`
- `CS`: `Engine/CodeSwitch/IndicASRBackend.swift`. `CSR`: `Engine/CodeSwitch/README.md`. `Gate`: `Engine/Speaker/SpeakerGate.swift`. `Diar`: `Engine/Meeting/Diarization.swift`
- `PRT`: `Tests/EngineTests/PreviewReplayTests.swift`. `Pend`: `VoicePlus_ImplementationBuild_V4_Wave1+Design_Pending.md`. `Resolved`: `Package.resolved` (FluidAudio 0.15.6)

**Leaderboards and independent benchmarks**
- LB: https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results/resolve/main/english_short_latest.csv
- LB-hi: https://huggingface.co/datasets/hf-audio/multilingual_evals/resolve/main/multilingual_hi.csv
- LBlong: https://huggingface.co/datasets/hf-audio/leaderboard_longform/resolve/main/longform_latest.csv
- GS: https://huggingface.co/blog/open-asr-leaderboard-global-south
- MacP: https://github.com/moona3k/macparakeet/tree/main/benchmarks/asr
- OpenBench: https://github.com/argmaxinc/OpenBench/blob/main/BENCHMARKS.md
- MSFT: https://arxiv.org/html/2604.14493v2
- CASE: https://github.com/gittb/case-benchmark
- EOT: https://github.com/livekit/eot-bench
- EOTHi: https://github.com/livekit/eot-bench/blob/main/output/livekit__eot-bench-data__validation__min_silence_100ms/hi/comparison/report.md
- JR: https://raw.githubusercontent.com/john-rocky/apple-silicon-llm-bench/main/RESULTS.md
- LC4167: https://github.com/ggml-org/llama.cpp/discussions/4167
- Willison: https://simonwillison.net/2026/Apr/27/vibevoice/
- Neos: https://neosophie.com/en/blog/20260223-diarization
- ArgmaxApple: https://www.argmaxinc.com/blog/apple-and-argmax
- DevApple: https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4
- DevAppleLive: https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5

**FluidAudio**
- FA-B: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
- FA-M: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md
- FA-R: https://github.com/FluidInference/FluidAudio/releases
- FA-Stream: https://docs.fluidinference.com/asr/streaming
- FA-Nemo: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Nemotron.md
- FA-NemoML: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/NemotronMultilingual.md
- FA-Cohere: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Cohere.md
- FACAM: https://github.com/FluidInference/FluidAudio/pull/652
- FASortf: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Sortformer.md
- UniCML: https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml
- EOUCML: https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml

**ASR and streaming models**
- P3: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- P2: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- Uni: https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- EOU: https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1
- NVOML: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license
- NemoEN: https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
- Nemo35: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- Nemo35CML: https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML
- Nemo35Sherpa: https://huggingface.co/apbaxel/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-int8
- NemoCpp: https://github.com/NVIDIA/NeMo-Speech.cpp
- NemoHinglish: https://huggingface.co/smajji/nemotron-hinglish-v5
- QASR17: https://huggingface.co/Qwen/Qwen3-ASR-1.7B
- QASRRep: https://arxiv.org/html/2601.21337v1
- MLXQ: https://github.com/moona3k/mlx-qwen3-asr/
- Indic: https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual
- IndicSherpa: https://github.com/k2-fsa/sherpa-onnx/discussions/3199
- SraV: https://huggingface.co/ARTPARK-IISc/SraVaani-1.0
- Trelis: https://huggingface.co/Trelis/Whisper-Hinglish-Preview
- Bodhan: https://huggingface.co/bodhan-ai/indic-transcribe-flex
- Cohere: https://huggingface.co/CohereLabs/cohere-transcribe-03-2026
- Gran41: https://huggingface.co/ibm-granite/granite-speech-4.1-2b
- Gran50: https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc
- CanQwen: https://huggingface.co/nvidia/canary-qwen-2.5b
- VV: https://github.com/microsoft/VibeVoice
- VVDoc: https://github.com/microsoft/VibeVoice/blob/main/docs/vibevoice-asr.md
- Voxtral: https://huggingface.co/mistralai/Voxtral-Mini-3B-2507
- VoxRTSwift: https://github.com/Blaizzy/mlx-audio-swift/pull/263
- Kyutai: https://huggingface.co/kyutai/stt-1b-en_fr
- KyutaiSTT: https://kyutai.org/stt/
- Moon: https://arxiv.org/html/2602.12241v1
- MoonGH: https://github.com/moonshine-ai/moonshine
- ArgmaxPro: https://app.argmaxinc.com/docs/wiki/open-source-vs-pro-sdk
- Vosk: https://github.com/alphacep/vosk-space/blob/master/models.md
- LTM172: https://github.com/tomqwu/ListenToMe/issues/172

**EOU and VAD**
- Silero: https://github.com/snakers4/silero-vad
- SileroQ: https://github.com/snakers4/silero-vad/wiki/Quality-Metrics
- Smart: https://github.com/pipecat-ai/smart-turn
- SmartCard: https://huggingface.co/pipecat-ai/smart-turn-v3
- SmartDaily: https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/
- SoniqoTurn: https://soniqo.audio/guides/turn
- Namo: https://huggingface.co/videosdk-live/Namo-Turn-Detector-v1-Multilingual
- FireVAD: https://github.com/FireRedTeam/FireRedVAD
- TENVAD: https://github.com/TEN-framework/ten-vad/blob/main/LICENSE
- LKLicense: https://huggingface.co/livekit/turn-detector/blob/main/LICENSE
- Turnsense: https://huggingface.co/latishab/turnsense
- TextEOT: https://arxiv.org/html/2609.11066v1

**Speaker and diarization**
- WeSpkPaper: https://arxiv.org/html/2306.15161
- WeSpkPre: https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md
- CAMpp: https://ar5iv.labs.arxiv.org/html/2303.00332
- CAMCML: https://huggingface.co/FluidInference/campplus-coreml
- ReDim2: https://github.com/PalabraAI/redimnet2
- ReDim2Paper: https://arxiv.org/html/2603.11841
- SherpaSpk: https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models
- DiarCML: https://huggingface.co/FluidInference/speaker-diarization-coreml
- Comm1Blog: https://huggingface.co/pyannote/speaker-diarization-community-1 (the benchmark table is on the model card, not in the pyannote.ai blog)
- Sortf: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
- FSEEND: https://github.com/Audio-WestlakeU/FS-EEND
- DiariZen: https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md

**Cleanup models and runtimes**
- S1: https://huggingface.co/superwhisper/s1-mini
- S1GGUF: https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/README.md
- MTP: https://www.marktechpost.com/2026/08/20/meet-s1-mini-superwhispers-462-mb-open-weights-text-normalizer-that-turns-raw-asr-transcripts-into-clean-written-text/
- Muesli: https://github.com/Muesli-HQ/muesli
- Q35-2B: https://huggingface.co/Qwen/Qwen3.5-2B
- Q35-08: https://huggingface.co/Qwen/Qwen3.5-0.8B
- Q3-4B: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507
- Gemma4: https://huggingface.co/google/gemma-4-E2B-it
- Llama32: https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct
- Smol3: https://huggingface.co/HuggingFaceTB/SmolLM3-3B
- LFM: https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct
- LFMLic: https://www.liquid.ai/lfm-license
- GraniteNano: https://huggingface.co/blog/ibm-granite/granite-4-nano
- XLMRPC: https://huggingface.co/1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase
- NeMoTP: https://github.com/NVIDIA/NeMo-text-processing
- TPRS: https://github.com/FluidInference/text-processing-rs
- Envious: https://enviouswispr.com/blog/fine-tuning-apple-on-device-model-self-corrections/
- Pladder: https://github.com/dinooo13/pladder/pull/6
- FMBench: https://github.com/TetsuakiBaba/FoundationModels.bench/issues/1
- Rudrank: https://rudrank.com/exploring-foundation-models-supported-languages-internationalization
- MLXSwift: https://github.com/ml-explore/mlx-swift
- MLXSwift430: https://github.com/ml-explore/mlx-swift/pull/430
- LCppXC: https://github.com/ggml-org/llama.cpp/blob/master/build-xcframework.sh
- LCppRel: https://github.com/ggml-org/llama.cpp/releases
- OllamaFAQ: https://docs.ollama.com/faq
- OllamaMLX: https://ollama.com/blog/mlx
- FV277: https://github.com/altic-dev/FluidVoice/issues/277
- OWASP: https://genai.owasp.org/llmrisk/llm01-prompt-injection/

**Owner's links**
- Gladia: https://www.gladia.io/blog/best-open-source-speech-to-text-models
- Northflank: https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks
- Assembly: https://www.assemblyai.com/blog/top-open-source-stt-options-for-voice-applications
- Reddit1 (not readable): https://www.reddit.com/r/LocalLLaMA/comments/1g2shx7/whats_the_best_open_source_speech_to_text_model/
- Reddit2 (not readable): https://www.reddit.com/r/LocalLLaMA/comments/1sgoflg/best_local_model_for_text_clean_up/
- VibeVoice: https://github.com/microsoft/VibeVoice
- Audapolis: https://github.com/bugbakery/audapolis

---

## 8. Fact-check notes (20 Sep 2026)

Every flagged claim was re-checked against its source: the leaderboard CSVs (commit of 14 Sep), the FluidAudio docs, releases and v0.15.6 source, the model cards and the HF API, plus the repo. What changed:
- **Confirmed as written:** the 25 European languages and no Hindi for v3; the leaderboard numbers 4.70 / 4.86 / 3.89 / 4.14 / 4.31 and every Hindi number; the MacParakeet figures; Smart Turn's BSD-2 licence, 8 MB size and 23 languages; eot-bench English numbers; the LiveKit licence; the CASE numbers; S1-mini's licence, size and 94.8%; MLX-Swift PR #430 still open; EnviousWispr's 13% and 846 ms; Willison's 525 s and 30.44 GB.
- **EOU tiers:** corrected 8.29% / 4.87% to 8.23% / 4.88% ([FA-B]). "One-line change" became a catalog entry plus a new download.
- **Unified 320 ms 2.37%:** it comes from the CoreML model card (a 150-file subset), not Models.md. Source changed to [UniCML]. Unified's vocabulary boosting is CTC-spotter rescoring, not decode-time, and TDT has it too, so the "only route" claim was removed.
- **Meetings:** VoicePlus does not run FluidAudio's online diarizer. It uses `DiarizerManager` only for embeddings, on 3–5 s chunks, with its own greedy clustering, which is unmeasured. The 38.2% applies to FluidAudio's pipeline, not to VoicePlus.
- **ITN** is already linked through FluidAudio 0.15.6 (`NemoTextProcessing.xcframework`), so plan A needs one new binary target, not two.
- **Leaderboard:** "no open model beats Parakeet" was reworded, and ARK-ASR-0.6B was added (4.56 average, best open en-IN at 3.43, not Cohere). On long-form, Cohere (9.73) beats TDT v3 (10.72). The old-to-new board shift is 0.75–1.5 points, not 1.3–1.5.
- **OIWER:** the claim that "Roman spellings are accepted" is unsupported. The lattice admits orthographic variants approved by linguists; romanized Hindi is marked unverified.
- **eot-bench Hindi:** exact values are 42.6% / 6.5% vs 49.5% / 7.4%, a small gain rather than none ([EOTHi]). The 93.44% Hindi figure is for v3.0.
- **Caveats added:** CASE is a single-author benchmark whose own model is in the table, and TitaNet's drop is not the worst. S1-mini's 11.6% and 98.6% come only via a trade write-up. The Apple 1.98% rests on 607 words from an interested author, and the 13% on 15 cases. The noisy Qwen collapse was on synthetic fixtures. IndicConformer and SraVaani are gated, and IndicConformer's output script is unverified. FluidAudio dropped Qwen3-ASR in 0.15.3. mlx-qwen3-asr does stream. AssemblyAI's "proprietary" claim was not found in its post.
- **Added:** Bodhan Indic Transcribe Flex as a licence-gated Hindi candidate (found via Muesli).

[R5.4]: DECISIONS.md
[R1.5]: DECISIONS.md
[Bias]: DECISIONS.md
[Golden]: DECISIONS.md
[Catalog]: Engine/ASRRuntime/ModelCatalog.swift
[MM]: Engine/ASRRuntime/ModelManager.swift
[EP]: Engine/Audio/Endpointer.swift
[CS]: Engine/CodeSwitch/IndicASRBackend.swift
[CSR]: Engine/CodeSwitch/README.md
[Gate]: Engine/Speaker/SpeakerGate.swift
[Diar]: Engine/Meeting/Diarization.swift
[PRT]: Tests/EngineTests/PreviewReplayTests.swift
[Pend]: VoicePlus_ImplementationBuild_V4_Wave1+Design_Pending.md
[Resolved]: Package.resolved
[LB]: https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results/resolve/main/english_short_latest.csv
[LB-hi]: https://huggingface.co/datasets/hf-audio/multilingual_evals/resolve/main/multilingual_hi.csv
[LBlong]: https://huggingface.co/datasets/hf-audio/leaderboard_longform/resolve/main/longform_latest.csv
[GS]: https://huggingface.co/blog/open-asr-leaderboard-global-south
[MacP]: https://github.com/moona3k/macparakeet/tree/main/benchmarks/asr
[OpenBench]: https://github.com/argmaxinc/OpenBench/blob/main/BENCHMARKS.md
[MSFT]: https://arxiv.org/html/2604.14493v2
[CASE]: https://github.com/gittb/case-benchmark
[EOT]: https://github.com/livekit/eot-bench
[EOTHi]: https://github.com/livekit/eot-bench/blob/main/output/livekit__eot-bench-data__validation__min_silence_100ms/hi/comparison/report.md
[JR]: https://raw.githubusercontent.com/john-rocky/apple-silicon-llm-bench/main/RESULTS.md
[LC4167]: https://github.com/ggml-org/llama.cpp/discussions/4167
[Willison]: https://simonwillison.net/2026/Apr/27/vibevoice/
[Neos]: https://neosophie.com/en/blog/20260223-diarization
[ArgmaxApple]: https://www.argmaxinc.com/blog/apple-and-argmax
[DevApple]: https://dev.to/iravoice/apple-speechanalyzer-vs-whispercpp-a-40-speaker-mac-benchmark-40i4
[DevAppleLive]: https://dev.to/simple_memo/ios-26s-speechanalyzer-on-a-live-mic-the-5-things-the-docs-dont-tell-you-2ng5
[FA-B]: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
[FA-M]: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Models.md
[FA-R]: https://github.com/FluidInference/FluidAudio/releases
[FA-Stream]: https://docs.fluidinference.com/asr/streaming
[FA-Nemo]: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Nemotron.md
[FA-NemoML]: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/NemotronMultilingual.md
[FA-Cohere]: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/Cohere.md
[FACAM]: https://github.com/FluidInference/FluidAudio/pull/652
[FASortf]: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/Sortformer.md
[UniCML]: https://huggingface.co/FluidInference/parakeet-unified-en-0.6b-coreml
[EOUCML]: https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml
[P3]: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
[P2]: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
[Uni]: https://huggingface.co/nvidia/parakeet-unified-en-0.6b
[EOU]: https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1
[NVOML]: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license
[NemoEN]: https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b
[Nemo35]: https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
[Nemo35CML]: https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML
[Nemo35Sherpa]: https://huggingface.co/apbaxel/sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-int8
[NemoCpp]: https://github.com/NVIDIA/NeMo-Speech.cpp
[NemoHinglish]: https://huggingface.co/smajji/nemotron-hinglish-v5
[QASR17]: https://huggingface.co/Qwen/Qwen3-ASR-1.7B
[QASRRep]: https://arxiv.org/html/2601.21337v1
[MLXQ]: https://github.com/moona3k/mlx-qwen3-asr/
[Indic]: https://huggingface.co/ai4bharat/indic-conformer-600m-multilingual
[IndicSherpa]: https://github.com/k2-fsa/sherpa-onnx/discussions/3199
[SraV]: https://huggingface.co/ARTPARK-IISc/SraVaani-1.0
[Trelis]: https://huggingface.co/Trelis/Whisper-Hinglish-Preview
[Bodhan]: https://huggingface.co/bodhan-ai/indic-transcribe-flex
[Cohere]: https://huggingface.co/CohereLabs/cohere-transcribe-03-2026
[Gran41]: https://huggingface.co/ibm-granite/granite-speech-4.1-2b
[Gran50]: https://huggingface.co/ibm-granite/granite-speech-5.0-470m-turboctc
[CanQwen]: https://huggingface.co/nvidia/canary-qwen-2.5b
[VV]: https://github.com/microsoft/VibeVoice
[VVDoc]: https://github.com/microsoft/VibeVoice/blob/main/docs/vibevoice-asr.md
[Voxtral]: https://huggingface.co/mistralai/Voxtral-Mini-3B-2507
[VoxRTSwift]: https://github.com/Blaizzy/mlx-audio-swift/pull/263
[Kyutai]: https://huggingface.co/kyutai/stt-1b-en_fr
[KyutaiSTT]: https://kyutai.org/stt/
[Moon]: https://arxiv.org/html/2602.12241v1
[MoonGH]: https://github.com/moonshine-ai/moonshine
[ArgmaxPro]: https://app.argmaxinc.com/docs/wiki/open-source-vs-pro-sdk
[Vosk]: https://github.com/alphacep/vosk-space/blob/master/models.md
[LTM172]: https://github.com/tomqwu/ListenToMe/issues/172
[Silero]: https://github.com/snakers4/silero-vad
[SileroQ]: https://github.com/snakers4/silero-vad/wiki/Quality-Metrics
[Smart]: https://github.com/pipecat-ai/smart-turn
[SmartCard]: https://huggingface.co/pipecat-ai/smart-turn-v3
[SmartDaily]: https://www.daily.co/blog/announcing-smart-turn-v3-with-cpu-inference-in-just-12ms/
[SoniqoTurn]: https://soniqo.audio/guides/turn
[Namo]: https://huggingface.co/videosdk-live/Namo-Turn-Detector-v1-Multilingual
[FireVAD]: https://github.com/FireRedTeam/FireRedVAD
[TENVAD]: https://github.com/TEN-framework/ten-vad/blob/main/LICENSE
[LKLicense]: https://huggingface.co/livekit/turn-detector/blob/main/LICENSE
[Turnsense]: https://huggingface.co/latishab/turnsense
[TextEOT]: https://arxiv.org/html/2609.11066v1
[WeSpkPaper]: https://arxiv.org/html/2306.15161
[WeSpkPre]: https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md
[CAMpp]: https://ar5iv.labs.arxiv.org/html/2303.00332
[CAMCML]: https://huggingface.co/FluidInference/campplus-coreml
[ReDim2]: https://github.com/PalabraAI/redimnet2
[ReDim2Paper]: https://arxiv.org/html/2603.11841
[SherpaSpk]: https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models
[DiarCML]: https://huggingface.co/FluidInference/speaker-diarization-coreml
[Comm1Blog]: https://huggingface.co/pyannote/speaker-diarization-community-1
[Sortf]: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
[FSEEND]: https://github.com/Audio-WestlakeU/FS-EEND
[DiariZen]: https://huggingface.co/BUT-FIT/diarizen-wavlm-large-s80-md
[S1]: https://huggingface.co/superwhisper/s1-mini
[S1GGUF]: https://huggingface.co/superwhisper/s1-mini-GGUF/blob/main/README.md
[MTP]: https://www.marktechpost.com/2026/08/20/meet-s1-mini-superwhispers-462-mb-open-weights-text-normalizer-that-turns-raw-asr-transcripts-into-clean-written-text/
[Muesli]: https://github.com/Muesli-HQ/muesli
[Q35-2B]: https://huggingface.co/Qwen/Qwen3.5-2B
[Q35-08]: https://huggingface.co/Qwen/Qwen3.5-0.8B
[Q3-4B]: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507
[Gemma4]: https://huggingface.co/google/gemma-4-E2B-it
[Llama32]: https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct
[Smol3]: https://huggingface.co/HuggingFaceTB/SmolLM3-3B
[LFM]: https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct
[LFMLic]: https://www.liquid.ai/lfm-license
[GraniteNano]: https://huggingface.co/blog/ibm-granite/granite-4-nano
[XLMRPC]: https://huggingface.co/1-800-BAD-CODE/xlm-roberta_punctuation_fullstop_truecase
[NeMoTP]: https://github.com/NVIDIA/NeMo-text-processing
[TPRS]: https://github.com/FluidInference/text-processing-rs
[Envious]: https://enviouswispr.com/blog/fine-tuning-apple-on-device-model-self-corrections/
[Pladder]: https://github.com/dinooo13/pladder/pull/6
[FMBench]: https://github.com/TetsuakiBaba/FoundationModels.bench/issues/1
[Rudrank]: https://rudrank.com/exploring-foundation-models-supported-languages-internationalization
[MLXSwift]: https://github.com/ml-explore/mlx-swift
[MLXSwift430]: https://github.com/ml-explore/mlx-swift/pull/430
[LCppXC]: https://github.com/ggml-org/llama.cpp/blob/master/build-xcframework.sh
[LCppRel]: https://github.com/ggml-org/llama.cpp/releases
[OllamaFAQ]: https://docs.ollama.com/faq
[OllamaMLX]: https://ollama.com/blog/mlx
[FV277]: https://github.com/altic-dev/FluidVoice/issues/277
[OWASP]: https://genai.owasp.org/llmrisk/llm01-prompt-injection/
[Gladia]: https://www.gladia.io/blog/best-open-source-speech-to-text-models
[Northflank]: https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks
[Assembly]: https://www.assemblyai.com/blog/top-open-source-stt-options-for-voice-applications
[Reddit1]: https://www.reddit.com/r/LocalLLaMA/comments/1g2shx7/whats_the_best_open_source_speech_to_text_model/
[Reddit2]: https://www.reddit.com/r/LocalLLaMA/comments/1sgoflg/best_local_model_for_text_clean_up/
[Audapolis]: https://github.com/bugbakery/audapolis
