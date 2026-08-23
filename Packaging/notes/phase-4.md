# VoicePlus — Phase 4 (v1.4.0)

"It does it, not just types it." A second hotkey (default **Right ⌘**, configurable) opens the *act* domain: hold it and say what should happen — "open Safari", "click Merge", "open the PR tab and scroll to the failing check" — and VoicePlus performs it instead of typing it. Deterministic catalogue first (200 actions, no model call), agentic fallback second (screenshot-free native loop over the AX tree), and **every risky action goes through the consent engine**: reversible just runs, semi-reversible gets a 5 s undo toast, irreversible never executes without your click or spoken "confirm". A tinted agent cursor animates every step — your real pointer never moves.

## What's new
- **Deterministic action layer (P4.1).** 200-entry action catalogue (mac 72, browser 30, editor 32, chat 22, mail 22, files 22) bundled into the .app; click-by-name with fuzzy label match, focus app/tab/window, scroll, keystroke, fill field, open URL/file. Each action: precondition → execute → AX-readback postcondition. No model call on this path.
- **Act routing behind the second key (P4.2).** Right ⌘ (own settings key) holds the act domain open; utterances captured through the shared engine are routed by `ActRouter` — deterministic match first, compound/"can you…" goals to the agent. A 3-line gatekeeper pre-route hook claims act utterances so they **never get typed as dictation**; filler-only holds do nothing.
- **Agent cursor (P4.3).** Tinted glowing pointer with trailing wisp on the overlay animates glide/click/typing/highlight for every dispatched action. Statically asserted: no `CGWarp`/`CGEventPost`/`NSCursor` — the user's pointer is never moved.
- **Consent engine (P4.4).** Rule-table classifier `reversible / semi / irreversible` with conservative default (unknown ⇒ irreversible). Semi → undo toast with 5 s draining ring + compensating action; irreversible → slide-out confirmation card, click or spoken "confirm". Policy lives in code — deliberately no user config.
- **Agentic fallback (P4.5).** Native screenshot-free loop: AX summary → provider-backed planner (routing-table, Data-Panel-logged) → consent-gated execution; step chips in the pill; DONE/GIVEUP/tool-call parser that **never guesses** on unparseable plans; "stop" cancels mid-flight with LIFO rollback. (Cua evaluated: MIT core but screenshot+VM loop conflicts with the no-screenshots rule — native loop shipped, seam kept.)
- **Native connectors (P4.6).** Slack, Gmail, Google Calendar, Linear, Notion, GitHub — API path when the target matches, UI automation otherwise. PKCE OAuth via a loopback receiver (port 1456), secrets in Keychain, GitHub PAT path needs no client ID; **every connector call shows in the Data Panel** (`act.connector`). Settings > Services tab holds the OAuth start buttons.

## Install
1. Open the dmg, drag **VoicePlus** to **Applications** (replaces v1.3.0 in place; settings and history preserved).
2. First launch: right-click > **Open** (ad-hoc signed, not notarized — Gatekeeper warns once).
3. Grant **Microphone**, **Accessibility**, **Input Monitoring**. Accessibility is what lets actions click and verify via AX readback.
4. Optional: Settings > Services to connect Slack/Gmail/Calendar/Linear/Notion (needs OAuth client IDs via environment — see notes below) or GitHub via PAT (works out of the box).

Verify the artifact: `shasum -a 256 VoicePlus_4_1.4.0.dmg` must match `Packaging/releases/CHECKSUMS.txt`
(`98ec9cf4367b0e8ee1be0f16e5ae902c6b3bce8bae472603ad79a2826e8e5ecc`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test (passed for this artifact).

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Install from this dmg over `VoicePlus_3_1.3.0.dmg` (`verify_install.sh` first) | Mount, codesign, launch OK; state preserved; catalog.json present inside the .app bundle | [ ] |
| 2 | Hold **Right ⌘**, say "open Safari" | Safari activates; agent cursor glides and clicks; your real pointer does not move; nothing is typed anywhere | [ ] |
| 3 | Hold the **normal** hotkey, say "open Safari" | It is *dictated* as text at the cursor — the act domain only exists behind the second key | [ ] |
| 4 | In a GitHub PR page: Right ⌘, "open the PR tab and scroll to the failing check" | Step chips appear; agent cursor walks the steps; page ends scrolled to the failing check; every step visible | [ ] |
| 5 | Right ⌘, "close this window" (semi-reversible) | Executes with a 5 s undo toast + draining ring; clicking ↩ restores the window | [ ] |
| 6 | Right ⌘, "send the message" in Mail with a draft open (irreversible) | **Nothing sends.** Slide-out confirmation card appears; only clicking it or saying "confirm" sends; "cancel" aborts | [ ] |
| 7 | Start a multi-step agentic task and say "stop" mid-flight | Execution halts ≤ 1 step later; queued steps rolled back; pill reports stopped | [ ] |
| 8 | Right ⌘, mumble fillers only ("uh… hmm") and release | No action, no typed text, no error | [ ] |
| 9 | Settings > Services: connect GitHub with a PAT; Right ⌘, "comment 'LGTM' on my open PR" | Comment lands via API (not UI automation); Data Panel shows one `act.connector` row with host + bytes | [ ] |
| 10 | Open Data Panel after steps 2–9 | Deterministic actions show **zero** network rows; only the planner/connector calls appear, each attributed | [ ] |
| 11 | Say "delete all my emails" style irreversible bulk phrasing | Conservative classification: confirmation card (or refusal), never silent execution | [ ] |
| 12 | Quit and relaunch | Second-key binding, connector tokens (Keychain) and history persist; no crash log | [ ] |

## Lab numbers (2026-08-24, M2 Pro 16 GB, debug build)
- **Action conformance phase gate: 1398/1398 = 100.00%** across 15 mock apps × catalogued actions (746 readback-verified, 652 delivery-only; gate ≥ 99%).
- **Irreversible-never-unconfirmed: 200-case random submission fuzz — zero unconfirmed executions**, plus a router-level `mail.click_send` case; earlier unit-level fuzz 2000 iterations clean.
- Act routing matrix: 200/200 catalogue phrasings; 300-plan consent fuzz clean; planner parser never guesses (GIVEUP on unparseable).
- Acceptance (`Phase4AcceptanceTests`): PR-tab+scroll agentic flow over the mock action system; second-key gating; gatekeeper claim; loopback OAuth parsing. Whole package: **944 automated tests green / 0 failed**.

## Known deviations and limitations
- **`LiveActionSystem` is untested on hardware** — the 1398/1398 gate is on mock apps; the live "PR tab" demo is the human test script above.
- **Connector OAuth needs real client IDs** supplied via environment (none are bundled); only the GitHub PAT path works with zero setup. Live endpoints and the loopback browser flow are untested against real services.
- Consent policy is code-only by design (no user config); compensating actions exist only where the target API allows.
- Agent cursor rendering and confirmation-card UI are mock/unit-verified; live CoreAnimation rendering untested headless.
- Carried: ad-hoc signature, no notarization; `contextBiasing`/`dualPath`/`cloudASR` off; human test scripts for phases 1–3 still pending on a clean account.
