---
license: apache-2.0
tags:
- speech
- audio
- voice
- speaker-diarization
- speaker-change-detection
- coreml
- speaker-segmentation
base_model:
- pyannote/speaker-diarization-3.1
- pyannote/wespeaker-voxceleb-resnet34-LM
---

# Speaker Diarization CoreML Models

State-of-the-art speaker diarization models optimized for Apple Neural Engine, powering real-time on-device speaker separation with research-competitive performance.

Support any language, models are trained on acoustic signatures

## Model Description

This repository contains CoreML-optimized speaker diarization models specifically converted and optimized for Apple devices (macOS 13.0+, iOS 16.0+). These models enable efficient on-device speaker diarization with minimal power consumption while maintaining state-of-the-art accuracy.

## Usage

See the SDK for more details [https://github.com/FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)

### With FluidAudio SDK (Recommended)

Installation
Add FluidAudio to your project using Swift Package Manager:

```
dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.0.2"),
],
```

```swift
import FluidAudio

Task {
    let diarizer = DiarizerManager()
    try await diarizer.initialize()
    
    let audioSamples: [Float] = // your 16kHz audio
    let result = try await diarizer.performCompleteDiarization(
        audioSamples, 
        sampleRate: 16000
    )
    
    for segment in result.segments {
        print("Speaker \(segment.speakerId): \(segment.startTimeSeconds)s - \(segment.endTimeSeconds)s")
    }
}


### Direct CoreML Usage
``swift
import CoreML

// Load the model
let model = try! SpeakerDiarizationModel(configuration: MLModelConfiguration())

// Prepare input (16kHz audio)
let input = SpeakerDiarizationModelInput(audioSamples: audioArray)

// Run inference
let output = try! model.prediction(input: input)
```


## Acknowledgments
These CoreML models are based on excellent work from:

sherpa-onnx - Foundational diarization algorithms
pyannote-audio - State-of-the-art diarization research
wespeaker - Speaker embedding techniques


### Key Features
- **Apple Neural Engine Optimized**: Zero performance trade-offs with maximum efficiency
- **Real-time Processing**: RTF of 0.02x (50x faster than real-time)
- **Research-Competitive**: DER of 17.7% on AMI benchmark
- **Power Efficient**: Designed for maximum performance per watt
- **Privacy-First**: All processing happens on-device


## Intended Uses & Limitations

### Intended Uses
- **Meeting Transcription**: Real-time speaker identification in meetings
- **Voice Assistants**: Multi-speaker conversation understanding
- **Media Production**: Automated speaker labeling for podcasts/interviews
- **Research**: Academic research in speaker diarization
- **Privacy-Focused Applications**: On-device processing without cloud dependencies

### Limitations
- Optimized for 16kHz audio input
- Best performance with clear audio (no heavy background noise)
- May struggle with heavily overlapping speech
- Requires Apple devices with CoreML support

### Technical Specifications
- **Input**: 16kHz mono audio
- **Output**: Speaker segments with timestamps and IDs
- **Framework**: CoreML (converted from PyTorch)
- **Optimization**: Apple Neural Engine (ANE) optimized operations
- **Precision**: FP32 on CPU/GPU, FP16 on ANE

## Training Data

These models are converted from open-source variants trained on diverse speaker diarization datasets. The original models were trained on:
- Multi-speaker conversation datasets
- Various acoustic conditions
- Multiple languages and accents

*Note: Specific training data details depend on the original open-source model variant.*