# Public evaluation sets (V5 §V, V1)

Audio is never committed. `lab fetch --set <name>` downloads to
`~/Library/Application Support/VoicePlus/Eval/<name>/` (override: `VOICEPLUS_EVAL_CACHE`) and writes
`manifest.json` there. A small hand-written manifest may live here as `public/<name>/manifest.json`;
it wins over the cache copy. `lab datasets` lists the catalogue (fetchable / gated / large).

Manifest: `{ set, language, audioRoot, licence, source, items: [{ id, audio, reference, tags, entities?, input?, label?, segments? }] }`
— `audioRoot` is relative to the eval cache; `tags` are the condition breakdown in reports.

Real-model run (Lab cannot link Engine):
1. `VOICEPLUS_EVAL_FETCH=librispeech-test-clean swift test --filter PublicEvalAcceptanceTests`
2. `VOICEPLUS_EVAL_SET=librispeech-test-clean swift test --filter EvalPublicSetTests` → `hyp-parakeet-tdt-v3.json`
3. `VOICEPLUS_EVAL_SET=librispeech-test-clean VOICEPLUS_EVAL_HYP=<cache>/librispeech-test-clean/hyp-parakeet-tdt-v3.json swift test --filter PublicEvalAcceptanceTests`
   → `lab eval --gate` table + `Lab/results/<date>-<set>-parakeet-tdt-v3.json`.
In the app, `parakeet-tdt-v3` is a registered eval backend (`LabWiring`).

Noise (V3): `lab mix --set librispeech-test-clean --limit 50` (opt-in test: `VOICEPLUS_EVAL_MIX=<set>
VOICEPLUS_EVAL_LIMIT=50 swift test --filter NoiseMixAcceptanceTests`) writes `<cache>/<set>-noisy/`:
the clean items (`snr-clean`) + babble (3 other LibriSpeech talkers) and pink noise at 20/10/5/0 dB,
seeded, tagged `snr-<dB>` / `noise-<kind>`. MUSAN (FluidInference mirror, `noise/` only) plugs in with
`--noise-dir <dir>` once the owner has disk for it (T1); tags `noise-musan`.
