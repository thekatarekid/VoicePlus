# VoicePlus — Phase 3 (v1.3.0)

"It knows what 'this' means." Hold the hotkey and point, click, or circle things while you talk — "move this over there", "make that shorter", "reply to her" — and VoicePlus binds the deictic words to whatever you touched, drew on, or have on screen at the moment you said them. When two candidates are equally plausible it asks back: pulse rings + "which one?" in the pill, answered by pointing or speaking. Everything runs locally; the input timeline is a 30 s RAM-only ring buffer, never persisted.

## What's new
- **Input timeline recorder (P3.1).** While the hotkey is held, cursor path, click points, drawn strokes and selection changes are recorded on the **same clock as the ASR audio spans** (CaptureAlignment starts on hotkey hold). Multi-display coordinates normalized; listen-only `CGEvent` tap; 30 s ring buffer, RAM only, nothing persisted.
- **Ink overlay (P3.2).** Per-display transparent click-through overlay; strokes you draw while talking render live (jitter + taper), fade after 1.5 s; bound regions pulse on resolution; region bundle counter shows in the pill.
- **Deixis resolver (P3.3).** "this / that / there / these" → word's audio timestamp → pointer position or stroke region at that moment → AX hit-test → element/region reference. Resolved bindings land as a `contextLine` in the pipeline's `StageContext` (dictation/transforms see what you meant) and `lastBindings` are kept for the Phase 4 act path.
- **Deep AX reading (P3.4).** Full-window text extraction including scrollback (`AXVisibleCharacterRange` walking, 200k cap), cached per window with invalidation. Replaces the shallow focused-window text: feeds the biasing context harvester and transform/question context.
- **Conversational referents (P3.5).** "her / him / the deck / the file" resolved from thread participants + visible artifacts (from the AX context) by gender/kind/salience; close-salience ties are flagged ambiguous.
- **Reverse elicitation (P3.6).** Ambiguous binding → rings on the candidates + "which one?" pill text with a deadline tick; point or speak to answer; timeout falls back to clarifying text in the pill.

## Install
1. Open the dmg, drag **VoicePlus** to **Applications** (replaces v1.2.0 in place; settings, personas, snippets and history are preserved).
2. First launch: right-click > **Open** (build is ad-hoc signed, not notarized — Gatekeeper will warn once).
3. Grant **Microphone**, **Accessibility** and **Input Monitoring** when prompted. Input Monitoring is what lets the timeline recorder see your pointer while the hotkey is held; Accessibility is what lets the resolver hit-test what you pointed at.

Verify the artifact: `shasum -a 256 VoicePlus_3_1.3.0.dmg` must match `Packaging/releases/CHECKSUMS.txt`
(`5344f3e9c8f90e7d012780af96d9c8ad3850cc11998901219f66a3c178da5969`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test (passed for this artifact).

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Install from this dmg over `VoicePlus_2_1.2.0.dmg` (`verify_install.sh` first) | Mount, codesign `--verify`, launch OK; settings/history preserved; Input Monitoring prompted once | [ ] |
| 2 | With two displays: open Finder windows on both, hold hotkey, click a file on display 1, say "move **this** over **there**", pointing at display 2's window mid-sentence | Both referents resolve — the clicked file and the second window; contextLine reflects them; no wrong-display binding | [ ] |
| 3 | Hold hotkey and draw a circle around a paragraph in Notes while saying "make this two lines" | Stroke renders live and fades ~1.5 s; the circled paragraph (not the cursor position) is the transform target; region counter shows in pill | [ ] |
| 4 | In a Mail thread with two participants, say "reply to her" | Referent resolves to the female participant from the thread; contextLine names her | [ ] |
| 5 | In Terminal with output scrolled off-screen, select nothing, hold hotkey, ask "what was the error above?" | Answer draws on full-window scrollback (deep AX read), not just the visible text | [ ] |
| 6 | Arrange two similar buttons close together, point between them and say "click this" | Pulse rings appear on both candidates + pill reads "which one?"; pointing at one resolves it | [ ] |
| 7 | Trigger the same ambiguity and answer nothing | On deadline, rings vanish and the pill shows clarifying text; nothing is guessed | [ ] |
| 8 | Say "this" while pointing at empty desktop | Near-miss ranking degrades gracefully; no crash, pill explains or falls back to plain dictation | [ ] |
| 9 | Plain dictation into TextEdit ("hello world", no pointing) | Phase 1/2 behaviour unchanged: text lands ≤ 700 ms; no overlay artifacts left behind | [ ] |
| 10 | Quit and relaunch | No crash log; overlay windows recreated per display; timeline buffer empty (nothing persisted) | [ ] |

## Lab numbers (2026-08-24, M2 Pro 16 GB, debug build)
- **Deixis phase gate: 120/120 synthetic cases = 100%** (gate ≥ 95%) across two displays — point, stroke, move-then-point, incl. "move this over there" resolving both referents (`DeixisFixtureTests`).
- Timeline/overlay/deep-AX/referent/elicitation units: 22 + 20 + 29 tests; integration acceptance in `Phase3AcceptanceTests` (two-display resolution, ink-bundle binding, pronoun/artifact referents, elicitation point/timeout, lander wiring).
- Whole package at this tag: **936 automated tests green / 0 failed**.

## Known deviations and limitations
- **Live `CGEvent` tap, AX hit-testing and overlay rendering are untested on hardware** — they need real TCC grants (Input Monitoring + Accessibility); the 120/120 gate is on synthetic pointer traces. The two-display live demo is the human test script above.
- Referent providers (participants/artifacts) are AX-derived; apps with poor AX trees degrade to pointer-only deixis.
- Carried from earlier phases: ad-hoc signature, no notarization, no hardened runtime; `contextBiasing`/`dualPath` off by default; synthetic TTS fixtures; human test scripts for phases 1–2 still pending on a clean account.
