# VoicePlus 1.10.0 — V3 waves 3 and 4 (the document is complete)

`VoicePlus_V3-w34_1.10.0.dmg` · sha256 `1dba134819bea6e83e0adf5b4de2f23375c94aaf5bb2192c144794cbc6392c24`
Built from `0233c62` in a clean worktree. **1970 tests, all passing** (`--no-parallel`).
Every item R0–R8 of `VoicePlus_Improvements_V3_Build.md` is implemented. Still a **candidate**, not a
reliability release (V3 §10.4): every hardware check in build-doc §5 is unrun.

## What changed for the user

**One window instead of nine truncated tabs and three floating panels.** Sidebar and detail: Today,
Meetings, Dictionary / Apps, Voice, Privacy, Settings, on ⌘1–⌘6. The Lab, the Data Panel and voice
enrollment are folded in; all eleven old tabs are placed and every one of 46 settings is still
reachable. Two settings that had only ever been editable with `defaults write` now have real controls:
the never-inject app list and the ambient-capture switch.

**One menu, from anywhere.** Left or right click on the glyph or on the idle notch presence opens the
same menu: status and microphone, dictate / latch / mute, recover held text, meeting, open the window,
quit. Stop is there explicitly while capture is open. Building the menu reads no focus and dequeues
nothing, so opening it cannot disturb where your text was going to land.

**A Timeline you can search and actually empty.** Search, source filters, per-row delete and
delete-all, each deletion verified against the store rather than optimistically removed from the view.
Seven-day retention is now enforced, and expiry clears the search index rather than leaving rows
findable.

**The microphone indicator now tracks real ownership.** It reads the actual capture-graph owner, not
an intention. A failed start no longer leaves it lit, and an open microphone outranks "muted" and
"paused" in what it shows — an indicator that says off while the mic is open is the one bug this
feature cannot have.

**"Latch" means one thing now.** The double-tap mode is `latched` everywhere; `handsFree` is gone, and
the comments that called the persistent mute a "latch" are corrected. A test fails if the old name
regrows.

## The Qwen second pass is off, and this is the full reason

R5's gate: useful gain on difficult speech, no clean-speech regression, deadline met. Measured with
real int8 weights on the twenty real-room dictations, broken down by segment class as §5.4 requires:

| class (n) | Parakeet | Qwen | two-pass @1500 ms |
|---|---|---|---|
| all (20) | **0.099** | 0.178 | 0.112 |
| entities (7) | **0.081** | 0.197 | 0.102 |
| ≥7 s (8) | **0.182** | 0.335 | 0.200 |
| digits (3) | **0.405** | 0.738 | 0.405 |
| 5–7 s (11) | **0.048** | 0.081 | 0.059 |

**No class wins.** Under the shipping deadline the gated two-pass improved 0 segments and damaged 2,
with 4 of 6 gated segments timing out. Latency p95 1816 ms against a 1500 ms budget. Peak memory,
measured not estimated: 1866 MB against Parakeet's 90 MB. So `qwenRefinement` stays off, and a test
now fails if the default is flipped without a new table.

The port itself is correct — it had been transcribing English into Devanagari because Qwen3-ASR names
its own output language in the assistant turn and the port never wired forced decoder ids. Fixed: WER
1.000 → 0.000 on the probe line. V3 §5.4 calls either outcome a valid completion; this is the
measured one.

## Known gaps, carried deliberately (build doc §8)

- **Ambient keeps nothing yet (G11).** It is opt-in, off by default, wired and tested — but the
  enrolled-speaker verdict is `.unknown` because the transcript seam carries text and a segment id,
  not audio. Every segment is therefore discarded. On this machine the WeSpeaker weights are absent,
  so the verdict would be "model unavailable" (suppress) regardless. To finish: carry the samples on
  the seam, or compute the verdict in `LatchRuntime` where the audio already is.
- **Escape is implemented but bound to no key (G1).** A global monitor needs Input Monitoring, which
  V3 §2.1 keeps behind an escape hatch, and a bare-Escape hot key would steal Escape system-wide.
  Needs a design decision.
- **"Start meeting" is disabled (G9).** `MeetingCoordinator` has no manual-start path, so it reads
  "starts when a meeting is detected".
- **~14 timing assertions fail under parallel test execution (G5).** They pass serially; release
  verification uses `--no-parallel`. Caused by real-model corpus tests competing for the machine, not
  by any product change.

## Not verified

Everything needing a microphone, a real app, a display or a TCC grant. In particular: the delivery
matrix across Notes, Mail, Brave, Slack, VS Code, Terminal and Numbers; 50 consecutive dictations;
latch across three apps with focus changes and one sleep/wake; onboarding on a clean account; thermals
over 30 minutes latched; the window on notch and notchless displays; VoiceOver, reduced-motion and
increased-contrast passes; and the **live** accessibility read that feeds field-role hints, which is
proven only against mocks.

Ad-hoc signed. No Developer ID, no notarization — Gatekeeper will reject it until an identity exists.
