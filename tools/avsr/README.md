# Auto-AVSR → CoreML (V5 LR2 / LR3)

The app never downloads these weights. The owner fetches the checkpoints by hand and converts them.

1. `git clone https://github.com/mpc001/auto_avsr` and install its requirements (torch 2.2) plus `coremltools>=7.2`.
2. Download the LRS3 checkpoints from the auto_avsr model zoo: the visual-only `vsr_trlrs3_base.pth` and the
   audio-visual `avsr_trlrwlrs2lrs3vox2avsp_base.pth`. **Non-commercial research licence** (LR4: accepted, the
   app is non-commercial).
3. `PYTHONPATH=auto_avsr python3 tools/avsr/convert_auto_avsr.py --vsr vsr.pth --avsr avsr.pth \
   --out ~/Library/Application\ Support/VoicePlus/Models/auto-avsr`
4. The folder then holds `auto-avsr-avsr.mlmodelc`, `auto-avsr-vsr.mlmodelc` and `tokens.txt`.
   `AVSRModelLocator` finds them; `CoreMLAVSRModel` loads them only through `ModelResidency`
   (`vision.auto-avsr.avsr` ≈ 620 MB, `vision.auto-avsr.vsr` ≈ 520 MB, both `.onDemand`).

What is exported: the front-ends + Conformer encoder (+ fusion MLP for AV) + CTC head, fp16. The attention
decoder is not exported; the app runs CTC prefix beam search on the CPU (`Engine/Vision/CTCPrefixBeamSearch`).
Expect a few points of WER above the paper's joint CTC/attention numbers.

## LR6 evaluation (needs the owner's LRS3 + MUSAN copies)

`Tests/EngineTests/AVSRRecognizerTests.swift › lrs3Eval` runs when `VOICEPLUS_LRS3_MANIFEST` points at a JSONL
manifest and the models above are installed. One line per utterance:

```json
{"id":"...","crops":"/abs/path/utt.u8","wav":"/abs/path/utt.wav","noise":"/abs/path/musan.wav",
 "ref":"reference text","audio_only_noisy_hyp":"V1-harness Parakeet hypothesis on the 0 dB mix"}
```

`crops` is raw `T×88×88` UInt8 mouth crops at 25 fps (produce them with the same `MouthCropper` over the
video). The test reports lips-only WER, fused WER on the 0 dB MUSAN mix and the audio-only WER, and fails
unless fused beats audio-only. Write the numbers to `Lab/results` with model id, set, date and peak RSS.
