# Engine/Biasing — decode-time context biasing (P1.5, Bet 2)

Pipeline: `ContextSource`s → `ContextHarvester` (dedup) → `Ranker` (source × recency × salience,
**hard cap 400**) → `BiasPrefixTree` (token-id trie built with `BiasVocabulary`) →
`ShallowFusionBiaser: LogitBiaser` (boost on prefix match, completion bonus, partial-match
unbiasing, `maxBoost` clamp as the false-insertion guard) → installed on any `Decoder`.

- Sources: `AXTreeSource` (live `LiveAXFocusedWindowText`, AX only, no screenshots),
  `RecentWordsRing` (10 min), `CorrectionSource` (`DatabaseCorrectionStore` over
  CorrectionRecord/DictionaryRecord), `CodeSymbolSource` (file names), `ContactsSource`
  (`LiveContacts`, reads only if already authorized), `ParticipantsSource` (app-fed).
- Vocab: the frozen `Decoder` has no tokenizer API, so `BiasVocabulary.load` reads
  `parakeet_vocab.json` (id→piece) / SentencePiece `.vocab`; `discoverParakeet()` finds the
  cached model; `synthetic()` for tests.
- `ScriptedLogitDecoder` (top-K logits + true re-argmax) is the synthetic decoder for the
  Lab/tests; `NarrowBeamBiasedDecoder` (width 2–4) wraps any `StepwiseDecoder`.
- Gating: `BiasingController.makeBiaser()` returns nil unless `FeatureFlag.contextBiasing`.
- Lab: `BiasingMetrics` (entity recall, false-insertion rate, added latency, µs per boost call).
