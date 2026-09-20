---
license: other
license_name: nvidia-open-model-license
license_link: >-
  https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/
language:
- en
metrics:
- wer
library_name: nemo
tags:
- speech-recognition
- FastConformer
- end-of-utterance
- voice agent
pipeline_tag: automatic-speech-recognition
base_model:
- nvidia/parakeet_realtime_eou_120m-v1
base_model_relation: finetune
---


# Parakeet Realtime EOU 120M — CoreML

CoreML conversion of [nvidia/parakeet-realtime-eou-120m-v1](https://huggingface.co/nvidia/parakee
t-realtime-eou-120m-v1) for streaming speech recognition with end-of-utterance detection on Apple
 Silicon.

Used by [FluidAudio](https://github.com/FluidInference/FluidAudio) for real-time transcription.

## Models

The RNNT pipeline is split into three CoreML models, exported at two chunk sizes:

| Model | Description |
|-------|-------------|
| `streaming_encoder.mlmodelc` | FastConformer encoder with loopback state caching |
| `decoder.mlmodelc` | 1-layer LSTM decoder (640 hidden units) |
| `joint_decision.mlmodelc` | Joint network for token prediction + EOU detection |

### Chunk Size Variants

| Variant | Latency | WER (test-clean) | RTFx (M2) |
|---------|---------|-------------------|------------|
| `160ms/` | 160ms | 8.29% | 4.78x |
| `320ms/` | 320ms | 4.87% | 12.48x |

Benchmarked on LibriSpeech test-clean (2620 files, 5.40h audio) on Apple M2.

## Usage with FluidAudio

```swift
import FluidAudio

let manager = StreamingEouAsrManager()
await manager.initialize()

// Transcribe with EOU detection
await manager.startStreaming(
    eouCallback: { transcript in
        print("Utterance complete: \(transcript)")
    },
    partialCallback: { partial in
        print("Partial: \(partial)")
    }
)

// Feed audio chunks as they arrive
await manager.feedAudio(samples)
```

CLI

# Transcribe a file
swift run fluidaudio parakeet-eou --input audio.wav

# Benchmark
swift run -c release fluidaudio parakeet-eou --benchmark --chunk-size 320

Architecture

120M parameter RNNT (Recurrent Neural Network Transducer) with:
- Encoder: 17-layer FastConformer with cache-aware streaming
- Decoder: 1-layer LSTM, 640 hidden size
- Joint: Linear projection with 1027 output classes (1024 tokens + EOU token + SOS + blank)
- EOU token: ID 1024 signals end-of-utterance

Streaming State

The encoder maintains loopback state between chunks:
┌─────────────────────┬──────────────────┬───────────────────────┐
│        State        │      Shape       │      Description      │
├─────────────────────┼──────────────────┼───────────────────────┤
│ preCache            │ [1, 128, N]      │ Mel-level context     │
├─────────────────────┼──────────────────┼───────────────────────┤
│ cacheLastChannel    │ [17, 1, 70, 512] │ Conformer layer cache │
├─────────────────────┼──────────────────┼───────────────────────┤
│ cacheLastTime       │ [17, 1, 512, 8]  │ Temporal cache        │
├─────────────────────┼──────────────────┼───────────────────────┤
│ cacheLastChannelLen │ [1]              │ Cache length tracking │
└─────────────────────┴──────────────────┴───────────────────────┘
Export

Converted from PyTorch using coremltools. To re-export:

python3 Scripts/ParakeetEOU/Conversion/convert_split_encoder.py \
  --output-dir Models/ParakeetEOU \
  --model-id nvidia/parakeet-realtime-eou-120m-v1

License

NVIDIA Open Model License — see
https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/.

Original model: https://huggingface.co/nvidia/parakeet-realtime-eou-120m-v1

---