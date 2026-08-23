# VoicePlus — Phase 2 (v1.2.0)

"Talk to your text." Select text anywhere, hold the hotkey, and say what you want done with it — rewrite, restructure, ask a question, or fire a snippet — and keep talking for follow-ups without re-selecting. Phase acceptance ("a rough paragraph reaches final form via voice only") is verified by the scripted no-keyboard E2E test: paragraph → "make this two lines" → "call out the churn number" → "bold it" with zero keystrokes. Rewrites use the local provider by default; nothing leaves the machine unless you connected a provider yourself, and every call shows in the Data Panel.

## What's new
- **Transform routing (P2.1).** `SelectionDetector` reads the current AX selection; with a selection the gatekeeper routes deterministically to `transform` or `question` (Bet 5: dictate vs transform is decided by selection, not by the model). Selection text plus surrounding context is assembled for the rewrite.
- **Rewrite engine (P2.2).** `TransformExecutor` via Providers (local default, best-available preferred) with a local-rules fallback; output re-injected via replace-range only over the text you selected (confidence contract kept: low-confidence spans untouched); `WordDiff` drives the morph animation. 60-case transform suite (tone, shorten, restructure, translate-format) and the injection matrix re-run for replace-range.
- **Transform UX (P2.3).** Pill turns accent-tinted "editing N words"; inline morph (collapse/expand, one beat); 5 s **"↩ undo / try again"** ghost row on the pill; the pill stays **warm for 8 s** after a transform so the next instruction reuses the same selection — chained turns with no re-selection (Kivi pattern).
- **Q&A on selection (P2.4).** A question about the selection ("what's the churn number here?") types the answer **below** the selection with a visible "answer:" attribution and never replaces it.
- **Personas (P2.5).** Per-app plain-English persona box in Settings, auto-drafted from Phase 1 style learnings ("Auto-draft from my style") and editable; per-recipient override hooks from thread-participant detection; persona decorates every transform and dictation context.
- **Spoken snippets (P2.6).** Trigger phrase → expansion, managed in Settings > Snippets; exact-match pre-route wins over every other route, so "my address" lands the expansion, never a rewrite.

## Install
1. Open the dmg, drag **VoicePlus** to **Applications** (replaces v1.1.0 in place; settings, personas and history are preserved).
2. First launch: right-click > **Open** (build is ad-hoc signed, not notarized — Gatekeeper will warn once).
3. Grant **Microphone** and **Accessibility** when prompted; **Input Monitoring** is requested for the global hotkey. Accessibility is what lets VoicePlus read your selection.
4. Optional: Settings > Providers to connect Ollama/LM Studio/an API key for higher-quality rewrites; with none connected the local rules fallback handles simple transforms.

Verify the artifact: `shasum -a 256 VoicePlus_2_1.2.0.dmg` must match `Packaging/releases/CHECKSUMS.txt`
(`ff450a8ca29c89f0072fa45185e602e9c4ab05dda2c3781ce177f945893d9840`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test (passed for this artifact).

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Install from this dmg over `VoicePlus_1.5_1.1.0.dmg` (`verify_install.sh` first) | Mount, codesign `--verify`, launch OK; settings + history preserved; no permission re-prompt | [ ] |
| 2 | In **Mail**, paste a rough 4-sentence paragraph containing "churn went from 4% to 7%"; select it all; hold hotkey, say "make this two lines" | Pill tints and reads "editing N words"; selection morphs in place into two lines; 5 s ghost "↩ undo / try again" appears; nothing outside the selection changes | [ ] |
| 3 | Within 8 s, without re-selecting, hold hotkey and say "call out the churn number" | Same text is rewritten again with the churn figure made prominent; no re-selection needed | [ ] |
| 4 | Within 8 s, say "bold it" | Text becomes bold (rich field) or wrapped in `**…**` (plain field); still no keyboard use | [ ] |
| 5 | Repeat steps 2–4 in **Slack** and in **Notes** | Same chained behaviour in both; replace-range never clobbers adjacent text | [ ] |
| 6 | Click "↩ undo" on the ghost right after a transform | Selection reverts to the pre-transform text exactly | [ ] |
| 7 | Wait > 8 s after a transform, then hold hotkey and say "hello world" with nothing selected | Pill is cold: "Hello world" is **dictated** at the cursor, not applied as a transform | [ ] |
| 8 | Select the paragraph, say "what is the churn number?" | Answer appears **below** the selection prefixed "answer:"; selection itself untouched | [ ] |
| 9 | Settings > Snippets: add trigger "my sign-off" → "Best,\nAditya"; in Mail (no selection) say "my sign-off" | Expansion lands verbatim; no rewrite, no model call on the Data Panel | [ ] |
| 10 | Settings > Personas: open the Mail persona, click "Auto-draft from my style", edit one sentence, save | Draft appears from learned style; edit persists across relaunch; next Mail transform reflects it | [ ] |
| 11 | Select text in **Terminal** and say "make this shorter" | Refused/guarded: nothing is executed, no Return pressed; pill explains | [ ] |
| 12 | Open Data Panel after steps 2–10 | With no provider connected: pipeline egress 0 bytes. With a provider: one row per transform/question, none for snippets or dictation | [ ] |
| 13 | Quit and relaunch | Personas, snippets, history restored; no crash log in Console | [ ] |

## Lab numbers (2026-08-24, M2 Pro 16 GB, debug build)
- Transform suite: 60 scripted cases + replace-range injection-matrix re-run — 30 tests green (P2.1+P2.2).
- Q&A / personas / snippets: 50 tests green (P2.4–P2.6).
- Transform UX + no-keyboard E2E (`TransformUXTests`, with `CorrectionUXTests`: 36): MockEngine paragraph → "make this two lines" → "call out the churn number" → "bold it" via mock selection + injector, **zero keystrokes**, undo path and warm-window expiry covered.
- Whole package: **930 automated tests green / 0 failed**.

## Known deviations and limitations
- **Live AX selection untested on hardware**; Mail/Slack/Notes acceptance is verified mock-only until the test script above is run.
- Rewrite quality depends on the connected provider; the local-rules fallback covers only simple transforms (shorten, case, line splitting).
- Personas settings UI and the snippet stage were wired into `AppContainer` in this phase; per-recipient overrides rely on thread-participant detection that is mock-level.
- Carried from Phase 1/1.5: ad-hoc signature, no notarization, no hardened runtime; `contextBiasing` and `dualPath` off by default; synthetic fixtures; CI unverified; security-review follow-ups in `docs/SECURITY-REVIEW.md`.
