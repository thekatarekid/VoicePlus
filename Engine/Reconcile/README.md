# Engine/Reconcile — dual-path silent correction (Bet 4, P1.5.1)

`DualPathRunner` runs the fast preview (`PreviewRecognizer`) and the accurate final pass
(`FinalRecognizer`) concurrently over the same audio; `DualPathTiming` (overlap / contention
ratio) is the ANE-contention profiling hook. `PreviewTimeline` gives preview words approximate
audio ranges (no timing/confidence upstream). `WordAligner` aligns preview vs final with an
audio-overlap-aware edit distance and groups mismatches into `Disagreement`s.
`CorrectionPlanner` decides per region: drop (case/punct-only, small delta), suggest
(low-confidence final, readback unavailable, **safety-rule mismatch**), or correct.
`CorrectionApplier` writes through `ReplaceRangeSink` (Injection re-checks `expected`), emits
`CorrectionEvent`s to a `CorrectionEventSink` (P1.5.2 UX). `DualPathReconciler` gates on
`FeatureFlag.dualPath`. Readback is abstracted as `DocumentReadback` (production: AX value).
