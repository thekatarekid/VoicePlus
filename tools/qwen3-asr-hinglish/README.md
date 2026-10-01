# Srota (Hinglish Qwen3-ASR) → CoreML — V5 G1

Source: [`moorlee/qwen3-asr-0.6b-hinglish`](https://huggingface.co/moorlee/qwen3-asr-0.6b-hinglish)
(Apache-2.0), a fine-tune of `Qwen/Qwen3-ASR-0.6B` on HiACC + OpenSLR-104 (MUCS-2021).
Same architecture, tokenizer (`vocab.json` byte-identical, 2,776,833 bytes) and chat template as the
base model, so the **existing Qwen3-ASR CoreML path** converts it unchanged: FluidInference's
`mobius/models/stt/qwen3-asr-0.6b/coreml/convert-qwen3-asr.py` (the converter that produced the base
`qwen3-asr-0.6b/int8` our `Qwen3AsrManager` already loads), pointed at the fine-tune with `--model-id`.

Publisher-reported WER (their `eval.json`, not ours): HiACC test 15.8 % (base 24.7 %),
MUCS-2021 test 35.1 % (base 50.7 %). Output: Hindi in Devanagari, English in Latin — G3's
`ScriptOutputStage` writes the user's script.

## Steps (owner, one machine with ~6 GB free; the safetensors alone are 1.56 GB)

```bash
./convert.sh            # clones mobius, converts, quantises int8, installs into VoicePlus' models root
```

What it does (`convert.sh`, all steps from the base model's mobius recipe):
1. `git clone --depth 1 https://github.com/FluidInference/mobius`; `uv sync` in `models/stt/qwen3-asr-0.6b/coreml`.
2. Audio encoder: `convert-qwen3-asr.py --model-id moorlee/qwen3-asr-0.6b-hinglish --components audio_encoder`.
3. Decoder: `convert_stateful_decoder.py --model-id moorlee/qwen3-asr-0.6b-hinglish` (fused stateful decoder + lm head).
4. int8 weight-only quantisation of both (`quantize_int8.py`, the mobius "Int8 Quantization (Revisited)" config).
5. `xcrun coremlcompiler compile` both into
   `~/Library/Application Support/VoicePlus/Models/qwen3-asr-0.6b-hinglish/`, then
   `export_embeddings.py` writes `qwen3_asr_embeddings.bin` (uint32 vocab, uint32 hidden, fp16 table —
   the `Qwen3EmbeddingWeights` format) and the fine-tune's `vocab.json` is copied beside them
   (`HinglishASRFiles.folderName`, `Qwen3WeightsLayout.requiredPaths`).

Untested here (disk-bound machine; no download > 500 MB allowed): run once, then check the file names
`convert-qwen3-asr.py` writes for the encoder (the script picks up `*audio_encoder*.mlpackage`).

VoicePlus then finds it (`ModelID.qwen3AsrHinglish`, `HinglishASRFactory`) and routes dictation to it
whenever Hindi is one of the LANG1 languages.

## Publishing (so other users download it)
Upload the four items to a HF repo, set `HinglishASRFiles.publishedCoreMLRepo` and give the catalog
entry its `remoteFiles` (path + size + sha256 from the upload). Until then the catalog never fetches it.

## V1 (G1 acceptance)
```bash
lab eval --model hinglish-srota --set mucs2021
lab eval --model hinglish-srota --set hiacc
lab eval --model hinglish-nemotron --set mucs2021   # the other candidate, see ../nemotron-hinglish
```
Results land in `Lab/results/`. If Nemotron-Hinglish wins on both sets, flip
`HinglishASRCandidate.shipped`.
