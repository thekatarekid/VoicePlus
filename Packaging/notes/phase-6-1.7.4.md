# VoicePlus 1.7.4 — dictation no longer wedges itself permanently after one use

Onboarding's **"Dictate now"** worked **once**. Pressing **"Try again"** then said:

> VoicePlus is already recording.

and said it forever. With the real hotkey the same failure wore a different face: an error
appeared on key **release**, and after four or five attempts the hotkey **stopped working
altogether** — no listening state on press, and a broken animation flashing on release.
Nothing short of relaunching the app cleared it.

Ships in the same dmg as 1.7.5, 1.7.6, 1.7.7 and 1.7.8. Tag `release/phase-6/v1.7.4` ·
2 commits (`14010b7`, `9a01b91`) on top of 1.7.3 (`06c5ccd`) · sha256 and dmg size recorded
at the release build.

## 1. What was actually happening

Two defects compounding into one symptom.

- **A flag that outlived the session it described.** `RealEngine.start()` set
  `listening = true` **before** `try audio.start()` and never rolled it back when that threw
  — a denied microphone, a 3 s HAL start timeout, a format mismatch. The flag then stood up
  with no capture behind it, and every later start threw `alreadyListening`: *"VoicePlus is
  already recording."*, for the rest of the process.
- **Three racing Tasks with no order between them.** `DictationCoordinator` ran start,
  finalize and cancel as independent `Task`s. A key released during warm-up ran `stop()`
  **before its own `start()` had finished** — the stop threw `notListening` and was
  swallowed, the start then succeeded, and the engine was left recording with nobody left to
  stop it.
- **Onboarding and the hotkey share one engine**, which is why a failure on either path
  killed the other, and why "it worked once" was the whole of the good behaviour.

## 2. What ships instead

- **One session flag, with one owner.** The coordinator holds it; nothing else writes it.
- **All engine calls run on a serial chain**, so a release can never overtake its own start.
- **Unconditional teardown on every exit path** — success, throw, cancel — so a session
  cannot outlive the code that created it.
- **`RealEngine.start` rolls back fully on a failed `audio.start()`**, so a capture that
  never opened leaves no flag behind.
- **A held-over session is released and retried, not refused.** An `alreadyListening` start
  is retried once after a forced cancel: a wedge **clears itself instead of needing a
  relaunch**, which matters because the owner's copy of this bug required quitting the app.
- **The preflight is bounded** (`refreshEngineIfNeeded` sits in the hotkey path, so an
  engine swap cannot hang a key press), **`SwappableEngine.swap` cancels the outgoing engine
  unconditionally**, and **`AppDelegate` resets the hotkey gesture when capture never
  opened** — the reason the hotkey went dead after four or five failures.

## 3. Tests

- New `Tests/AppTests/DictationSessionLifecycleTests.swift` and
  `Tests/EngineTests/RealEngineStartRollbackTests.swift` — **11 tests** over the four ways
  the session used to leak: a second utterance after a success, after a failed start, after
  a cancel, after a stop that threw; a key released during warm-up; an engine another owner
  left recording; an engine swap mid-utterance; and a preflight that overruns.
- The preflight bound is a **raced continuation, not a task group** — `withTaskGroup` waits
  for its children on exit, so the timeout never actually fired.
- **Full package: `swift build` clean, 1313 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **Dictate twice in a row** — from onboarding and from the hotkey. The second attempt is
   the one that used to fail.

3. **If you ever do see "VoicePlus is already recording." again, try once more** rather than
   relaunching. It is now supposed to clear itself; if it does not, that is worth reporting.

## Known and remaining

- **No agent on this machine has a microphone**, so the failure modes that *start* this bug
  — a denied mic, a real HAL start timeout, a format mismatch — are reproduced against the
  capture protocol and mocks, not against real hardware. The rollback, the serialisation and
  the self-healing retry are covered by tests.
- **The hotkey path has not been driven by a real key press by any agent.** The gesture
  reset is tested at the coordinator boundary; the CGEvent leg is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
