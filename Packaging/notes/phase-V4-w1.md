# VoicePlus 1.11.2 — V4 wave 1 and the Spool design

## 1.11.2 — fixes from the first fresh-install run

`VoicePlus_V4-w1_1.11.2.dmg` · sha256 `86d8cdd5c4f2914e36dc7748ea274ebfe3a436c3e27bb95d52ae522713b37ae9`
Built from `5a02a51` in a clean worktree (`Packaging/release.sh V4-w1 1.11.2 --no-github`), `verify_install.sh` OK.
1.11.2 is 1.11.1 plus five fixes for problems the owner hit on a fresh install (FX1–FX5). Everything from
"1.11.1" down is unchanged.

**What changed for the user.**
- **Onboarding no longer freezes on "Try your first sentence".** Writing the practice sentence into
  VoicePlus's own text field went through Accessibility from a background thread, which locked up the
  app. Text for VoicePlus's own windows is now inserted directly on the main thread, and a watchdog logs
  any main-thread stall longer than 2 s. (FX1)
- **The chin no longer sticks on "Working…" after fn is released.** It now follows every end of a turn,
  including ones the filtered feed used to hide. (FX2)
- **No false "The speech model isn't ready" right after the first download.** The app now waits for the
  new model to finish loading before it says anything, and onboarding retries once. Download sizes are
  now real (721 MB for the stack, not 914 MB), and the progress line reads "Downloading model N of 3 ·
  name · X of Y MB overall". (FX3)
- **Designer notes are no longer shown as captions.** 14 recovery messages that showed internal notes
  (such as "After 2 s, name the wait") were rewritten as plain user text, and a test now blocks such notes. (FX4)
- **The chin's pulse stays centred.** (FX5)

**Gate.** `swift test --no-parallel` at `5a02a51`: 3215 tests, all passing (+54 over 1.11.1).

**Not verified.** Each fix is still to be checked by the owner on the installed app. Still open: other
Accessibility callers have no own-process guard, and the pill stays up about 27 s after a landing.


## 1.11.1 — a pause before the first word no longer triggers a mic warning

`VoicePlus_V4-w1_1.11.1.dmg` · sha256 `8a2edfd55e788854c72f39361bb828787b25ae23bdbbfa0a387aa46cedcbf7a5`
Built from `82ef429` in a clean worktree (`Packaging/release.sh V4-w1 1.11.1 --no-github`), `verify_install.sh` OK.
The only change since 1.11.0 is the mic gate fix (`82ef429`). Everything from "1.11.0" down is unchanged in 1.11.1.

**What changed for the user.** On the built-in mic in a quiet room, waiting about a second before the
first word could bring up "Mic level is very low" in the pill and a bad mic status in the menu. The
speech itself was fine. The cause was the start of capture. For 30–45 ms the mic reads 10–20 dB below
the room, and the energy VAD took that dip as the room's noise floor. The room then counted as speech,
so the mic check graded the room instead of the voice. Now a level has to last 60 ms before it can
become the floor, so the check grades the first second of real speech. The energy VAD is what
dictation uses when the Silero VAD model is not on disk, and it is always what onboarding and the
microphone self-test use. Silero was not measured on this corpus. The verdict also no longer depends
on how busy the machine is, whichever VAD runs: the check now receives audio one VAD frame at a time
and gives its verdict at a fixed frame. The mic-quality thresholds are unchanged.

**Gate.** 0 mic warnings on the quiet-room corpus: **passes 20 / 20** (1.11.0: 2 / 20). The results
are identical whether the audio is fed in 50 ms blocks, 10 ms blocks or the whole file at once.
`swift test --no-parallel` at `82ef429`: 3161 tests, all passing.

**Cost, and what is still open.**
- In a real room the steady noise floor reads about 2–3 dB higher, so speech needs that much more level
  to start a segment.
- The mic check's own floor estimate has no 60 ms hold yet. On 9 of the 20 corpus files its SNR reads
  6–26 dB too high. This never causes a warning, but it has to be fixed before Wave 2 uses the corpus
  to set the SNR bounds.
- The Settings microphone test still runs its own analyzer on whole blocks.

## 1.11.0

`VoicePlus_V4-w1_1.11.0.dmg` · sha256 `e80a1b58715c68f31661886001899246914657f03cc7ca02477caf618165cf92`
Built from `928551d` in a clean worktree (`Packaging/release.sh V4-w1 1.11.0 --no-github`), `verify_install.sh` OK.
Every wave 1 item of `VoicePlus_Improvements_V4.md` §14.2 and the whole Spool design
(`design/design_v1.md`) are implemented. Waves 0–3 each closed with `swift test --no-parallel` all green
(3108 tests at the wave 3 gate); the release-candidate test run is R1's, recorded in `progress.md`.
This is a **candidate**: every hardware check in build doc §5 is still unrun.

### What changed for the user

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

### V4 wave 1 gates

| Gate | Result |
|---|---|
| digits class WER < 0.20 | **passes** — raw 0.062, processed 0.094 (lines 04 / 05 / 11) |
| 0 mic warnings on the quiet-room corpus | **fails — 2 / 20.** Lines 02 and 14 open with ~1.1 s of room; the energy VAD opens a segment on it and the analyzer grades room as speech. Known issue; the fix belongs to VAD onset, not the thresholds. **Fixed in 1.11.1: 20 / 20.** |
| 0 phantom landings on silent holds | fixture-verified; owner repeats live |
| cold launch → first landing p95 < 2.5 s; key-down → first buffer p95 < 150 ms | now logged once per process at `.info`; owner measures |
| latch lands every ≥ 2 s pause; mid-sentence placement ≤ 2 wrong in 30 × 5 apps | mock / pipeline tests only; owner session |

### Not verified

Everything needing a microphone, a display, real apps or TCC grants: the tape flight and mark overlays on
real carets, notch placement, VoiceOver and high-contrast passes, onboarding on a clean account and on an
external monitor, the live fn system-action prompt, and the timing gates above. See build doc §5.

Ad-hoc signed. No Developer ID, no notarization — first launch needs right-click › Open.
