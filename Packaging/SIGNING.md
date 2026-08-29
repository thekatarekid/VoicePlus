# Signing, TCC, and "the permission prompt never appeared"

This documents why VoicePlus's privacy prompts are fragile today, what the build
does about it, and exactly what a user has to do by hand when a prompt does not
show up. **Every problem in this file disappears the day we have a Developer ID
certificate and notarize the app.** Nothing here is a fix; it is damage control
around a hard constraint (no Developer ID identity on the build machine).

---

## 1. How macOS decides whether to show a permission prompt

Two separate gates have to pass. They fail in different, confusingly silent ways.

### Gate A — the Info.plist usage string

For most TCC services, the app must ship a purpose string in `Info.plist`. If it
is missing, macOS does **not** log a warning and does **not** show a prompt — it
either kills the process outright on first use, or returns "denied" immediately.
From the user's chair that looks identical to "the dialog never appeared".

| API used by VoicePlus | Source | Required key |
|---|---|---|
| `AVCaptureDevice` / `AVAudioEngine` | `App/Services/PipelineAudioSource.swift` | `NSMicrophoneUsageDescription` |
| `SFSpeechRecognizer` | `Engine/ASRRuntime/AppleSpeechRecognizer.swift` | `NSSpeechRecognitionUsageDescription` |
| `CNContactStore` | `Engine/Biasing/LiveProviders.swift`, `App/Onboarding/ContactsImport.swift` | `NSContactsUsageDescription` |
| `EKEventStore` | `Engine/Meeting/MeetingDetector.swift` | `NSCalendarsFullAccessUsageDescription` (+ legacy `NSCalendarsUsageDescription`) |
| CoreMediaIO camera-in-use polling | `Engine/Meeting/MeetingDetector.swift` | `NSCameraUsageDescription` |
| Apple Events / AX injection | `Injection/LiveSystemAccess.swift` | `NSAppleEventsUsageDescription`, `NSAccessibilityUsageDescription` |
| `NWListener` OAuth loopback | `Providers/OAuthPKCE.swift` | `NSLocalNetworkUsageDescription` |

`make_app.sh` now **fails the build** if any of these keys is missing from the
assembled bundle. Keep `App/Resources/Info.plist` and
`Packaging/Info.plist.template` in sync; the App module's plist wins.

Two services have **no usage-description key at all**:

- **Input Monitoring** (`kTCCServiceListenEvent`) — the global-hotkey `CGEventTap`
- **Accessibility** (`kTCCServiceAccessibility`) — text injection
- (also **Screen Recording**, for the ScreenCaptureKit system-audio fallback)

Adding `NSInputMonitoringUsageDescription` does nothing; no such key exists.
These three are gated entirely on Gate B.

### Gate B — the code signature

TCC stores each grant against **the app's code-signing identity**, not its path.
For a properly signed app that identity is the *designated requirement* — roughly
"bundle id `X` signed by Team `Y`" — which survives updates, so a new build
inherits the user's previous answer.

An **ad-hoc signature has no Team ID.** Its designated requirement degrades to
`cdhash H"<exact hash of this exact binary>"`. Every rebuild produces a different
cdhash, so:

- macOS treats each build as a **different application** that happens to reuse
  the bundle id `in.adityakatare.voiceplus`;
- the stale TCC row for that bundle id no longer matches the running binary;
- for Input Monitoring and Accessibility the system **denies without
  re-prompting**. `CGRequestListenEventAccess()` returns `false` instantly and no
  dialog is drawn.

Microphone behaves better (it re-prompts more willingly), which is why the
reported symptom was "the mic prompt worked, Input Monitoring produced nothing".

#### Tested and rejected: "hardened runtime breaks TCC on an ad-hoc signature"

1.6.0 was `flags=0x2(adhoc)`; 1.6.1+ is `flags=0x10002(adhoc,runtime)`. When 1.6.2
stopped showing the microphone prompt, the hardened-runtime switch was the obvious
suspect. **It is not the cause. Do not revert `--options runtime` chasing a missing
prompt.** Measured on macOS 26.6.2 with three probe bundles that differ only in how
they are signed, each calling `AVCaptureDevice.requestAccess(for: .audio)`:

| probe | signature | result |
| --- | --- | --- |
| plain | ad-hoc, no hardened runtime | real dialog, `AUTHREQ_PROMPTING`, row created |
| runtime | ad-hoc + `--options runtime` | real dialog, `AUTHREQ_PROMPTING`, row created |
| full | ad-hoc + runtime + the entitlements we ship | real dialog, `AUTHREQ_PROMPTING`, row created |

tccd also logs `Prompting policy for hardened runtime; allow prompt: Allow` for
VoicePlus itself. TCC attributes and persists ad-hoc identities fine; the missing
Team ID costs us grant *stability* across rebuilds (above), not the prompt.

The 1.6.2 microphone regression was an onboarding-flow bug: the app never called
`requestAccess` at all, so tccd logged only `preflight=yes` status queries and no
`preflight=no` request. Since that call is the only way an app can appear in
Privacy & Security › Microphone — **that pane has no "+" button** — the user could
not add it by hand, and `tccutil reset Microphone` alone did nothing. See
`OnboardingStateMachine.initialPhase` and `Permission.isPromptable`.

**Diagnosing this class of bug:** ask tccd whether the app asked at all.

```bash
/usr/bin/log show --last 2m --predicate 'process == "tccd"' --info --debug \
  --style compact | grep -i -E "Microphone|voiceplus"
```

`preflight=yes` is a *status query* (`authorizationStatus`). `preflight=no` plus
`AUTHREQ_PROMPTING` is a *real request*. Only the second one registers the app.
No microphone lines at all means the bug is in our code, not in the signature.

To make the app ask without clicking through onboarding, use the headless self-test.
Launch it through LaunchServices — running the executable from a shell makes TCC
attribute the request to the terminal instead of to VoicePlus:

```bash
tccutil reset Microphone in.adityakatare.voiceplus
open -n -a Packaging/build/VoicePlus.app --args --request-permission microphone
```

It prints `before:`/`after:` lines and logs `permission self-test: … -> granted`.
A passing 1.6.3 build produces, for `in.adityakatare.voiceplus`:
`AUTHREQ_CTX … preflight=no` → `AUTHREQ_PROMPTING … kTCCServiceMicrophone` →
`TCCDEvent: type=Create, service=kTCCServiceMicrophone`.

### Gate C — App Translocation (the other silent killer)

An app that is quarantined (downloaded dmg) **and** not notarized is run from a
randomised read-only path under `/private/var/folders/.../AppTranslocation/`
instead of where the user put it. Permissions granted to a translocated copy are
attached to a path that vanishes on next launch, so grants never stick and
prompts can fail to appear. Dragging the app to `/Applications` in Finder usually
breaks translocation; `xattr -dr com.apple.quarantine` definitely does.

---

## 2. What the build does about it

`Packaging/make_app.sh`:

- **Verifies all nine usage strings** are present and fails the build otherwise.
- **Signs with the hardened runtime** (`--options runtime`). Ad-hoc + hardened
  runtime validates fine locally, and it is what a real Developer ID build will
  use, so the entitlement set is exercised now rather than at notarization time.
  `com.apple.security.cs.disable-library-validation` is required with it: an
  ad-hoc signature has no Team ID, so library validation would otherwise refuse
  to load any embedded framework.
- **Signs inside-out, never `--deep`.** `--deep` is deprecated and applies the
  app's entitlements to nested binaries, which is wrong. Nested bundles are
  signed first without entitlements; the outer app last, with them.
- **Pins `--identifier in.adityakatare.voiceplus`** so the identifier recorded in
  the signature can never drift from `CFBundleIdentifier`. A mismatch there makes
  TCC records unmatchable.
- **Strips non-relocatable `LC_RPATH` entries** and audits every Mach-O in the
  bundle for references to `/Users/…`, `/Library/Developer/…` or the SwiftPM
  scratch dir. (The CLT bootstrap shim bakes
  `$HOME/Library/Developer/VoicePlus-toolchain/Library/Developer/Frameworks`
  into the binary; it is removed.)
- **Copies runtime resources into `Contents/Resources`** so nothing is read from
  a repo checkout the user does not have.

Verify a build by hand:

```bash
codesign -dvvv --entitlements :- Packaging/build/VoicePlus.app
codesign -vv --strict --deep    Packaging/build/VoicePlus.app
plutil -p Packaging/build/VoicePlus.app/Contents/Info.plist
```

---

## 3. User-facing recovery: "VoicePlus never asked for Input Monitoring"

Give the user these steps, in order. Steps 1–2 fix the overwhelming majority.

**1. Install it properly, then clear quarantine.**

```bash
# Drag VoicePlus.app from the dmg into /Applications first, then:
xattr -dr com.apple.quarantine /Applications/VoicePlus.app
```

Launch it from `/Applications`, never from the mounted dmg or `~/Downloads`.

**2. Reset the stale TCC records and try onboarding again.**

```bash
Packaging/reset_tcc.sh                     # in.adityakatare.voiceplus only
# equivalent to:
#   tccutil reset ListenEvent       in.adityakatare.voiceplus
#   tccutil reset Accessibility     in.adityakatare.voiceplus
#   tccutil reset Microphone        in.adityakatare.voiceplus
#   tccutil reset SpeechRecognition in.adityakatare.voiceplus
```

Quit VoicePlus completely (menu-bar icon → Quit) **before** resetting, and
relaunch after. Never run `tccutil reset ListenEvent` with no bundle id — that
clears Input Monitoring for every app on the Mac.

**3. Add the app manually.** Input Monitoring and Accessibility can always be
granted without any prompt:

- System Settings → Privacy & Security → **Input Monitoring** → **+** →
  `/Applications/VoicePlus.app` → toggle on
- System Settings → Privacy & Security → **Accessibility** → **+** →
  `/Applications/VoicePlus.app` → toggle on

If a `VoicePlus` row is already listed, select it, press **−** to remove it, then
re-add with **+**. A stale row that no longer matches the current build's cdhash
is precisely what suppresses the prompt, and toggling it off/on does not fix
that — it has to be removed and re-added.

**4. After each new build.** Because the cdhash changes, expect to repeat step 3
(or step 2) on every update until the app is notarized. Reboot only if steps 1–3
all fail; `tccd` occasionally caches an old identity.

---

## 4. The real fix

Get an Apple Developer ID Application certificate and notarize:

```bash
CODESIGN_IDENTITY="Developer ID Application: <Name> (TEAMID)" \
  Packaging/make_app.sh <version>
xcrun notarytool submit <dmg> --keychain-profile <profile> --wait
xcrun stapler staple <dmg>
```

With a Team ID in the signature the designated requirement becomes stable across
builds, so TCC grants persist through updates, Gatekeeper stops warning, App
Translocation stops happening, and everything in section 3 becomes unnecessary.
Also remove `com.apple.security.cs.disable-library-validation` from
`Packaging/VoicePlus.entitlements` at that point.
