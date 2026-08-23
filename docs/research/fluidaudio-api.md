# FluidAudio API research note

Source: `git clone --depth 1 https://github.com/FluidInference/FluidAudio` at commit `6428e29` (2026-08-22);
latest release **v0.15.6** (2026-08-19). Read from source, not docs; paths below are relative to `Sources/FluidAudio/`.

## Package facts
- Package / product / module name: **`FluidAudio`** (library); CLI product `fluidaudiocli`. Pod `FluidAudio.podspec` also exists.
- `swift-tools-version: 6.0`; platforms **macOS 14 / iOS 17**. No SwiftPM deps, but one **binaryTarget** `NemoTextProcessing`
  (xcframework zip from `FluidInference/text-processing-rs`, downloaded at resolve time) + two C wrapper targets (`cxxLanguageStandard .cxx17`).
- License: **Apache-2.0** (repo). Model licenses on HF: Parakeet TDT v3 **CC-BY-4.0** (NVIDIA), Silero VAD **MIT**,
  speaker-diarization (pyannote-derived) CC-BY-4.0, Parakeet EOU "other".
- Add: `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")`, `.product(name: "FluidAudio", package: "FluidAudio")`.
- Model cache: `~/Library/Application Support/FluidAudio/Models/<repo-folder>/` (`Shared/MLModelConfigurationUtils.defaultModelsDirectory(for:)`).
  Default `MLModelConfiguration`: preprocessor on CPU, everything else `.cpuAndNeuralEngine` (no GPU).

## HF repos (`ModelNames.swift`, `enum Repo`)
| Use | Repo | Approx download |
|---|---|---|
| ASR batch (default) | `FluidInference/parakeet-tdt-0.6b-v3-coreml` | Preprocessor + Encoder.mlmodelc (int8, 445 MB) + Decoder 24 MB + JointDecisionv3 13 MB + `parakeet_vocab.json` ≈ **~500 MB** (repo total 3.6 GB incl. EncoderInt4 298 MB, Encoder_v2 594 MB, fp32 variants) |
| ASR v2 (English) | `FluidInference/parakeet-tdt-0.6b-v2-coreml` | similar |
| CTC 110M (keyword spotting for custom vocab) | `FluidInference/parakeet-ctc-110m-coreml` | 106 MB |
| Streaming EOU 120M | `FluidInference/parakeet-realtime-eou-120m-coreml/{160ms,320ms,1280ms}` | ~1.3 GB repo (one variant ≈ 1/3) |
| Streaming Nemotron 0.6B (en) | `FluidInference/nemotron-speech-streaming-en-0.6b-coreml/{560,1120,2240}ms` | ~0.6 GB/variant |
| VAD | `FluidInference/silero-vad-coreml` | **8 MB** |
| Diarization (online) | `FluidInference/speaker-diarization-coreml` | 129 MB |
| Diarization (Sortformer streaming) | `FluidInference/diar-streaming-sortformer-coreml` | — |

## ASR (Parakeet TDT, batch / sliding window) — `ASR/Parakeet/SlidingWindow/TDT/`
```swift
import FluidAudio
// download+load (skips download if cached). version: .v2 | .v3 | .tdtCtc110m | .tdtJa
let models = try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8,
                                                 progressHandler: { p in print(p) })
let asr = AsrManager(config: .default, models: nil)   // `public actor AsrManager`
try await asr.loadModels(models)
var state = try TdtDecoderState()                     // throwing init; persists across chunks of one utterance
let result: ASRResult = try await asr.transcribe(samples16k, decoderState: &state, language: .english)
// overloads: transcribe(AVAudioPCMBuffer, ...), transcribe(URL, ...) (auto disk-backed > streamingThreshold),
//            transcribeDiskBacked(URL, ...)
result.text; result.confidence /* mean token softmax prob, 0.1...1.0 */
result.tokenTimings   // [TokenTiming]? — token, tokenId, startTime, endTime, confidence (per token!)
buildWordTimings(from: result.tokenTimings ?? [])   // [WordTiming] word/start/end
```
- `ASRConfig(sampleRate:16000, tdtConfig:, parallelChunkConcurrency:, streamingEnabled:, streamingThreshold:, dualDecodeArbitration:, seamGapRepair:...)`.
- `TdtConfig(includeTokenDuration:, maxSymbolsPerStep:, durationBins:[0,1,2,3,4], blankId: 8192 (v3), boundarySearchFrames:, maxTokensPerChunk:, consecutiveBlankLimit:)`.
- Timestamps: encoder frame = **80 ms** (`Shared/ASRConstants.secondsPerEncoderFrame`), so token times are 80 ms-quantised; built in
  `AsrManager+TokenProcessing.swift` from `TdtHypothesis.timestamps/tokenDurations/tokenConfidences`.
- Decoder types: `TdtDecoderV2` / `TdtDecoderV3` (chosen in `AsrManager.swift:294/312/339`), entry `decodeWithTimings(encoderOutput:…) -> TdtHypothesis`
  (`TdtDecoderV3.swift:103`). Supporting: `TdtDecoderState`, `TdtHypothesis` (internal: `score, ySequence, timestamps, tokenDurations, tokenConfidences`),
  `TdtJointDecision`, `TdtModelInference`, `TdtDurationMapping`, `DualDecodeArbitration`.
- Multi-stream convenience: `SlidingWindowAsrManager` (actor: `startStreaming(source:)`, `streamAudio(buffer)`, `finish()`, `reset()`, `cancel()`) and
  `SlidingWindowAsrSession` (`createStream`, `getStream(for:)`). These re-run TDT over a sliding window; not true streaming.

### Per-token log-probs / logit bias — what is and isn't exposed
- **Public:** only `TokenTiming.confidence` (softmax prob of the *chosen* token, clamped) and `ASRResult.confidence` (mean). No n-best, no full logits.
- **Internal, greedy only:** the joint CoreML model (`JointDecisionv3.mlmodelc`) returns `token`, `probability`, `durationBin`, plus
  **`top_k_ids` / `top_k_logits`** (raw logits, top-K only, v3). Extracted in `TdtModelInference.runJointPrepared(...)` (`Decoder/TdtModelInference.swift:84-172`)
  into `internal struct TdtJointDecision { token, probability, durationBin, topKIds: [Int]?, topKLogits: [Float]? }` (`Decoder/TdtJointDecision.swift`).
  Full-vocab logits are **not** returned by the CoreML graph — the argmax happens inside the model; a true logit bias over the whole vocab would need a re-exported joint.
- **Hook point for a logit bias:** `TdtDecoderV3.decodeWithTimings` main loop, `Decoder/TdtDecoderV3.swift:~280-300` — after
  `var score = TdtDurationMapping.clampProbability(decision.probability)` it calls `Self.tokenLanguageFilter(label:&label, score:&score, topKIds:, topKLogits:, ...)`
  and `Self.applyEnglishBlocklist(label:&label, score:&score, topKIds:, topKLogits:, vocabulary:, blankId:)` (`:635`). Both already re-pick `label` from the
  top-K by adding/suppressing logits — a hotword bias over `topKLogits` slots in exactly there (same `(label, score) inout` shape). Top-K width is fixed by the model export.
- **Reference implementation of exactly this:** `ASR/Parakeet/Streaming/Nemotron/NemotronVocabularyBias.swift` — shallow-fusion hotword bias inside the
  RNN-T greedy loop (`candidates()`, `observe(tokenId)`, `effectiveBoost`, flat log-prob bonus added before argmax), enabled via
  `StreamingNemotronAsrManager.setCustomVocabulary([CustomVocabularyTerm])` (requires the logits-producing step decoder, not `decoder_joint_argmax`).
- **TDT path's official custom-vocab mechanism is post-hoc, not logit-level:** `SlidingWindowAsrManager.configureVocabularyBoosting(vocabulary: CustomVocabularyContext,
  ctcModels: CtcModels, config:)` runs the 110M CTC head (`CtcModels.loadDirect(from:variant:)`), keyword-spots with `CtcKeywordSpotter` (DP over CTC log-probs,
  `BKTree` fuzzy match) and rewrites text via `VocabularyRescorer` (`CustomVocabulary/Rescorer/*`). Results land in `ASRResult.ctcDetectedTerms / ctcAppliedTerms`.
  `CustomVocabularyTerm(text:, weight:, aliases:, tokenIds:, ctcTokenIds:, …)`. The CTC path *does* expose real per-frame log-probs (`CTC/CtcDecoder.swift`, `ARPALanguageModel.swift`).

## Streaming ASR — `ASR/Parakeet/Streaming/`
```swift
public protocol StreamingAsrManager: Actor {  // StreamingAsrManager.swift:20
  func loadModels() async throws; func appendAudio(_ buffer: AVAudioPCMBuffer) throws
  func processBufferedAudio() async throws; func finish() async throws -> String; func reset() async throws
  func setPartialTranscriptCallback(_ cb: @escaping @Sendable (String) -> Void); func getPartialTranscript() -> String }
// optional: StreamingAsrTokenTimestampProvider.getTokenTimestampsMs(), StreamingAsrRawTokenProvider.getRawTokenStrings(), StreamingAsrEouProvider.getEouTimestampsMs()
let eou = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: 1280)   // 120M, English, true streaming + end-of-utterance
try await eou.loadModels()                  // downloads parakeet-realtime-eou-120m-coreml/160ms
await eou.setEouCallback { finalText in ... }; await eou.setPartialCallback { partial in ... }
let partial = try await eou.process(audioBuffer: buf); let text = try await eou.finish()
let nem = StreamingNemotronAsrManager(...)  // 0.6B en, chunk 560/1120/2240 ms; finishWithTokenTimings() -> (text, [TokenTiming]); setCustomVocabulary(_:)
```
Streaming managers give token timestamps (ms) but **no per-token confidence** (`TokenTiming` only from Nemotron `finishWithTokenTimings`).

## VAD (Silero) — `VAD/`
```swift
let vad = try await VadManager(config: VadConfig(defaultThreshold: 0.85, computeUnits: .cpuAndNeuralEngine)) // downloads silero-vad-coreml
// VadManager.chunkSize = 4096 samples (256 ms @ 16 kHz); VadManager.sampleRate = 16000
let frames: [VadResult] = try await vad.process(samples)           // .probability, .isVoiceActive, .outputState; also process(URL)/process(AVAudioPCMBuffer)
let segs: [VadSegment] = try await vad.segmentSpeech(samples, config: VadSegmentationConfig(
    minSpeechDuration: 0.15, minSilenceDuration: 0.75, maxSpeechDuration: 14.0, speechPadding: 0.1,
    silenceThresholdForSplit: 0.3, negativeThreshold: nil, negativeThresholdOffset: 0.15))   // .startTime/.endTime
var st = await vad.makeStreamState()                               // streaming w/ Silero hysteresis
let r = try await vad.processStreamingChunk(chunk4096, state: st, config: .default, returnSeconds: true)
st = r.state; if let e = r.event { e.kind == .speechStart / .speechEnd; e.time }
```
Also `FsmnVadManager` (FunASR FSMN VAD, `FluidInference/fsmn-vad-coreml`). `VadManager(config:, vadModel: MLModel)` for injecting a model in tests.

## Diarization — `Diarizer/`
```swift
let models = try await DiarizerModels.downloadIfNeeded()          // speaker-diarization-coreml (segmentation + WeSpeaker embedding)
let d = DiarizerManager(config: DiarizerConfig.default); d.initialize(models: models)   // final class, not actor
let res: DiarizationResult = try d.performCompleteDiarization(samples, sampleRate: 16000, atTime: 0)
res.segments: [TimedSpeakerSegment] (speakerId, startTimeSeconds, endTimeSeconds, qualityScore)
let emb: [Float] = try d.extractSpeakerEmbedding(from: samples)     // WeSpeaker embedding; d.initializeKnownSpeakers([Speaker])
```
Alternatives: `OfflineDiarizerManager` (pyannote community-1, VBx/AHC clustering), `SortformerDiarizer` (streaming, overlap-aware), `LSEENDDiarizer`.

## Implications for VoicePlus
1. Use `AsrManager` + `TdtDecoderState` for the batch path: gives per-token confidence + 80 ms timestamps → enough to populate `TranscriptSpan.confidence/audioRange`.
2. Real logit-level hotword biasing requires a **fork** patching `TdtDecoderV3.decodeWithTimings` (top-K only) — or the Nemotron streaming path which ships it upstream.
   Cheapest first step: `configureVocabularyBoosting` (CTC rescoring, +106 MB model) which needs no fork.
3. Silero VAD is tiny (8 MB) and chunk-synchronous (256 ms); thresholds tunable per call. Our `Fixtures/audio/vad/labels.json` spans are the F1 ground truth.
4. Binary xcframework dependency + ~500 MB first-run model download must be handled in onboarding and in `Packaging/` (models are not bundled).
