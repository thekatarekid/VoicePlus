# Nemotron-Hinglish → CoreML — V5 G1 (second candidate)

Source: [`smajji/nemotron-hinglish-v1`](https://huggingface.co/smajji/nemotron-hinglish-v1) (Apache-2.0),
a NeMo fine-tune of `nvidia/nemotron-3.5-asr-streaming-0.6b` — the base of G2's model — on Hinglish /
Indian English. One `.nemo` file.

Convert with the **same** recipe FluidInference used for G2:
`mobius/models/stt/nemotron-asr-streaming-multilingual-0.6b/coreml/conversion_scripts/convert_nemotron_multilingual.py`
(Linux + CUDA, Python 3.10, `uv`; pins a NeMo fork), at the 1120 ms chunk:

```bash
git clone --depth 1 https://github.com/FluidInference/mobius
cd mobius/models/stt/nemotron-asr-streaming-multilingual-0.6b/coreml/conversion_scripts
uv sync
huggingface-cli download smajji/nemotron-hinglish-v1 nemotron-hinglish-v1.nemo --local-dir .
uv run python convert_nemotron_multilingual.py --help   # then: --nemo-path nemotron-hinglish-v1.nemo at the 1120 ms chunk
uv run python dump_lang_tags.py --nemo-path nemotron-hinglish-v1.nemo   # metadata.json lang tags
# compile each .mlpackage on a Mac: xcrun coremlcompiler compile out/<name>.mlpackage <dest>
```

Install into `~/Library/Application Support/VoicePlus/Models/nemotron-hinglish-v1-1120ms/` with
`encoder.mlmodelc`, `decoder.mlmodelc`, `joint.mlmodelc`, `metadata.json`, `tokenizer.json`
(`NemotronMultilingualFiles.requiredPaths`). If the fine-tune dropped the prompt kernel (plain RNNT,
no `prompt_id`), the multilingual manager cannot load it — check `inspect_model.py` first and use the
English Nemotron recipe/runtime instead.

V1: `lab eval --model hinglish-nemotron --set mucs2021|hiacc` (runs through G2's runtime,
`NemotronHinglishBackend`, prompt `hi`).
