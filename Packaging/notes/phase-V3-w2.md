# VoicePlus 1.9.0 — V3 wave 2

`VoicePlus_V3-w2_1.9.0.dmg` · sha256 `91caf4a95181be3dccf9c143398a8de8fda3126c5bc87c74ae312dafb0c557e2`
Built from `c903352` in a clean worktree. **1821 tests, all passing.** Still a candidate, not a
reliability release (V3 §10.4): every hardware check in build-doc §5 is unrun.

## What changed for the user

**Latch works.** Double-tap and keep talking: endpoints close segments while listening continues, and
the mode survives every finalize. It never worked before — `finalize()` cleared the flag on every
utterance, so "hands-free" ended after one sentence. A single tap stops. Sleep, lock and hard mute all
stop capture and cancel pending insertion; waking is never a silent resume.

**Dictation fits the field it lands in.** A terminal inside an editor now gets terminal rules — no
auto-capitalization, no trailing period, never submit — decided by the field's accessibility
description rather than by which app it is. Code identifiers (`user_session_token`, `--flag`, `$HOME`,
paths) survive formatting unchanged. Mid-sentence insertion gets a leading space and no capital.

**Learned corrections are visible and reversible.** Dictionary lists what was learned, what it was
heard as, and where it came from. Forget removes it from the live lexicon *and* purges the training
pairs, so retraining cannot quietly relearn it — proven by a test that trains, corrects, forgets, and
re-runs the same audio.

**Onboarding is five steps and never a wall.** Welcome → Microphone with a real level meter →
Accessibility → try the key with a real landing → Done. The model installs in the background from the
moment onboarding opens; no Continue button is ever gated on it. Every denied permission has a way
forward. The practice field previously could report "heard" but never "landed" — it was never wired to
the lander at all. It is now.

**Speaker filtering stops pretending.** With the embedding weights absent it says "Speaker model
unavailable — VoicePlus can't tell voices apart" instead of implying a check ran.

## The Qwen second pass is off, and that is the measured answer

R5's gate asks for useful gain on difficult speech, no clean-speech regression, and the 1500 ms
deadline met. Measured on the twenty real-room dictations with the real int8 weights:

| | |
|---|---|
| pass-1 mean WER | 0.0991 |
| pass-2 mean WER | 0.1784 |
| segments pass 2 improved | 1 of 20 |
| segments pass 2 made worse | 7 |
| latency against a 1500 ms deadline | 1.9–4.2 s |

It fails all three conditions, so `qwenRefinement` stays off. This is not caution: the port itself is
correct now. It had been transcribing English into Devanagari because Qwen3-ASR names its own output
language in the assistant turn and the port never wired forced decoder ids — fixed, WER 1.000 → 0.000
on the probe line. The gate that would select the minority of helpful segments is built and measured
(recall 1.000, precision 0.167). V3 §5.4 calls either outcome a valid completion.

## Not verified

Every hardware check: the delivery matrix across real apps, 50 consecutive dictations, latch across
three apps with focus changes, one sleep/wake, onboarding on a clean account, thermals over 30 minutes
latched. Also unverified: the **live** accessibility read that feeds field-role hints — there is no
accessibility permission or window server on the build machine, so the mapping from real VS Code /
Terminal elements to hints is proven only against mocks.

Two known gaps carried forward (build doc §8): Escape is implemented but bound to no key, because a
global monitor needs Input Monitoring and a bare-Escape hot key would steal Escape system-wide; and
the `handsFree` → `latched` rename stops at seven files still held by other work, behind deprecated
aliases.

Ad-hoc signed. No Developer ID, no notarization — Gatekeeper will reject it until an identity exists.
