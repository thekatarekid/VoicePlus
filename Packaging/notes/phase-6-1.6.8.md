# VoicePlus 1.6.8 — VoicePlus no longer belongs in Input Monitoring

You asked the obvious question: Claude, Wispr Flow, Gemini, Raycast, Spokenly and
Muesli all run global hotkeys on this Mac, and none of them appear in **Privacy &
Security › Input Monitoring**. Why did we?

The answer is that we had picked the one API that requires it, and nothing about the
feature ever did. This release changes the mechanism. **Input Monitoring is no longer
requested, no longer checked, and no longer part of onboarding.** With it goes the
forced quit-and-relaunch, which was never a property of VoicePlus — it is a property
of `kTCCServiceListenEvent` alone.

sha256 `9ce250f7d8644d092ad89c80b46993ec63a3f4327317abd120f73e9a4f02a8ab`
Tag `release/phase-6/v1.6.8` · **1207 tests pass, 0 failures** · verify_install OK ·
2 commits (`260b044`, `c07e58a`) on top of 1.6.7 (`f9ebac5`).

## 1. Why we needed it, and why nobody else does

`HotkeyService` used `CGEvent.tapCreate(options: .listenOnly)`. A CGEvent tap on
keyboard events is **the single global-input API on macOS gated on
`kTCCServiceListenEvent`** — the TCC service whose System Settings pane is called
Input Monitoring. Every other way to hear a key press system-wide is gated on
something else or on nothing at all:

| Mechanism | TCC service | Bare modifier? | Press *and* release? |
|---|---|---|---|
| `CGEvent.tapCreate(.listenOnly)` | **ListenEvent** (Input Monitoring) | yes | yes |
| Carbon `RegisterEventHotKey` | **none** | no — chords only | yes |
| `NSEvent.addGlobalMonitorForEvents` | **none** (measured; see §3) | yes | yes |
| `NSEvent.addLocalMonitorForEvents` | none, but only while we are frontmost | yes | yes |

So the requirement was an implementation detail of one line, not a cost of
hold-to-talk and not a cost of the bare-modifier gesture.

**What comparable apps do.** Read-only inspection of the copies installed on this
machine, none of which appear in the user's Input Monitoring list:

- **Spokenly** — a native dictation app, the closest comparable — links
  `RegisterEventHotKey` in its main executable and does not link `CGEventTapCreate`
  there.
- **Claude** and **Wispr Flow** are Electron apps; `Electron Framework` links
  `RegisterEventHotKey`, which is what Electron's cross-platform `globalShortcut`
  API is implemented with on macOS.

Stated with the caveat it deserves: **linking a symbol is not calling it**, and
`Electron Framework` links `CGEventTapCreate` too (as does the `Wispr Flow` binary).
Not every tap needs Input Monitoring — the gate is a keyboard tap. This section is
corroboration for the mechanism we chose, not the proof. The proof is §3, and it is
about our own binary.

## 2. What VoicePlus uses now

`HotkeyService.start()` picks a backend from the binding (`HotkeyBackendSelector`, a
pure function, tested):

| Binding | Backend | Permission |
|---|---|---|
| **Right ⌥** (default), Left ⌥, Right ⌘, Right ⌃, fn | `NSEvent` global + local `flagsChanged` monitors | **none** |
| ⌃⌥D, ⌃⌥A | Carbon `RegisterEventHotKey` + `InstallEventHandler` | **none** |
| any, with `hotkeyForceEventTap` set | the 1.6.7 `.listenOnly` event tap | Input Monitoring |

**The default hotkey is unchanged: Right ⌥, hold to talk, double-tap for hands-free.**
Hold threshold 250 ms, tap guard 180 ms, double-tap window 350 ms —
`HotkeyStateMachine` was not touched at all. Both keys, dictation (Right ⌥) and act
(Right ⌘), are bare modifiers and both now cost nothing.

**Deviation from the plan this release was scoped against, and it is the good kind.**
The brief anticipated demoting the bare modifier to an opt-in that still costs Input
Monitoring, and making a chord the new default. Measurement said that was
unnecessary — a bare-modifier global monitor delivers with *zero* TCC grants — so
Right ⌥ stays the default and its permission cost is nil. Every choice in the shipped
picker now reads "no extra permission", rather than the trade-off framing the plan
assumed.

Input Monitoring remains reachable only through the `hotkeyForceEventTap` escape
hatch — a defaults key that **nothing in the shipped UI turns on** — so that an
install hitting an unforeseen global-monitor failure has a way back without a new
build. That is the only path on which VoicePlus still asks for Input Monitoring, and
it is the only place the quit-and-relaunch copy still appears.

A trap worth recording, because it is the one that would have burned the next
attempt: `RegisterEventHotKey` **accepts** a bare-modifier registration
(`kVK_RightOption`, empty modifier mask), returns `noErr` with a valid ref, and then
never fires. Anyone who tests only the return code concludes it works. That is why
the selector routes on `HotkeyBinding.Style` and never on "did registration succeed".

## 3. The measurement

Reasoning from first principles about macOS TCC has been wrong twice on this project,
so this was measured, in the shipped code path, on this machine (macOS 26.6.2, arm64).

The method: take **this release's own bundle**, change only `CFBundleIdentifier` to a
throwaway id that has never existed, re-sign ad-hoc, and launch it through
LaunchServices so TCC attributes it to that id rather than to the terminal. It then
has **no TCC record of any kind**. Its own permission report, from its own log:

    permission report: bundle=in.adityakatare.vpzero168
    permission report: AXIsProcessTrusted()=false
    permission report: CGPreflightListenEventAccess()=false
    permission report: microphone=notDetermined
    permission report: accessibility=notDetermined
    permission report: inputMonitoring=notDetermined

**(a) It arms, with Input Monitoring ungranted.** Same process, seconds later:

    capabilities: capture=false hotkey=true inject=false hotkeyNeeds=nothing (first read)
      [accessibility=notDetermined inputMonitoring=notDetermined microphone=notDetermined]
    hotkey: armed (#1) via globalMonitor for Right ⌥ — needs no permission
    hotkey: armed (#1) via globalMonitor for Right ⌘ — needs no permission

**(b) It receives, with Input Monitoring ungranted.** Real HID modifier transitions
were generated permission-free with `IOHIDSetModifierLockState(kIOHIDCapsLockState)`
(caps-lock state read before and restored after; it was and is off). The control is
self-validating: `CGEventSource.secondsSinceLastEventType(.hidSystemState,
.flagsChanged)` went **1205.27 s → 0.13 s** across the burst, so the system certainly
saw modifier keys. The app's own liveness watchdog then stayed **silent** through the
20 s grace and beyond — and that watchdog logs *"armed but receiving nothing while the
system sees modifier keys"* precisely when `eventsReceived == 0` and the system did see
them. Silence there is the app asserting `eventsReceived > 0`.

**(c) The A/B that names the culprit.** Same binary, same zero-grant identity, one
defaults key flipped to force the old event tap:

    capabilities: capture=false hotkey=false inject=false hotkeyNeeds=inputMonitoring (first read)
      [accessibility=notDetermined inputMonitoring=notDetermined microphone=notDetermined]

No `armed` line at all. The event tap is the thing that needed the permission; the
monitor never did.

**(d) It is not opportunistic.** Launched under the *real* bundle id, where this
machine has Input Monitoring granted, it still chooses the monitor:

    capabilities: capture=true hotkey=true inject=false hotkeyNeeds=nothing (first read)
      [accessibility=notDetermined inputMonitoring=granted microphone=granted]
    hotkey: armed (#1) via globalMonitor for Right ⌥ — needs no permission

Backend selection is by binding style, never by what happens to be granted.

## 4. What changed around it

- `PermissionPlanner.baselineOrder` is `[.microphone, .accessibility]`.
  `capabilities(_:hotkeyRequires:)` takes the *active backend's* requirement — nil for
  every shipped binding — so a missing or denied ListenEvent can no longer block
  `canUseGlobalHotkey`.
- The onboarding walk and its checklist skip Input Monitoring. Verified in the
  zero-grant process: `onboarding: microphone status=notDetermined phase=explain`,
  `onboarding: accessibility status=notDetermined phase=explain`, and nothing else.
- **Bonus fix: the Settings hotkey picker was decorative.** It wrote its own defaults
  key and offered an `f5` the binding type could not express, so choosing a key did
  nothing. It now writes `hotkeyBinding`, and an armed service observes
  `UserDefaults.didChangeNotification` — so a change in Settings reaches the running
  app instead of waiting for the next launch.
- **Migration is clean.** All five 1.6.7 raw values survive verbatim; a Right ⌥ user
  keeps Right ⌥, now free. An unparseable stored value logs and falls back to the
  default.
- Signing untouched: the shipped artifact still reads
  `designated => identifier "in.adityakatare.voiceplus"`, so grants from 1.6.4 onward
  carry over.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then
   run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **You can remove VoicePlus from Input Monitoring.** It is not read any more. Leaving
   it there is harmless; removing it changes nothing about how the hotkey behaves.

3. **Accessibility is still required**, and still only for typing text into other apps
   — it is not, and never was, what the hotkey needed. It remains the one permission
   that is picked up live, with no relaunch.

4. Press and hold **Right ⌥**. Nothing else changed about the gesture.

## Known and remaining

- **The last human link is still unverified, exactly as in 1.6.7.** What is proven is
  that the monitor arms and that real HID `flagsChanged` events reach it with no
  grants. What is *not* synthesised end-to-end is a real finger holding **Right ⌥**
  for 250 ms → `startCapture` → overlay: `CGEventPost` needs Accessibility, and
  `IOHIDSetModifierLockState` can only move caps lock, not the right Option key. So
  delivery is proven with a different modifier than the bound one. The classifier that
  turns a flag word into a press/release edge is covered by unit tests and, per
  `HotkeyBackendFlagWordTests`, `NSEvent.keyCode`/`modifierFlags.rawValue` are
  bit-identical to the backing `CGEvent` fields — but one human press is still what
  closes this.
- **`IOHIDPostEvent` is a dead end**, recorded so it is not retried: it returns
  `status=0` on both `kIOHIDParamConnectType` and `kIOHIDEventSystemConnectType` and
  injects nothing.
- **Carbon is shipped but lightly exercised.** ⌃⌥D / ⌃⌥A were verified to register
  (`status=0`, duplicate returns `-9878`) and to drive the state machine through
  press/release and double-tap in a probe. No one has lived on a chord binding for a
  day. The default path is the monitor, so this is a secondary risk.
- **`hotkeyForceEventTap` has no UI**, by design. If a machine ever turns up where the
  global monitor does not deliver, it is `defaults write in.adityakatare.voiceplus
  hotkeyForceEventTap -bool YES` plus the Input Monitoring grant *and* a relaunch.
  Nothing has needed it.
- **The appcast download URL 404s anonymously** because the repository is private.
  Pre-existing since the first phase-6 release, unchanged here, not addressed.
- **Accessibility read `notDetermined` for the copy under `Packaging/build`** during
  verification, while the installed copy in `/Applications` has it. Expected — TCC
  keys Accessibility on the installed client, and this is a second copy at a different
  path — but it means `inject=false` in the quoted lines above, and the injection path
  was therefore not exercised in those runs. Unchanged from previous releases.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
