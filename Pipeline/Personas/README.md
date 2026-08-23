# Pipeline/Personas — P2.5

One plain-English box per app (`Persona.text`), auto-drafted by `PersonaDrafter` from the app's
`StyleProfile` (P1.7 learnings) until the user edits it; edits are never overwritten, clearing the box
reverts to auto-drafting. Per-recipient overrides are keyed by `PersonaRecipient.key` and matched
against `ContextParticipants` (default reads `extra["thread.participants"]`, comma/semicolon separated).

`PersonaManager.decorate(context)` fills `extra["persona"]`, which `PromptBuilder` (Providers) and the
transform/Q&A prompts read. `DatabasePersonaStore` persists in the `personas` table: the box text is the
same `PersonaRecord` row Settings edits; draft state lives in `persona-meta:<bundle>`, overrides in
`persona-recipient:<bundle>:<key>`; `style:` rows belong to `DatabaseStyleProfileStore`.
