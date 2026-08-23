# VoicePlus — Phase 1.5 (v1.1.0)

"Dual-path silent correction" (Bet 4). The fast EOU preview lands immediately; the accurate TDT v3 final pass runs alongside it and, when it disagrees, the wrong word is silently fixed in place after landing — without ever touching text you have edited yourself. Shipped behind the `dualPath` flag, **default off** (see below). Everything still runs on device; no new network egress.

## What's new
- **Reconciler (P1.5.1).** `DualPathRunner` runs the EOU preview and the TDT v3 final pass concurrently (ANE contention profiled via `DualPathTiming`); `WordAligner` diffs final vs preview at word level using audio-span alignment, so only the words that actually changed are candidates.
- **Correction planner + safety rule.** A span is corrected only if it (a) differs semantically, (b) exceeds the confidence-delta threshold, and (c) passes the **safety rule**: the target text must still exactly match what we injected, verified by an AX readback of the document (`InjectionDocumentReadback`). Any mismatch downgrades the correction to a suggestion or drops it — a correction can never land on text you typed after dictating.
- **Correction UX (P1.5.2).** Corrected word gets a shimmer then a 2 s underline (NSPanel anchored via AX word rects); hover shows "was: …" with one-tap revert; **"Show what changed"** submenu in the menu-bar dropdown lists recent corrections (`CorrectionLedger`); global and **per-app off switch** in Settings > Snippets & corrections > "Silent corrections"; **"put it back"** voice undo reverts the last silent correction (consulted before the regular repair undo).
- **`dualPath` flag stays off by default.** In-app, the reconciler's preview side is the landed (formatted) text rather than a re-run of the EOU model, so the real EOU+TDT disagreement rate on human speech — and therefore the ≥ 95 % precision bar — is unmeasured on hardware. Until that is measured in the Lab on a real mic, the conservative default is off; the feature is one toggle away (step 3 below).

## Install
1. Open the dmg, drag **VoicePlus** to **Applications** (replaces v1.0.0 in place; settings and history are preserved).
2. First launch: right-click > **Open** (build is ad-hoc signed, not notarized — Gatekeeper will warn once).
3. Grant **Microphone** and **Accessibility** when prompted; **Input Monitoring** is requested for the global hotkey. No new permissions vs Phase 1.

Verify the artifact: `shasum -a 256 VoicePlus_1.5_1.1.0.dmg` must match `Packaging/releases/CHECKSUMS.txt`
(`451351335368748bc27ac7dffa2659d259332ffe9e3baef5fd138617d2e3db31`). `Packaging/verify_install.sh` runs the same check plus a mount/codesign/launch smoke test (passed for this artifact).

## Human test script (must pass before the phase is "done")
| # | Step | Expected | Pass? |
|---|------|----------|-------|
| 1 | Install from this dmg over `VoicePlus_1_1.0.0.dmg` (`verify_install.sh` first) | Mount, codesign `--verify`, launch OK; settings + history preserved; no permission re-prompt | [ ] |
| 2 | Settings > Flags, before changing anything | `dualPath` is **off**; dictation behaves exactly as v1.0.0 (no underlines ever appear) | [ ] |
| 3 | Settings > Flags: turn `dualPath` **on**; relaunch | Toggle persists; Settings > Snippets & corrections shows the "Silent corrections" section enabled | [ ] |
| 4 | Hold hotkey, say "send the deck to Mariah by Thursday" into TextEdit | Preview lands ≤ 700 ms after release; if the final pass disagrees with a preview word, that word shimmers, corrects in place, and shows a 2 s underline; nothing else in the line moves | [ ] |
| 5 | Hover the underlined word within 2 s | Tooltip "was: <preview word>"; one click reverts to the preview word | [ ] |
| 6 | Dictate a sentence, then **immediately** type three characters at the end before the final pass lands | Typed characters are never moved, overwritten or split; any pending correction is silently dropped (safety rule) | [ ] |
| 7 | Dictate, let a correction land, then hold hotkey and say "put it back" | Only the corrected word reverts; correction disappears from "Show what changed" | [ ] |
| 8 | Menu bar > **Show what changed** | Submenu lists today's corrections as "was → now" with app name; empty state reads correctly when nothing was corrected | [ ] |
| 9 | Settings > Snippets & corrections: add TextEdit to the per-app off list; repeat step 4 | No correction is applied in TextEdit (no shimmer/underline); still applied in Notes | [ ] |
| 10 | Open Data Panel after steps 4–9 | Pipeline egress 0 bytes; "clean" status (dual path adds no network calls) | [ ] |
| 11 | Turn `dualPath` back **off**; quit and relaunch | No underlines; no crash log in Console; previous state restored | [ ] |

## Lab numbers (2026-08-24, M2 Pro 16 GB, debug build)
- `ReconcileTests` (22): splice property fuzz with concurrent user edits — corrections never alter user-modified text (0 violations); correction precision ≥ 95 % on synthetic fixture disagreements.
- `CorrectionUXTests` + `TransformUXTests` (36) cover ledger, overlay anchoring model, per-app switch, "put it back" routing, reconciler wiring behind the flag.
- Whole package: **930 automated tests green / 0 failed** (all targets, after de-flaking four timing tests under the full parallel run).

## Known deviations and limitations
- **`dualPath` defaults off** (reasons above). Reconciler preview = landed formatted text stand-in instead of a second EOU run, so `DualPathTiming` contention numbers are not meaningful in-app; replacement text from the final pass can lose adjacent punctuation.
- "put it back" is routed in `UtteranceLander` ahead of `RepairSession` (whose undo stack is private).
- **Not verified on hardware:** AX word-rect anchoring and overlay rendering, a real EOU+TDT dual-path run on a live mic, Mail/Slack/Notes acceptance (mock-only).
- Per-app off list is stored as a settings key list (no UI for bulk edit).
- Carried from Phase 1: ad-hoc signature, no notarization, no hardened runtime; `contextBiasing` off; Silero VAD → energy VAD fallback; synthetic fixtures only; CI unverified; security-review follow-ups in `docs/SECURITY-REVIEW.md`.
