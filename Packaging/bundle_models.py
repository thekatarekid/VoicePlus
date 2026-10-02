#!/usr/bin/env python3
"""Stage the default model stack from a verified local cache; no personal data or downloads.
Every manifest path is constrained to its model folder and every byte re-hashed before copying.
Usage: bundle_models.py SOURCE_MODELS_ROOT DESTINATION_MODELS_ROOT [--verify-only]
       bundle_models.py --vad DESTINATION_MODELS_ROOT   (V5 C6: the checked-in Silero VAD, every build)
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

STACK = {
    'parakeet-tdt-0.6b-v3': ('parakeet-tdt-0.6b-v3-coreml', ['Preprocessor.mlmodelc', 'Encoder.mlmodelc', 'Decoder.mlmodelc', 'JointDecisionv3.mlmodelc', 'parakeet_vocab.json']),
    'parakeet-realtime-eou-120m-coreml-160ms': ('parakeet-realtime-eou-120m-coreml-160ms', ['streaming_encoder.mlmodelc', 'decoder.mlmodelc', 'joint_decision.mlmodelc', 'vocab.json']),
    'speaker-diarization': ('speaker-diarization-coreml', ['pyannote_segmentation.mlmodelc', 'wespeaker_v2.mlmodelc']),
}

# N6 — the CTC vocabulary-boosting model (CC-BY-4.0, ~98 MB). Bundled when the source has it, and
# required for FULL_INSTALLER (`--require-boost`), so a full install never downloads or compiles it
# inside a dictation. Folder = FluidAudio Repo.parakeetCtc110m.folderName.
BOOST = {'parakeet-ctc-110m-coreml': ('parakeet-ctc-110m-coreml', ['AudioEncoder.mlmodelc', 'MelSpectrogram.mlmodelc', 'vocab.json', 'tokenizer.json'])}

# V5 C6 — Silero VAD (MIT, ~1 MB) is checked in under Packaging/vad/ and ships in *every* bundle,
# thin or full, so no install ever falls back to the energy VAD. Folder = FluidAudio Repo.vad.folderName.
VAD = {'silero-vad': ('silero-vad-coreml', ['silero-vad-unified-256ms-v6.2.1.mlmodelc'])}
VAD_SOURCE = Path(__file__).resolve().parent / 'vad'

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def verified_files(folder, model_id, required):
    folder = folder.resolve()
    manifest_path = folder / 'voiceplus-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest['modelID'] != model_id or not manifest['files']:
        raise ValueError(f'{folder.name}: wrong or empty manifest')
    paths = []
    for entry in manifest['files']:
        relative = Path(entry['path'])
        path = folder / relative
        if relative.is_absolute() or '..' in relative.parts or path.is_symlink() or not path.resolve().is_relative_to(folder):
            raise ValueError(f'{folder.name}: unsafe manifest path')
        if not path.is_file() or path.stat().st_size != entry['size'] or digest(path) != entry['sha256']:
            raise ValueError(f'{folder.name}: integrity mismatch: {relative}')
        paths.append(relative)
    for required_path in required:
        key = Path(required_path)
        if key.suffix == '.mlmodelc':
            if key / 'coremldata.bin' not in paths:
                raise ValueError(f'{folder.name}: incomplete {required_path}')
        elif key not in paths:
            raise ValueError(f'{folder.name}: missing {required_path}')
    return paths

def verified_notices(folder):
    files = []
    for line in (folder / 'SHA256SUMS').read_text().splitlines():
        expected, name = line.split('  ', 1)
        if Path(name).name != name or digest(folder / name) != expected:
            raise ValueError('Model attribution integrity mismatch')
        files.append(Path(name))
    required = {'tdt-CC-BY-4.0.txt', 'eou-NVIDIA-Open-Model-License.pdf', 'eou-NOTICE.txt',
                'speaker-upstream-NOTICE.txt', 'legacy-segmentation-LICENSE', 'sources.json'}
    if not required.issubset({f.name for f in files}):
        raise ValueError('Required model attribution missing')
    return files


def bundle(source, destination, verify_only=False, require_boost=False):
    notices = Path(__file__).resolve().parent / 'model-notices'
    notice_files = verified_notices(notices)
    plans = [(name, verified_files(source / name, model_id, required))
             for name, (model_id, required) in STACK.items()]
    for name, (model_id, required) in BOOST.items():
        if (source / name / 'voiceplus-manifest.json').is_file():
            plans.append((name, verified_files(source / name, model_id, required)))
        elif require_boost:
            raise ValueError(f'{name}: missing from {source}; FULL_INSTALLER needs the boosting model')
    if verify_only:
        return
    destination.mkdir(parents=True, exist_ok=True)
    notice_dest = destination / 'Notices'
    notice_dest.mkdir(exist_ok=True)
    for path in notice_files + [Path('SHA256SUMS')]:
        shutil.copy2(notices / path, notice_dest / path)
    for name, paths in plans:
        for relative in paths + [Path('voiceplus-manifest.json')]:
            target = destination / name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name / relative, target)
        model_id, required = {**STACK, **BOOST}[name]
        verified_files(destination / name, model_id, required)
    (destination / 'README.txt').write_text('''VoicePlus default local speech stack\n\nParakeet TDT 0.6B v3 — NVIDIA / FluidInference — CC-BY-4.0\nhttps://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml\nParakeet realtime EOU 120M, 160ms — NVIDIA / FluidInference\nhttps://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml\nSpeaker embedding / segmentation — WeSpeaker / pyannote / FluidInference\nhttps://huggingface.co/FluidInference/speaker-diarization-coreml\nParakeet CTC 110M (vocabulary boosting, when present) — NVIDIA / FluidInference — CC-BY-4.0\nhttps://huggingface.co/FluidInference/parakeet-ctc-110m-coreml\n\nConverted CoreML weights are unchanged. Each folder retains its SHA256 manifest\nand original model repository attribution. No recordings or personal vocabulary\nare included. Included Notices/ contains the upstream cards, license copies and attribution.
The notice revisions identify documentation; model bytes are pinned by SHA256 manifests.\nThe app treats this signed Models directory as read-only.\n''')

def bundle_vad(destination, source=VAD_SOURCE):
    """Copy the checked-in VAD into DESTINATION_MODELS_ROOT, re-hashing every byte before and after."""
    for name, (model_id, required) in VAD.items():
        paths = verified_files(source / name, model_id, required)
        for relative in paths + [Path('voiceplus-manifest.json')]:
            target = destination / name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name / relative, target)
        verified_files(destination / name, model_id, required)
        license_file = source / 'LICENSE-silero-vad.txt'
        if license_file.is_file():
            notices = destination / 'Notices'
            notices.mkdir(parents=True, exist_ok=True)
            shutil.copy2(license_file, notices / license_file.name)

if __name__ == '__main__':
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == '--vad':
        bundle_vad(Path(sys.argv[2]))
        print('Silero VAD: SHA256 verification passed; copied into app bundle')
        sys.exit(0)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--require-boost', action='store_true')
    args = parser.parse_args()
    bundle(args.source, args.destination, args.verify_only, args.require_boost)
    print('Default model stack: SHA256 verification passed' + ('' if args.verify_only else '; copied into app bundle'))
