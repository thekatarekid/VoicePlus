# VoicePlus — 1.6.3 (patch on Phase 6)

**This is the build to install.** 1.6.3 fixes a regression **we introduced in 1.6.1/1.6.2**: on those builds you could not grant Microphone at all. The onboarding Microphone screen opened straight into the "macOS only asks once" recovery UI — no **Allow** button anywhere — and VoicePlus never appeared in System Settings → Privacy & Security → **Microphone**, so there was nothing to switch on either. A permanent dead end. Along with the fix, three related defects found in the same pass are fixed here.

**1032 tests pass** (two consecutive full runs).

---

## ⚠️ Before you install — please read

**1. Replace the app and clear quarantine.**
Quit any running VoicePlus (menu-bar icon → Quit), open the dmg, drag **VoicePlus** to **/Applications** replacing the old copy, then:

```bash
xattr -dr com.apple.quarantine /Applications/VoicePlus.app
```

**2. Permissions granted to an earlier build do not carry over to this one.**
The app is **ad-hoc signed** (no Developer ID certificate exists for this project). macOS therefore identifies it by a **code hash that changes with every single build**, so to TCC this dmg is a different application from the one you granted last time. tccd says so literally:

```
Failed to match existing code requirement
```

What that means per pane:

- **Microphone** — nothing to do. The app will simply **ask again**; that is exactly the fix in this release. Click **Allow** when the dialog appears.
- **Input Monitoring** and **Accessibility** — macOS never prompts for these, so a stale row silently denies the new build. Open System Settings → Privacy & Security → **Input Monitoring**, select the existing **VoicePlus** row, remove it with **−**, then add `/Applications/VoicePlus.app` with **+**. Do exactly the same under **Accessibility**. From the terminal, `Packaging/reset_tcc.sh` does the same thing (VoicePlus's bundle id only — it never wipes a service for every app).

**3. This repeats on every update.** It is not something the build can work around. The real cure is signing with an Apple **Developer ID** certificate and **notarizing**; until that identity exists, every new dmg is a new app as far as macOS is concerned. See `Packaging/SIGNING.md` §4.

---

## What's fixed

### The microphone dead end (39cb91d, 375f97a)

**What happened.** The 1.6.1 permission rewrite persisted an "asked once" flag (`onboarding.requested.<permission>`), and `OnboardingStateMachine.initialPhase` opened **any** permission carrying that flag directly in the settings-recovery phase. That is correct for Input Monitoring and Accessibility — macOS genuinely never prompts for those, and their panes have **+**/**−** buttons. It is fatal for the microphone.

The only call site of `AVCaptureDevice.requestAccess(for: .audio)` is the **Allow** button, which is rendered solely in the `.explain` phase. Skip `.explain` and the API is never called — and calling that API is the **only** way an app can ever appear in the Microphone list, because that pane has no **+** button to add one by hand. So: flag set, plus a `tccutil reset` clearing the actual grant, equalled a screen telling you to enable an app that was not in the list and could not be put there. Forever.

Proven from tccd: 1.6.2 emitted only `preflight=yes` status queries and **never** a `preflight=no` request.

**The fix.** Promptable services (microphone, speech recognition, contacts, calendars) are now modelled separately from non-promptable ones (input monitoring, accessibility):

- A promptable service whose **live** status is `notDetermined` **always** opens on the Allow button, whatever any persisted flag says.
- A dismissed dialog stays retryable — a request that resolves still-`notDetermined` keeps the Allow button instead of becoming a Settings problem.
- The 0.5 s poll **self-heals a stale flag**, so a `tccutil reset` now recovers in-app with no rebuild and no Terminal.
- **Re-check** re-invokes the API for an undecided promptable service, and the recovery panel gained an **"Ask macOS again"** button.
- Per-service copy is now truthful: "macOS only asks once" and the remove-with-**−**/add-with-**+** instructions appear **only** for Input Monitoring and Accessibility, whose panes actually have those buttons.

Verified on real hardware: after `tccutil reset Microphone`, tccd logged `AUTHREQ_CTX … preflight=no` and `AUTHREQ_PROMPTING … kTCCServiceMicrophone, subject=Sub:{in.adityakatare.voiceplus}`, the dialog appeared, and TCC created the record.

**Hardened runtime was investigated and CLEARED — do not revert it.** The obvious suspect for a missing prompt was `--options runtime` on an ad-hoc signature. It is not the cause. Probe bundles signed ad-hoc **with** `--options runtime` and our exact entitlements got the real prompt and registered normally. `--options runtime` **stays**; the evidence is written up in `Packaging/SIGNING.md`, along with how to read `preflight=yes` vs `preflight=no` in tccd, so nobody chases this again.

### Fix A — meeting capture is now opt-in (a43fc80)

Every launch previously requested **Calendar and Reminders** authorization with no user intent at all. `AppDelegate` called `MeetingCoordinator.startMonitoring()` unconditionally, and `startMonitoring()` called `requestAccess()` unconditionally; the Reminders prompt came along because `EKEventStore()`'s no-argument initialiser covers **every** entity type, so merely holding one as a stored property made TCC evaluate both. A user who never wanted meeting capture got two dialogs out of nowhere on first run — the mirror image of the microphone bug: a promptable service asked without the user ever choosing the feature.

Meeting capture is now **off by default**. `startMonitoring()` is inert until the user enables **"Capture meetings"**; launch is status-query only; and the notification request moved to *after* a meeting the user accepted actually produced notes. tccd on a clean launch now shows **zero** Calendar/Reminders lines and **zero** prompts of any kind.

### Fix B — the onboarding phase is now logged (e7343c5, fca72b8)

The original regression was **invisible in logs** — the dead end and the correct path were byte-identical in `os_log`, which is why it took a user report to find it. The permission step now logs one concise line when it is entered or advances:

```
onboarding: microphone status=notDetermined phase=explain
```

Plus a headless `VoicePlus --onboarding-selftest`, which drives the real view model from welcome through every permission with the live TCC checker — no window, no click, no authorization request — so a build's phase lines can be read back directly. It reads your real persisted `onboarding.requested.*` flags (a stale flag plus a live `notDetermined` status *was* the bug), and its writes are dropped, so reporting on the state cannot change it.

### Fix C — three wall-clock tests de-flaked (3efde4b)

Each passed in isolation by 20–600× its own margin and failed under a loaded run, so every release showed a different random subset red — which would mask a real regression rather than catch one. **Nothing was deleted**; each assertion is restated as the thing it was actually there to prove: two timeouts became hang guards at 120 s / 60 s, the chaos latency check is now load-normalised against a baseline measured in the same run under the same contention, and the suite is `.serialized`.

---

## Install

1. Follow **Before you install** above, in order.
2. First launch: right-click → **Open** (ad-hoc signed, not notarized).
3. Walk the permission steps. Microphone will prompt; Input Monitoring and Accessibility need the **−** / **+** dance from step 2.

Verify the artifact: `shasum -a 256 VoicePlus_6_1.6.3.dmg` must match
`5cde1597ffeb337ade8dcac93da748d0d88d2220807a9819ccab06a3bf3058b4`
(also in `Packaging/releases/CHECKSUMS.txt`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test — passed for this artifact.

Includes everything in 1.6.1 and 1.6.2: the TCC-critical `Info.plist` keys, hardened-runtime ad-hoc signing and rpath strip, the onboarding permission recovery flow, the pipeline-driven mic meter, the notch-clear pill, on-screen window placement, and bundle-first resource lookup. See `Packaging/notes/phase-6-1.6.1.md` and `Packaging/notes/phase-6-1.6.2.md`.

---

## What was NOT verified on real hardware

- **The enable → Calendar-request path.** That flipping "Capture meetings" on is the single place a Calendar dialog can originate is unit-tested only; nobody has toggled it on the machine.
- **The microphone prompt appearing through the GUI Allow button.** The API call itself is proven via tccd (`preflight=no` → `AUTHREQ_PROMPTING` → TCC record created), but no one could click the dialog from an automated session.
- **The pill waveform during live dictation** — still carried over from 1.6.2.

If anything still misbehaves, this shows exactly where it stops:

```bash
log stream --predicate 'subsystem == "in.adityakatare.voiceplus"'
```

Look for `onboarding: <permission> status=… phase=…`, `onboarding poll: …`, `mic check: capture started on …` and `window settled: …`.

## Carried limitations

Everything in `Packaging/notes/phase-6.md` still applies: Indic RNNT weights not shipped, iOS keyboard source-only, `directedSpeech` off by default, no notarization.
