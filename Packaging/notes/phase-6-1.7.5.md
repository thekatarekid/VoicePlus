# VoicePlus 1.7.5 — the onboarding window no longer clips its own buttons

The onboarding window was a hard-coded **520 × 420** for six steps of very different
heights, with no scroller anywhere. When a model download started, roughly **120 pt** of
progress UI appeared on the model step — a progress bar, a wrapping progress line, a Cancel
button, an info line and a two-line amber warning — and the footer went off the bottom
edge. That footer is **Back / Skip / Continue**: the only way forward, cut in half by the
window it lived in.

Option subtitles were truncating mid-sentence in the same window, for the same reason.

Ships in the same dmg as 1.7.4, 1.7.6, 1.7.7 and 1.7.8. Tag `release/phase-6/v1.7.5` ·
1 commit (`8b359e3`) on top of 1.7.4 (`9a01b91`) · sha256 and dmg size recorded at the
release build.

## 1. What was actually happening

- **A fixed `.frame(width: 520, height: 420)`** — a size that suits a step at rest and
  nothing else. Six steps, one height.
- **Nothing scrolled**, so content that did not fit simply overflowed the window rather
  than becoming reachable.
- **The action row had no reserved space.** It was laid out after the step content, so it
  was the first thing to lose when the content grew — the worst possible casualty, since it
  is the only exit.
- **Subtitles used truncation rather than wrapping**, so an option's explanation ended
  mid-sentence.

## 2. What ships instead

- **Each step reports its own laid-out height** and the window adopts it — new
  `App/Onboarding/OnboardingWindowSizing.swift` — **clamped to the usable area of the
  display the window opens on**, so sizing to content can never size past the screen.
- **The step area is the only flexible region, and it scrolls.** The progress bar and the
  action row keep their space at any content height, so **the clipped footer is now
  structurally impossible** rather than merely unlikely.
- **Progress text sits in a reserved fixed-height box**, so a per-tick update from
  *"95 MB"* to *"96 MB"* is a text change rather than a relayout of the window.
- **Sub-1 pt geometry republishes are ignored**, which removes the residual jitter from
  measurement noise during a live download.
- **Option subtitles wrap** instead of truncating mid-sentence.

## 3. Tests

- New `Tests/AppTests/OnboardingWindowSizingTests.swift` — **15 tests**: the window adopts
  the tallest reported content, the clamp holds against a small display, the chrome keeps
  its height while the step area absorbs the overflow, a sub-point change does not
  republish, and a step that grows mid-flight (the download case) still leaves the action
  row fully on screen.
- **All six steps checked in their tallest states.**
- **Full package: `swift build` clean, 1313 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **Start a model download and look at the bottom of the window.** Back / Skip / Continue
   should be whole and clickable throughout.

3. **Say whether the window growing feels right** — it now changes size between steps, and
   whether that reads as responsive or as jumpy is a judgement no test here can make.

## Known and remaining

- **Every visual judgement is unverified — an agent has no window server.** Precisely
  unknown: how the resized window *looks* at each step, whether the grow animation is
  pleasant, and whether the scrolling step area is ever visibly scrolled in practice on a
  normal display. The sizing arithmetic, the clamp, the fixed chrome and the jitter
  suppression are covered by tests.
- **The clamp has not been seen against a genuinely small display.** Its behaviour is
  tested; its appearance is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
