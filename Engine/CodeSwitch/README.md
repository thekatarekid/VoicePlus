# Engine/CodeSwitch — Hindi+English in one breath (P6.3)

No language toggle. The detector watches streaming text, the merger turns mixed-script spans
into one string, and the pill shows a small script indicator of what was heard.

## Research: AI4Bharat models (checked 2026-08-24)

| Model | Decoders | License | Formats | CoreML |
| --- | --- | --- | --- | --- |
| `ai4bharat/indic-conformer-600m-multilingual` (HF) — 22 Indian languages | CTC + RNNT | **MIT** (HF model card + `AI4Bharat/IndicConformerASR` GitHub) | PyTorch/NeMo `.nemo`, ONNX community exports | **No official CoreML export.** Muesli (MIT) ships its own "IndicConformer RNNT CoreML backend"; its conversion scripts may be copied with attribution. |
| Older IndicWav2Vec / IndicWhisper | CTC / seq2seq | MIT / Apache-2.0 | PyTorch | none |

Conclusion: commercial use is fine (MIT). Hindi+English code-switching in the 600M multilingual
model is implicit (Hindi output is Devanagari; English loanwords usually come out transliterated,
so `ScriptAwareMerger` + the Latin TDT pass are both needed). Weights are **not shipped** —
they are ~2.4 GB and have no CoreML artifact we can verify; the engine exposes a slot instead.

Sources: huggingface.co/ai4bharat/indic-conformer-600m-multilingual, github.com/AI4Bharat/IndicConformerASR,
github.com/Muesli-HQ/muesli (README: "AI4Bharat IndicConformer RNNT CoreML backend").

## Adding the weights

1. Convert `indic-conformer-600m-multilingual` RNNT (encoder / decoder / joint) to CoreML with
   `coremltools` (or reuse Muesli's converter, MIT — keep the attribution header).
2. Place in `<models dir>/indic-conformer-600m/`: `Encoder.mlmodelc`, `Decoder.mlmodelc`,
   `Joint.mlmodelc`, `vocab.json` (`IndicASRAvailability.requiredFiles`).
3. Implement `IndicASRBackend` (conforms to `FinalRecognizer`) with the real RNNT greedy loop —
   mirror `FluidAudioTDTDecoder` — and register it in `AppContainer` in place of
   `UnavailableIndicBackend`. `IndicASRAvailability.check(modelsDirectory:)` gates it at runtime.

## Pieces

- `Script.swift` — `Script` (latin / devanagari / other / neutral; marks + digits + punctuation are neutral),
  `SpokenLanguage`, `ScriptSegment`, `ScriptSegments` (what the App passes to Injection).
- `LanguageDetector.swift` — streaming; Devanagari → Hindi by script, Latin words → romanized
  Hindi vs English by function-word list + character trigrams. Yields `.mixed` for Hinglish.
- `ScriptAwareMerger.swift` — `[TranscriptSpan] -> ScriptSegments`; spacing rules (no space
  before `, . ! ? ; : ।`, none after opening quote/bracket), provenance `codeswitch.merge`.
- `IndicASRBackend.swift` — protocol, availability check, `UnavailableIndicBackend`,
  `MockIndicBackend`, `CodeSwitchRouter` (routes to Indic only when installed and preview looks Hindi).
- `ScriptIndicator.swift` — pill indicator model (`EN`, `हि`, `EN·हि`) with confidence hysteresis.

Fixture: `Fixtures/transcripts/hinglish.json` (single-breath Hindi+English, `expected` string).
Untested on hardware: the real RNNT backend (no weights); everything else is covered by
`Tests/EngineTests/CodeSwitchTests.swift`.
