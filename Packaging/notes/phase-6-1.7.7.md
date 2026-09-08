# VoicePlus 1.7.7 — the warm-up records, and only one owner holds the microphone

Two faults under the same surface.

**"Dictate now" left the notch on "Warming up…"** for a long time before anything happened,
and whatever was said during that time was gone.

And **two owners were fighting over the microphone**: onboarding's level meter and the
speech engine each believed they had configured capture, while only the first of them
actually had.

Ships in the same dmg as 1.7.4, 1.7.5, 1.7.6 and 1.7.8. Tag `release/phase-6/v1.7.7` ·
2 commits (`9f4b0c3`, `54888e6`) on top of 1.7.6 (`243c57a`) · sha256 and dmg size recorded
at the release build.

## 1. What was actually happening

- **The model was resolved before the microphone was opened.**
  `RealEngine.start(prewarm:)` resolved the recognizers **before** `audio.start()`, so a
  **cold CoreML load of Parakeet TDT** ran with the microphone shut — unbounded, with no
  progress to show, and **every word spoken during it discarded**. That is the whole of
  "Warming up…".
- **Nothing loaded the model eagerly**, so the **first** key press of the session paid the
  entire compile.
- **`PipelineAudioSource.start()` returned success while doing nothing** whenever the source
  was already running. The onboarding meter is handed the **same source the engine uses**,
  so the second owner inherited a graph whose **ring, VAD and utterance tap belonged to the
  first owner's session** — and whichever owner stopped first **closed the microphone under
  the other**.

## 2. What ships instead

- **Explicit audio ownership, with rank and preemption.** The **engine outranks** the meter
  and diagnostics. A start either **takes the graph and restarts it clean** — ring, VAD and
  tap rebuilt for the new owner — **or throws `AudioCaptureError.busy`**. There is no third
  outcome that quietly succeeds.
- **A stop releases the graph only if that owner still holds it**, so a displaced owner's
  late `stop()` cannot close the new owner's microphone. **Displaced owners are told.**
- **Capture-first cold start.** `RealEngine.start` **opens the microphone before resolving
  the model**; samples captured while the model loads are **buffered**, and the preview pass
  is flushed the moment the recognizer is ready — so a push-to-talk press **never loses its
  opening words**.
- **Eager preload.** New `RealEngine.preloadModel()` and `AppContainer.warmUpEngine()` load
  the model **at launch** and again **after a download-driven engine swap**, so the first
  press is not the cold one.

## 3. Tests

- New `Tests/AppTests/AudioSourceOwnershipTests.swift` and
  `Tests/EngineTests/RealEngineColdStartTests.swift` — **8 tests**: the engine taking the
  graph from the meter and getting it restarted, tap and all; a meter **refused out loud**
  while dictation holds capture; a displaced owner's late stop that must not close the new
  owner's microphone; a failed start that leaves no owner; audio **and preview text spoken
  during a cold model load surviving**; a failed cold start releasing capture; and
  `preloadModel()` loading **without** publishing *"Warming up…"*.
- **Full package: `swift build` clean, 1313 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **Speak immediately on the key press, before you think the app is ready.** Those words
   should now appear. That is the specific thing to test.

3. **Please say how long the first press takes now** — the model is loaded at launch, so it
   should not be the slow one. The real cold-load duration is not something an agent here
   can measure.

## Known and remaining

- **The badly-wrong hotkey transcription is not confirmed fixed.** The owner reported the
  hotkey path producing **completely wrong text** where onboarding was accurate. Recognizer
  configuration was proven **identical** between the two paths and biasing was **ruled out**
  as a text corruptor, which leaves a shared-capture-graph corruption as the leading
  explanation — and this is exactly the fix for that — but **the cause is not confirmed on
  hardware.** Please retry the hotkey and say whether the text is right now.
- **The real cold-load duration is unmeasured.** No agent here has loaded Parakeet TDT, so
  how long the eager preload actually takes at launch is unknown.
- **No agent on this machine has a microphone**, so ownership, preemption and the buffered
  cold start are covered against the capture protocol and mocks, not against a real HAL
  device.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
