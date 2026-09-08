# VoicePlus 1.7.3 — the status row fits its text, and you can see it without hovering

Three complaints about one surface, the little row under the notch.

It was **cut off**:

> VoicePlus · Ready — hold R…

There was no state in which the rest of that sentence ever became readable. It was
**invisible**: at rest the indicator drew nothing at all inside a 4 pt chin at 35% black —
a near-black sliver under a black bezel — so the app looked like it had no presence unless
you happened to hover over the notch. And it was **mute about how to use the app**: nothing
ambient said VoicePlus was running and armed, and nothing anywhere reminded you which key
starts dictation.

Ships in the same dmg as 1.7.1 and 1.7.2. Tag `release/phase-6/v1.7.3` · 1 commit
(`06c5ccd`) on top of 1.7.2 (`3b9c75e`) · sha256 and dmg size recorded at the release
build.

## 1. What was actually happening

- **The hover panel was a hard-coded 190 pt** drawing `lineLimit(1)` with
  `truncationMode(.tail)`. Any message longer than 190 pt was clipped, permanently — the
  panel never grew, never wrapped, never scrolled. "hold Right ⌃" was exactly the part that
  fell off the end, so the one thing the row existed to teach was the one thing it hid.
- **`.ready` at rest was an `EmptyView`** in a 4 pt chin at 35% black. Against a black
  bezel that is not a subtle indicator; it is nothing. The app's only ambient sign of life
  required the user to already know where to point the mouse.
- **The hotkey was not discoverable anywhere**, and where a label did exist it was written
  as a literal — so a user who rebound the key in Settings would have been told the wrong
  one.

## 2. What ships instead

- **The row is sized to its content.** New `App/Core/PresenceRow.swift` handles text fitting
  and the hotkey hint; `PresenceRow.fit` measures in the **real font**, and
  `NotchGeometry`/`NotchPresenceGeometry` clamp the result against actual notch and screen
  geometry. The pill gets the same treatment for its fixed notices.
- **A narrow display degrades in order, never mid-word.** When the sentence genuinely will
  not fit, whole components drop in priority order — the **hint**, then the
  **"VoicePlus · " prefix**, then **trailing whole words**. No half a word plus an ellipsis.
- **At rest it is a status light, not a banner.** The chin is now 10 pt at 72% black
  carrying **one small lit dot**: visible, and quiet.
- **It announces itself when there is something to announce.** The full row expands for
  **six seconds** at launch and whenever the app **recovers out of a blocked state** — so it
  tells you the moment a permission is granted or a model download makes dictation live
  again. It **never** expands after an ordinary utterance, and it is click-through while
  announcing so it cannot swallow a click. Hover still expands it at any time.
- **The hotkey label is read live from the configured binding** (`HotkeyHint.label`):
  *"hold Right ⌃"* for a bare modifier, *"press ⌃⌥D"* for a chord. Change the binding in
  Settings and the hint follows, instead of hardcoding "Right Control".

## 3. Tests

- New `Tests/AppTests/PresenceRowTests.swift` — **17 tests**. They pin the property, not the
  pixels: the fitted width holds the whole string, degradation drops components in order and
  never splits a word, the hint tracks the binding rather than a literal, and the announce
  window fires on launch and on unblock but not after an utterance.
- `NotchPresenceTests` updated for content-sized geometry.
- **Full package: `swift build` clean, 1259 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **Watch the notch on first launch.** The row should announce itself for about six
   seconds, tell you which key to hold, and then settle to a single dot.

3. **Please say whether the dot reads as present-but-quiet, and whether six seconds is
   right.** Those are judgements no test on this machine can make (see below), and they are
   the two things most worth changing if they are wrong.

## Known and remaining

- **Every visual judgement here is unverified — an agent has no window server.** Precisely
  unknown: whether the lit-dot chin reads as visible-but-quiet against a **real** bezel,
  whether the six-second announcement feels informative or intrusive in daily use, and the
  **true measured width** of the expanded row in the system font on real hardware. The
  fitting, degradation order, hint derivation and announce triggers are covered by tests;
  how any of it *looks* is not.
- **The degradation ladder has not been seen on a genuinely narrow display.** Its order is
  tested; the appearance at each rung is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
