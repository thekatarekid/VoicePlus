# VoicePlus 1.7.6 — the dot's click means something, and errors stay long enough to read

Two faults on the notch surface introduced with 1.7.3's presence row.

Clicking the new **green presence dot** opened the menu bar app's menu. Not sometimes — the
dot had been wired unconditionally to `statusItem.popUpMenu()` for **every** state, so the
one control that describes the app's health answered every click with a list of commands.

And errors **flashed past unread**. `RealEngine` emits `.landed` then `.idle` back to back,
while the reducer mapped `.error` to a preview that the next `.idle` erased — so the pill
ran its slide-in and its slide-out in the **same run-loop pass**. That is the "broken
animation" the owner saw on key release, and the reason he could not screenshot the error
he was hitting.

Ships in the same dmg as 1.7.4, 1.7.5, 1.7.7 and 1.7.8. Tag `release/phase-6/v1.7.6` ·
1 commit (`243c57a`) on top of 1.7.5 (`8b359e3`) · sha256 and dmg size recorded at the
release build.

## 1. What was actually happening

- **The click had one behaviour for every state.** A ready dot, a warning dot and a blocked
  dot all popped the same menu, so a dot that meant "the microphone is denied" answered a
  click with something other than the way to fix it.
- **`landing` → `hidden` in one pass.** Two engine events arriving back to back reduced to
  a visible state and its retraction with no time in between, so the panel animated in and
  out at once.
- **An error was not its own state.** It was `.preview("⚠︎ …")` — a transcript-shaped
  string — so it could not be sized, dwelled or styled as a notice, and any subsequent
  `.idle` erased it as though it had been speech.

## 2. What ships instead

- **A click router** — new `App/Core/PresenceClick.swift`. The **primary click** pins the
  expanded row open for **5 s in place**, with no focus change, so the dot explains itself.
  On a **blocked** dot it goes to the actual remedy instead: relaunch, the **Microphone**
  or **Input Monitoring** privacy pane, or our own **Settings** for a missing model.
- **Right-click / ⌃-click still opens the menu**, which preserves the escape hatch for a
  culled status item.
- **A presenter owns the single write path to the pill** — new
  `App/Core/PillPresentation.swift`. `PillPresenter` gates every write to
  `PillViewModel.state`: **a visible state lands immediately**, but a **retraction waits out
  the current state's minimum** — `PillDwell` of **4 s** for an error or warning, **0.6 s**
  for *"Landing…"*, 0 for everything else. The flicker is not smoothed; it is unreachable.
- **`.error` is now its own `PillState` case** with a **headline and a subtitle**, so it can
  be sized and dwelled as a notice — **legible for four seconds**, long enough to read and
  to photograph.
- The panel stays a **non-activating `NSPanel`**, and nothing on the explain path activates
  the app.

## 3. Tests

- New `Tests/AppTests/PillPresenterTests.swift` — **13 tests**: a visible state lands with
  no delay, a retraction inside the dwell is held and then applied, `landed` followed
  immediately by `idle` produces one visible notice rather than a flicker, an error outlives
  its erasing `.idle`, and the dwell differs correctly between a notice and "Landing…".
  `PillTests` updated for `.error` as its own case.
- **Full package: `swift build` clean, 1313 tests passing.**

## What you need to do

1. Quit VoicePlus, replace it in **/Applications** with the copy from this dmg, then run
   once:

       xattr -dr com.apple.quarantine /Applications/VoicePlus.app

2. **Click the dot.** It should explain itself in place for about five seconds — and, if it
   is red, take you to the thing that will fix it. Right-click still gives you the menu.

3. **If you hit an error, you should now be able to read it — and screenshot it.** Please
   do, if you do.

## Known and remaining

- **Every visual judgement here is unverified — an agent has no window server.** Precisely
  unknown: whether the pinned click-to-explain row reads as an explanation, whether five
  seconds is the right pin, and whether the four-second error pill is long enough to read
  without being long enough to annoy. The dwell arithmetic, the routing per dot state and
  the single write path are covered by tests.
- **The privacy-pane deep links have not been followed on this machine.** The URLs are
  pinned by test; whether each one lands on the right pane on the owner's macOS version is
  not verified here.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since
  the first phase-6 release, unchanged here.
- Ad-hoc signed, **not notarized** — no Developer ID on this machine. Unchanged.
