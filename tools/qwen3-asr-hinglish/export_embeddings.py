"""V5 G1 — write qwen3_asr_embeddings.bin for VoicePlus' Qwen3 port from a Qwen3-ASR safetensors.

Format (Engine/ASRRuntime/Qwen3ASR/Qwen3AsrModels.swift, Qwen3EmbeddingWeights):
uint32 vocabSize, uint32 hiddenSize, then float16[vocabSize * hiddenSize], little endian.
"""
import struct
import sys

import numpy as np
from huggingface_hub import hf_hub_download
from safetensors.numpy import load_file

model_id, out = sys.argv[1], sys.argv[2]
tensors = load_file(hf_hub_download(model_id, "model.safetensors"))
key = next(k for k in tensors if k.endswith("embed_tokens.weight"))
w = tensors[key].astype(np.float16)
vocab, hidden = w.shape
assert (vocab, hidden) == (151936, 1024), f"unexpected embedding shape {w.shape} at {key}"
with open(out, "wb") as f:
    f.write(struct.pack("<II", vocab, hidden))
    f.write(w.tobytes())
print(f"{out}: {key} {vocab}x{hidden}")
