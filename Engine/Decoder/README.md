# Engine/Decoder — frozen interface (P1.3 T1)

**Status: FROZEN as of P1.3 T1.** Additive changes only (new optional protocol members with
default implementations). P1.5 (biasing) and P1.6 (beam/alternates) build against this file:
`Engine/Decoder/Decoder.swift`.

## Types

| Type | Purpose |
|---|---|
| `DecodedToken { tokenId, text, logProb, startTime, endTime }` | One sub-word token. `logProb` is natural log (≤ 0). `text` keeps the SentencePiece word marker `▁`; use `isWordStart` / `strippedText`. Times are seconds from utterance start, absolute (chunk offset already applied), 80 ms quantised for Parakeet. |
| `EncoderFrames { values, frameCount, hiddenSize, frameDuration, timeOffset }` | Row-major `[frames][hidden]` encoder output. `timeOffset` is the chunk start in seconds. |
| `PrefixState { tokenIds, text, frameIndex }` | What has been decoded so far; passed to the biaser at each step. |
| `DecodeResult { tokens, score, text }` | `score` = Σ logProb; `text` = tokenizer-joined text. |

## Protocols

```swift
public protocol Decoder: AnyObject, Sendable {
    var name: String { get }
    var biaser: LogitBiaser? { get set }
    func decode(encoderFrames: EncoderFrames) async throws -> DecodeResult
    func reset() async
}

public protocol LogitBiaser: Sendable {
    func boost(tokenIds: [Int], prefixState: PrefixState) -> [Int: Float]   // additive log-prob bonus per candidate id
}
```

### Contract
- A `Decoder` is stateful per utterance. Call `reset()` between utterances; chunks of one
  utterance go through `decode` in order and each returns only the *new* tokens for that chunk.
- `decode` never returns blank tokens. Tokens are in time order.
- `biaser.boost` is called once per non-blank emission step with the **top-K candidate ids** the
  joint exposes (Parakeet TDT v3 CoreML joint returns `top_k_ids/top_k_logits`; full-vocab logits
  are not available — see `docs/research/fluidaudio-api.md`). Bonus is added to the raw logit of the
  matching candidate before re-argmax; ids not in the returned dict get 0. The chosen token's
  `logProb` reflects the *unbiased* softmax probability so confidence stays honest (Bet 9).
- Biaser implementations must be pure/cheap; they are called thousands of times per utterance.

## Implementations
- `FluidAudioTDTDecoder` (`Engine/Decoder/FluidAudioTDTDecoder.swift`) — adapter over the upstream
  FluidAudio 0.15.x greedy TDT path. Upstream does **not** expose `decodeWithTimings` or a per-step
  hook publicly, so the adapter:
  1. Runs full utterances through `AsrManager.transcribe(_:decoderState:)` and maps
     `ASRResult.tokenTimings` → `[DecodedToken]` (`logProb = log(confidence)`).
  2. V5 B1: holds **two `AsrManager`s over one `AsrModels`** — `decode` (final pass) applies the
     installed `VocabularyBooster` (`CTCVocabularyBooster`: parakeet-ctc-110m keyword spotting +
     FluidAudio's constrained rescorer, mapped back to tokens by `BoostAlignment`); `decodePreview`
     (`PreviewDecoding`, used by `PollingPreviewRecognizer`) is never boosted. The legacy
     `LogitBiaser` is accepted for protocol conformance and ignored (it could never change a word).
  `EncoderFrames` for this adapter are **not** raw encoder output: `FluidAudioTDTDecoder.decode`
  expects `EncoderFrames` produced by `FluidAudioTDTDecoder.frames(fromSamples:)` (samples packed,
  hiddenSize 1, frameDuration 1/16000), because the upstream runs preprocessor+encoder+decoder
  as one unit. A raw-frames path is the fork follow-up.
- `MockDecoder` (tests + `Lab`) — replays scripted `[DecodedToken]`, applies an installed `booster`
  (e.g. `ScriptedVocabularyBooster`), ignores `biaser`.

## Word confidence (Engine/Confidence)
`WordConfidence.aggregate(tokens)` groups sub-word tokens into words (`isWordStart` boundaries) and
uses the **min-prob rule**: word confidence = min over its tokens' `probability`. Span audioRange
= first token start … last token end. See `Engine/Confidence/WordConfidence.swift`.

## Runtime layout (Engine/ASRRuntime)
- `ModelManager` (actor): disk layout `~/Library/Application Support/VoicePlus/Models/<ModelDescriptor.folderName>/` (= FluidAudio's `Repo.folderName`, so its loaders resolve to the same folder instead of re-downloading), HF download with
  byte-range resume (`HFDownloader`) + `voiceplus-manifest.json` (SHA256 per file), load/unload, `warmStart()`,
  and warm-start discovery of FluidAudio's own cache. Catalog: TDT v3 (final), EOU 120M/160 ms (preview),
  TDT-CTC 110M (bundled tiny), Whisper small (placeholder, no runtime).
- `RealEngine` (`EngineProtocol`): `AudioSource` → `PreviewRecognizer` (EOU, cumulative partials → `.partial` +
  `.previewing`) and on `stop()` a `FinalRecognizer` (TDT via the frozen `Decoder`) whose word spans replace the preview.
- `BundledModel` / `RecognizerFactory`: first launch fetches the 110M model first, big models in the background;
  until anything is on disk `AppleSpeechRecognizer` (on-device SFSpeechRecognizer) handles dictation.

## Verified on this machine (2026-08-23, M-series, FluidAudio 0.15.6)
`Fixtures/audio/clean` (12 TTS files) with Parakeet TDT v3 int8: **mean WER 2.9 %**, per-file final pass 100–190 ms;
remaining errors are number formatting ("three thirty" → "3 30") and one name ("Priya" → "Kriya", confidence 0.95 vs ≥0.99
for correct words). EOU 160 ms preview: incremental partials, 7.7 % WER on clean_01. `RealEngine` end-to-end: 10 preview
updates, final landed 142 ms after stop, WER 0 on clean_02. Run: `swift test --filter ASRGoldenTranscriptTests`
(skips without models; `VOICEPLUS_LIVE_MODELS=1` downloads them).
