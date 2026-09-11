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

## Biasing is not a suspect for bad dictation accuracy — measured 2026-09-08

Read this before investigating biasing as a cause of wrong words, and before tuning `BiasingConfig`.

Two independent reasons it cannot be responsible on the shipping build:

1. **The flag is off.** `FeatureFlag.contextBiasing` is `defaultOn: false` (P1.12 T2, DECISIONS.md).
   With no `feature_flags.json` override, `BiasingController.makeBiaser()` returns nil and
   `AppContainer.prepareForUtterance()` installs *no* biaser at all.
2. **Even switched on it cannot change a word.** On the real Parakeet path,
   `FluidAudioTDTDecoder` runs FluidAudio's greedy TDT to completion and *then* calls
   `BiasRescorer.apply`, which adjusts the `logProb` of tokens that were **already chosen**. It
   never re-picks a token, so no value of `boostPerToken` / `maxBoost` can substitute one word for
   another. `ShallowFusionBiaser` only does true shallow fusion under `ScriptedLogitDecoder` /
   `NarrowBeamBiasedDecoder`, neither of which the app builds.

Measured through the app's real configuration (Parakeet TDT 0.6B v3, 12 clean fixtures, a trie built
by the real `ContextHarvester` + `Ranker` from unrelated on-screen prose deliberately stuffed with
phonetic neighbours) — `Tests/EngineTests/BiasedDecodeWERTests.swift`:

    biaser == nil        mean WER 0.0291
    biaser installed     mean WER 0.0291   (byte-identical text on all 12 fixtures)
    "the quick brown fox jumps over the lazy dog"   WER 0.000 on both paths

What biasing *does* change is confidence, and that is worth knowing if the flag is ever flipped
back on: a candidate that walks into the trie and then leaves it is penalised by up to `maxBoost`
(−4 log-prob ≈ ×0.018 probability), which can drop a correct, acoustically-confident word below
`TranscriptSpan.lowConfidenceThreshold` and change how every downstream stage treats it
(Bet 9 rewrite contract). `leavingTheTrieCanPushACorrectWordBelowTheLowConfidenceThreshold`
measures that; `biasingPerturbsConfidenceNotText` pins the text-invariance.

`Tests/AppTests/ShippingDecoderConfigTests.swift` pins the install path itself, so tests and
`AppContainer` cannot drift apart again.

### Privacy of the harvest

Screen text harvested by `AXTreeSource` lives only in `ContextHarvester.lastEntries` and the
in-memory `BiasPrefixTree`, both rebuilt per utterance and never written to disk (guarded by
`harvestedScreenTextIsNotPersisted`). No screenshots: AX only. `LiveContacts` reads nothing unless
Contacts authorization was already granted elsewhere. The only persisted vocabularies are the user's
own `dictionary` and `corrections` rows in the local SQLite — terms they entered, confirmed, or
imported in onboarding — and nothing here leaves the machine.

## R4.1b — the ranked context list and the refinement prompt

A second path through the same harvest, for the consumer that *can* change a word: a text prompt.

    ContextSources → ContextHarvester → ContextRanker → RankedContext (tiered, deduped, cap 400)
                                                        ├─ PromptBuilder → bounded, sanitised string
                                                        ├─ ContextGate    → should this segment get
                                                        │                   a second pass?
                                                        └─ ContextRecallProbe (measurement only)

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
  `ContextRecallProbe.swift` logs — `ContextPrivacyTests` reads the source to keep that true. What a
  caller *may* log is `RankedContext.shape`, `PromptBuilder.Result.shape` and
  `ContextGate.Decision.summary`: counts and enum cases, never a term.
- `ContextGate` is the consumer today (V3 §7.1): pass-1 confidence plus phonetic near misses of list
  terms (`PhoneticContextIndex`, double metaphone + edit distance, possessive-aware). R5.2 wires the
  refinement pass and R5.3 owns the shipped policy; `PromptBuilder.prompt(for:)` is the call it makes.

### Measured — real-room corpus, 11 September 2026

`Tests/EngineTests/ContextRecallCorpusTests.swift`, Parakeet TDT 0.6B v3 on the twenty real-room
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
