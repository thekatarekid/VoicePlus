# Actions/Deixis, Referents, Elicitation (P3.3 / P3.5 / P3.6)

- `DeixisResolver` — for each deictic `TranscriptSpan` (this/that/these/those/here/there): audio midpoint
  → `CaptureAlignment` → timeline instant (minus a small gesture lead) → ink bundle in ±0.6 s wins
  (`RegionReference`: bounds, centroid, covered elements) else `InputTimeline.pointer(at:)` → `AXHitTesting`
  → `ElementReference`; near-miss ranks by distance and flags `isAmbiguous` when two are within `ambiguityDelta`.
  `DeixisBinding.contextLine` is what the pipeline/actions receive.
- `AXHitTesting` — `MockAXHitTester` (flat rect list) for tests; `LiveAXHitTester` wraps
  `AXUIElementCopyElementAtPosition` (Quartz↔Cocoa via `DisplayNormalizer`), guarded by `AXIsProcessTrusted`.
- `ReferentResolver` — pronouns → `ContextParticipants` by gender/salience; "the deck/file/…" → `VisibleArtifact`
  by kind/salience; providers are protocols (`ParticipantProviding`, `ArtifactProviding`) so the AX layer plugs in.
- `ReverseElicitation` — pure state machine: `.ask` → `.prompting` (rings + "which one?") → `.point`/`.speech`
  → `.resolved`, or `.tick` past deadline → `.timedOut(clarifyingText:)` for the pill.
Not wired into the coordinator/overlay (App composition root is owned by the App agent).
