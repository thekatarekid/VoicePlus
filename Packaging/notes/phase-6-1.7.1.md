# VoicePlus 1.7.1 — dictation now starts working when the model finishes downloading

The owner installed 1.7.0, went through onboarding, chose **Best**, and watched all
**900 MB** download to completion. The next screen confirmed it:

> Using Parakeet TDT 0.6B v3.

And then dictation did not work **at all**. Pressing the hotkey produced:

> No speech model installed — Dictation is off until a speech model is installed

Onboarding's own **"Dictate now"** button showed **"Listening…"** and never recognised a
word. The microphone was fine — the mic-check step earlier in the same run had passed for
real. The app had the model, said it had the model, and could not use it.

Ships in the same dmg as 1.7.2 and 1.7.3. Tag `release/phase-6/v1.7.1` · 1 commit
(`d4f804d`) on top of 1.7.0 (`fa6a3f4`) · sha256 and dmg size recorded at the release
build.

## 1. What was actually happening

The speech engine was resolved **exactly once, at app launch**, and never re-resolved.

A fresh install *necessarily* launches with no model on disk. So every collaborator that
took the engine at startup — the coordinator, the pill, the presence indicator, the code
switcher, onboarding, a dozen in all — took `UnavailableEngine` and held it for the life
of the process, no matter what downloaded afterwards. Quitting and relaunching would have
fixed it; nothing in the app told the user that, and nothing should have required it.

The staleness was **pre-existing, and had been masked**. Before 1.7.0, an app with no
recogniser silently fell back to `MockEngine` replaying a canned fixture, so a stale
engine produced *fabricated* transcripts rather than silence. Removing that fallback in
1.6.9/1.7.0 was correct, and it turned a hidden bug into a visibly dead app. This is the
same defect surfacing honestly.

## 2. What ships instead

- **The engine has a stable lifetime, not stable contents.** New
  `Shared/Engine/SwappableEngine.swift` is a box: it owns **one** state subject and **one**
  event broadcaster and re-attaches them to whichever engine is inside. Every collaborator
  holds the box, subscribes once, and keeps working across a swap. No refactor of a dozen
  call sites, and no second subscription path that could go stale in a different way.
- **Availability is asked, not assumed.** A new `EngineAvailabilityReporting` protocol is
  how the app finds out whether the engine inside can actually hear.
- **`AppContainer.refreshEngineIfNeeded()` swaps only on an availability flip** — a real
  engine when a model lands, `UnavailableEngine` when one disappears — so an ordinary
  utterance never disturbs a working engine. It runs at three moments, which were three
  faces of one bug rather than three bugs:
  1. **A download completes** (`ModelManagerTiers.onModelsChanged`).
  2. **Hotkey down**, as a preflight, so the first press after a download is already live.
  3. **Before onboarding's "Dictate now."**
- **A mid-utterance swap lands nothing rather than something wrong.** The outgoing engine
  is cancelled, and a `stop()` whose `start()` belonged to a previous generation returns no
  spans — so a swap in flight cannot land half an utterance, and cannot land the same one
  twice.
- **A failed or cancelled download changes nothing.** The change notification does not
  fire, so the app stays honestly unavailable instead of swapping in an engine that has no
  model behind it.

## 3. Tests

- New `Tests/AppTests/EngineSwapTests.swift` — **8 tests**. They pin the property, not the
  implementation: a subscriber bound before the swap sees the new engine's states, a swap
  happens only on an availability flip, a stale `stop()` returns no spans, and a failed
  download leaves the engine unavailable.
- **Full package: `swift build` clean, 1259 tests passing** (1224 at 1.7.0).

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **If dictation was dead after your model finished downloading, that was this bug.** It
   was not your microphone, not the model, and not a failed download — the app simply
   never looked again. You should no longer need to relaunch after a download.

## Known and remaining

- **No agent on this machine has a real downloaded model**, so the construction of the
  *real* engine inside the swap — the CoreAudio graph plus the FluidAudio model load — is
  unverified. What is covered is the swap machinery: subscriber continuity, the
  availability-flip condition, generation-scoped `stop()`, and the no-swap-on-failure path.
- **A true end-to-end round trip — download → speak → text appears — has not been run by
  anyone.** Please do it once on a real machine after installing.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
