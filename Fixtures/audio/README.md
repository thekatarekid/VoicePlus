# Synthetic audio fixtures

All files here are **generated** by `Fixtures/tools/gen_fixtures.py` (re-runnable, seed `20260823`).
Format: 16 kHz, mono, 16-bit PCM WAV. Total ~10 MB.

## Provenance & licensing
- Speech: macOS built-in text-to-speech (`say`) with voices **Samantha** (en_US), **Daniel** (en_GB),
  **Rishi** (en_IN), converted with `afconvert -f WAVE -d LEI16@16000 -c 1`, silence-trimmed and
  RMS-normalised to about -20 dBFS. Sentences were written for this repo.
- Noise / far-field / silence / clipping: pure Python stdlib (`wave`, `struct`, `random`), no sox.
- **No third-party or recorded human audio.** Fixtures are owned by this project and may be redistributed
  under the repo licence. Apple TTS output is used only as test data, never shipped in the app.

## Suites
| Suite | Files | Purpose |
|---|---|---|
| `clean/` | 12 | General prose / email / chat; WER baseline |
| `entity/` | 10 | Hard entities: TeamViewer AG, Kothari, kubectl, gpt-4o, Anthropic, GRDB, FluidAudio, Devanagari, Sundar Pichai, Zsh |
| `technical/` | 10 | Code / terminal dictation (`git commit dash m`, snake case, paths, camelCase) |
| `commands/` | 10 | Repair / transform commands ("no, Thursday", "scratch that", "put it back"...) |
| `noisy/` | 19 | 8 clean files x {10 dB pink, 0 dB white} SNR + 3 far-field sims (attenuation, echoes, LPF) |
| `vad/` | 6 | Speech spans with 0.5–3 s gaps; ground truth in `labels.json` (3 with -30 dB pink floor) |
| `silence/` | 2 | Digital silence + ~-60 dBFS pink noise (mic-quality / no-speech tests) |
| `clipping/` | 1 | +12 dB gain hard-clipped (~4% samples at full scale) |

Each suite has a `manifest.json`: `[{file, transcript, suite, speaker, notes, [source]}]`.
`vad/labels.json`: `{"spans": {file: [[start_s, end_s], ...]}}`.

Regenerate: `python3 Fixtures/tools/gen_fixtures.py` (add `--skip-tts` to reuse existing TTS wavs and only
rebuild the derived suites). Voices must be installed (`say -v '?'`).
