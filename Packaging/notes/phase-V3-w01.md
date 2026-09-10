# VoicePlus 1.8.0 — V3 waves 0 and 1

`VoicePlus_V3-w01_1.8.0.dmg` · sha256 `caa3009dcd628d740ee9c667b16970c5f300aaa47b9396b79051006ef3b85185`
Built from `727fbd6` in a clean worktree. **Candidate, not a reliability release** (V3 §10.4): the R5
refinement gate is open, and every hardware check on the owner checklist is still unrun.

## What changed for the user

**Text lands once, and you can see what landed.** The pill used to show the 120M streaming preview and
nothing else, so what you read was a weaker model's guess without punctuation — that was the accuracy
problem people felt. On land it now shows the **committed text** for about 1.2 seconds.

**Dictating into Brave, Chrome, Edge and Arc no longer double-types.** A method that posted without
throwing is never retried. Chromium's accessibility value does not reflect a change, so the old code
read "unchanged", called it a failure, and posted a second time — text landed twice or a success was
reported as a failure. Unconfirmable now reads "Landed · not confirmed" instead of lying either way.

**Text with nowhere safe to go is held, not guessed at.** Switch apps mid-dictation and the words wait
with Insert here / Copy / Discard, naming the destination. Returning focus no longer inserts by itself —
the old 1.5 s auto-flush could put your words in the wrong window. Quitting with held text warns you.

**Password fields and apps you name are refused outright,** with nothing posted.

**Repair by voice:** "scratch that", "no, <replacement>", "put it back" — applied only when the text
region still matches, never by blind backspaces or ⌘Z.

**No model choice any more.** One stack (Parakeet TDT v3 + EOU 120M) installs on first run. Existing
installs keep what is on disk and re-download nothing.

**Echo cancellation stops being advertised where it never ran.** Every previous manifest claimed
`aec=appleVoiceProcessing` while the capture graph ran `vp=false`. Measured on twenty real-room
dictations, the plain tap beat the spectral gate (WER 0.1000 vs 0.1182) and won all seven points of a
30→0 dB sweep, so the plain tap is now the default and the manifest tells the truth.

## Evidence

1626 automated tests, 1624 green. Both failures are in the Qwen refinement path, which ships behind a
flag that is **off by default**: the port transcribes English speech into Devanagari (WER 1.000), and a
deadline test overran 5.0 s by 0.6 s under load. Neither affects dictation.

Corpus replay through the real `AppContainer` pipeline: 202 stage runs, **0 contract violations** — the
`wakeVerb` and `adapt.lexicon` stages had silently failed the provenance contract on every span, so
their output was being discarded.

Fixture WER unchanged by the segment work, verified against a before/after build with only
`RealEngine.swift` reverted.

## Not verified

Everything needing a microphone, a real app, or a TCC grant: the delivery matrix across Notes, Mail,
Brave, Slack, VS Code, Terminal and Numbers; 50 consecutive dictations; the 1.2 s dwell as seen on
screen; the quit alert; unplug-mid-dictation and sleep/wake recovery; onboarding on a clean account.
Owner checklist, build doc §5.

Ad-hoc signed. No Developer ID, no notarization — Gatekeeper will reject it until an identity exists.
