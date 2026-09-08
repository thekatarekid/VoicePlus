# VoicePlus 1.7.15 — AirPods would have silently ruined dictation, and a way to prove what the microphone actually heard

The hunt for the live-microphone accuracy problem went one round further. The owner read

> The quick brown fox jumps over the lazy dog

and got *"the quake brown fogs jump above the lazy doll"* — roughly **55% WER on a clean read**.
Successive investigations had already **measured and cleared** the acoustic chain, the decoder,
biasing, audio format conversion, the preview-versus-final landing, end-of-utterance truncation,
the VAD and post-processing. This round **cleared the last synthetic suspects** and ships the two
things that came out of it: **a latent bug that would have ruined dictation for anyone with a
Bluetooth headset**, and **the ability to capture the audio that actually failed** — plus, from the
verification pass over that new code, **a privacy defect in the recording switch** and **two faults
in the model store the 1.7.13 migration had introduced**.

**This is the dmg — it carries 1.7.13 and 1.7.14 as well.** Tag `release/phase-6/v1.7.15` ·
5 commits (`c9491df`, `8849dff`, `89611c6`, `4410afb`, `e96a167`) on top of 1.7.12 (`823fda0`) ·
sha256 `8bbbca887795428dcc0d149e8baca3e04f62865eca9c074f732ac8d367398b4c`, 15,738,218 bytes,
built 2026-09-08.

## 1. The latent bug: being the system default outweighed being a phone-call microphone

**`InputSelectionPolicy` awarded the system default input a bonus of `+50`, which dwarfed every
transport score.** The consequence: the moment a **Bluetooth headset connects and macOS makes it
the default input**, dictation would **silently move onto an HFP/SCO link** — a **narrowband 8 kHz
(CVSD) or 16 kHz (mSBC), heavily compressed** microphone, telephony bandwidth — **with no
indication to the user and a large accuracy cost**.

- **The bonus is now withheld from a narrowband Bluetooth input.** `BluetoothInputDetector` already
  owned the transport classification; it now exposes it as one bit,
  **`BluetoothInputMode.isNarrowbandSpeech`**, and the policy reads that.
- **It still wins when it is the only input available.** Refusing to dictate at all would be a
  worse defect than dictating over SCO.
- **An explicit user pin still overrides everything** (`audio.input.preferredUID`). The user is
  allowed to be wrong; it is their Mac.
- **Wideband and LE Audio Bluetooth are untouched** — the rule is about telephony bandwidth, not
  about Bluetooth.
- **When the app substitutes a different microphone it says so**, in the UI and in the log, rather
  than doing it silently. `InputSelectionPolicy.decide` returns **`Choice.avoidedNarrowbandBluetooth`**
  so the substitution is a stated fact rather than an invisible one.

**Settings › General gains a Microphone picker** — **Automatic**, or a specific device, with
**low-quality inputs labelled as such in the list**. A device that was pinned and then unplugged
**falls back** rather than showing a blank row.

## 2. The diagnostic: record the utterance that failed, and replay it

**Every accuracy measurement so far has been taken on synthetic fixtures, and the failure is not
reproducible from them.** That gap **cannot be closed offline**, because nobody has the audio that
failed — so the deliverable is **the ability to capture the real thing**.

- **New `UtteranceRecorder` saves both sides of the chain**: `<stamp>-raw.wav` (what capture
  delivered, pre-DSP), `<stamp>-processed.wav` (what the recognizer got), and `<stamp>.json` — a
  manifest recording the **device, its transport, the nominal sample rate, the capture-graph
  summary, the robustness profile and level statistics**. A failing dictation can then be **replayed
  through the existing fixture harness**.
- **Opt-in and off by default, written locally, never leaving the machine.** Files land in
  `~/Library/Application Support/VoicePlus/Recordings`, **only the newest 20 utterances are kept**,
  and Settings shows an **orange note while it is on**, with a **count of what is stored**, **Show
  in Finder** and **Delete all**.

**The loop, end to end.** Turn it on in **Settings › General › Microphone**, reproduce a bad
dictation, turn it back off, then:

    eval "$(Scripts/bootstrap-toolchain.sh)"
    VOICEPLUS_REPLAY_TEXT="the quick brown fox jumps over the lazy dog" \
      swift test --scratch-path .build-capture --filter replaySavedRecordings

`RecordingReplayTests` reads the saved recordings back **through the real recognizer** and prints,
per recording, the manifest, the level, what the model heard and the **WER against the reference** —
**no fixture manifest to author**. **The whole loop was verified end to end against a fixture.**
`Engine/Audio/README.md` carries **a table explaining how to read each outcome** — replay clean but
live wrong means the fault is downstream of capture; replay bad but the audio sounds fine means the
model is failing on this voice and room; `-raw` good and `-processed` bad implicates the spectral
gate.

## 3. Turning "save recordings" off now stops the next dictation, not the next launch

**The diagnostic switch from section 2 was read exactly once — when the engine was built at launch.**
So **turning it off stopped nothing**: the recorder stayed installed and went on writing a raw and a
processed WAV, plus a manifest, **for every dictation until the app was relaunched** — while the
Settings copy directly under the toggle said *"Turn it off when you're done."* Turning it **on**
mid-session was inert in the same way, with the copy asserting the opposite. A switch about **audio
of your voice being written to disk** that does not take effect when you turn it off is a **privacy
defect**, not a UI nit, and it was found before this dmg rather than after.

- **The switch is now a predicate re-read at every `start()`**, so it means what it says **in both
  directions**.
- **A recorder is always allocated but stays disarmed** — two empty buffers, **no directory, no
  file** — and `begin()` is only called when the switch is on, so `finish()` returns nil and
  **nothing touches the disk**.
- **Off by default, local-only and the newest-20 retention are unaffected** and still hold. An
  **explicitly injected recorder still records unconditionally**, which is what the tests and Lab are
  asking for when they pass one.
- **One narrow window remains, by design:** a toggle flipped off *during* an utterance **still writes
  that utterance**, which began while you were opted in.

## 4. The model store: a migration that could blind the integrity check, and 468 MB nobody collected

**Verifying 1.7.13's `ModelLayoutMigration` against the shapes a real disk can be in turned up two
faults, both fixed here.** They matter to anyone upgrading, because **the migration runs on the next
launch of this build**.

**A branch could permanently blind the truncation check.** `voiceplus-manifest.json` records the byte
count every file had when the install succeeded, and it is **the only thing `ModelIntegrity` can
check a silently truncated file against** — the check added in 1.7.11 because a half-downloaded model
reported itself installed. The migration's `adoptedExisting` branch **kept the manifest-less copy of
a model, deleted the manifest-bearing one, and wrote nothing in its place**, and **nothing else in
the app ever writes a manifest for an already-installed model** — so once that branch ran, the
degradation **never healed**.

- **Every branch now settles the manifest before it returns**, through one `ModelManifest.ensure`:
  already there → nothing to do (one file read, the common case); otherwise **adopt the manifest from
  the copy about to be deleted**, but only when it describes the survivor **exactly, file for file,
  byte for byte** — a `stat` per file instead of a **SHA-256 pass over 468 MB**; otherwise **rebuild**
  with the same writer both fetchers already use.
- **Never for an incomplete folder.** A manifest built over a truncated file **records the truncation
  as correct**, turning a detectable fault into a permanent lie.
- **The no-op branch settles it too**, so an install an earlier build already stripped **is healed**
  rather than left un-checkable forever.
- **`ModelIntegrity.assess` now distinguishes `.verified` / `.unverifiable` / `.incomplete`.** An
  empty problem list only means "nothing we can see is wrong", and **without a manifest the set of
  things we can see is strictly smaller** — so a **manifest-less model is never reported verified**.

**Parked directories were never collected.** Replacing an installed model is a **swap, not a
delete-then-move**, so that a failure halfway leaves a working model under *some* name rather than
none: `FluidAudioFetcher.fetch` parks the outgoing copy as `.replaced-<uuid>`, the migration parks
the duplicate it undoes as `.superseded-<uuid>`. Each deletes its own park immediately afterwards —
**if it gets that far**. Killed mid-swap, **the park survived and nothing ever looked at it again**:
**~468 MB stranded** under a name no presence check reads and `repair` never visits, **not even
visible as a model in Settings**.

- **`ParkedModelDirectories.sweep` collects them, conservatively:** direct children of the models
  root only; **only `<a model folder name we own>.<kind>-<a parsable UUID>`**, so a stranger's
  directory, a real model folder and our own `.staging-<id>` (where a cancelled download's resumable
  `.partial` files live on purpose) are **all excluded**; **never FluidAudio's own models directory**;
  **never symlinks**; a **15-minute grace period** measured from the newest of creation, content and
  **attribute** modification time (parking is a rename, and a rename bumps `st_ctime` while leaving
  `st_mtime` and birth time alone, so a park made by moving a year-old tree reads as **seconds old**
  by the right clock); and **claim by atomic rename to `.sweeping-<uuid>` before removing anything**,
  which exactly one racing sweeper can win.
- **`ModelRootLock` puts the whole maintenance pass under an `flock`**, so **two VoicePlus processes
  launching together cannot interleave** a park, a rename and a delete over the same two paths. The
  lock is per-open-file-description, so **a crash cannot leave a stale one**, and **the wait is
  bounded and then abandoned** — a hung holder must not become an app that never finishes launching.
- **`swift test` no longer runs maintenance inside a real model store.** Eleven tests point
  `ModelManager` at the real `~/Library/Application Support/VoicePlus/Models` to score WER and golden
  transcripts against whatever is actually downloaded; maintenance runs from `init`, so those
  **read-only intentions were entitled to migrate and delete inside a user's 468 MB store**. They now
  pass `Maintenance.skip`.

**Cost on an already-migrated install:** one `open`, a `stat` per model, one directory listing.

## 5. What was measured and cleared this round

- **Every prior accuracy figure had been taken on 16 kHz fixtures, where `AudioConverter16k` is a
  no-op** — so **the 44.1 kHz conversion a real microphone forces had never actually been
  exercised**. It now has been: **WER 0.0140 identically at 16 kHz, 44.1 kHz and 48 kHz**, duration
  drift **0.01%**, and **zero sample drift** between streaming and one-shot conversion.
- **Absolute level was cleared too** — **flat WER from −20 dBFS down to −60 dBFS**.
- **A genuine bug surfaced while testing this.** Silent audio produced **`-inf` dBFS, which JSON
  cannot encode**, so encoding the manifest would have thrown and **discarded the recording — in
  precisely the "the microphone delivered nothing" case that most needs capturing**. Levels are now
  **floored at −200 dBFS**, which no real signal reaches.

## 6. On the owner's specific report, recorded honestly

**The Bluetooth theory did not explain it.** Their own unified log shows **41 of 41 capture graphs**
at `device=MacBook Pro Microphone … tap=44100Hz/1ch`, and **the affected dictations match that
window row for row** — those were captured on the **built-in microphone**, with **AirPods paired but
not connected**.

**So the live-microphone accuracy issue remains unresolved.** The **model, decoder, DSP, conversion
and post-processing are all now measured clean**. The open hypothesis is **far-field reverberation
from a MacBook microphone at arm's length**, since **every fixture tested to date is anechoic
text-to-speech with no reverb**, and reverb is a **classic source of exactly these
phonetically-adjacent, right-syllable-count substitutions**.

**The replay diagnostic is what will confirm or refute it.** If the replayed audio **scores badly
but sounds fine**, capture is faithful and the model is failing on real-room speech; if the **raw
file scores well and the processed one badly**, the spectral gate is implicated after all.

## 7. Tests

- New `Tests/EngineTests/UtteranceRecorderTests.swift` — **12 tests**: nothing is ever written
  unasked; raw, processed and a manifest that explains the recording; **a silent processed track
  still encodes a manifest**; the newest-20 cap; capture through `AcousticCaptureSource` **without
  changing what the sink receives**; and the device rules — **AirPods as system default do not win
  over the built-in mic**, narrowband Bluetooth **is still used when it is the only input**, an
  **explicit user choice of AirPods is honoured**, **high-quality Bluetooth keeps its system-default
  standing**, and a **wired mic still beats the built-in**.
- New `Tests/EngineTests/LiveCapturePathWERTests.swift` — **4 tests**: duration preserved through
  live-capture conversion, streaming tap conversion matching one-shot, and the **WER sweeps across
  sample rates and across absolute level**.
- New `Tests/AppTests/MicrophoneSettingsTests.swift` — **6 tests**: Automatic is the default and a
  choice writes the key the capture source reads; the recording toggle is **off by default**; an
  unplugged pinned device **falls back**; the note **explains the substitution rather than making it
  silently**; a low-quality Bluetooth mic is **labelled** in the picker; and the summary **counts
  utterances, not the three files each one writes**.
- New `Tests/EngineTests/RecordingReplayTests.swift` — the **replay harness itself**, opt-in and
  driven by `VOICEPLUS_REPLAY_TEXT`.
- `Tests/EngineTests/AudioUnitTests.swift` updated — `skipsDisplayAndVirtualDefaults` **expected
  AirPods to win as system default**. That expectation **was the bug**, and now says so.
- `Tests/EngineTests/UtteranceRecorderTests.swift` gained the switch tests for section 3 — that the
  toggle is read **at every start, not once at launch**, in **both directions**; that a disarmed
  recorder **writes no directory and no file**; and that an **explicitly injected** recorder still
  records unconditionally.
- New `Tests/EngineTests/ModelMaintenanceTests.swift` — **18 tests** over section 4: every migration
  branch **leaves a valid manifest** (adopted from the donor when it matches byte for byte, rebuilt
  otherwise, and **never written over an incomplete folder**); `assess` reporting **`.unverifiable`
  rather than `.verified`** for a manifest-less model; and the sweeper's whole guard list — **only
  our own park names**, **only direct children**, **`.staging-` left alone**, **symlinks left
  alone**, **FluidAudio's directory refused**, the **grace period measured from attribute-modification
  time**, and the **`.sweeping-` claim** being collectable in turn.
- Eleven tests that point `ModelManager` at the **real model store** now pass `Maintenance.skip`, so
  the suite can no longer migrate or delete inside a user's 468 MB of models.
- **`swift build` clean, 1430 tests passing, 0 failures** — full package, from a clean scratch path.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.13, 1.7.14 and 1.7.15.** Its companions are the speech model that was
   downloaded twice and the Actions key that could not be rebound — read their notes for what to
   check.

3. **Open Settings › General › Microphone and confirm the note names the mic you expect.** If you
   have a Bluetooth headset connected, the note should say VoicePlus chose something else **and
   why**. Pick a specific device if you would rather decide yourself.

4. **If dictation is still landing wrong words, capture one.** Turn on **"Save recordings of what I
   dictate"**, reproduce it, turn the toggle back off, and run the replay command in
   `Engine/Audio/README.md`. That file is the only way anyone here can see what your microphone
   actually heard.

## Known and remaining

- **The live-microphone accuracy issue remains unresolved.** The **model, decoder, DSP, conversion
  and post-processing are all measured clean on fixture audio**; the **Bluetooth theory did not
  explain the owner's own report** — their log shows the built-in mic at 44.1 kHz throughout. The
  **open hypothesis is far-field room reverberation**, and **nothing in this build claims to have
  fixed the accuracy problem**. The Bluetooth fix is a **real latent bug found on the way**, not the
  cause.
- **Untested on hardware: everything that needs a real microphone.** That a connected Bluetooth
  headset is actually **stepped around** at the HAL, that the **picker rebinds the live device**,
  and that a **real utterance records and replays**. No agent here has a microphone or TCC
  permission; the policy, the recorder and the replay path are covered against **protocols, mocks
  and fixture audio**, and the **replay loop was verified end to end against a fixture** rather than
  against a live capture.
- **Every visual judgement is unverified** — the new **Microphone section in Settings › General**,
  the substitution note, the **orange recording note**, and the **Show in Finder / Delete all**
  buttons. The wording is tested; its appearance is not.
- **The reclaim from 1.7.13 is still untested against a real duplicate pair on a user's disk**, and
  **the real HuggingFace download remains unverified** — pre-existing, unchanged here. The same
  applies to the section 4 work: **the sweeper has never collected a park left by a real crash**, and
  the **cross-process `flock`** has never been exercised by **two VoicePlus processes launching at
  once** on this machine. Both are covered by tests against temporary directories.
- **On the owner's own machine this migration is a no-op.** Their models root already holds
  `parakeet-tdt-0.6b-v3` and `parakeet-realtime-eou-120m-coreml-160ms`, **both carrying a valid
  manifest**, with **no legacy folder and nothing parked** — so the first launch of this build moves
  **no bytes**: a `stat` per model, two small manifest reads, one directory listing.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the first
  phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
