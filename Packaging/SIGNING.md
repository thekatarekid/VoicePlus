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
