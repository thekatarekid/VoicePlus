# VoicePlus 1.11.0 — V4 wave 1 and the Spool design

`VoicePlus_V4-w1_1.11.0.dmg` · sha256 `e80a1b58715c68f31661886001899246914657f03cc7ca02477caf618165cf92`
Built from `928551d` in a clean worktree (`Packaging/release.sh V4-w1 1.11.0 --no-github`), `verify_install.sh` OK.
Every wave 1 item of `VoicePlus_Improvements_V4.md` §14.2 and the whole Spool design
(`design/design_v1.md`) are implemented. Waves 0–3 each closed with `swift test --no-parallel` all green
(3108 tests at the wave 3 gate); the release-candidate test run is R1's, recorded in `progress.md`.
This is a **candidate**: every hardware check in build doc §5 is still unrun.

## What changed for the user

**Spool.** The app has a face: a cassette whose reels turn counterclockwise while you speak and
clockwise while text is written, with one oxide tape running from the live-words ribbon into the pill.
The menu-bar glyph is the cassette. When a verified caret is known, the tape flies from Spool's mouth to
where the text will land and leaves a short fading line under it.

**You see the final text before it is typed.** Release the key and the final text sits in the pill for
the preview dwell (900 ms by default, or 600 / 1500 / manual) before anything is written. Escape during
listening, finishing or the preview means nothing is typed. If focus moves while you speak or during the
preview, the text is held rather than typed into the wrong place, and "Insert here" re-checks the
destination.

**Words it is unsure of are marked.** Uncertain words get a dotted underline in the pill and, in Notes,
TextEdit, Mail and Safari, over the text itself. Click one to pick an alternative, keep it, or edit it;
the replacement only lands if the range still holds what was written.

**Dictation starts faster and stops typing things nobody said.** The key works before the app has
finished loading ("Starting microphone…"), the capture graph stays warm, and model maintenance no longer
runs on launch. Silent holds land nothing: a no-speech gate, a hallucination guard, and pre-roll only
from a graph that is actually running.

**Mid-sentence dictation fits the sentence.** Caret context is three-valued (known, unknown, none), so
capitalisation and leading spaces follow what is actually before the caret; punctuation is provisional
until the next words arrive; a spacing setting controls the leading space.

**Numbers.** Spoken digit runs are joined by their timing, and number formatting tolerates the
recognizer's own punctuation. Replay of the three number lines in the real-room corpus: WER 0.062 raw,
0.094 after formatting (gate < 0.20).

**Latch lands as you go.** In latch mode each pause of the configured length (1–5 s, default 2) lands
that segment through the normal lander.

**fn / 🌐 is the default key**, with a prompt when macOS still has fn bound to a system action. **Escape
now cancels a turn** (closing V3 gap G1) and is never taken outside one.

**Point at it.** With the key held you can draw a box on screen; VoicePlus reads the element, its text and
a crop of what is under it, and the chip in the pill says what it captured.

**Your voice, learned passively.** Speaker verification (WeSpeaker) learns from your normal holds;
enrollment is also a step in onboarding and on the Voice page.

**One window, redesigned.** Today (held drafts first, then recent dictations with what happened to each),
Meetings, Dictionary & Apps (per-app rules now actually applied), Voice (mic picker, live meter, test
sentence), Privacy (history switch that really stops saving, network log, scoped delete, diagnostics)
and seven Settings pages. Every screen has real empty, loading, error and partial states.

**Every error names its fix.** One recovery catalogue of 59 entries drives the pill, the window,
onboarding and the menu. Unconfirmed or partial deliveries are never retried automatically.

**Accessibility.** Reduce Motion gives Spool a still pose and the pill no animation; VoiceOver hears
start, "Microphone closed", "Final text ready · N words to review" and the result once each; Larger Text
reflows the window; marks are placed on whole graphemes (CJK, RTL, emoji).

## V4 wave 1 gates

| Gate | Result |
|---|---|
| digits class WER < 0.20 | **passes** — raw 0.062, processed 0.094 (lines 04 / 05 / 11) |
| 0 mic warnings on the quiet-room corpus | **fails — 2 / 20.** Lines 02 and 14 open with ~1.1 s of room; the energy VAD opens a segment on it and the analyzer grades room as speech. Known issue; the fix belongs to VAD onset, not the thresholds. |
| 0 phantom landings on silent holds | fixture-verified; owner repeats live |
| cold launch → first landing p95 < 2.5 s; key-down → first buffer p95 < 150 ms | now logged once per process at `.info`; owner measures |
| latch lands every ≥ 2 s pause; mid-sentence placement ≤ 2 wrong in 30 × 5 apps | mock / pipeline tests only; owner session |

## Not verified

Everything needing a microphone, a display, real apps or TCC grants: the tape flight and mark overlays on
real carets, notch placement, VoiceOver and high-contrast passes, onboarding on a clean account and on an
external monitor, the live fn system-action prompt, and the timing gates above. See build doc §5.

Ad-hoc signed. No Developer ID, no notarization — first launch needs right-click › Open.
