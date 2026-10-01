# Error pairs (V5 B4) — evaluation only

One JSON line per utterance a model got wrong in a V1 public-set run: `set, model, id, tags`
(condition: `snr-*`, `noise-*`, …), `reference`, `hypothesis`, `errors`, `referenceWords`, and the
aligned word `edits` (`sub`/`del`/`ins`, Open-ASR-normalised). Never used for training or shipped.

- `librispeech-test-clean.jsonl` — Parakeet TDT v3, 671 / 2620 utterances (V1 run, WER 2.08 %).
- `librispeech-test-clean-noisy.jsonl` — Parakeet TDT v3, 184 / 450 (V3 babble/pink × 20/10/5/0 dB).

Regenerate: `lab pairs --set <set> --model <id> --hyp <cache>/<set>/hyp-<id>.json`, or
`lab eval … --pairs`. Re-running a (set, model) replaces that model's lines only.
