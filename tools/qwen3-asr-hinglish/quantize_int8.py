"""V5 G1 — int8 weight-only quantisation, as the base `qwen3-asr-0.6b/int8` export
(mobius QWEN3_ASR_COREML.md, "Int8 Quantization (Revisited)")."""
import sys

import coremltools as ct
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

src, dst = sys.argv[1], sys.argv[2]
config = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric"))
linear_quantize_weights(ct.models.MLModel(src), config=config).save(dst)
print(f"{dst}: int8")
