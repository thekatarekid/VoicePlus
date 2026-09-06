# VoicePlus 1.6.7 — the dictation key no longer kills the app

Patch release on the Phase 6 line, and the largest one since the line began. 1.6.6
armed the event tap for the first time, which meant a keypress could finally reach
the overlay code — and the overlay code was a trap instruction. Pressing the
dictation key killed VoicePlus, every time, on every Mac. That is fixed, along with
a green "It landed. You're set." that was reported for a transcript that never
existed, and a claim about relaunching that this release has to take back.

sha256 `12e2583638c27028b936b591b3cde96c0c4c77543ed10f847dfdb4c829f349a7`
Tag `release/phase-6/v1.6.7` · **1165 tests pass, 0 failures** · verify_install OK ·
13 commits (`8e8559f`…`f9ebac5`).

## 1. The crash (P1) — fixed

Three crash reports, byte-for-byte identical: `EXC_BREAKPOINT` (SIGTRAP) on the main
thread. The unified log gives the message verbatim:

    Fatal error: Use of unimplemented initializer
    'init(contentRect:styleMask:backing:defer:)' for class 'VoicePlusApp.OverlayWindow'

**Root cause.** `App/Overlay/OverlayWindow.swift:13` called the *five*-argument
`super.init(contentRect:styleMask:backing:defer:screen:)`. That is an ObjC
convenience initializer, and AppKit's implementation of it re-dispatches through
`self` to the *four*-argument designated initializer. `OverlayWindow` has stored
properties with no defaults and its own designated init, so it inherits none of
NSWindow's initializers and never overrode the four-argument one — for exactly that
case the Swift compiler emits an `@objc` stub whose entire body is a trap. AppKit
called the subclass. The subclass had a `brk #0x1` waiting.

Every capture start goes through `InkOverlayController.show()`, so
`InkOverlayController.show()` **could never succeed even once, on any Mac**.

**Reproduced standalone and deterministic.** A faithful reduction of the class:
5-arg `super.init` with a real screen → trap, exit 133 (128+5 = SIGTRAP); 5-arg with
`screen = nil` → same trap; 4-arg → survives; overriding the 4-arg designated init →
survives. Independent of the notch, of display count, and of whether `screen` is nil.

**It was not a 1.6.6 regression.** `App/Overlay/OverlayWindow.swift` has exactly one
commit and line 13 was never touched. What 1.6.6 changed was that `CapabilityWatcher`
finally armed the tap, so a keypress could reach the code at all. For PID 81294:
launched 19:36:12.72, "tap armed for Right ⌥" at 19:36:13.298, trap at 19:36:31.07 —
one keypress, ~18 s later, nothing else in between.

**The confirming signature** was the asymmetry you could see without a debugger: the
menu-bar item "Start dictation (no hotkey)" never crashed, because it calls the
coordinator directly and never touches the overlay. Hotkey dies, menu item lives.

**The fix** (`8ec3ad0`) does both halves: call the four-argument initializer and
place the window with `setFrame`, *and* override the four-argument designated init so
no trap stub exists for any future AppKit path to find. Verified at the binary level
on the two shipped artifacts — in 1.6.6 the `@objc` thunk is
`bl __swift_stdlib_reportUnimplementedInitializer` followed by `brk #0x1` and the
Swift body symbol does not exist at all; in 1.6.7 both symbols exist and the thunk
tail-calls the real initializer and returns. `OverlayWindowInitTests` constructs
`OverlayWindow` for three display shapes (including multi-display and off-origin) in a
real AppKit process, so the class that was unconditionally fatal is now covered.

**The tap path was rebuilt at the same time** (`8e8559f`, `0201ac4`). A second, latent
bug lived there: the tap's `userInfo` was `Unmanaged.passUnretained(self)` in a class
with **no `deinit`** — a raw pointer to an object the tap does not own, kept safe only
by AppDelegate happening to hold the service for the life of the process. It is now an
integer token resolved through a lock-protected registry, so a retired token is a
dictionary miss rather than freed memory; `deinit` tears the tap down; `start()`
retires any leftover tap first, so there is exactly one live tap per service; and
CoreGraphics sits behind an installer seam so arm → re-arm → stop is testable in a
process that can never create a working tap. Both bugs from the crash investigation
are closed.

## 2. The false "It landed. You're set." (P2) — fixed

Two independent bugs in the onboarding dictation test, and the second was worse than
the first.

`runGuidedDictation` called `engine.start(prewarm:)` and `engine.stop()` in
*consecutive statements*. The capture window was therefore zero-length: you spoke
after the engine had already stopped, the final pass received ~0 samples, and
FluidAudio threw `ASRError.invalidAudioData` under its 300 ms / 4800-sample floor.
Reaching that guard at all proves the model was loaded — this was never a model
problem.

Then the catch **discarded the error and emitted the success event with an empty
string**. The state machine stored it; the view checked only `landedText != nil`; an
empty string is not nil; you got a green "It landed. You're set." for a transcript
that did not exist. And the button never called `UtteranceLander` at all, so "It
landed" could not have been true on any machine even with perfect audio. The raw
token `invalidAudioData` reached the pill because the engine formatted errors with
`"\(error)"` instead of `localizedDescription`.

What ships now (`ab156d5`, `3f0a315`):

- A **two-state button** — *Dictate now* / *Stop & transcribe* — with a real capture
  window between the two presses, a **30 s self-stop**, and a teardown that releases
  the microphone.
- An **`isFinalizing` latch**, so an impatient second press of Stop cannot overwrite a
  good transcript with a `notListening` failure.
- `dictationLanded(String)` is replaced by a **`GuidedDictationOutcome`** of
  **landed / heard / noSpeech / failed**. "It landed" now requires an injection that
  reported success, via the new `DictationCoordinator.guidedLanding`.
- Engine errors publish `EngineMessage.describe(error)` — "Invalid audio data
  provided. Must be at least 300ms of 16kHz audio." — not an enum token.
- `RealEngine.stop()` under 300 ms now returns no spans and goes `.landed` → `.idle`
  instead of throwing, so a stray tap of the hotkey shows nothing rather than a red
  pill.

**Honest limit:** on this build the last onboarding step says "Heard you — that's
Parakeet TDT 0.6B v3 working" and never "It landed", because
`OnboardingDependencies.landUtterance` is left unwired. That is true rather than
false — pressing a button inside the onboarding window makes VoicePlus frontmost, so
there is genuinely no other field to inject into — but it is not an end-to-end
landing test. See *Known and remaining*.

## 3. Model readiness and real model names (P3 / P4)

The original report — "it's still downloading" — was **refuted**: the full Parakeet
TDT 0.6B v3 (461 MB, all required files) was already on disk in the FluidAudio cache
the model manager registers, and the EOU model was in VoicePlus' own models root.
Nothing was downloading. But the design defects behind the complaint were real, and
are fixed:

- Entering the dictation step now asks what can actually transcribe, and the screen
  **names the recogniser it will use**: "Using Parakeet TDT 0.6B v3.", or "Using Apple
  Speech (on-device) for now — Parakeet TDT 0.6B v3 is still downloading — 42%."
  The button is disabled **only** when nothing on the Mac can transcribe — the app no
  longer offers you a test that cannot possibly work.
- **Download progress is real**: bytes, the model's actual name, and an ETA that
  appears only once it means something.
- Choosing a tier now **starts a download for any tier not already installed or in
  flight**. The old guard was `download == .notStarted`, so choosing a second tier
  after a first download fetched nothing at all.
- A model that lands mid-session is picked up without a relaunch — `prewarm`
  re-resolves when the provider's revision changes.
- **Real names and real sizes beside each tier**, derived from the model catalog
  rather than hardcoded:

  | Tier | Model(s) | Size |
  |---|---|---|
  | Fast | Parakeet TDT-CTC 110M (tiny) | 110 MB |
  | Balanced | Parakeet TDT 0.6B v3 | 500 MB |
  | Best | Parakeet TDT 0.6B v3 **+** Parakeet Realtime EOU 120M (160 ms) | 900 MB |

  All three hardcoded numbers were wrong. "Best" advertised "~1.2 GB" for what is
  really two models totalling 900 MB — and the names were nowhere on screen, so there
  was no way to tell what the 1.2 GB even was.

## 4. The notch chin — a presence indicator that is always there (P5)

There was no always-visible VoicePlus affordance anywhere. The pill is show-on-demand
only, and the menu-bar status item — the one persistent surface — has no saved
position and is exactly the thing macOS culls first on a 1800 pt notched panel with
this many menu-bar agents.

1.6.7 adds **the notch chin** (`fdb1e49`, `c04a202`, `9b5e9fa`): a small
non-activating panel hanging off the bottom of the display's forbidden top band, with
six states — **ready / listening / processing / muted / paused / blocked** (precedence
muted > paused > blocked > listening > processing > ready). It:

- shares **one geometry rule** with the pill — top edge == `frame.maxY - topBand` — so
  it can never drift under the camera housing. Measured live on the reporting
  hardware: housing at `{{790,1131},{220,38}}`, every chin state topping out at
  y=1130, one point below it, on every state × hover × display fixture.
- is **click-through except while the pointer is provably on it**, so it never eats a
  click meant for something behind it. Clicking it pops the status item's own menu —
  the way back into Settings and Quit when macOS has hidden the status item, which was
  the actual complaint.
- **joins all Spaces**, is stationary and full-screen-auxiliary, and sits one window
  level below the pill.
- can be **switched off in Settings › General**, with a mirror checkbox in the status
  menu.

Full screen suppresses **only the quiet states**. `listening`, `processing` and
`muted` always draw — hiding a hot-mic indicator in a full-screen Space is precisely
the failure the product spec forbids, and full screen (Zoom, Keynote) is when it
matters most.

A logging line added to prove placement paid for itself immediately: it showed the
panel compositing at level 3 rather than 25, because `isFloatingPanel = true` sets the
window level as a side effect and was silently discarding the level set before it.
Fixed and re-verified at level 25, `onscreen=true`, `key=false`.

## 5. Relaunching after a grant — correcting the record (P6)

**1.6.6 told you no relaunch was ever needed. That was wrong for Microphone and Input
Monitoring.** It was right only for Accessibility. We are retracting the general
claim, with the evidence that forced it.

| Service | Does a grant reach the running app? | |
|---|---|---|
| **Accessibility** | **Yes — no relaunch.** | Unchanged from 1.6.6, and still proven. |
| **Microphone** | **No — quit and reopen.** | Our 1.6.6 position was wrong. |
| **Input Monitoring** | **No — quit and reopen.** | Our 1.6.6 position was wrong. |

**Evidence (a) — Apple's own declarative policy.**
`/System/Library/PreferencePanes/Security.prefPane/…/PrivacyTCCServices.plist`
defines `quitAllowTitleForAppName` for `kTCCServiceListenEvent` and
`kTCCServiceMicrophone`, and has **no entry at all** for
`kTCCServiceAccessibility`. The strings themselves are categorical:

> "…will not have access to your microphone until it is quit."
> "…will not be able to monitor input from your keyboard until it is quit."

By contrast the Screen Recording string is hedged — "**may** not be able to record" —
which is what makes the *will/may* distinction load-bearing rather than a reading of
tone.

**Evidence (b) — a natural experiment on this machine, from tccd's own grant
timestamps against three consecutive VoicePlus processes.** Microphone was granted 6 s
into PID 76635's life; that process polled once a second for its remaining **25 s and
never stopped reading `denied`**. Input Monitoring was granted 16 s into PID 76861's
life; it read `notDetermined` for its remaining **18 s**. Each *following* process
read the new value on its very first query. In the same window, in the same build,
**Accessibility did flip live inside a running process** — a grant at 19:25:30.054
produced a capability change at 19:25:31.021, under a second, through the
`com.apple.accessibility.api` notification the app already observes.

The obvious confound was ruled out without a human: a background `LSUIElement` probe
ticked a `.default`-mode 1 Hz timer 49 times in 50 s, so nothing was App-Napped. The
status APIs genuinely did not move.

**The distinction this release refuses to blur.** What was measured is that the
**status API** stays stale for the life of the process. Whether the underlying
**capability** — an actual capture session, a freshly created event tap — is also
dead was *not* measured, and is not claimed anywhere in the code or the copy. For
VoicePlus the two are currently the same thing, because every feature is gated on that
status. It matters only for a future self-recovery path. Equally: a status API
reporting "granted" is not proof the capability works — `CGEvent.tapCreate` returns a
non-NULL tap with no Input Monitoring permission whatsoever, which is why liveness is
judged from event delivery and never from tap creation.

**What the app now does about it** (`8e8559f`, `f7372de`, `4f86f3c`, `5c3bfa8`):

- `Permission.grantReachesRunningApp` records the verdict per service *with its
  evidence*, and `RelaunchAdvisor` decides when the offer is honest: you were sent to
  System Settings for a service macOS only hands over at launch, you came back, a 3 s
  grace elapsed, and it still reads off. This closes a real design gap — the only
  1.6.6 trigger (`onTapProvenDead`) presupposes an armed tap, and the tap never arms
  while preflight reads false, so in exactly the scenario reported it **structurally
  could not fire**.
- The prompt **quotes macOS' own sentence** instead of contradicting it, keeps its
  headline conditional (the app cannot read TCC.db, so it cannot distinguish "granted
  and withheld" from "you looked and changed nothing"), and refuses to offer a
  relaunch from a translocated copy.
- A **first-time Microphone ask is explicitly told a restart is not needed** — that
  grant arrives through the app's own dialog, which is live in-process.
- Accessibility keeps its 1.6.6 behaviour and copy exactly.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then
   run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

   This should now be **silent** (carried forward from 1.6.5: no file in the bundle
   ships read-only).

2. If you grant **Microphone** or **Input Monitoring**, **quit and reopen VoicePlus
   afterwards.** macOS does not hand those two to a process that is already running —
   see section 5. **Accessibility does not need a restart**; it is picked up in about
   a second.

3. Press the dictation key. It will not kill the app any more.

Permissions granted to **1.6.4 or later carry over unchanged** — the signature still
reads `designated => identifier "in.adityakatare.voiceplus"`, the build-independent
designated requirement introduced in 1.6.4, and it is verified in the shipped
artifact.

## Known and remaining

Stated plainly, including what could not be settled without a human.

- **The last link is unverified on hardware.** "Real finger on the dictation key → tap
  → startCapture → overlay" could not be synthesised: posting the event to our own PID
  does not reach a session tap, and posting it session-wide would have driven every
  other dictation app on the machine. Everything on *either side* of that link is
  verified — the tap arms in production (exactly one arm per service over 65 s of
  steady state, zero re-arms), and the initializer that trapped is a real function in
  the shipped binary. One human press settles it.
- **The onboarding test cannot say "It landed" on this build.**
  `OnboardingDependencies.landUtterance` is nil, so the final step reports *heard*, not
  *landed*. Honest, but not end-to-end. Wiring it is a few lines in `AppDelegate`;
  `DictationCoordinator.guidedLanding` is implemented and tested on both branches.
- **The P6 capability experiment is still open.** Whether the *capability* (not just
  the status API) recovers mid-session after pressing "Later" needs a grant toggled
  while a process runs — System Settings clicks no agent here can make. The shipped
  behaviour is correct whichever way it lands; the result would only decide whether a
  self-recovery path could be added on top of the relaunch offer.
- **The 1.6.6 GitHub release title is now wrong.** "no more relaunching to pick up
  permissions" is the exact claim section 5 retracts for two of three services.
- **Eight `init()` trap stubs remain in the binary** — five in FluidAudio, two in our
  own status-item controller, all on plain `init()`. Every one was audited as
  unreachable: none is an AppKit designated initializer, so none sits on a path a
  framework re-dispatches into. That is an argument, not a test. The ship rule worth
  adopting is the one the crash investigation proposed: **no release without one code
  path that instantiates every window and view class.**
- **Two wall-clock tests flake under parallel load** — a gatekeeper latency budget and
  a golden-transcript end-to-end budget. Both pass in isolation (0.029 s and 226 ms
  against 32.7 ms and 1.169 s under load average 20–36). `swift test --no-parallel`
  is green at 1165/1165; a plain `swift test` on a loaded machine will show red.
- **Not verifiable headlessly:** that the notch chin composites over another app's
  full-screen window (collection behaviour is right and it reports onscreen on the
  desktop, but no full-screen Space could be entered); whether the chin reads as too
  faint or too loud on a Retina panel — pure taste, and each of size and opacity is one
  constant; real-pointer hover and the click-to-open-menu path; a live 900 MB model
  download (progress and ETA are unit-tested against a mock); the real FluidAudio
  decoder path.
- **Dead code left alone, deliberately:** `BundledModel.bootstrap` is still
  uncalled, so there is no bundled tiny model. The false claim that there was one has
  been removed from the picker copy.
- The latent `Unmanaged.passUnretained(self)` + missing `deinit` in `HotkeyService`
  from the crash investigation is **not** on this list — it was fixed in this release
  (section 1).
