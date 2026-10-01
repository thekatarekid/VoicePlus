#!/usr/bin/env python3
"""V5 LR2 — convert Auto-AVSR (mpc001/auto_avsr, LRS3) to the CoreML programs AVSRRecognizer loads.

Output (into --out, normally ~/Library/Application Support/VoicePlus/Models/auto-avsr/):
  auto-avsr-avsr.mlmodelc   inputs  video [1,T,88,88] f32 (normalised), audio [1,T*640] f32 (16 kHz)
                            output  ctc_log_probs [1,T,V] f32
  auto-avsr-vsr.mlmodelc    inputs  video [1,T,88,88]       output ctc_log_probs [1,T,V]
  tokens.txt                SentencePiece unigram pieces, one per line, index 0 = <blank>

Only the front-ends + Conformer encoder (+ fusion MLP for AV) + CTC head are exported; the
attention decoder is not — the app runs CTC prefix beam search on the CPU (Engine/Vision).

Licence (LR4): code Apache-2.0; the LRS3-trained weights are NON-COMMERCIAL RESEARCH ONLY.
VoicePlus is non-commercial (owner decision, 1 Oct 2026). See Packaging/model-notices/auto-avsr-NOTICE.txt.

Requires: python 3.10, torch 2.2, coremltools >= 7.2, a checkout of mpc001/auto_avsr on PYTHONPATH,
and the checkpoints the owner downloads by hand (the app never downloads them):
  vsr_trlrs3_base.pth   (visual-only, ~1 GB fp32)   avsr_trlrwlrs2lrs3vox2avsp_base.pth (AV)
Run with --check-disk first: conversion needs ~4 GB of scratch.
"""
import argparse
import shutil
import sys
from pathlib import Path

MAX_FRAMES = 25 * 30   # 30 s of video; flexible shape 1..MAX_FRAMES
SIDE = 88


def build(ckpt: Path, modality: str):
    import torch
    from lightning import ModelModule            # auto_avsr
    from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E  # noqa: F401  (import check)

    class Args:  # the minimal namespace ModelModule reads
        pass
    args = Args()
    args.modality = modality
    module = ModelModule(args)
    state = torch.load(ckpt, map_location="cpu")
    module.model.load_state_dict(state)
    model = module.model.eval()

    class Export(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, video, audio=None):
            v = video.unsqueeze(2)                                # [1,T,1,88,88]
            if modality == "audiovisual":
                a = audio.unsqueeze(-1)                           # [1,N,1]
                vf = self.m.encoder.frontend(v)
                af = self.m.aux_encoder.frontend(a) if hasattr(self.m, "aux_encoder") else a
                x = self.m.fusion(torch.cat([vf, af], dim=-1))
                enc, _ = self.m.encoder(x, None)
            else:
                enc, _ = self.m.encoder(v, None)
            return torch.log_softmax(self.m.ctc.ctc_lo(enc), dim=-1)
    return Export(model).eval(), module.token_list


def convert(ckpt: Path, modality: str, out: Path, name: str):
    import coremltools as ct
    import torch
    net, tokens = build(ckpt, modality)
    T = 50
    ex_video = torch.zeros(1, T, SIDE, SIDE)
    inputs = [ct.TensorType("video", shape=(1, ct.RangeDim(8, MAX_FRAMES), SIDE, SIDE))]
    example = (ex_video,)
    if modality == "audiovisual":
        ex_audio = torch.zeros(1, T * 640)
        inputs.append(ct.TensorType("audio", shape=(1, ct.RangeDim(8 * 640, MAX_FRAMES * 640))))
        example = (ex_video, ex_audio)
    traced = torch.jit.trace(net, example)
    ml = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType("ctc_log_probs")],
                    compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
    pkg = out / f"{name}.mlpackage"
    ml.save(str(pkg))
    compiled = ct.utils.compile_model(str(pkg))
    dest = out / f"{name}.mlmodelc"
    shutil.rmtree(dest, ignore_errors=True)
    shutil.move(compiled, dest)
    shutil.rmtree(pkg, ignore_errors=True)
    (out / "tokens.txt").write_text("\n".join(tokens) + "\n")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--vsr", type=Path, help="visual-only checkpoint")
    p.add_argument("--avsr", type=Path, help="audio-visual checkpoint")
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--check-disk", action="store_true")
    a = p.parse_args()
    free = shutil.disk_usage(a.out if a.out.exists() else Path.home()).free / 2**30
    if a.check_disk or free < 8:
        print(f"free disk: {free:.1f} GiB (need >= 8 GiB to keep the machine healthy)")
        if free < 8:
            sys.exit(1)
    a.out.mkdir(parents=True, exist_ok=True)
    if a.vsr:
        convert(a.vsr, "video", a.out, "auto-avsr-vsr")
    if a.avsr:
        convert(a.avsr, "audiovisual", a.out, "auto-avsr-avsr")


if __name__ == "__main__":
    main()
