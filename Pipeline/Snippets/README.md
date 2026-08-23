# Pipeline/Snippets — P2.6 spoken snippets

`SnippetStoring` (in-memory / `DatabaseSnippetStore` over `SnippetRecord`) — CRUD with validation and
normalized exact matching (`SnippetNormalizer`: lower-case, punctuation stripped, whitespace collapsed).

Routing: `SnippetPreRoute` is a `GatekeeperPreRouting` hook; wrap the local classifier with
`PreRoutingClassifier(hooks: [SnippetPreRoute(store:)])` and pass it as `GatekeeperStage(local:)`.
An exact trigger match routes `.dictate` with confidence 1 before any repair/transform/question rule.
`SnippetStage` (id `snippet`) then expands the trigger — register it first among the dictation stages.
Low-confidence triggers are flagged for repair, not expanded (Bet 9).
