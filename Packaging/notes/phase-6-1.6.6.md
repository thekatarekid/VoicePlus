# VoicePlus 1.6.6 — no more relaunching to pick up permissions

Patch release on the Phase 6 line. The 1.6.5 report was "I have to quit and reopen
the app every time I grant something, and Accessibility never takes at all." Both
halves now have a measured answer, and one of them was our bug.

sha256 `736716ea540a74154573e6cc287ca8bf31411fd905987403ce5c6c13f31dd058`
Tag `release/phase-6/v1.6.6` · **1074 tests pass** (two consecutive full runs) · verify_install OK.

## Does granting a permission require quitting and relaunching?

Measured per service, on this machine, on macOS 26.6.2:

| Service | Restart needed? | Why |
|---|---|---|
| **Microphone** | **No.** | `AVCaptureDevice.authorizationStatus` re-queries tccd on every call, and capture re-checks authorization and re-opens the device at the start of every dictation. |
| **Accessibility** | **No** — and proven. | `AXIsProcessTrusted()` *is* cached per process, but macOS drops that cache on the `com.apple.accessibility.api` distributed notification, which the app already subscribes to. Your own toggle was observed making the running app issue a fresh tccd query **213 ms later**. Accessibility is also the only TCC service for which macOS ships no "quit and reopen" alert at all — so that button has been **removed** from this screen. |
| **Input Monitoring** | **It was our bug, not an OS limit.** | See below. |

### The Input Monitoring bug

`hotkey.start()` had exactly one caller: the completion of the permission walk.
That completion never runs while onboarding is open, and it was being held behind
the **Accessibility** pre-prompt — a permission the hotkey does not need. So on the
reporting machine Input Monitoring had been granted for **twenty minutes** and no
event tap had ever been created. Nothing was waiting on a restart; nothing was
waiting on anything. The app simply never tried.

A new `CapabilityWatcher` (`App/Services/CapabilityArming.swift`) now owns the tap
lifecycle instead. It re-reads the whole permission matrix every second, plus on the
accessibility notification and on app activation, and arms the tap the moment the
grant lands — about a second, no restart. The arming rule is a pure function
(`CapabilityArming.decision`): once armed, a granted permission returns `.hold`, so
the 1 s poll is idempotent and cannot stack a second tap.

`CGEvent.tapCreate` is not a permission test — measured with a throwaway bundle id
holding no Input Monitoring at all, six creations returned six non-NULL taps. So
"working" is judged from event delivery against `CGEventSource`'s system-wide
modifier idle time, which needs no permission: a tap that is deaf while the system
is seeing modifier keys gets one silent re-arm, and only if it is *still* deaf is a
restart offered.

### The honest caveat

It was **not** possible to prove that an event tap begins delivering events, in an
already-running process, immediately after Input Monitoring is granted. That needs a
human at the switch, and Apple's own Settings copy claims a restart is needed. So if
the hotkey still does nothing a few seconds after you grant it, **Quit & Reopen**
remains on that screen as the fallback — for Input Monitoring only.

## Why Accessibility could never be granted

Now identified exactly. The Accessibility row you had been toggling stored a code
requirement of:

    cdhash H"459b5909…"

That is the CDHash of **VoicePlus 1.0.0** — the very first Phase 1 build. The row had
been dead since 1.1.0. Toggling a row rewrites **only its auth value**; it never
rewrites the stored code requirement. That is why the switch could be on and the app
still be refused, and why turning it off and on again could never have worked.

That poisoned row has since been cleared. A fresh grant is recorded against

    identifier "in.adityakatare.voiceplus"

— the build-independent designated requirement shipped in 1.6.4 — and will survive
every future build.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then
   run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. Open **System Settings → Privacy & Security → Accessibility**, press **+**, pick
   **VoicePlus** in your Applications folder, and switch it on.

**There is no "−" step this time** — the bad row is already gone. Do not quit the app
afterwards; it picks the grant up on its own within a second.

Microphone and Input Monitoring grants made on 1.6.4 or 1.6.5 carry over unchanged:
the signature still reads `designated => identifier "in.adityakatare.voiceplus"`.

## Also in this release

- The recovery copy stopped asserting things the app cannot know. It used to claim
  "that switch belongs to an older build" from nothing more than
  `attempts >= 1 && !isTranslocated`, without ever establishing that an entry exists,
  that its switch is on, or that its stored requirement mismatches — none of which
  any app can read. It now leads with the cure (numbered steps at body size, not
  caption text), keeps the cause conditional, and mentions corroborating grants only
  when they actually exist.
- **"Remove the old entry…"** runs the scoped `tccutil reset <service> <bundle id>`
  for you, gated on the escalated phase where nothing is granted, so there is never a
  working grant to destroy.
- Every permission screen now says, per service, whether you need to quit — saying
  nothing was its own failure mode in 1.6.5.
- The recovery steps stay readable in the 520×420 window: the permissions step
  scrolls, so the numbered steps can never be the first thing clipped — which was the
  exact failure being fixed.

Carried forward from 1.6.5: no file in the bundle ships read-only, so
`xattr -dr com.apple.quarantine` is silent (it printed three "Permission denied"
lines on 1.6.4).
