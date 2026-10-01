# Engine/Biasing — vocabulary boosting (V5 B1) and the ranked context list

## V5 B1 — final-pass CTC vocabulary boosting (replaces decode-time shallow fusion)

    Dictionary + confirmed corrections + RankedContext(.authored)   (never screen text)
        → BoostVocabulary.build (dedupe, ≥3 letters, cap 400, rebuilt per utterance)
        → BoostingController.makeBoosterForUtterance()  (AppContainer.prepareForUtterance, hotkey-down)
        → BiasingRecognizerProvider.install(booster) → FluidAudioTDTDecoder.booster
        → final pass: TDT greedy → CTCVocabularyBooster (parakeet-ctc-110m keyword spotting +
          FluidAudio's constrained rescorer) → BoostAlignment maps the rescored words back to tokens

- **Two `AsrManager`s, one `AsrModels`.** `FluidAudioTDTDecoder.decode` (final) is boosted;
  `decodePreview` (streaming manager, used by `PollingPreviewRecognizer`) never is — the pill never
  shows a term the CTC pass has not confirmed.
- **No flag.** An empty list installs nothing; a missing CTC model makes the booster a no-op and
  `ManagedCTCBoostingSource` fetches it (~103 MB, `ModelRole.onDemand`) in the background the first
  time a non-empty list asks. That utterance is unboosted; the next one is boosted.
- **Confidence stays honest.** Untouched words keep their tokens bit-for-bit; a replaced word takes
  the best log-prob of the tokens it replaced (no invented certainty) and their audio range.
- Deleted (V5 A1, X3/X5): `ShallowFusionBiaser`, `BiasRescorer`, `NarrowBeamBiasedDecoder`,
  `ScriptedLogitDecoder`, `ContextRecallProbe`, `BiasingController`, flag `contextBiasing`. They
  could only re-score a token the greedy decoder had already chosen, and the Lab measured 0
  entity-recall gain. `LogitBiaser` stays on the frozen `Decoder` protocol, accepted and inert.
- Kept: `ContextHarvester`, `Ranker`, `ContextRanker` (consumed by B2/E1 and the authored tier
  here); `BiasingMetrics` (entity recall / false insertions — the B1 gate); `BiasVocabulary`
  (error mapping only); `PrefixTree`.
- Gate: `Tests/EngineTests/CTCBoostingLiveTests.swift` (entity fixtures, real models; skips without
  them). The public-set gate (Earnings-22 entity subset + MUSAN 10 dB) runs through the V1 harness.

## R4.1b — the ranked context list and the refinement prompt

A second path through the same harvest, for the consumer that *can* change a word: a text prompt.

    ContextSources → ContextHarvester → ContextRanker → RankedContext (tiered, deduped, cap 400)
                                                        ├─ PromptBuilder → bounded, sanitised string
                                                        └─ ContextGate    → should this segment get
                                                                            a second pass?

- `ContextRanker` ranks in **bands first, score second** (`ContextTier`): corrections + Dictionary
  (`.authored`) → focused-window text and open-document names (`.screen`) → recent vocabulary and
  the permissioned name sources (`.recent`). `Ranker` still scores inside a band, so "how much does
  a source count" lives in one place. The band order is why a text editor showing four hundred
  capitalised words cannot push a Dictionary entry out of the 400-term cap.
- `ContextSession` owns the lifetime: `rebuild()` per utterance, `discard()` per session (which also
  drops `ContextHarvester.lastEntries`). `RankedContext` is deliberately **not `Codable`** — history,
  diagnostics and sync move `Codable` values, so there is no path by which screen text reaches them.
- `PromptBuilder` turns the list into a bounded string. Screen text is **data, never instructions**:
  role labels (`system:`), directives ("ignore", "you must", "from now on"), imperative openings,
  URLs/schemes/emails, template and chat markers, and invisible/bidi scalars are dropped before the
  prompt exists. `Limits` caps the whole string (default 1,000 characters), the term count (400) and
  each term (48 characters, 4 words); the cap holds for a five-megabyte "term" too.
- Nothing in `ContextRanker.swift`, `PromptBuilder.swift`, `ContextGate.swift` or
  `BoostVocabulary.swift` logs — `ContextPrivacyTests` reads the source to keep that true. What a
  caller *may* log is `RankedContext.shape`, `PromptBuilder.Result.shape` and
  `ContextGate.Decision.summary`: counts and enum cases, never a term.
- `ContextGate` is the consumer today (V3 §7.1): pass-1 confidence plus phonetic near misses of list
  terms (`PhoneticContextIndex`, double metaphone + edit distance, possessive-aware). R5.2 wires the
  refinement pass and R5.3 owns the shipped policy; `PromptBuilder.prompt(for:)` is the call it makes.

### Measured — real-room corpus, 11 September 2026 (historical: the probe and its test were deleted in V5 B1)

`ContextRecallCorpusTests`, Parakeet TDT 0.6B v3 on the twenty real-room
recordings, ten curated entities, one simulated workspace for all twenty (the corpus's own names plus
sixty unrelated ones, several of them sound-alikes of words the corpus gets right):

    without list  entity recall 0.600 (6/10)   false insertions 2  rate 0.0090
    with list     entity recall 0.800 (8/10)   false insertions 6  rate 0.0270
    recall gain +20.0 pp · list 189/400 terms · prompt 1000/1000 characters · gate opened 6/20

The *with list* arm is `ContextRecallProbe`, a reference-blind stand-in for a context-primed second
pass (a hypothesis word that sounds like a list term becomes that term). It is a measurement
instrument and is installed nowhere. Three of the four added false insertions are its bluntness
("Sundays" → "Sundaes"), not the list's: it has neither acoustics nor a language model. R5.4
re-measures the same corpus with Qwen3 actually reading the prompt.
