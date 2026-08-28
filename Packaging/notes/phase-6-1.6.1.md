# VoicePlus — 1.6.1 (patch on Phase 6)

Three bugs stopped onboarding dead on a real notched MacBook running macOS 26.6.2: "Allow Input Monitoring" did nothing and Accessibility was unreachable; the mic-check level bar never moved and insisted "Very quiet…" with the mic granted and the right input device selected; and the notch pill was drawn *under* the physical camera housing, so only its left and right ends were visible. All three are fixed here.

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

### Packaging — the reason macOS silently refused to prompt (1acf570)
- **TCC-critical `Info.plist` keys were missing.** `NSSpeechRecognitionUsageDescription`, `NSContactsUsageDescription`, `NSCalendarsFullAccessUsageDescription` (+ legacy `NSCalendarsUsageDescription`), `NSCameraUsageDescription`, `NSLocalNetworkUsageDescription` and `NSAccessibilityUsageDescription` were all absent. A missing purpose string makes macOS refuse *without logging anything and without drawing a dialog* — from the user's chair it is indistinguishable from "the prompt never appeared". `make_app.sh` now **fails the build** if any of the nine required keys is missing from the assembled bundle.
- **Hardened-runtime ad-hoc signing.** Signed with `--options runtime`, inside-out (never `--deep`), with `--identifier in.adityakatare.voiceplus` pinned so the signature's identifier can never drift from `CFBundleIdentifier` — a drift there makes TCC records unmatchable.
- **A non-relocatable `LC_RPATH` pointing at the build machine's toolchain was stripped**, and every Mach-O in the bundle is now audited for references to `/Users/…`, `/Library/Developer/…` or the SwiftPM scratch dir. Runtime resources are copied into `Contents/Resources` so nothing is read from a repo checkout the user does not have.

### BUG 1 — "Allow Input Monitoring" did nothing; Accessibility unreachable (17ac108)
`CGRequestListenEventAccess()` and `AXIsProcessTrustedWithOptions(prompt:)` are **not blocking consent dialogs**. They return the current authorization in microseconds and at most post a notification, so `false` is the guaranteed answer on a first call — and once any TCC row exists for the bundle id (for an ad-hoc build, that means *any earlier build*), they return `false` silently forever.

- Onboarding permission steps **never dead-end**. Every non-grant routes to one state that always offers **Open System Settings** (modern `PrivacySecurity.extension` pane id, legacy `Security.prefPane` fallback), **Re-check**, and **Continue anyway**.
- **Live status polling every 0.5 s** while the permissions step is visible, and on app re-activation — the checkmark flips the moment you toggle the switch in System Settings, with no click back in the app.
- **Stale-TCC recovery copy** after a repeated failed re-check: shows the bundle id, the cdhash, and a copyable `tccutil` command (never run for you).
- **Skip is now per-permission.** Previously Skip jumped past **all** remaining permissions in one go — which is exactly why Accessibility was unreachable after Input Monitoring failed.
- The menu-bar "Check permissions…" orchestrator gets the same treatment instead of stopping after it opens Settings.

### BUG 2 — mic-check bar frozen, always "Very quiet…" (17ac108)
Onboarding was metering **engine state, not audio**. `RealEngine` emits one synthetic `.listening(level: 0)` at start, before a single sample exists, which pinned the verdict to "too quiet" forever; the pipeline's purpose-built `.level(rms:)` channel had **no consumer at all**.

- The meter is now driven by the **real audio pipeline's level channel** (`PipelineMicLevelPublisher`). No ASR model is resolved, no recognizer runs, and `.previewing` can no longer freeze the meter. The old engine-state publisher survives only as the mock fallback, and the UI labels it as a simulated meter.
- **Real capture errors now reach the screen** with their actual message instead of being logged and swallowed; a start that timed out no longer reports success.
- The verdict distinguishes **"no audio ever arrived"** from **"audio arrived and it is quiet"**, and withholds "too quiet" until 1.5 s of real audio has actually been heard.

### BUG 3 — pill drawn under the camera housing (f1c5db8)
The notched branch placed the pill's top edge at `screen.frame.maxY`, so the top 38 pt across the housing's 220 pt had no physical panel behind it. Replaced with one rule: **the pill hangs off the bottom of the screen's forbidden top band** (`max(safeAreaInsets.top, menu-bar delta)`). Retract rolls up to that boundary instead of translating off the top, so the slide animation no longer passes through the housing either. Also: coordinate-space-safe notch width, re-layout on `didChangeScreenParameters`, and a startup log of the computed frames.

---

## Install
1. Follow **Before you install** above — in order. Steps 1–2 fix the overwhelming majority of "no prompt appeared".
2. First launch: right-click → **Open** (ad-hoc signed, not notarized).

Verify the artifact: `shasum -a 256 VoicePlus_6_1.6.1.dmg` must match
`020958a94e1af2b51831a0ece5b1d11c09e89d2aaaf2020f821ccdddd134d612`
(also in `Packaging/releases/CHECKSUMS.txt`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test — passed for this artifact.

**A newer patch exists: install `VoicePlus_6_1.6.2.dmg` instead** unless you specifically want this build.

---

## What was NOT verified on real hardware

These are covered by automated tests and instrumented with log lines, but no one has watched them run on the notched MacBook:

- **Audio actually arriving from the physical mic** at the mic-check step.
- **The permission poll against real TCC** (tested against a mock status source).
- **Multi-display placement** of the pill.
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
