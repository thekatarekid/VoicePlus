# VoicePlus 1.7.12 — the error notice covered half the screen, and the dot's click went back to opening the menu

Two things the owner hit on real hardware, both on the notch surface.

When dictation failed, what appeared was, in their words:

> a big black strip emanating from the notch in the center with an error

A **black slab over roughly half the screen height** — for a one-sentence error. And,
separately:

> It was ok to open menu on left clicking the notch. No need to make it right click.

Ships in the same dmg as 1.7.10 and 1.7.11 — **this is the dmg**. Tag
`release/phase-6/v1.7.12` · 1 commit (`30911bb`) on top of 1.7.11 (`a2f2887`) · sha256
`d2114de0a682e74b754928fbd9b67b55e7df1a4176c4faa71046c8df3970be01`, 15,655,544 bytes.

## 1. What was actually happening

**It was not the geometry math.** Every frame `NotchGeometry` computed was correct, and the
panel was still a slab.

- **`NSHostingView.sizingOptions` defaults to `.standardBounds`**, which publishes the SwiftUI
  content's **minimum** size as the panel's **`contentMinSize`** — and **AppKit then grows the
  window to it after every `setFrame`.** The layout code was being overruled by the hosting
  view, silently, after it had finished.
- **`.fixedSize` on the notice stack made that minimum enormous.** A notice with
  `.fixedSize(horizontal: false, vertical: true)` has a **one-word minimum width** — so its
  **minimum height is the fully wrapped paragraph**.
- **Measured, not guessed.** A standalone AppKit probe set a panel to **420×64** and read back
  **420×1187** for the owner's actual message, and **420×4727** for a long one.

## 2. What ships instead

**Three layers, so no message length and no caller can produce a slab:**

- **`sizingOptions = []` with explicit content min/max** on **both** the pill and presence
  panels — the hosting view **opts out of window sizing entirely**, so a frame is **placement
  math and never content**.
- **A bounded notice view**: headline **two lines, tail-truncated**; subtitle **one line**; **no
  `fixedSize`**. A long error is **elided**, not unrolled.
- **`NotchGeometry.absoluteMaximumSize` — 560×96** — a real ceiling, **clamped per display**
  and applied in **both `size(for:on:)` and `layout(for:size:)`**, so even a caller asking for
  **9000×9000** gets a pill.

**And the presence dot's left-click opens the status menu again**, at the owner's request. The
**1.7.6 remedy routing is removed rather than kept for blocked states** — a click whose meaning
depends on **decoding the dot's colour first** is exactly the unpredictability being complained
about, and every remedy it offered (**Check permissions…**, **Settings…**, **Quit**) is **one
item away in the menu anyway**. **`PresenceClickRouter` survives as the single tested decision
point**; the code that no longer has a job was **deleted rather than left asserting behaviour
we no longer have**.

## 3. Tests

- `Tests/AppTests/NotchGeometryTests.swift` — **2,600- and 5,000-character messages stay
  bounded across five display shapes**, in both sizing and layout, including a caller demanding
  an absurd size.
- `Tests/AppTests/PillPresenterTests.swift` updated for the simplified click contract.
- **`swift build` clean, 1347 tests passing** for the whole package.

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **This dmg carries 1.7.10, 1.7.11 and 1.7.12.** Its two companions are the dictation key
   that was also the act key, and the model that reported "installed" while half-downloaded —
   read their notes for what to check.

3. **Provoke an error and look at the notch.** It should be a **compact two-line pill under the
   notch**, never a strip down the screen.

4. **Left-click the presence dot.** The status menu should open, and **focus should stay where
   it was** — the panel remains a non-activating `NSPanel` and nothing here activates the app.

## Known and remaining

- **Every visual judgement here is unverified** — an agent has no window server. Specifically
  unconfirmed: **that the error notice now reads as a compact two-line pill under the notch**,
  and **that left-clicking the dot pops the menu without stealing focus**. The size ceiling is
  measured and pinned by test; how it *looks* is not.
- **No agent on this machine has a microphone, a window server or hardware**, so the surfaces
  here are covered against geometry and the click router rather than a real display.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the
  first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
