# VoicePlus docs index

The living documents stay at the repo root:

| Doc | What it is |
|---|---|
| [`PRODUCT-SPEC.md`](../PRODUCT-SPEC.md) | Why: the product definition (v4). |
| [`DESIGN.md`](../DESIGN.md) | Everything visible, in the terms the Swift code uses. Tests read it. |
| [`DECISIONS.md`](../DECISIONS.md) | Flag defaults and kill-criteria readings, dated. |
| [`progress.md`](../progress.md) | Build log since 2026-09-30 (older entries in [`history/`](history/)). |
| [`CLAUDE.md`](../CLAUDE.md) | Agent conventions and toolchain. |

Everything else lives here. Filenames are unchanged from when they were written, so a citation like
"`VoicePlus_ContextWriter_Plan.md` §6" in code still finds the file by name.

## Timeline: plan → release

| Wave | Plan / build docs (`plans/`) | Shipped as | Release notes |
|---|---|---|---|
| Phases 0–6 | `VoicePlus_Build.md` (item IDs P0.x–P6.x) | 0.0.1 – 1.7.15 | `Packaging/notes/phase-0` … `phase-6-1.7.15` |
| V1, V2 | `VoicePlus_Improvements_V1.md`, `_V2.md` | planning that preceded V3 | — |
| V3 | `VoicePlus_Improvements_V3.md`, `_V3_Build.md` | 1.8.0 – 1.10.0 | `phase-V3-w01`, `-w2`, `-w34` |
| V4 Wave 1 + Spool design | `VoicePlus_Improvements_V4.md`, `VoicePlus_ImplementationBuild_V4_Wave1+Design.md` (+ `_Pending`) | 1.11.0 – 1.12.12 | `phase-V4-w1`, `phase-V3-Spool-Full` |
| V5 | `VoicePlus_Improvements_V5.md`, `_V5_Build.md` | 1.13.0 | `progress.md` |
| N-fixes | `investigations/VoicePlus_Investigation_2026-10-01.md`, `-10-02.md` | 1.14.0 | `progress.md` |
| H-fixes | `investigations/VoicePlus_Investigation_2026-10-03.md` | 1.15.0 – 1.15.5 | `progress.md` |
| **Context Writer (current)** | `VoicePlus_ContextWriter_Plan.md` (follows `investigations/…-10-06.md`) | 1.16.0 (step 1) | `progress.md` |

## Folders

| Folder | Contents | Status |
|---|---|---|
| `plans/` | Build plans and improvement waves listed above. | Done, except Context Writer. |
| `investigations/` | Dated root-cause write-ups that preceded each fix wave. | Done. |
| `research/` | Model research V1/V2 (multilingual), public corpora, FluidAudio API notes. | Reference. |
| `testing/` | `VoicePlus_HumanTest.md`: the manual test plan (V5). | Reference. |
| `reviews/` | `SECURITY-REVIEW.md` (Phase 1). | Reference. |
| `design-history/` | Earlier UI/UX docs, signature-pill concepts, and `design/` (Underline, Spool v1–v3, mascots). `design/design_v3.*` is still the top design authority (see `DESIGN.md` §0) and tests read it. | Superseded by `DESIGN.md`, kept as source. |
| `history/` | Archived `progress.md` entries. | Archive. |

Elsewhere: signing and TCC in [`Packaging/SIGNING.md`](../Packaging/SIGNING.md); release notes in `Packaging/notes/`; per-module notes in each module's `README.md`; eval results in `Lab/results/`.

## Adding a doc

- Investigation: `docs/investigations/VoicePlus_Investigation_YYYY-MM-DD.md`
- Plan or build doc: `docs/plans/`; add a row to the timeline above.
- Research: `docs/research/`
