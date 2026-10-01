# V4 re-validation — librispeech-test-clean-noisy · 2026-10-01 · Apple M2 Pro / Version 26.6.2 (Build 25G83) / 16 GB

| condition | n | final WER % | preview EOU WER % | preview polling WER % | analyzer good/poor/bad | analyzer SNR median dB |
|---|---|---|---|---|---|---|
| clean | 50 | 1.65 | 8.37 | 4.83 | 50/0/0 | 42.82 |
| babble@snr-20 | 50 | 3.07 | 10.14 | 5.90 | 50/0/0 | 33.99 |
| babble@snr-10 | 50 | 9.91 | 25.71 | 14.27 | 50/0/0 | 31.36 |
| babble@snr-5 | 50 | 17.22 | 56.01 | 22.05 | 49/0/0 (+1 none) | 30.64 |
| babble@snr-0 | 50 | 69.93 | 89.86 | 69.10 | 44/0/0 (+6 none) | 27.53 |
| pink@snr-20 | 50 | 1.65 | 9.20 | 4.36 | 50/0/0 | 29.20 |
| pink@snr-10 | 50 | 1.65 | 10.14 | 4.83 | 49/0/0 (+1 none) | 19.84 |
| pink@snr-5 | 50 | 2.95 | 19.22 | 5.42 | 39/0/0 (+11 none) | 15.23 |
| pink@snr-0 | 50 | 6.01 | 34.32 | 9.55 | 1/0/0 (+49 none) | 13.86 |

| preview | WER % (all conditions) | first word p50 ms | p95 ms | never a word | CPU s / audio s |
|---|---|---|---|---|---|
| preview-eou | 29.22 | 533 | 1575 | 58 | 0.16 |
| preview-polling | 15.59 | 817 | 2091 | 3 | 0.08 |
| parakeet-tdt-v3 (final, reference) | 12.67 | 0 | 0 | 0 | – |

| segment class (clean, final) | n | WER % |
|---|---|---|
| < 5 s | 26 | 1.26 |
| 5–7 s | 11 | 1.60 |
| ≥ 7 s | 13 | 1.90 |
| entities | 50 | 1.65 |
| number words | 5 | 0.00 |
| technical | 1 | 0.00 |

mic quality: WER ≥ 2× clean (1.65%) in 4/8 noisy conditions; current bounds flag 0% of those utterances poor/bad and 0% of the conditions that stay near clean. Analyzer SNR median: degraded max 31.4 dB, near-clean min 15.2 dB.
note: SNR = whole-utterance power ratio of the V3 mix (Kaldi convention); the analyzer estimates p90 speech frames over p10 floor, so its dB read higher.
note: qwenRefinement not re-measured: Qwen3-ASR 0.6B int8 weights (1.2 GB) are not on disk and the disk budget forbids the download → T1.