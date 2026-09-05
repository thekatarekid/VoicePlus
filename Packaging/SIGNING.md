# Signing, TCC, and "the permission prompt never appeared"

This documents why VoicePlus's privacy prompts are fragile, what the build does
about it, and exactly what a user has to do by hand when a grant does not stick.

Since 1.6.4 the build produces a **build-independent designated requirement**, so
TCC grants survive rebuilds without any Apple Developer Program membership —
§4 is the fix, not a workaround. What still needs a Developer ID and
notarization is Gatekeeper, quarantine and App Translocation (§5).

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

An **ad-hoc signature has no Team ID and no certificate.** Its designated
requirement degrades to `cdhash H"<exact hash of this exact binary>"`. Every
rebuild produces a different cdhash, so:

- macOS treats each build as a **different application** that happens to reuse
  the bundle id `in.adityakatare.voiceplus`;
- the stale TCC row for that bundle id no longer matches the running binary;
- for Input Monitoring and Accessibility the system **denies without
  re-prompting**. `CGRequestListenEventAccess()` returns `false` instantly and no
  dialog is drawn.

Microphone behaves better (it re-prompts more willingly), which is why the
reported symptom was "the mic prompt worked, Input Monitoring produced nothing".

#### The switch and the requirement are different columns

This is the part that makes the bug look supernatural, and it was measured on the
reporting machine (macOS 26.6.2, VoicePlus 1.6.3) rather than reasoned about.

A TCC row holds *both* an `auth_value` (the switch you see in System Settings)
**and** a `csreq` (the code requirement, captured when the switch was first
turned on). tccd re-evaluates the requirement on every single query. Flipping the
switch off and on rewrites `auth_value` only — **it never rewrites `csreq`**. So a
row can show as ON and answer "not granted" forever:

```
tccd  matchesCodeRequirement: … from in.adityakatare.voiceplus : cdhash H"219911ca…"; status: -67050
tccd  Failed to match existing code requirement for subject in.adityakatare.voiceplus
      and service kTCCServiceListenEvent
```

`-67050` is `errSecCSReqFailed`. The running build's cdhash was `cb56c554…`; the
Input Monitoring row stored `219911ca…` and the Accessibility row `459b5909…` —
two *different* long-gone dev builds. Same binary, same bundle id, three services,
three stored requirements.

Two conclusions worth writing down, because both contradict the obvious guess:

- **Restarting the app does not help.** A brand-new process of the installed app
  read `AXIsProcessTrusted() == false` and `CGPreflightListenEventAccess() ==
  false` immediately. There is no per-process cache to defeat; every 0.5 s poll is
  a fresh tccd round-trip that is freshly answered "no match".
- **Neither does the Re-check button.** It asks a question whose answer cannot
  change until the row is replaced.

The microphone escaped only because it is promptable:
`AVCaptureDevice.requestAccess` **rewrites the row with the current cdhash**.
Input Monitoring and Accessibility have no such call, so they have no way back.

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
- **Picks the strongest available signing identity** and, when there is none,
  pins an explicit designated requirement so the signature is still stable across
  builds. In order: `CODESIGN_IDENTITY` if set; otherwise a valid keychain
  identity named `VoicePlus Local Signing` (`CODESIGN_CERT_NAME` overrides the
  name); otherwise ad-hoc **plus** `-r '=designated => identifier
  "in.adityakatare.voiceplus"'`. See §4.
- **Fails the build if no designated requirement can be read back**, and prints a
  loud `WARNING` if the requirement still contains a `cdhash` clause — that is
  the exact condition under which a user's grants die on the next build. The
  requirement is echoed in the build log, so every release has it on record.
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

## 3. User-facing recovery: "the switch is on but VoicePlus says it is off"

Give the user these steps, in order. Steps 1–2 fix the overwhelming majority.

Ask for the app's own report first — it is one launch and no clicking, and it
prints the requirement TCC is evaluating against, which is the whole answer:

```bash
open -n -a /Applications/VoicePlus.app --args --onboarding-selftest
/usr/bin/log show --last 1m --predicate 'subsystem == "in.adityakatare.voiceplus"' \
  --info --style compact | grep "permission report"
```

`designatedRequirement=cdhash H"…"` means grants cannot survive a rebuild;
`identityStable=true` means they can. `AXIsProcessTrusted()=false` /
`CGPreflightListenEventAccess()=false` next to a visibly-on switch is the
stale-`csreq` case in §1 Gate B, and step 3 is the only cure.

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

**4. Once, not once per update.** Step 3 has to be done exactly once for a build
whose report says `identityStable=true` (§4). Rows created by a pre-1.6.4 build
store that build's cdhash and stay unmatchable forever, so every user upgrading
from 1.6.3 or earlier has to do it one final time. Reboot only if steps 1–3 all
fail.

---

## 4. The fix available today: a build-independent designated requirement

No Apple Developer Program membership is needed for this part. The requirement
TCC stores has to stop naming one exact binary; that is the whole trick, and
there are two ways to do it. `make_app.sh` picks the strongest one available.

### 4a. Ad-hoc + an explicit designated requirement (default, zero setup)

`codesign` lets the requirement be stated instead of derived:

```bash
codesign --force --sign - --options runtime --identifier in.adityakatare.voiceplus \
  -r '=designated => identifier "in.adityakatare.voiceplus"' VoicePlus.app
codesign -d -r- VoicePlus.app
#   designated => identifier "in.adityakatare.voiceplus"
```

That string is a property of the bundle id, not of the bytes, so it is identical
in every build while the cdhash changes — measured, see §4c. TCC stores it at
grant time and re-evaluates it per launch, so the grant keeps matching.

Trade-off, stated plainly: an `identifier`-only requirement has no anchor, so any
other locally signed binary claiming the same bundle id would satisfy it too.
That is not a regression — an ad-hoc build has no Team ID to check against
either, and anyone able to place a binary in `/Applications/VoicePlus.app` has
already won. §4b removes even that.

### 4b. A self-signed certificate (stronger; one administrator command)

A self-signed code-signing certificate gives the signature a stable *leaf*, so
codesign derives `identifier "…" and certificate leaf H"…"` by itself — anchored,
and still no Developer Program.

```bash
Packaging/make_signing_cert.sh          # creates + imports; never asks for a password
```

The script is non-interactive up to the last step. Creating and importing the
certificate is scriptable; **trusting** it is not, and cannot be worked around:

```
security find-identity -p codesigning
  1) AF1E96AF…  "VoicePlus Local Signing" (CSSMERR_TP_NOT_TRUSTED)
     Valid identities only:  0 valid identities found
codesign --sign "VoicePlus Local Signing" …   →  "…: no identity found"
```

`codesign` refuses an untrusted identity even when pointed straight at the
keychain that holds it, and even when given its SHA-1 instead of its name. Trust
writes to the system trust store, so it needs an administrator password:

```bash
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain \
  "$HOME/Library/Application Support/VoicePlus/VoicePlus Local Signing.cer"
security find-identity -v -p codesigning     # must now list it
```

GUI equivalent if `sudo` is unwanted: open the `.cer` in Keychain Access, expand
**Trust**, set **Code Signing** to **Always Trust**.

`make_app.sh` then picks it up automatically (or pass
`CODESIGN_IDENTITY="VoicePlus Local Signing"`). Until it is trusted the build
falls back to §4a and says so — it never fails because of a missing certificate.

Keep `com.apple.security.cs.disable-library-validation` in
`Packaging/VoicePlus.entitlements`: a self-signed certificate still has no Team
ID, so library validation would refuse the embedded frameworks. Only a real
Developer ID lets that entitlement go.

### 4c. How to check it actually worked

Build twice with a version bump and compare. The requirement must be
byte-identical while the cdhash moves:

```bash
codesign -d -r- Packaging/build/VoicePlus.app   # designated => …
codesign -dvvv  Packaging/build/VoicePlus.app 2>&1 | grep CDHash=
```

`make_app.sh` prints both and warns if the requirement still contains `cdhash`.

Measured on the reporting machine, two assemblies of the same source at 1.6.4 and
1.6.5:

```
build A  CDHash=07802cae335ea9750d0992bfbf77c358b85315ca
build B  CDHash=934a9d35ba91abe75bedb893e423cb12dc5083dd
both     designated => identifier "in.adityakatare.voiceplus"     (cmp: identical)
codesign --verify -R=<A's requirement> buildB   →  explicit requirement satisfied
codesign --verify -R=<B's requirement> buildA   →  explicit requirement satisfied
```

For contrast, shipped 1.6.3:
`# designated => cdhash H"cb56c554cba441f6fef195efaa7ea5ac8a0715e2"` — a value
that exists only for that one binary.

And the mechanism itself, caught live: launching build A (cdhash `07802cae…`)
made tccd re-evaluate all three of 1.6.3's rows and fail every one, each against a
*different* old build's hash —

```
tccd  … from in.adityakatare.voiceplus : cdhash H"cb56c554…"; status: -67050   kTCCServiceMicrophone
tccd  … from in.adityakatare.voiceplus : cdhash H"219911ca…"; status: -67050   kTCCServiceListenEvent
tccd  … from in.adityakatare.voiceplus : cdhash H"459b5909…"; status: -67050   kTCCServiceAccessibility
```

— while the app's own report from the same launch read
`AXIsProcessTrusted()=false`, `CGPreflightListenEventAccess()=false`,
`identityStable=true`. Three services, one binary, three stored requirements:
that is `csreq` being per-row and per-build, and it is exactly what §4a removes.

Note the microphone line: a grant given to 1.6.3 does **not** transfer to a
rebuild either. It recovers by itself because the microphone is promptable —
`AVCaptureDevice.requestAccess` rewrites the row, and from 1.6.4 onwards it
rewrites it with the build-independent requirement. Input Monitoring and
Accessibility have no such call, which is why they need §3 step 3 exactly once.

### 4d. What this does NOT buy

Nothing here touches Gatekeeper. Self-signed and ad-hoc both still mean:

- `spctl --assess` rejects the app;
- a downloaded dmg is quarantined, so the app needs
  `xattr -dr com.apple.quarantine /Applications/VoicePlus.app`;
- App Translocation (§1 Gate C) still applies until quarantine is cleared, and a
  translocated copy can never hold a TCC grant, whatever its requirement says.

Only notarization fixes those — §5.

---

## 5. The complete fix: Developer ID + notarization

```bash
CODESIGN_IDENTITY="Developer ID Application: <Name> (TEAMID)" \
  Packaging/make_app.sh <version>
xcrun notarytool submit <dmg> --keychain-profile <profile> --wait
xcrun stapler staple <dmg>
```

With a Team ID in the signature the designated requirement is stable *and*
anchored to Apple, Gatekeeper stops warning, App Translocation stops happening,
and §3 and §4 both become unnecessary. Also remove
`com.apple.security.cs.disable-library-validation` from
`Packaging/VoicePlus.entitlements` at that point.
