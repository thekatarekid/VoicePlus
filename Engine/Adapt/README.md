# Engine/Adapt — personal adaptation loop + learned lexicon (P6.1, P6.2)

- `TrainingPairStore`: append-only JSONL of `(audio-span, corrected-text)` pairs + WAV clips
  under `AppPaths.supportDirectory()/Adapt`; `ingest(CorrectionRecord)` for repair/dual-path
  events, `ingestEdit(spans:editedText:)` word-diffs post-dictation edits (`WordDiff`).
  Audio comes through `UtteranceAudioProvider` (live = capture ring; tests = in-memory).
- `AdapterTrainer`: `BiasListLearner` (default; saturating term weights + misheard→corrected
  variants → `PersonalLexicon`) and `LoRAAdapterStub` (interface only; reports
  `.infeasible` with the reason, logged to `LabRunRecord`). `AdaptationLoop.retrain()` tries
  LoRA then bias list, persists `lexicon.json`; `LearnedLexiconSource` feeds the Biasing ranker.
- `PersonalWERTracker`: per-day WER on the user's own corrections → Lab "you" tab record.
- `PronunciationCapture` ("Train by voice"), `RememberToastModel` (once per word, persisted),
  `RegressionGuard` (stage `adapt.lexicon`: exact/Double-Metaphone substitution with confidence
  carry-over; original text kept as a `.repair` alternate).
