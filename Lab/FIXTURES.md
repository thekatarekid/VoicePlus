# Lab fixtures — provenance, gaps, licensing

The harness (`Lab/Harness`) scores every directory under `Fixtures/audio/` that has a
`manifest.json` (`[{file, transcript, suite, speaker?, notes?, source?, entities?}]`).
`entities` is optional: when present it is the curated entity list used for entity recall;
when absent `EntityScorer.detectEntities` derives one from the reference (capitalised
non-sentence-initial tokens, mixed-case / digit / hyphen tokens, and a known list).

## What exists today (synthetic, project-owned)

| Suite | Files | Provenance | Licence |
|---|---|---|---|
| clean, entity, technical, commands | 42 | macOS `say` TTS (Samantha en_US, Daniel en_GB, Rishi en_IN); sentences written for this repo; `Fixtures/tools/gen_fixtures.py`, seed 20260823 | Project licence. Apple TTS output used as test data only, never shipped |
| noisy | 19 | Derived from `clean/` with stdlib-generated pink/white noise (10 dB / 0 dB SNR) and far-field simulation | Project licence |
| vad, silence, clipping | 9 | Stdlib-generated; engine-level fixtures (not scored by the harness by default) | Project licence |

See `Fixtures/audio/README.md` for the generator details.

Limits of the synthetic set: TTS speech is over-articulated, has no disfluencies, no real
accent variation beyond the three voices, no cross-talk, no real room acoustics. Scores on
it are an upper bound. **Kill-criteria decisions (PRODUCT-SPEC Part 5) must not be taken on
synthetic data alone.**

## Real-world suites still needed (T2 backlog)

| Suite (dir) | Content | Candidate source | Licence status |
|---|---|---|---|
| `calls/` | Earnings-call style audio, 2–10 min, multiple speakers, phone bandwidth | Earnings-22 (Rev.com) | CC-BY-4.0 — redistributable with attribution; verify per-file before inclusion |
| `accent_indic/` | Indian-English dictation, native speakers, real mics | Svarah (AI4Bharat) or self-recorded with consent | Svarah: CC-BY-4.0. Self-recorded: need written consent + release per speaker |
| `accent_other/` | Scottish, Nigerian, Singaporean, Australian English | Common Voice (Mozilla) subsets | CC0 — redistributable |
| `code_dictation/` | Real developers dictating code/terminal commands | Self-recorded (contributors) | Contributor release; record the spoken form *and* the intended text |
| `meetings/` | Far-field laptop mic, 2–4 speakers, cross-talk | AMI corpus | CC-BY-4.0 |
| `noisy_real/` | Café, street, keyboard typing, HVAC | Self-recorded; or mix DEMAND noise (CC-BY-SA-4.0) into consented speech | DEMAND is share-alike: keep derived files in a clearly marked directory |
| `entities_real/` | Names, products, commands from actual users' dictionaries | Self-recorded, per-user opt-in only | Never redistribute without explicit release; keep out of the public harness repo |

Rules for adding a suite:
1. One directory per suite, 16 kHz mono 16-bit WAV, `manifest.json` with `source` filled in
   (dataset name + licence + URL, or "self-recorded, release on file: <id>").
2. Add `entities` explicitly for anything where the heuristic would be wrong
   (e.g. lowercase product names, acronyms pronounced as words).
3. Reference transcripts are verbatim (no formatting), since the harness scores after the
   pipeline too — formatters should be evaluated via `--stages` against `Fixtures/transcripts`
   style expectations, not by editing the audio manifest.
4. Anything not redistributable stays out of git (`Fixtures/private/`, git-ignored) and out
   of the published harness (T6); the published artifact is the harness code + synthetic suites
   + pointers to the public datasets above.
