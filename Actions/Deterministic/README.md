# Actions/Deterministic — P4.1 deterministic action layer

Phrase → `ActionCatalog` (200 entries, `catalog.json`) → `ActionRequest` → `ActionExecutor` (precondition → execute → postcondition via AX readback). No model calls on this path.

- `ActionSystem` is the only door to the OS. `LiveActionSystem` = NSWorkspace + AX + CGEvent (needs Accessibility trust; Spaces via Mission Control shortcuts, delivery-only readback). `MockActionSystem` = in-memory desktop (apps/windows/elements/focus/spaces/scroll) used by the offline conformance matrix.
- `FuzzyMatch`: normalized exact / prefix / token-containment / OSA edit distance; `defaultThreshold` 0.72. Used for click-by-name, app/window/tab names and phrase→catalogue.
- Catalogue entry: `id`, `phrasings` (`{arg}` suffix captures a trailing spoken argument, raw text preserved), `category` (mac/browser/editor/chat/mail/files), `reversibility` (reversible/semi/irreversible — consumed by P4.4), `kind`, `params`, `apps` scope. Regenerate with the generator kept in the P4.1 commit message context or edit JSON directly; tests enforce 200 unique, well-formed, unambiguous phrasings.
- `ActionOutcome.success(verified:)` — `verified=false` means the system has no readback for that kind (keystrokes, URL/file open, Mission Control); delivery is the evidence.

Phase gate: `DeterministicConformanceTests` runs 15 mock apps × every applicable action (1398 cells) and asserts ≥99% success; current 100%.
