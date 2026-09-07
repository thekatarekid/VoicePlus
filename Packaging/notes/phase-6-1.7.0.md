# VoicePlus 1.7.0 — the mic check now needs a microphone, not a fixture

The first thing onboarding asks you to do is talk to it. **"Say something."** — a level
meter, and then **"Sounds good."** On this machine, with no speech model downloaded, the
app's owner ran that step, **said nothing at all**, and the bar filled and the step passed.
Underneath it, in small grey type:

> Simulated meter — no real capture is running in this build.

That caption was the whole of the honesty, and the step passed anyway. The meter was not
measuring a microphone. It was never opening one. This release makes a pass on that step
mean what it says: real audio, from real hardware, or no pass at all.

Ships in the same dmg as 1.6.9, which fixed the fabricated-transcript defect this bug sat
on top of. Tag `release/phase-6/v1.7.0` · 1 commit (`fa2c3a2`) on top of 1.6.9 (`329af01`) ·
**1224 tests pass, 0 failures** for the whole package.

sha256 `8f946c91a7ce11fe15489daaaf17aa99954536ae5d0a6449ffee897758ba4aa1`
`VoicePlus_6_1.7.0.dmg` · 15,521,882 bytes · 2026-09-07.

## 1. What was actually happening

The mic-check meter was fed by the **speech engine's** state rather than by the microphone.
`AppContainer` picked `PipelineMicLevelPublisher` — real capture — only when a live audio
pipeline existed, and one existed only when a recogniser did. That is never true during
onboarding, which is the one part of the app that runs *before* any model is on disk. So it
fell back to `EngineMicLevelPublisher`, which forwarded whatever `listening(level:)` numbers
the engine published.

On a machine with no model, that engine was the mock (see 1.6.9), and its "levels" were
numbers derived from a text fixture — not from audio. The verdict fired on any level
`>= 0.08`, so a fabricated number cleared the gate the same way a spoken word would.

Two consequences, both confirmed:

- **A silent user passed a microphone test.** Nothing about the outcome depended on the
  microphone, on the room, or on whether the user opened their mouth.
- **After 1.6.9 the same install got a dead meter instead of a fake one.** `UnavailableEngine`
  emits no levels at all, so the bar simply never moved. Less dishonest, still wrong: the
  step still could not tell the user anything true about their microphone.

Separately, a user who **denied or skipped** the microphone permission was routed to the
mic-check step regardless, and handed a meter that could never move for a reason the screen
never named.

## 2. What ships instead

- **Onboarding owns its own capture session.** New
  `PipelineMicLevelPublisher.standalone()` builds
  `AcousticCaptureSource(wrapping: CoreAudioCaptureSource())` → `AudioPipeline(vad: EnergyVAD())`
  → `PipelineAudioSource` — the same audio graph the app itself uses, minus the recogniser.
  Real microphone capture never required a speech model; now the mic check does not either.
  `EngineMicLevelPublisher` is **deleted**: there is no engine-derived path into the meter
  left to fall back to.
- **Passing without real audio is structurally impossible**, enforced at three layers rather
  than by one check that could be forgotten:
  1. `MicLevelPublishing.isRealCapture` lost its defaulted `true`. Every conformer must now
     declare its provenance out loud — the default was how a synthetic source got to look
     real by saying nothing.
  2. `OnboardingViewModel` refuses to subscribe to or start a source that is not live
     capture, and logs the refusal.
  3. `OnboardingStateMachine` is **default-deny**: it discards `.micLevel` entirely while
     capture provenance is unconfirmed, so an undeclared level never touches the peak and
     `verdict` is never even called.
- **The simulated-meter caption is gone**, along with the code path that made it reachable.
- **A blocked microphone gets its own screen.** A denied or undetermined permission now opens
  `.micCheck` on a new **"The microphone is blocked."** verdict with no capture started, copy
  that names the problem, a button to **Open Microphone privacy**, and a **Re-check** that
  asks about the permission and only proceeds on an actual grant — instead of dropping the
  user on a dead bar or skipping the step in silence.

## 3. Tests

- New `Tests/AppTests/OnboardingMicCheckHonestyTests.swift` — **11 tests**. They pin the
  property, not the implementation: undeclared levels can neither pass nor be counted, a
  non-capture publisher is never started and never metered, "Try again" clears provenance, a
  capture failure blocks the step, and a denied microphone is immune to injected levels.
- **Full package: `swift build` clean, 1224 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **Please do the mic check for real on first launch.** Speak into it and watch the bar. That
   round trip — a genuine grant, real speech, "Sounds good." — is the one thing no test on
   this machine can perform (see below), and it is thirty seconds of your time.

3. If you previously passed "Say something." without speaking, that was this bug. It told you
   nothing about your microphone either way.

## Known and remaining

- **The HAL leg is untested — an agent cannot speak into a microphone.** What is unverified is
  precisely: that `standalone()` opens a real input device and delivers taps on real hardware,
  and that a genuine grant → speak → "Sounds good." round trip works end to end. Everything
  above the hardware boundary — provenance, gating, verdicts, the blocked screen, the refusal
  paths — is covered by tests. The standalone check for the same leg is
  `/Applications/VoicePlus.app/Contents/MacOS/VoicePlus --mic-selftest` on the signed bundle,
  which exercises the identical capture graph headlessly under the app's own TCC identity.
- **Nobody has seen the blocked screen on a machine that actually denied the microphone.** Its
  copy and routing are covered by tests against the state machine; the visual is unverified.
- **`OnboardingDependencies.mock(pretendRealMicCapture: true)` still lets a synthetic meter
  stand in**, by design and by name — it exists so tests can exercise the post-capture logic.
  Nothing in the app sets it: `AppContainer` builds a real capture graph unconditionally.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the
  first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
