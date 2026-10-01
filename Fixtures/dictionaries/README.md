# Public dictionaries (V5 P1–P7)

Public lists fix casing/formatting of words already recognised; they never feed decode-time boosting.

| Item | File / source | Shipped? | Licence |
|---|---|---|---|
| P1 | macOS Text Replacements (`NSSpellChecker.userReplacementsDictionary`) | read at runtime | user's own data |
| P3 | `casing.txt` (13.5 k canonical names) → compiled into `Pipeline/Dictionaries/CasingLexicon+Bundled.swift` | yes, ~120 KB | Wikidata CC0; Homebrew cask metadata BSD-2-Clause |
| P4 | CMUdict `cmudict.dict` (3.6 MB) | no — downloaded on request into `~/Library/Application Support/VoicePlus/Dictionaries/` | BSD-2-Clause, © Carnegie Mellon University |
| P4 | `cmudict-sample.dict` (40 lines, test fixture) | tests only | BSD-2-Clause, © Carnegie Mellon University |
| P5 | SCOWL/ESDB size-50 word list (0.8 MB) | no — downloaded on request; fallback `/usr/share/dict/words` (public domain, ships with macOS) | SCOWL licence, © Kevin Atkinson (notice in `PublicDictionaryCatalog.scowl`) |
| P6 | IndicXlit (AI4Bharat) | no — needs a Core ML conversion; rule-based Devanagari fallback in code | MIT |
| P7 | GLiNER2-small Core ML (FluidInference, via FluidUse) | no — used only when weights are already on disk | Apache-2.0 |

All notices are in `PublicDictionaryCatalog.notices`, shown under Settings › Dictionary › Public word lists › Licences.

## Regenerating `casing.txt`

```
python3 Fixtures/dictionaries/generate_casing.py            # Wikidata SPARQL + Homebrew casks, ~2 min
python3 Fixtures/dictionaries/generate_casing.py --swift-only   # re-emit the compiled copy only
```

The generator keeps one-token names that are not all lowercase and whose lowercase form is not an
English word (`/usr/share/dict/words` + regular inflections; a top-10k frequency list, fetched at
generation time only, removes Titlecase/all-caps forms of frequent words such as "Zen", "MAX").
`casing-supplement.txt` is hand-curated (iPhone, macOS, …) and bypasses the English-word filter.

npm / PyPI / Homebrew-formula names are lowercase by convention and carry no casing information,
so they are not used (deviation from the V5 P3 wording, which lists them as sources). The list is
13.5 k entries rather than ~20 k: the English-word filter is deliberately strict, since a wrong
entry re-cases ordinary speech.
