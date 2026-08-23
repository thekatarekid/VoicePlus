#!/usr/bin/env python3
"""
Deterministic synthetic audio fixture generator for VoicePlus tests.

Re-runnable. Uses macOS `say` (TTS) + `afconvert` for speech, and pure-stdlib
Python (wave/struct/random with fixed seed) for noise, mixing, far-field,
VAD concatenation, silence and clipping. No third-party audio, no sox.

Output: Fixtures/audio/<suite>/*.wav + manifest.json (+ labels.json for vad/).
All files: 16 kHz, mono, 16-bit PCM WAV.

Usage: python3 Fixtures/tools/gen_fixtures.py [--out Fixtures/audio] [--skip-tts]
"""
import argparse, json, math, os, random, shutil, struct, subprocess, sys, wave

SR = 16000
SEED = 20260823
VOICES = ["Samantha", "Daniel", "Rishi"]  # en_US, en_GB, en_IN

# ---------------------------------------------------------------- sentences
CLEAN = [
    "Hey, just checking in. Are we still on for lunch tomorrow at noon?",
    "Please find the updated quarterly report attached to this email.",
    "I think the best approach is to start small and iterate from there.",
    "Thanks for your help yesterday, it really made a difference.",
    "Can you send me the address of the restaurant we talked about?",
    "The meeting has been moved to three thirty on Wednesday afternoon.",
    "I will be out of office next week and will reply when I am back.",
    "Let me know if you have any questions about the proposal.",
    "Sounds good to me, see you at the station around eight.",
    "We should probably book the flights before prices go up again.",
    "Dear Priya, thank you for the invitation, I would be glad to attend.",
    "Remind me to call the dentist on Monday morning before ten.",
]
ENTITY = [
    "TeamViewer AG reported strong growth in the enterprise segment this year.",
    "Mister Kothari will join the call from the Mumbai office at four.",
    "Run kubectl get pods to check whether the deployment is healthy.",
    "We switched the summarizer from gpt-4o to a smaller local model.",
    "Anthropic published a new paper on interpretability last week.",
    "The app stores transcripts in SQLite through GRDB.",
    "FluidAudio wraps the Parakeet model with Core ML on Apple Silicon.",
    "Hindi is written in the Devanagari script, which has many ligatures.",
    "Sundar Pichai announced the new chips at the developer conference.",
    "My shell is Zsh, but the deploy script still assumes bash.",
]
TECHNICAL = [
    "git commit dash m quote fix login bug end quote",
    "snake case user id equals request dot params dot user id",
    "camel case get user profile returns an optional user",
    "cd tilde slash Documents slash VoiceInput and run swift build",
    "open slash etc slash hosts with sudo nano",
    "npm install dash dash save dev typescript",
    "kebab case voice dash plus dash app dot swift",
    "grep dash r n todo space dot space pipe head",
    "export PATH equals dollar HOME slash bin colon dollar PATH",
    "let transcript colon array of transcript span equals empty array",
]
COMMANDS = [
    "no, Thursday",
    "scratch that",
    "put it back",
    "not that one",
    "make this shorter",
    "delete the last sentence",
    "undo that",
    "replace Monday with Friday",
    "make it more formal",
    "new paragraph",
]

# ---------------------------------------------------------------- wav helpers
def read_wav(path):
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getframerate() == SR, path
        n = w.getnframes()
        return list(struct.unpack("<%dh" % n, w.readframes(n)))

def write_wav(path, samples):
    clipped = [max(-32768, min(32767, int(round(s)))) for s in samples]
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(struct.pack("<%dh" % len(clipped), *clipped))

def rms(x):
    return math.sqrt(sum(v * v for v in x) / max(1, len(x))) or 1.0

def trim_silence(x, thresh=300, pad=int(0.15 * SR)):
    idx = [i for i, v in enumerate(x) if abs(v) > thresh]
    if not idx: return x
    a, b = max(0, idx[0] - pad), min(len(x), idx[-1] + pad)
    return x[a:b]

def pink_noise(n, rng):
    """Voss-McCartney pink noise, deterministic given rng."""
    rows = [0.0] * 16; out = []
    total = 0.0
    for i in range(n):
        k = 0
        while k < 16 and (i >> k) & 1 == 0: k += 1
        if k < 16:
            total -= rows[k]; rows[k] = rng.uniform(-1, 1); total += rows[k]
        out.append(total / 16 + rng.uniform(-1, 1) * 0.1)
    return out

def mix_snr(speech, noise, snr_db):
    s_rms = rms(speech); n_rms = rms(noise)
    gain = s_rms / (n_rms * (10 ** (snr_db / 20)))
    return [s + g * gain for s, g in zip(speech, noise)]

def far_field(x, rng):
    """Attenuate, add a couple of discrete echoes, roll off highs with a 1-pole LPF."""
    att = 0.35
    delays = [(int(0.023 * SR), 0.45), (int(0.061 * SR), 0.25), (int(0.110 * SR), 0.12)]
    out = [att * v for v in x] + [0.0] * delays[-1][0]
    for d, g in delays:
        for i in range(len(x)):
            out[i + d] += att * g * x[i]
    y, prev, a = [], 0.0, 0.6
    for v in out:
        prev = a * prev + (1 - a) * v; y.append(prev)
    return mix_snr(y, pink_noise(len(y), rng), 18)  # room floor

# ---------------------------------------------------------------- TTS
def tts(text, voice, out_wav, tmp_dir):
    aiff = os.path.join(tmp_dir, "tmp.aiff")
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, out_wav], check=True)
    os.remove(aiff)
    x = trim_silence(read_wav(out_wav))
    # normalise to ~-20 dBFS RMS
    g = (32768 * 0.1) / rms(x)
    write_wav(out_wav, [v * g for v in x])

def gen_suite(name, sentences, out_root, tmp_dir, skip_tts):
    d = os.path.join(out_root, name); os.makedirs(d, exist_ok=True)
    items = []
    for i, text in enumerate(sentences):
        voice = VOICES[i % len(VOICES)]
        fn = "%s_%02d_%s.wav" % (name, i + 1, voice.lower())
        path = os.path.join(d, fn)
        if not (skip_tts and os.path.exists(path)):
            tts(text, voice, path, tmp_dir)
        items.append({"file": fn, "transcript": text, "suite": name, "speaker": voice,
                      "notes": "macOS say TTS, trimmed, RMS-normalised to -20 dBFS"})
    json.dump(items, open(os.path.join(d, "manifest.json"), "w"), indent=2)
    return items

# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "audio"))
    ap.add_argument("--skip-tts", action="store_true", help="reuse existing TTS wavs")
    args = ap.parse_args()
    out = os.path.abspath(args.out); os.makedirs(out, exist_ok=True)
    tmp = os.path.join(out, ".tmp"); os.makedirs(tmp, exist_ok=True)
    rng = random.Random(SEED)

    clean = gen_suite("clean", CLEAN, out, tmp, args.skip_tts)
    gen_suite("entity", ENTITY, out, tmp, args.skip_tts)
    gen_suite("technical", TECHNICAL, out, tmp, args.skip_tts)
    gen_suite("commands", COMMANDS, out, tmp, args.skip_tts)

    # ---- noisy: 8 clean files x {10dB, 0dB} + far-field
    nd = os.path.join(out, "noisy"); os.makedirs(nd, exist_ok=True); items = []
    for item in clean[:8]:
        x = read_wav(os.path.join(out, "clean", item["file"]))
        base = item["file"][:-4]
        for snr in (10, 0):
            kind = "pink" if snr == 10 else "white"
            noise = pink_noise(len(x), rng) if kind == "pink" else [rng.gauss(0, 1) for _ in range(len(x))]
            fn = "%s_snr%02ddb_%s.wav" % (base, snr, kind)
            write_wav(os.path.join(nd, fn), mix_snr(x, noise, snr))
            items.append({**item, "file": fn, "suite": "noisy", "source": item["file"],
                          "notes": "%s noise mixed at %d dB SNR (seed %d)" % (kind, snr, SEED)})
    for item in clean[:3]:
        x = read_wav(os.path.join(out, "clean", item["file"]))
        fn = item["file"][:-4] + "_farfield.wav"
        write_wav(os.path.join(nd, fn), far_field(x, rng))
        items.append({**item, "file": fn, "suite": "noisy", "source": item["file"],
                      "notes": "far-field sim: -9 dB, 3 echoes (23/61/110 ms), 1-pole LPF, pink floor 18 dB SNR"})
    json.dump(items, open(os.path.join(nd, "manifest.json"), "w"), indent=2)

    # ---- vad: 6 files, speech + silences, ground-truth spans
    vd = os.path.join(out, "vad"); os.makedirs(vd, exist_ok=True); items = []; labels = {}
    for k in range(6):
        n_seg = 3 + (k % 3)
        segs = [clean[(k * 3 + j) % len(clean)] for j in range(n_seg)]
        noise_floor = k >= 3  # last three get a low noise floor instead of digital silence
        buf = [0.0] * int(rng.uniform(0.5, 1.5) * SR); spans = []; texts = []
        for s in segs:
            x = read_wav(os.path.join(out, "clean", s["file"]))
            start = len(buf) / SR
            buf.extend(x)
            spans.append([round(start, 3), round(len(buf) / SR, 3)]); texts.append(s["transcript"])
            buf.extend([0.0] * int(rng.uniform(0.5, 3.0) * SR))
        if noise_floor:
            buf = mix_snr(buf, pink_noise(len(buf), rng), 30)
        fn = "vad_%02d_%dsegs%s.wav" % (k + 1, n_seg, "_floor" if noise_floor else "")
        write_wav(os.path.join(vd, fn), buf)
        labels[fn] = spans
        items.append({"file": fn, "transcript": " ".join(texts), "suite": "vad",
                      "speaker": "/".join(sorted({s["speaker"] for s in segs})),
                      "notes": "%d speech spans, gaps 0.5-3 s%s; see labels.json" % (n_seg, ", +pink floor 30 dB SNR" if noise_floor else "")})
    json.dump(items, open(os.path.join(vd, "manifest.json"), "w"), indent=2)
    json.dump({"sample_rate": SR, "format": "file -> [[start_s, end_s], ...] speech spans", "spans": labels},
              open(os.path.join(vd, "labels.json"), "w"), indent=2)

    # ---- silence: digital silence + low-level noise
    sd = os.path.join(out, "silence"); os.makedirs(sd, exist_ok=True)
    write_wav(os.path.join(sd, "silence_digital_5s.wav"), [0.0] * (5 * SR))
    write_wav(os.path.join(sd, "silence_lownoise_5s.wav"), [v * 60 for v in pink_noise(5 * SR, rng)])  # ~ -60 dBFS
    json.dump([
        {"file": "silence_digital_5s.wav", "transcript": "", "suite": "silence", "speaker": "none", "notes": "all-zero samples, 5 s"},
        {"file": "silence_lownoise_5s.wav", "transcript": "", "suite": "silence", "speaker": "none", "notes": "pink noise ~-60 dBFS, 5 s; expected: no speech detected"},
    ], open(os.path.join(sd, "manifest.json"), "w"), indent=2)

    # ---- clipping: hard clip at +12 dB gain
    cd = os.path.join(out, "clipping"); os.makedirs(cd, exist_ok=True)
    src = clean[4]
    x = read_wav(os.path.join(out, "clean", src["file"]))
    write_wav(os.path.join(cd, "clipping_x4.wav"), [v * 4.0 for v in x])  # write_wav hard-clips
    json.dump([{"file": "clipping_x4.wav", "transcript": src["transcript"], "suite": "clipping",
                "speaker": src["speaker"], "source": src["file"],
                "notes": "gain +12 dB then hard clipped to int16; expect clipping-detector to flag"}],
              open(os.path.join(cd, "manifest.json"), "w"), indent=2)

    shutil.rmtree(tmp, ignore_errors=True)
    print("done ->", out)

if __name__ == "__main__":
    main()
