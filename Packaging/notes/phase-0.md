# VoicePlus — Phase 0 (v0.0.1)

## What's new
- _Fill in the phase highlights (one bullet per user-visible capability)._

## Install
1. Open the dmg, drag **VoicePlus** to **Applications**.
2. First launch: right-click > **Open** (build is ad-hoc signed, not notarized).
3. Grant **Microphone** and **Accessibility** when prompted.

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Fresh install from this dmg on a clean user account | App icon appears in the menu bar within 5s | [ ] |
| 2 | Press the hotkey and say "hello world" into TextEdit | "Hello world" lands at the cursor ≤ 700ms after key release | [ ] |
| 3 | Dictate into Mail, Notes, Slack, a browser text field | Text lands in each; no clipboard residue | [ ] |
| 4 | Upgrade in place over the previous phase's dmg | Settings + history preserved; no re-prompt for permissions | [ ] |
| 5 | Quit and relaunch | Previous state restored, no crash log in Console | [ ] |

## Known deviations
- Ad-hoc code signature; no notarization; Sparkle appcast unsigned (no EdDSA key).
