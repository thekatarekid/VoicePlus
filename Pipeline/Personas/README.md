# Pipeline/Personas — P2.5

One plain-English box per app (`Persona.text`), auto-drafted by `PersonaDrafter` from the app's
`StyleProfile` (P1.7 learnings) until the user edits it; edits are never overwritten, clearing the box
reverts to auto-drafting. Per-recipient overrides are keyed by `PersonaRecipient.key` and matched
against `ContextParticipants` (default reads `extra["thread.participants"]`, comma/semicolon separated).

`PersonaManager.decorate(context)` fills `extra["persona"]`, which `PromptBuilder` (Providers) and the
transform/Q&A prompts read. `DatabasePersonaStore` persists in the `personas` table: the box text is the
same `PersonaRecord` row Settings edits; draft state lives in `persona-meta:<bundle>`, overrides in
`persona-recipient:<bundle>:<key>`; `style:` rows belong to `DatabaseStyleProfileStore`.

**V5 F1 — auto-draft loop.** `PersonaLearningLoop.observe(original:fieldValue:bundleID:)` runs when a
landing's zero-edit window closes (`AppContainer`'s `ZeroEditTracker` sink): the user's version of the
dictation (`editedSegment` aligns it inside the field) feeds `StyleLearner`, then the persona is
re-drafted only while `isAutoDrafted`. `StyleProfile.dictationCount` backs Settings' "Learned from N
dictations". A box row saved by Settings after its meta row counts as an edit (never re-drafted).

**V5 F2 — personalisation into prompts.** `PersonaManager.decorate` also fills `personal.dictionary`
(Dictionary spellings; from `DatabasePersonaStore`'s database unless `dictionary` is set) and
`personal.style` (confident learned habits). Consumers render `Personalisation.read(from:).promptBlock`
(a `<personalisation>` delimited block, ≤ 1200 chars) at the point of use — D2 cleanup in Pipeline, CU8
planner from the same keys in Actions. Verbatim app rules (no `persona`, `style.enabled = false`) remove
instructions and habits from every prompt; spellings stay.
