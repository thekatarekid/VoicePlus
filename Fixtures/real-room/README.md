# Real-room recordings

Corpus for diagnosing live-microphone accuracy. Recorded by the owner with
Settings › General › Microphone › "Save recordings of what I dictate".

## Layout

```
Fixtures/real-room/
  builtin/     one pass of the script on the built-in microphone
  external/    the same script on a second microphone
  script.md    the reference sentences, numbered 01–20
```

Each pass holds, per utterance, `<stamp>-raw.wav`, `<stamp>-processed.wav`
and `<stamp>.json` (device, transport, sample rate, capture graph, levels).

## What is committed

The `.json` manifests and `script.md` are committed. **The `.wav` files are
git-ignored**: they are the owner's voice, and a recording in git history is
permanent. They stay in the working copy so agents on this machine can replay
them.

## Replaying

```sh
eval "$(Scripts/bootstrap-toolchain.sh)"
VOICEPLUS_REPLAY="$PWD/Fixtures/real-room/builtin" \
  swift test --scratch-path .build-capture --filter replaySavedRecordings
```

`VOICEPLUS_REPLAY_TEXT` scores a single reference against every file, so it
only suits a one-sentence check. Per-file scoring against `script.md` is built
in R1.

## Retention

The app keeps only the newest 20 utterances in its own Recordings folder, so
each microphone pass must be copied here before the next pass begins.
