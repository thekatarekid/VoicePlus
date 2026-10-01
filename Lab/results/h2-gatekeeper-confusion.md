# H2 · Gatekeeper confusion matrix (2026-10-01)

Set: `Fixtures/gatekeeper/h2-scripted.tsv` — 200 scripted utterances, 50 per class. Notes are expected to route as dictation (the gatekeeper has no note route; note ownership is O2/O3). Threshold tuning only.

## Shipped threshold 0.9

| class \ predicted | dictate | repairCommand | transform | question | none | acc |
|---|---|---|---|---|---|---|
| dictate | 48 | 2 | 0 | 0 | 0 | 0.96 |
| command | 0 | 50 | 0 | 0 | 0 | 1.00 |
| edit | 1 | 0 | 49 | 0 | 0 | 0.98 |
| note | 50 | 0 | 0 | 0 | 0 | 1.00 |

Overall 0.985 · false commands (dictation eaten) 2 · missed commands 1

## Route-threshold sweep

| threshold | accuracy | false commands | missed commands |
|---|---|---|---|
| 0.40 | 0.685 | 44 | 0 |
| 0.45 | 0.765 | 31 | 0 |
| 0.50 | 0.825 | 21 | 0 |
| 0.55 | 0.860 | 17 | 0 |
| 0.60 | 0.900 | 13 | 0 |
| 0.65 | 0.930 | 9 | 0 |
| 0.70 | 0.940 | 9 | 0 |
| 0.75 | 0.950 | 7 | 1 |
| 0.80 | 0.965 | 5 | 1 |
| 0.85 | 0.975 | 4 | 1 |
| 0.90 | 0.985 | 2 | 1 |
| 0.95 | 0.985 | 2 | 1 |

## Misses at the shipped threshold

- dictate → repairCommand: I said I would finish the draft by Monday and I will
- dictate → repairCommand: I think the second option is cheaper overall
- edit → dictate: fix the spelling in this
