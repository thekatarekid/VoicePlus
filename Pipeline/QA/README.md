# Pipeline/QA — P2.4 Q&A on selection

`QuestionAnswerStage` (id `question`, same raw value as P2.1's `.question`) answers a question about the
current selection. Inputs: the question spans + `StageContext.extra["selection.text"]` (and optional
`"selection.context"`). Output (`answer(_:context:)` → `QuestionAnswerOutput`):

- `spans`: the question spans with provenance stamped (never rewritten) + one appended answer span
  `"answer: …"` (confidence 1, zero-length audio range at the utterance end).
- `intent`: `.insertBelow(selectionLength:)` — the injector inserts `insertion` (`"\nanswer: …"`) after the
  selection's end; the selection is never replaced. `.none` when there is no selection/answer.

Answerers: `ProviderAnswerer` (via `PipelineProviderRouting`, persona-aware prompt, falls back) and
`HeuristicAnswerer` (offline: counts, gist, keyword sentence lookup, or an honest "can't answer offline").
