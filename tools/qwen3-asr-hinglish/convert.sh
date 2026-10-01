#!/usr/bin/env bash
# V5 G1 — convert Srota (moorlee/qwen3-asr-0.6b-hinglish) with the Qwen3-ASR CoreML recipe and install it.
# Needs: uv, git, Xcode CLT (coremlcompiler), >= 6 GB free disk. See README.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODEL_ID="${MODEL_ID:-moorlee/qwen3-asr-0.6b-hinglish}"
WORK="${WORK:-$(mktemp -d)/srota}"
DEST="${DEST:-$HOME/Library/Application Support/VoicePlus/Models/qwen3-asr-0.6b-hinglish}"

free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
if [ "${free_gb:-0}" -lt 6 ]; then echo "need >= 6 GB free (have ${free_gb} GB)"; exit 1; fi

mkdir -p "$WORK/out" "$DEST"
git clone --depth 1 https://github.com/FluidInference/mobius "$WORK/mobius"
cd "$WORK/mobius/models/stt/qwen3-asr-0.6b/coreml"
uv sync

# 1. Audio encoder (the base's `qwen3_asr_audio_encoder_v2`).
uv run python convert-qwen3-asr.py --model-id "$MODEL_ID" --components audio_encoder --output-dir "$WORK/out"
enc=$(find "$WORK/out" -maxdepth 2 -name "*audio_encoder*.mlpackage" | head -1)
# 2. Fused stateful decoder + lm head (macOS 15).
uv run python convert_stateful_decoder.py --model-id "$MODEL_ID" --output-dir "$WORK/out" --skip-validation
dec="$WORK/out/qwen3_asr_decoder_stateful.mlpackage"
# 3. int8, like the base export.
uv run python "$HERE/quantize_int8.py" "$enc" "$WORK/out/qwen3_asr_audio_encoder_v2.mlpackage"
uv run python "$HERE/quantize_int8.py" "$dec" "$WORK/out/q8_decoder.mlpackage"
rm -rf "$dec"; mv "$WORK/out/q8_decoder.mlpackage" "$dec"
# 4. Compile + install.
xcrun coremlcompiler compile "$WORK/out/qwen3_asr_audio_encoder_v2.mlpackage" "$DEST"
xcrun coremlcompiler compile "$dec" "$DEST"
# 5. Embedding table (Swift-side lookup) + tokenizer vocab (byte-identical to the base).
uv run python "$HERE/export_embeddings.py" "$MODEL_ID" "$DEST/qwen3_asr_embeddings.bin"
uv run python -c "from huggingface_hub import hf_hub_download as d; import shutil,sys; shutil.copy(d(sys.argv[1],'vocab.json'), sys.argv[2])" "$MODEL_ID" "$DEST/vocab.json"
echo "installed: $DEST"; ls -la "$DEST"
