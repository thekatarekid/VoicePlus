# VoicePlus 1.7.14 — the Actions key could not be rebound or turned off

The owner pressed **Right ⌘** expecting to dictate, and got:

> Actions need a model set up in Settings

**Right ⌘ was their _Actions_ key. Dictation was Right ⌥.** So the message was, strictly,
correct, and **their dictation was never broken.** But two things about that were genuinely
wrong, and both are the same root cause: **the Actions feature shipped with no UI at all.**

Ships in the same dmg as 1.7.13 — **this is the dmg**. Tag `release/phase-6/v1.7.14` · 2 commits
(`86c41da`, `59ad925`) on top of 1.7.12 (`823fda0`), interleaved in history with 1.7.13's ·
sha256, date and dmg size ⏳ recorded at the release build.

## 1. What was actually happening

- **The message named a Settings row that did not exist.** **`act.planner` was not among the
  routable stages**, so there was **nothing in the UI to configure** — the only way to route it
  was a **`defaults write`**. The pill pointed the user at a place they could not go.
- **The Actions key had no UI either.** **Nothing wrote `actHotkeyBinding`**, it appeared in
  **no menu and no settings pane**, and there was **no way to disable it**. Every fresh install
  therefore shipped a **live Right ⌘** that users would press **by accident**, with **no
  discoverable way to change or silence it** — and the only thing it could do was report a
  missing provider.

## 2. What ships instead

- **`act.planner` is routable, and appears as "Actions (voice commands)"** under Models,
  persisted through the **same `routing.<stage>` key** as every other stage — the exact key the
  old `defaults write` workaround used, so an existing hand-written pin is picked up rather than
  ignored.
- **It offers Auto and connected providers only — no local option.** **There is no local
  planner**, so a *"Local · balanced"* row would have been a **second unreachable instruction**,
  which is the defect being fixed, not a fix.
- **The Actions key is rebindable from both the menu-bar item and Settings › General**, with
  **"off" folded into the same picker** — so you **cannot end up with a live key and a dead
  feature**, which is precisely the state the owner was in.
- **The default is now off.** Actions **can do nothing until a provider is pinned**, so an
  armed-by-default key could only **swallow a keypress and report a missing provider**.
  **Installs that had set `actHotkeyBinding` by hand keep their opt-in** — turning off a key
  someone deliberately chose would be its own defect.
- **Off means the event source is never installed**, not that its events are dropped:
  `CapabilityWatcher` treats a switched-off key like a **revoked permission**. The switch is
  **re-read each tick**, so the picker **takes effect within a second, with no relaunch**.
- **The 1.7.10 collision guard is byte-for-byte unchanged.** It now sits behind
  **`ActKeyBinding.isLive`**, which simply **ANDs a second reason to stay shut** onto
  `isDistinct`. **Bind both to the same key and dictation still wins.** Both pickers **label the
  colliding key rather than hiding it**, so the rule is visible instead of mysterious.

## 3. Tests

- New `Tests/AppTests/ActKeySettingsTests.swift` — **14 tests**: `act.planner` is a routable
  stage whose pin **persists under `routing.act.planner`**; the act key is **off on a fresh
  install**, **rebindable**, and **silenceable**; a switched-off key is **inert for every pairing
  of the two bindings** *and* is **never armed by `CapabilityWatcher` at all**; arming **re-reads
  a binding written while the key was off**; and the **1.7.10 `isDistinct` guard is unchanged**.
- **`swift build` clean**; the full-package test total is recorded at the release build.

## 4. Also in this build: two investigations that changed no behaviour

Both were **plausible diagnoses of the dictation-accuracy problem, and measurement refuted
both** rather than confirming them. They ship as **tests and written-down numbers**, not as code
changes — recorded here so nobody re-derives them.

- **The always-on spectral-gate noise suppressor was suspected. It is _better_, not worse.**
  Measured **through** the acoustic chain (100 ms blocks, as `AcousticCaptureSource` feeds it)
  over **12 clean fixtures**: **`.raw` mean WER 0.0291 vs `.default` 0.0140**, and `.default` is
  equal or better at **every point of a 45→15 dB SNR room-floor sweep**. The pangram scored
  **WER 0.000 on both paths** across **3 accents and ±30 dB room floors**. The gate **does**
  mangle the waveform — **mean SDR 10.9 dB**, against a ~117 dB passthrough control — but
  **Parakeet is robust to it**. A **through-the-chain WER regression test** now sits alongside
  the existing bypass test, so this class of question is **answered by measurement in future**.
  Written up in `Engine/Audio/Robustness/SUITES.md`.
- **Biasing was suspected next. It was measured too.** **`FeatureFlag.contextBiasing` is off by
  default** and **no flags file exists on this machine**, so **no biaser was installed at all**.
  And **even enabled it cannot substitute a word**: on the real Parakeet path the rescorer runs
  **after** greedy TDT has finished and only **adjusts the confidence of tokens already chosen**.
  Measured: **byte-identical output on all 12 fixtures, WER 0.0291 both ways.** New coverage
  exercises the decoder **as `AppContainer` actually builds it** — a configuration that had
  **never been tested**, because every existing test resolved the recognizer through
  `RecognizerFactory` and left the biaser nil. **Privacy was confirmed clean along the way**:
  screen context is **accessibility-only**, held **in memory**, **rebuilt per utterance**, and
  **never written to disk**. Written up in `Engine/Biasing/README.md`.

Commits `429638b` and `4158ec4`; tests in `Tests/EngineTests/AcousticChainWERTests.swift`,
`Tests/EngineTests/BiasedDecodeWERTests.swift` and
`Tests/AppTests/ShippingDecoderConfigTests.swift`.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.13 and 1.7.14.** Its companion is the speech model that was downloaded
   twice — read its notes for what to check.

3. **Press your dictation key and confirm nothing else fires.** After this update the Actions
   key is **off by default** unless you had set it by hand, so a stray press should do
   **nothing at all** rather than report a missing provider.

4. **If you want Actions**, open **Settings › General**, pick a key for it — **anything other
   than your dictation key** — and then pin a provider for **"Actions (voice commands)"** under
   **Models**. The change takes effect **within a second**; no relaunch.

## Known and remaining

- **The live-microphone accuracy issue remains unresolved.** The **model, decoder, DSP and
  post-processing are all measured clean on fixture audio**, so the remaining suspect is **live
  capture itself**. Nothing in this build claims to have fixed it.
- **Untested on hardware:** that a **switched-off Actions key is silent under a real key press**,
  and that **rebinding it from either picker arms the new key without a relaunch**. No agent here
  has a keyboard event tap, a microphone or a window server; the switch, the arming rule and the
  collision guard are covered against protocols and mocks.
- **Every visual judgement is unverified** — the new picker in **Settings › General** and in the
  **menu-bar item**, and how the colliding key is labelled. The wording is tested; its appearance
  is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the
  first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
