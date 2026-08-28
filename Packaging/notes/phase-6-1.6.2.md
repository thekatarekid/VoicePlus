# VoicePlus — 1.6.2 (patch on Phase 6)

**This is the build to install.** 1.6.1 fixed the permission dead-end, the frozen mic meter and the pill under the notch — and then, on the real machine, the onboarding window turned out not to be visible at all in some configurations. 1.6.2 fixes that plus three more things found in the same pass: the meeting prompt had the notch bug too, the pill's waveform was dead, and resource lookup preferred a source checkout the user does not have.

**1006 tests pass.**

---

## ⚠️ Before you install — please read, this one needs you

The app is **ad-hoc signed** (no Developer ID certificate exists for this project). macOS therefore identifies it by a **code hash that changes on every single build**, and a leftover permission row from an older build **silently denies the new one — no prompt will ever appear.** Removing the stale rows is not optional.

**1. Replace the app and clear quarantine.**
Quit any running VoicePlus (menu-bar icon → Quit), open the dmg, drag **VoicePlus** to **/Applications** replacing the old copy, then:

```bash
xattr -dr com.apple.quarantine /Applications/VoicePlus.app
```

**2. Remove the stale VoicePlus entries — do this before first launch.**
System Settings → Privacy & Security → **Input Monitoring**: select any existing **VoicePlus** row and remove it with **−**. Then do exactly the same under **Accessibility**.
From the terminal, `Packaging/reset_tcc.sh` does the same thing (VoicePlus's bundle id only — it never wipes a service for every app).

**3. Launch, then walk the permission steps.**
If no prompt appears, use the step's **Open System Settings** button and add `/Applications/VoicePlus.app` with **+**. The checkmark now flips by itself the moment you toggle the switch — you do not have to come back and click anything.

**4. Honestly: this re-granting is needed after *every* update**, until the app is signed with an Apple Developer ID certificate and notarized. That is the real cure, and it is not something the build can work around — see `Packaging/SIGNING.md` §4.

---

## What's fixed

### Onboarding window could open where you could never see it (532e116, 2f44d9c)
Two independent variants, both of which look identical from the outside: **app running, no window, no way in.**

- **Off-screen on an external display running a full-screen Space.** `NSWindow.center()` centres on `NSScreen.main` — whichever display had focus at launch. With an AirPlay display attached, the onboarding window landed at (2759, 30) on a full-screen Space and was never composited. A new `WindowPlacement` helper pins app windows to the **built-in/primary** display, clamps the frame inside that screen's `visibleFrame`, adds `.moveToActiveSpace`, and activates. Applied to onboarding, the permission pre-prompt and the enrollment window.
- **A 1×0 window frame before SwiftUI laid it out.** Caught on the real 1.6.2 bundle: an `NSWindow` built from an `NSHostingController` has a 1×0 frame until first layout, so centring `window.frame.size` placed onboarding as a 1×0 window (log: `frame={{899,604},{1,0}}`). The window now measures its content's fitting size first and re-centres on the host screen if SwiftUI resizes it on first display.

Device check after the fix: onboarding lands at `{{640,380},{520,448}}` on the Built-in Retina Display, `onscreen=true`. Both paths log a **`window settled:`** line — `occlusionState` only means anything after the window server has composited.

### Meeting prompt panel had the same notch occlusion (7e82ace)
`MeetingPromptPanel` placed itself at `screen.frame.maxY - height - 8` on `NSScreen.main`, so its top ~30 pt sat under the camera housing — the same bug fixed for the pill in 1.6.1. It now uses the shared `NotchGeometry` top-band rule and the pill's host-screen rule, and logs its frame.

### Pill waveform was dead (7a629a4)
`DictationCoordinator` called `pill.model.bind(engineState:)` **without the `audioLevel:` argument**, so the only levels the waveform ever saw came from `EngineState.listening(level:)` — and `RealEngine` stopped emitting those the moment a preview moved the state to `.previewing`. Levels were, in effect, never passed to the pill and stopped at preview.

`RealEngine` now publishes levels on their own publisher for the whole utterance (`AudioLevelPublishing`); the app drives the pill from `PipelineAudioSource.onLevel` — real captured audio — and falls back to engine states only on the mock / `VOICEPLUS_FIXTURE` path.

### Bundle-first resource lookup (69a12c7)
`AppPaths.fixturesDirectory()` and `ActionCatalog.defaultURL()` resolved a `#filePath`-relative source-tree path **first** and only fell back to `Bundle.main`, so a dev build never exercised the lookup a user's install actually takes. Now **bundle first, source checkout second** (kept so `swift test` / `swift run` still find `Fixtures/`).

### Also
`verify_install.sh` had a flaky check: `codesign | grep -q` under `set -o pipefail` SIGPIPEs the producer when grep matches early, so a correct bundle intermittently reported "Identifier != CFBundleIdentifier".

---

## Install
1. Follow **Before you install** above — in order. Steps 1–2 fix the overwhelming majority of "no prompt appeared".
2. First launch: right-click → **Open** (ad-hoc signed, not notarized).

Verify the artifact: `shasum -a 256 VoicePlus_6_1.6.2.dmg` must match
`651ace2609b30309ef13334437bdc2c67ef1af824155b33cff8e589d206ac486`
(also in `Packaging/releases/CHECKSUMS.txt`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test — passed for this artifact.

Includes everything in 1.6.1: the TCC-critical `Info.plist` keys, hardened-runtime ad-hoc signing and rpath strip; the onboarding permission recovery flow (deep link, 0.5 s live polling, Re-check, Continue anyway, per-permission Skip, stale-TCC recovery copy); the pipeline-driven mic meter; and the notch-clear pill. See `Packaging/notes/phase-6-1.6.1.md`.

---

## What was NOT verified on real hardware

These are covered by automated tests (1006 pass) and instrumented with log lines, but no one has watched them run on the notched MacBook:

- **Audio actually arriving from the physical mic** at the mic-check step.
- **The permission poll against real TCC** (tested against a mock status source).
- **Multi-display placement** — the off-screen fix was verified on the built-in display only; the AirPlay/full-screen-Space case that caused it has not been re-reproduced.
- **The pill waveform during live dictation.**

If any of them still misbehaves, this shows exactly where it stops:

```bash
log stream --predicate 'subsystem == "in.adityakatare.voiceplus"'
```

Look for `mic check: capture started on …`, `mic check: first audio block reached the meter`, `onboarding poll: …`, and `window settled: …`.

## Also note
During debugging, an agent ran `defaults delete in.adityakatare.voiceplus`, which **cleared the app's saved preferences** — the onboarding-completed flag, the hotkey choice, and routing overrides. Onboarding will therefore run again from the top and those settings need re-picking. Dictionary, history and profile data live in the app's database, not in `defaults`, and were not touched.

## Carried limitations
Everything in `Packaging/notes/phase-6.md` still applies: Indic RNNT weights not shipped, iOS keyboard source-only, `directedSpeech` off by default, no notarization.
