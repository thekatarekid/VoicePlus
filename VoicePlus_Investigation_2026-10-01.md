# VoicePlus — Insertion, invisible pill, permission relaunch: investigation and fix plan

**Date:** 2026-10-01 · **Build investigated:** 1.12.12 (`ba26f5b`) · **Status:** investigation only, nothing changed.
**Evidence:** today's unified log (subsystem `in.adityakatare.voiceplus`), tccd log, code at HEAD.

## Findings

### F1 · Claude/Electron text fields are invisible to Accessibility — the root of "Couldn't confirm insertion"
- 79 of 80 writes today went into `com.anthropic.claudefordesktop` by keystroke. Every turn with a logged verdict reads **"unverified: readback unavailable"** — not "unconfirmed": nothing could be read at all.
- Electron builds its AX tree only when another app sets `AXManualAccessibility` (Chromium: `AXEnhancedUserInterface`). Neither string exists anywhere in the repo or its history.
- Proof it is not only timing: the tape-flight caret probe reads `AXSelectedTextRange` *before* the write and still gets `caretUnavailable` on 8/8 turns.
- Why `dbe9393` did nothing: its test mock is told the caret is readable (`axCaretReadable = true`); real Claude exposes nothing.

### F2 · Readback runs before the keystrokes land
- `Injection/TextInjector.swift:169` reads "after" immediately after `postToPid`. Electron applies keystrokes later on its own run loop. The mock applies them instantly, so tests cannot see the race. Fixing F1 alone would turn "unavailable" into "unconfirmed" and still warn.

### F3 · The spec makes an unreadable field a sticky warning
- `DESIGN.md:51, :306` map `verified:false` — *including "could not run"* — to "⚠ Couldn't confirm insertion", which stays until acted on (`:468`). V4.20 (a plain "Landed" when readback is unavailable) was withdrawn. So every Claude dictation leaves a warning up.

### F4 · The invisible-but-working pill: pinned to another display
- The pill picks its display only on a hidden→visible transition. Because every Claude write ends **unconfirmed** (F1–F3), the next fn press goes unconfirmed → starting, never through hidden — so the display is never re-chosen.
- An AirPlay TV ("Samsung The Frame", extended right of the laptop) dropped at 09:44:46 and returned at 09:46:24; the next press at 09:48:22 began the chain covering the 09:53 report. The display is chosen from the mouse position (`NotchGeometry.swift:255-256`); a mouse on the TV — or exactly on the laptop's top edge, where `CGRect.contains` misses and the code falls back to `NSScreen.main` — pins the pill to the TV.
- "On screen" is `panel.isVisible` — ordered in, but never checks *which* screen. So the chin correctly stands down for a pill drawn on the TV, and the laptop shows nothing while text keeps landing.
- Confidence: mechanism high; the TV as the destination is inferred (the log never records the pill's display).

### F5 · Dictated line breaks send the message in Electron apps — **safety**
- `ElectronAdapter` (Claude, Slack, VS Code, Discord, Notion, Obsidian) and Cursor type `\n` as Return, which submits. Dictating two paragraphs into Claude sends the first one alone. Google Sheets routes through the Chromium adapter, so a newline commits the cell.

### F6 · "Paused · move away to insert" — not reproduced in today's log
- All 80 writes fired 0.62–0.67 s after the text was ready: the 600 ms dwell auto-inserting. No turn waited for Insert now in the logged window.
- Candidates: genuine hover (the pill is ≥560×160 pt over the top of the destination window and takes the mouse once words appear); a missed SwiftUI exit during a still preview (`dbe9393` re-checks only on re-render); keyboard focus left on the pill. `pauseDwell`/`resumeDwell` log nothing, so the reason is unprovable today.

### F7 · "Quit and reopen" is macOS's sheet, not VoicePlus's
- tccd logged the Microphone change at 05:47:43.9; System Settings sent a Quit AppleEvent at 05:47:46.67 and relaunched the app (pid 9037 → 47017); the same on grant (→ 48022). VoicePlus's own `RelaunchPrompt` never fired.
- macOS shows this sheet for Microphone, Input Monitoring, Screen Recording and Camera — **any** app, FluidVoice included. Accessibility has none, and VoicePlus picked up the Accessibility revoke/grant live within 2 s.
- VoicePlus's part: it trusts the process-cached `AVCaptureDevice.authorizationStatus`. Choosing "Later" therefore leaves a grant invisible and a revoke unnoticed — so today a relaunch really is required.

### Corrections to earlier sessions
- The "TCC pins the ad-hoc cdhash" explanation (2026-09-30) is **wrong**: since 1.6.4 the designated requirement is `identifier "in.adityakatare.voiceplus"`, so grants carry across builds. Running from the disk image was not a permissions confound.
- Today's single-process observation (pid 42939) covered only 06:45 onward; the permission toggling happened earlier, in pids 9037/47017/48022, and macOS did relaunch the app each time.
- tccd still resolves the bundle id to a stale `/Volumes/VoicePlus 1.12.10/` path and logs lookup errors — harmless, worth clearing via LaunchServices.

## Fix plan (priority order)

| # | Fix | Where | Proving test (Swift Testing) | Needs hardware |
|---|---|---|---|---|
| 1 | **Newline safety:** type `\n` as ⇧↩ in Electron/Cursor; Sheets via spreadsheet path | `Injection/AppAdapter.swift` `ElectronAdapter.prepare` | multi-paragraph payload emits ⇧↩, never bare ↩ | Claude, Slack |
| 2 | **Enable target-app AX:** set `AXManualAccessibility` on Electron app elements at key-down (cached per pid); detect Electron by `Electron Framework.framework`, not only bundle ids; Chromium `AXEnhancedUserInterface` opt-in only | `SystemAccess.enableAppAccessibility(pid:)` | mock exposes caret only after enable is called | Claude, VS Code; check no slowdown |
| 3 | **Settle before judging:** poll readback ~30 ms up to ~400 ms, stop at first confirm | `Injection/TextInjector.swift:169` | mock applies keystrokes after N reads — fails on today's code | Claude, Terminal |
| 4 | **Re-choose the pill's display every new turn** (unconfirmed/held/error → starting); choose like the chin (notch display) or inclusive edge bounds | `PillPanelController.render` (pure rule) | unconfirmed → starting re-pins; `y == maxY` resolves to laptop | AirPlay TV |
| 5 | **"On screen" means visible on the chin's display:** ordered in + occlusion visible + same screen + frame > 1 pt; republish on occlusion/screen-change | `PillPanelController`, `PresenceIndicatorController` | chin not suppressed by a pill on another display | AirPlay TV |
| 6 | **Diagnostics:** notice-level pill placement per turn (display, mouse); every orderFront/Out with reason; every dwell pause/resume with reason + pointer + frame | Pill, TurnController | — | — |
| 7 | **Live microphone status:** measure first (deny, launch, grant, "Later", capture); if capture works, add an uncached status probe and gate on it | `PipelineAudioSource`, `PermissionPlanner`, `RelaunchAdvisor` | stale-denied/fresh-granted captures; fresh-denied refuses within a tick | revoke/grant cycle |
| 8 | **Hover re-check on mouse-moved** during a preview, not only on re-render | `PillPanelController` | stale hover cleared without a re-render | pointer near notch |

## Decisions for the owner
1. **Unreadable destinations** (Figma, Google Docs, AX-less terminals): keep the spec's sticky "⚠ Couldn't confirm", or revive V4.20 — a neutral, non-sticky "Inserted in &lt;app&gt;" without ✓, keeping the warning for a readback that ran and found nothing?
2. **Pill display:** always the notch/built-in display, or the display under the mouse at each new turn?
3. **Preview hover target:** the whole ≥560×160 panel, or only the words and buttons?
4. **Microphone measurement (step 7):** a ~2-minute revoke/grant test on your Mac decides whether "Later" can ever work.
