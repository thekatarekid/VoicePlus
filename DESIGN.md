# VoicePlus — DESIGN.md

Design source of truth for **the one window, the menu, and onboarding**. Item R0.1.

Two kinds of statement appear here, and they are always labelled:

- **As-is** — a description of what the shipped code already draws, read out of the source. Nothing
  in an as-is section is a proposal. Do not "fix" it while implementing something else.
- **Spec** — what R2.4 (additive pill rows), R6.2 (onboarding) and R7 (one window, one menu) must
  build. Spec sections are the only place a decision is being made.

Authority order: `PRODUCT-SPEC.md` (why) → `VoicePlus_Improvements_V3.md` (what) →
`VoicePlus_Improvements_V3_Build.md` (tasks) → this file (how it looks and how it behaves per
state). Where this file and V3 §9 disagree, V3 §9 wins and this file is wrong and should be fixed.

**The pill is not redesigned.** See §8. §12 is the list of things that are out of bounds.

---

## 1. Typography

One family for prose and UI, one for machine text. No third face, no downloaded webfont, no icon
font (SF Symbols only).

- **SF Pro Text / SF Pro Display** — everything a person reads as language. In code this is the
  system font: `Font.body`, `.callout`, `.caption`, `.title2`, or `.system(size:weight:)`. Do not
  name "SF Pro" in code; ask for the system font and let macOS pick Text vs Display by size.
- **SF Mono** — only where character identity or column alignment carries meaning: bundle IDs,
  file paths, model IDs, hosts, byte counts, raw diagnostics, transcript text shown for inspection
  (Timeline, Meetings, Benchmark output). In code: `.font(.caption.monospaced())` /
  `.monospacedDigit()`. This matches what the app already does
  (`SettingsView.swift:132`, `SnippetsSettings.swift:102`, `LabWiring.swift:132`,
  `OnboardingView.swift:151`).

### 1.1 Roles

| Role | Face | Token | Size / weight | Where |
|---|---|---|---|---|
| Window title | SF Pro Display | `.title2.weight(.semibold)` | 17 pt semibold | Detail-pane header, one per section |
| Section heading | SF Pro Text | `.headline` | 13 pt semibold | `Section(...)` headers, card titles |
| Body | SF Pro Text | `.body` | 13 pt regular | Prose, list rows, settings labels |
| Control label | SF Pro Text | `.body` | 13 pt regular | Toggles, pickers, buttons |
| Secondary / helper | SF Pro Text | `.caption` + `.secondary` | 11 pt regular | The sentence under a control that explains it |
| Fine print | SF Pro Text | `.caption2` + `.secondary` | 10 pt regular | Counts, timestamps, "overridden" flags |
| Sidebar item | SF Pro Text | `.body` | 13 pt regular; selected row `.weight(.medium)` | Sidebar |
| Numeric readout | SF Mono | `.body.monospacedDigit()` | 13 pt regular | Latency, WER, bytes, level dB |
| Code / identifier | SF Mono | `.caption.monospaced()` | 11 pt regular | Bundle IDs, hosts, model IDs, paths |
| Transcript | SF Mono | `.callout.monospaced()` | 12 pt regular | Timeline / Meetings / Benchmark transcript bodies |
| Error headline | SF Pro Text | `.callout.weight(.semibold)` | 12 pt semibold | §7 |
| Error detail | SF Pro Text | `.caption` + `.secondary` | 11 pt regular | §7 |

Rules: never more than three type sizes visible in one pane at once; never bold a whole paragraph;
never use italics for emphasis (macOS does not); never centre a paragraph of prose; sizes are
Dynamic-Type-relative tokens, never hard-coded points, except inside the pill and the notch chin,
which are fixed-geometry surfaces (§8).

---

## 2. Colour

**Dark-first, native macOS.** Every surface is drawn with system materials and semantic colours so
that Dark Mode, Light Mode, Increase Contrast, Reduce Transparency and the user's own accent choice
all work without a second palette. There is no hand-authored hex value anywhere in the window,
settings or onboarding.

### 2.1 One accent

The accent is **the system accent colour** — `Color.accentColor` / `NSColor.controlAccentColor`.
The app ships **no `AccentColor` asset** and must not add one: the user's chosen accent is the
brand. As-is, the accent appears in exactly four places
(`PillView.swift:135`, `ConsentPanels.swift:138`, `CorrectionOverlay.swift:142`,
`RepairFanoutPanel.swift:122`).

Accent budget for the window: **one accented element per pane** — the selected sidebar row, or the
one default button, or the one live progress bar. Never accent two things a user must choose
between. Never use the accent to mean "danger", "warning" or "recording".

### 2.2 Semantic roles

| Role | Token | Means |
|---|---|---|
| Window background | `.windowBackgroundColor` | The detail pane |
| Sidebar background | `.sidebar` material (`List` + `.listStyle(.sidebar)`) | The sidebar, vibrant by default |
| Card / grouped background | `.controlBackgroundColor` | Inset groups, tables, code blocks |
| Primary text | `.primary` / `.labelColor` | Body, headings |
| Secondary text | `.secondary` / `.secondaryLabelColor` | Helper sentences, timestamps |
| Tertiary text | `.tertiaryLabelColor` | Disabled rows, placeholder |
| Separator | `.separatorColor` | Hairlines. 1 device pixel, never a 1 pt grey box |
| Accent / selection | `.accentColor` | Selection, default button, determinate progress |
| Ready / verified | `.green` (system) | Delivered-verified, mic level good, permission granted |
| Attention / unverified | `.yellow` (system) | Landed-not-confirmed, mic quality warning, still installing |
| Error / failed | `.orange` (system) | Failed delivery, model integrity failure, error notices |
| Hard-mute / destructive | `.red` (system) | Hard mute, Discard, Delete all |
| Live microphone | `.red` (system) | The mic glyph while capture is open — the one thing red also means |

Rules: colour is never the only carrier of meaning — every coloured state also carries a glyph and
a word (§6 covers Differentiate Without Colour). Red means exactly two things (mic-is-open,
destructive) and nothing else. Green never means "network" and never means "premium".

---

## 3. Spacing, radii, contrast

### 3.1 Spacing scale

`2, 4, 6, 8, 10, 12, 14, 16, 20, 24, 32` pt. Nothing off-scale. The existing pill and chin already
sit on it (`10` HStack spacing, `14` horizontal padding, `9`/`6`/`4` chin paddings, `8` edge
margin).

| Use | Value |
|---|---|
| Icon-to-label | 6 |
| Inside a control row | 8 |
| Between rows in a group | 8 |
| Between controls and their helper sentence | 4 |
| Between groups / sections | 20 |
| Detail pane padding | 20 (16 on a window at minimum width) |
| Sidebar row inset | 8 vertical, 10 horizontal |
| Between a heading and its first row | 12 |
| Toolbar / header height | 52 |

### 3.2 Corner radii

| Surface | Radius |
|---|---|
| Sheet / dialog | 12 |
| Card, inset group, code block | 8 |
| Button, text field, popup | 6 (system default; do not override) |
| Badge / capsule | full capsule |
| Pill (as-is) | 18 on a notched display, 12 otherwise, **bottom corners only** |
| Notch chin (as-is) | 10 when the row is expanded, otherwise `min(6, height/2)`, bottom corners only |

### 3.3 Contrast targets (WCAG 2.1 AA, stated numerically)

| Content | Required ratio |
|---|---|
| Text below 18 pt regular / 14 pt bold | **≥ 4.5 : 1** against its own background |
| Text at or above 18 pt regular / 14 pt bold | **≥ 3.0 : 1** |
| Glyphs, level bars, focus rings, chart strokes, toggle tracks | **≥ 3.0 : 1** |
| Text over a vibrant material | **≥ 4.5 : 1** measured against the *lightest* backdrop the material can sit on |
| Increased-contrast variant, all text | **≥ 7.0 : 1** (AAA) where the system material allows |
| Disabled text | exempt from the ratio, but must still differ from enabled text by more than colour |

Computed against today's build:

- White on the pill (`black.opacity(0.92)`) computes to **≈ 18.5 : 1** over a white backdrop and
  21 : 1 over black. Passes with room.
- White on the ready chin (`black.opacity(0.72)`) computes to **≈ 8 : 1** over a white menu bar.
  Passes.
- `MUTED`, white on `red.opacity(0.88)`, computes to **≈ 3.5 : 1** — above the 3 : 1 glyph bar, but
  **below 4.5 : 1** for a 9 pt bold label. This is recorded as-is and **is not changed here** (§12:
  no pill redesign); §6.2 specifies the increased-contrast variant that fixes it.
- Any new window text must be checked against 4.5 : 1 *before* it ships; system semantic colours on
  system backgrounds satisfy it by construction, hand-tinted text does not.

---

## 4. State vocabulary

The words on screen and the identifiers in code, from V3 §4.7. **The user-facing word is the only
word allowed in UI copy.** The code name is the only name allowed in identifiers, log lines and
test names. No third synonym gets invented in either place.

| User-facing | Meaning | Code name | Renamed from |
|---|---|---|---|
| **Hold** | Push-to-talk while the key is down | `hold` | — (unchanged) |
| **Latch** | Double-tap; listening continues across endpoints | `latched` | `handsFree` |
| **Mute** | Persistent hard mute; survives relaunch, never auto-clears | `muted`, `MuteController` | comments calling it the "mute latch" |
| **Timeline** | Ambient transcript history in the window | `AmbientTimeline` | — (new) |
| **Held** | Committed text waiting for a destination | `held` | the `FocusGuard` queue, under a new delivery rule |

Consequences that are not optional:

- `InputTimeline` **keeps its name in code** and is **never** shown to a user as "Timeline". It is
  an internal deixis structure, not history. The window's Timeline is `AmbientTimeline`.
- Never write "hands-free" in UI copy or in new code. It is **Latch**.
- Never write "paused" where the state is `muted`, and never write "muted" where the state is
  `paused`. Pause is a soft, forgettable state; Mute is a promise about the microphone.
- Held text is **held**, never "queued", "pending", "buffered" or "saved".
- Delivery outcomes read as: **Landed** (`delivered(verified: true)`), **Landed · not confirmed**
  (`delivered(verified: false)`), **Held** (`held`), **Didn't land** (`failed`).

---

## 5. Focus and keyboard navigation

### 5.1 One window

There is one window (`R7.1`). It is a `NavigationSplitView`: sidebar + detail. It is resizable,
remembers its frame and its selected section, and is **not** a modal or a panel. No standalone
Settings window, no standalone Data Panel, no standalone Lab window, no standalone enrollment
window (`R7.2`). Onboarding is the one exception: a separate, non-resizable window that exists only
until it is finished (§11).

### 5.2 Keyboard map

| Key | Effect |
|---|---|
| `⌘,` | Open the window at **Settings** |
| `⌘1` … `⌘6` | Jump to sidebar section 1–6 in the order listed in §9 |
| `⇥` / `⇧⇥` | Move focus through focusable controls in reading order: header → sidebar → detail |
| `⌃⇥` | Move focus between the two panes (sidebar ⇄ detail) without walking every control |
| `↑` / `↓` | Move the selection within the focused list (sidebar, Timeline, Meetings, Dictionary) |
| `↩` | Activate the focused row's primary action, or the pane's default button |
| `Space` | Toggle the focused checkbox/switch; preview the focused Timeline row |
| `⌘F` | Focus the search field of the section that has one (Timeline, Meetings, Dictionary) |
| `⎋` | Close a sheet; clear a search field; never closes the window while a sheet is open |
| `⌘W` | Close the window (the app keeps running; it is a menu-bar app) |
| `⌫` | Delete the selected row in Timeline / Meetings / Dictionary, with confirmation for destructive scope |

### 5.3 Focus rules

- **Full Keyboard Access must work.** Every actionable thing is reachable by `⇥` with no dead ends.
  Nothing is click-only. Nothing depends on hover to be discoverable — hover may only *reveal
  affordances that are also reachable by keyboard* (this is why the chin's hover row is a
  convenience and the click always opens the menu).
- The focus ring is the **system** ring (`.focusEffectDisabled()` is banned). Never draw a custom
  ring; never suppress it because it "looks noisy".
- On opening a section, initial focus is the detail pane's **first interactive control**, not the
  sidebar, except when the section is empty, where focus lands on the empty state's single call to
  action.
- Focus never moves on its own while the user is typing, and never moves because an async load
  finished. A late-arriving result may update content; it may not steal focus.
- **Dictation focus is sacred.** Neither the window nor the menu may take keyboard focus away from
  the user's destination app during capture. The menu is opened from a non-activating panel/status
  item; the pill panel is `nonactivatingPanel` and `ignoresMouseEvents` (as-is, §8). Any new
  affordance that could activate the app during capture is a bug.
- Sheets are used only for a genuine either/or (delete-all confirmation, model integrity failure).
  Everything else is inline in the detail pane.
- VoiceOver: every section has a `.accessibilityLabel`; every state row carries the state word in
  its label, not only a colour; the Timeline list is a table with a rotor-navigable row label of
  "time, source, first words".

---

## 6. Reduced motion and increased contrast — every state

Two system settings drive these: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` /
SwiftUI `@Environment(\.accessibilityReduceMotion)`, and
`accessibilityDisplayShouldIncreaseContrast` / `@Environment(\.colorSchemeContrast)`. Neither is
read anywhere in the app today — wiring them is part of the work that consumes this document.

**Rule for reduced motion:** no state may *require* motion to be understood. Every animation
listed below degrades to an instant change of the same end state. Nothing cross-fades, nothing
slides, nothing repeats forever. Duration 0 is always a legal rendering.

**Rule for increased contrast:** materials become opaque, hairlines become 1 pt solid separators,
every text/background pair is re-checked at **≥ 7 : 1**, glyph strokes gain weight (`.semibold` →
`.bold`), and every state that leans on colour gains a text label if it did not have one.

### 6.1 Pill states (existing; behaviour only, never look)

| State | Motion as-is | Reduced motion | Increased contrast |
|---|---|---|---|
| `hidden` → visible | Panel slides from retracted to shown, 0.14 s ease-out | No slide: order in directly at the shown frame | unchanged (nothing drawn) |
| visible → `hidden` | Slide back to retracted, then order out | Order out directly, after the same `PillDwell` minimum | unchanged |
| `idle` ("Warming up…") | `.easeOut(0.12)` content change | Instant | Text at `.primary`, no `.secondary` |
| `listening` | Waveform bars animate `.linear(0.05)` per push | Bars still update per level, no interpolation (`.animation(nil)`) | Bar fill white 1.0 instead of 0.9; bar width unchanged |
| `preview` | 0.12 s content change as text grows | Instant text replacement | unchanged (already white on near-black) |
| `landing` | 0.12 s swap to the check glyph | Instant | Check glyph `.bold` |
| `warning` | 0.12 s swap | Instant | Yellow → the highest-contrast system yellow; headline stays `.semibold` |
| `unavailable` | 0.12 s swap | Instant | as warning |
| `error` | 0.12 s swap | Instant | Orange glyph `.bold`; subtitle at `.primary` |
| `transform` | Morph preview collapse/expand over `model.beat`; ghost row fades in | **No morph**: draw the final token row immediately; ghost row appears without a transition | Accent background at full opacity; ghost buttons get a visible border |
| Dwell (`PillDwell`) | notice 4.0 s, acknowledgement 0.6 s | **Unchanged** — dwell is legibility, not motion, and reduced motion must not shorten a message | Unchanged |

### 6.2 Notch chin (presence) states (existing)

| State | Motion as-is | Reduced motion | Increased contrast |
|---|---|---|---|
| `off` | none | none | none |
| `ready` | Static green dot; `.easeOut(0.12)` on hover expand | Expand instantly | Chin opacity 0.72 → 1.0; dot 5 pt → 6 pt |
| `listening` | Level bar `.linear(0.08)` | Bar jumps to each level, no interpolation | Bar white 0.85 → 1.0; chin fully opaque |
| `processing` | Indeterminate shimmer, `.easeInOut(0.9).repeatForever(autoreverses:)` | **No repeating animation.** Draw a static bar at a fixed 50 % width — an indeterminate state must not become a perpetual motion source | Static bar white 1.0 |
| `muted` | Static red badge | unchanged | Badge label 9 pt bold → 10 pt bold, and the red darkens until white-on-red reaches 4.5 : 1 (this is the fix for the 3.5 : 1 computed in §3.3) |
| `paused` | Static badge | unchanged | Chin fully opaque; badge `.bold` |
| `blocked` | Static orange badge | unchanged | Orange darkened to reach 4.5 : 1 for the badge text |
| Hover row expand | `.easeOut(0.12)` size + corner change | Instant resize | Row background fully opaque; 1 pt separator above the row |

### 6.3 Window and onboarding states (spec)

| State | Motion | Reduced motion | Increased contrast |
|---|---|---|---|
| Sidebar selection change | Detail content replaces with no transition (already instant) | unchanged | Selected row: accent fill **plus** a leading 3 pt accent bar, so selection is not colour-only |
| Loading a section | Indeterminate `ProgressView` (spins) | Replace with a static "Loading…" label plus a determinate bar when a fraction is known | Text at `.primary`, bar track ≥ 3 : 1 |
| Determinate progress (model install, enrollment, benchmark) | Bar animates to each new value | Bar jumps to each new value | Bar track and fill differ by ≥ 3 : 1; percentage always shown as text |
| Empty state appearing | No animation | unchanged | Illustration glyph `.bold`; body at `.primary` |
| Error banner appearing | No animation; it is simply there | unchanged | 1 pt orange border + glyph + word "Didn't land"/reason |
| Held row appearing (R2.4) | Enters with the pill's existing 0.12 s content change | Instant | as pill error row |
| Row insert in Timeline / Meetings | List insert, system default | `.animation(nil)` on the list | Alternating row backgrounds off; 1 pt separators on |
| Mic level meter (onboarding) | Continuous level, `.linear(0.08)` | Level updates without interpolation; **the numeric dB readout is always present**, so the meter is never the only signal | Meter fill ≥ 3 : 1 against its track |
| Onboarding step change | No slide, no cross-fade — content replaces | unchanged | Step indicator shows "Step 3 of 5" as text, not only as dots |
| Practice-field landing (onboarding) | Text appears in the field; landed row per §8.3 | Instant | as pill landed row |

If a state is added later and does not appear in one of these three tables, it is not finished.

---

## 7. Errors: sizing and copy voice

### 7.1 Copy voice

- **Name what happened, then name the action.** `Problem — Action`, em-dash separated, action in
  the imperative and matching a control the user can actually reach.
- Plain English. No jargon, no error codes, no exception text, no bundle IDs, no "unexpected".
- Never blame the user; never blame "the system". Say what the app observed.
- One sentence for the headline, one for the detail. No paragraphs.
- No exclamation marks. No "Oops". No apologies. No "please".
- Never claim success that was not verified — this is why **Landed · not confirmed** exists.
- Never claim zero network bytes (V3 §9.6); say what left the Mac.
- Sentence case. Serial commas. No trailing period on a headline; a period on the detail sentence.

The three canonical strings (V3 §6, required verbatim by R2.4):

```
Destination changed — Copy text
Microphone disconnected — Choose microphone
No speech detected — Try again
```

Each is a headline whose action word matches a real control: "Copy text" is the held row's Copy
action, "Choose microphone" opens Voice › Microphone, "Try again" is the dictation key.

### 7.2 Error sizing

| Surface | Sizing rule |
|---|---|
| Pill notice (as-is) | Headline `.callout.weight(.semibold)`, **max 2 lines**, tail-truncated; subtitle `.caption`, **max 1 line**, tail-truncated. The panel is widened to the exact strings by `NotchGeometry.size(for:on:measure:)` up to `absoluteMaximumSize` (560 × 96). **Never** `fixedSize(vertical:)` inside pill content — that is the 1.7.9 black-slab bug (`PillView.swift`, `PillPanelController.swift`). Every fixed sentence a state can draw must be listed in `PillState.messageLines` so the pill can never be narrower than its own text. |
| Window inline banner | Full detail-pane width, glyph + headline (`.callout.semibold`) + detail (`.caption`, `.secondary`) + up to two buttons. Grows vertically; never scrolls internally; never truncates. |
| Row-level error | One line, `.caption`, orange glyph, inline in the row; the full text is the row's accessibility label and its tooltip. |
| Onboarding step error | Inline under the control that failed, `.caption`, with the action as a button beside it. Never a sheet, never a dead end (§11). |
| Sheet | Only for a destructive confirmation or an integrity failure that blocks use. Title ≤ 6 words, body ≤ 2 sentences, two buttons max. |

Raw errors (`Error.localizedDescription`, OSStatus, AX error codes) go to `Log` and to Voice ›
Benchmark diagnostics. They never reach a user-facing string.

---

## 8. The existing pill and notch chin — documented as-is

**This section proposes nothing.** It records what the code draws so that R7 and R2.4 can be built
around it without touching it. Sources: `App/UI/PillView.swift`,
`App/UI/PillPanelController.swift`, `App/UI/PresenceIndicatorView.swift`,
`App/UI/PresenceIndicatorController.swift`, `App/Core/PillState.swift`,
`App/Core/PillPresentation.swift`, `App/Core/NotchGeometry.swift`,
`App/Core/NotchPresenceGeometry.swift`, `App/Ambient/PresenceState.swift`,
`App/Core/PresenceClick.swift`.

### 8.1 The pill — container

- A borderless, non-activating `NSPanel` at `.statusBar + 1`, transparent background, shadow on,
  `ignoresMouseEvents = true`, `canJoinAllSpaces + stationary + fullScreenAuxiliary + ignoresCycle`,
  `animationBehavior = .none`.
- `NSHostingView.sizingOptions = []` deliberately: the default `.standardBounds` publishes SwiftUI's
  minimum size as the window's `contentMinSize`, which is what produced the 1.7.9 black slab
  (measured 1187 pt for a short error, 4727 pt for a long one). **The pill's frame is placement
  math, never content.**
- Geometry: `defaultSize` 320 × 44; `expandedSize` 420 × 64 (used by `preview`, `warning`,
  `unavailable`, `error`, `transform`); `absoluteMaximumSize` 560 × 96; per-display ceiling is
  `min(560, max(420, screenWidth × 0.6))` and the room under the top band.
- Placement: the pill's **top edge is the bottom of the display's forbidden top band**
  (`ScreenMetrics.topBand = max(topInset, menuBarHeight)`), so it is never drawn under the camera
  housing. It slides between a `retracted` and a `shown` frame. Corner radius 18 with a notch, 12
  without, **bottom corners only** (`UnevenRoundedRectangle`).
- Body: `HStack(spacing: 10)` of icon, content, spacer, optional script badge; `.padding(.horizontal, 14)`;
  background `black.opacity(0.92)` (or `accentColor.opacity(0.92)` for `transform`); `foregroundStyle(.white)`;
  `.animation(.easeOut(duration: 0.12), value: state)`. Panel frame animations run 0.14 s ease-out
  and are interruptible.
- Accessibility identifier: `pill.<caseName>`.
- Re-placed on `didChangeScreenParametersNotification` while visible, without replaying the slide.

### 8.2 The pill — rows, exactly as they are

| State | Icon | Content |
|---|---|---|
| `hidden` | — | nothing; panel ordered out |
| `idle` | `mic`, `.secondary` | "Warming up…", `.callout`, `.secondary` |
| `listening(level:)` | `mic.fill` red — or `mic.badge.plus` red when latched | `WaveformView`: 24 capsule bars, white 0.9, bar width `w × 0.65`, gap `w × 0.35`, min height 3, frame height 24, `.linear(0.05)`; levels smoothed at 0.35 |
| `preview(text:)` | `mic.fill` red / `mic.badge.plus` red | the text, `.callout`, **2 lines max, head-truncated** (newest words win). Deliberately absent from `messageLines`: sizing to live text would make the pill twitch per syllable |
| `landing` | `checkmark.circle.fill` green | "Landing…", `.callout` |
| `warning(MicQuality)` | `exclamationmark.triangle.fill` yellow | `Notice` — headline "Mic level is very low" / "Mic is clipping" / "Noisy mic — N dB SNR"; subtitle "Check your input device before you speak" |
| `unavailable(reason:)` | `mic.slash.fill` yellow | `Notice` — headline is the reason; subtitle "Dictation is off until a speech model is installed" |
| `error(message:)` | `exclamationmark.circle.fill` orange | `Notice` — headline is the message; subtitle "Nothing was typed — press the key again to try that turn" |
| `transform(TransformPillInfo)` | `wand.and.stars`, or a small `ProgressView` while `.editing` | accent-tinted pill: headline ("editing N words" / "changed N words" / "no change" / "say more… (Ns)"), optional `MorphPreview`, and the ghost row `↩ undo` / `try again` / the quoted instruction |

- `Notice` is bounded on purpose: 2 headline lines + 1 subtitle line, so no message length can grow
  the pill past the reserved size.
- Script badge (optional, right-aligned): `.caption2.bold()`, capsule `white.opacity(0.18)`,
  padding 5 × 2, identifier `pill.script`.
- **Click behaviour:** the pill is not clickable. `ignoresMouseEvents = true` in every state except
  `transform` with a visible ghost row, which is the one clickable thing on the pill
  (`pill.ghost.undo`, `pill.ghost.tryAgain`).
- **Dwell (`PillDwell`)**: only a *retraction* is ever delayed. Any visible state replaces whatever
  is showing immediately. `.hidden` waits out the current state's minimum: 0 for
  `hidden/idle/listening/preview/transform`, **0.6 s** for `landing`, **4.0 s** for
  `error/warning/unavailable`. This exists because `RealEngine.stop()` emits `.landed` then `.idle`
  in the same run-loop pass.
- **Reducer:** engine → pill is pure (`PillStateReducer`). A mic-quality warning is *sticky for the
  utterance*, so it renders before speech starts and is not blown away by the first `listening` tick.

### 8.3 The notch chin (presence indicator), exactly as it is

Same one rule as the pill: **top edge = bottom of the top band**, asserted by
`NotchPresenceTests.sharesTheTopBoundaryWithThePill`. One thing under the notch at a time — the
chin hides while the pill is visible.

| State | Size | Background | Body |
|---|---|---|---|
| `off` | zero | clear | nothing ordered in |
| `ready` | 54 × 10 | `black.opacity(0.72)` (0.92 hovered) | one static 5 pt green dot at 0.95 — deliberately not pulsing |
| `listening(level:)` | 120 × 10 | `black.opacity(0.9)` | white 0.85 capsule level bar, min width 4, `.linear(0.08)` |
| `processing` | 120 × 10 | `black.opacity(0.9)` | indeterminate bar, `.easeInOut(0.9).repeatForever(autoreverses:)`, phase 0.25 → 0.85 |
| `muted` | 84 × 16 | `red.opacity(0.88)` | glyph + `MUTED`, 9 pt bold. Never shrunk, never suppressed — including in full screen |
| `paused` | 132 × 16 | `black.opacity(0.75)` | glyph + `Paused` |
| `blocked(reason)` | 132 × 16 | `orange.opacity(0.9)` | glyph + short badge; reasons: `microphoneDenied`, `hotkeyUnavailable`, `relaunchNeeded`, `modelDownloading`, `modelMissing` |
| hovered / introducing (any visible state) | ≥ 190 × 24, fitted to the text by `PresenceRow.fit`, capped at screen width − 16 | as the state | glyph (10 pt semibold) + one row of 11 pt medium text, padding 9. **No tail truncation** — `PresenceRow` shortens at a word boundary instead, because a fixed 190 pt is what produced "— hold R…" |

- Row sentences: "VoicePlus · Ready", "VoicePlus · Listening", "VoicePlus · Working…",
  "VoicePlus · Muted — the mic stays closed", "VoicePlus · Paused", plus the block reason's own
  detail. The hotkey hint ("hold Right ⌥") is appended by the controller when it fits.
- Precedence: `muted > paused > blocked > listening > processing > ready`. The indicator must never
  show something less alarming than reality.
- `isQuiet` states (`off`, `ready`, `paused`, `blocked`) may be hidden in a full-screen Space.
  `listening`, `processing` and `muted` are **never** hidden there.
- Corner radius 10 when expanded, else `min(6, height/2)`, bottom corners only. Edge margin 8,
  hover slop 8; the hover rect is the union of the resting chin, the expanded row and the camera
  housing itself — pointing at the notch reveals it.
- Hover polling: 0.2 s timer. `.easeOut(0.12)` on hover change.
- **Click: `PresenceClickRouter` returns `.menu` for every state and every button.** Left, right and
  control-click on the chin *and* on the status-item glyph open the same menu (V3 §9.3).
- Accessibility: identifier `presence.<caseName>`, label = the state's `detail` sentence.

### 8.4 What R2.4 may add — and only this

All three additions are expressed in the **existing** visual language: the same `Notice`/row layout,
the same fonts, the same near-black background, the same glyph vocabulary, the same
`expandedSize`/`messageLines` sizing path, the same `PillDwell` table. **No new mark, no sound, no
new animation, no new colour** (V3 §9.1).

1. **Final text on land.** On a delivered outcome, the pill replaces the preview with the
   *committed* text for ≈1.2 s, then returns to ready/hidden. Same row as `preview` — `.callout`,
   2 lines, head-truncated — with the `landing` state's green `checkmark.circle.fill`. Dwell for
   this state is the existing `acknowledgement`-class minimum, raised to the 1.2 s the task
   specifies; it is a legibility minimum, so reduced motion does not shorten it.
2. **Unverified variant of landed.** Same row, headline **"Landed · not confirmed"**, glyph
   `checkmark.circle` (unfilled) in yellow — the existing attention colour, not a new one — and the
   existing subtitle slot naming the recovery action. It must be visibly different from verified
   *without* relying on the colour alone, hence the unfilled glyph and the words.
3. **Held row.** `Notice` layout: headline names the destination
   ("Held for Notes" / "Destination changed — Copy text"), subtitle is the first words of the held
   text, and three actions in the ghost row's existing style and position:
   **Insert here · Copy · Discard**. This is the second state in which the pill accepts clicks, so
   `panel.ignoresMouseEvents` becomes `false` for it exactly as it already does for `transform`'s
   ghost row. Identifiers: `pill.held.insertHere`, `pill.held.copy`, `pill.held.discard`. Every
   held-row string must be added to `PillState.messageLines` so the panel is sized to it.
   The same three actions appear in the menu (§10), and a quit with held text present warns first.

Anything beyond these three is out of scope for R2.4 and for this document.

---

## 9. The one window (spec for R7)

`NavigationSplitView`. Sidebar width 200–260 pt, detail minimum 560 pt, window minimum 820 × 560.
Six sections, in this order, `⌘1`–`⌘6`:

1. Today / Timeline
2. Meetings
3. Dictionary / Apps
4. Voice
5. Privacy
6. Settings

Every section follows the same shape: a title, an optional single-line subtitle, content, and
exactly one of four renderings at a time — **content**, **empty**, **loading**, **error**. No
section may show a spinner and content simultaneously; a section that has partial data shows the
data and puts the failure in a row-level or banner error.

### 9.1 Today / Timeline

- **Purpose.** What the app is ready to do right now, what still needs a hand, and what was said
  recently. Readiness and pending recovery come first (V3 §9.4).
- **Content.** Top: a readiness strip — dictation key, microphone name and quality, model state,
  mute state — each a single row with a glyph, a word and, where it is not ready, one action.
  Below it: **Needs you** — every `held` item, each with destination, first words, and
  Insert here / Copy / Discard. Below that: the **Timeline** (`AmbientTimeline`), newest first,
  grouped by day, with search (`⌘F`), source filters, per-row delete, and Delete all. Rows show
  time, source, and the transcript in SF Mono.
- **Empty.** Two distinct empties. Nothing dictated yet: "Nothing dictated yet" + the dictation key
  name + "Hold it and say something." Ambient off: "Timeline is off" + "Turn on ambient capture in
  Privacy" — never an empty list with no explanation.
- **Loading.** Readiness strip renders immediately from cached state (it is never blank). The
  Timeline list shows a static "Loading…" row; with reduced motion, no spinner.
- **Error.** Timeline store unreadable: inline banner "Timeline can't be read — Open Privacy",
  readiness strip still shown. A held item that fails to re-insert keeps its row and gains a
  one-line row error.

### 9.2 Meetings

- **Purpose.** Meeting transcripts, and the switch that decides whether they are captured.
- **Content.** List of meetings (title, start, duration, source) → detail with the transcript in SF
  Mono, per-speaker where enrollment identified one, plus Copy, Export, Delete. Capture switch and
  the Calendar-permission state live at the top.
- **Empty.** Capture on, nothing recorded: "No meetings captured yet." Capture off: "Meeting
  capture is off" + a switch. Calendar denied: "Calendar access is off — Open System Settings".
- **Loading.** List placeholder rows (no shimmer); transcript pane shows "Loading transcript…".
- **Error.** Per-meeting: "This transcript can't be read" in the row with a Delete action. Whole
  store: inline banner, list hidden.

### 9.3 Dictionary / Apps

- **Purpose.** The words this Mac gets wrong, and the per-app behaviour (personas, snippets,
  never-inject list).
- **Content.** Two panes' worth in one section. **Dictionary**: term, spoken forms, add / edit /
  delete, Contacts import. **Apps**: one row per app — bundle ID in SF Mono, its persona, its
  snippets, and its injection policy including the **never-inject** switch (R2.3). Never-inject is
  a red-tinted switch with a one-line consequence sentence ("Dictation is held here, never typed").
- **Empty.** Dictionary: "No terms yet" + "Add a word VoicePlus keeps getting wrong" + Import from
  Contacts. Apps: "No app-specific settings" + "Every app uses your defaults."
- **Loading.** Static "Loading…" row; both lists are local, so this state should be a single frame.
- **Error.** Contacts denied: "Contacts access was denied — Open System Settings" (the existing
  string is kept). Store write failure: banner "Changes weren't saved — Try again".

### 9.4 Voice

- **Purpose.** The microphone, the voice enrolled on this Mac, and the measurements. Folds in the
  standalone enrollment window and the whole Lab UI (R7.2).
- **Content.** Three groups.
  **Microphone** — device picker (Automatic + devices), a live level meter with a numeric dB
  readout, quality verdict in the same words the pill uses (§8.2).
  **Enrollment** — enrolled / not enrolled, re-enroll, delete; enrollment runs inline in this pane,
  never in its own window. Enrollment is optional and says so.
  **Benchmark** — model stack, latency (p50/p95), WER against `Fixtures/`, thermal state, and the
  run button. Numbers in `.monospacedDigit()`. This is where model names, latency and thermal
  diagnostics live — **not** the pill (V3 §9.1).
- **Empty.** No enrollment: "No voice enrolled" + "Enrollment is optional. It helps ambient capture
  tell you apart." No benchmark run: "No measurements yet" + Run benchmark.
- **Loading.** Microphone list enumerating: picker disabled with "Looking for microphones…".
  Benchmark running: determinate progress with a percentage as text, a Cancel button, and partial
  results as they land.
- **Error.** Mic permission denied: "Microphone access is off — Open System Settings" with the meter
  greyed. Device vanished mid-session: "Microphone disconnected — Choose microphone" (§7.1, verbatim).
  Benchmark failure: inline banner naming the stage, with the raw detail behind a Copy diagnostics
  button, never in the sentence.

### 9.5 Privacy

- **Purpose.** State what is captured, what is saved, and what is transmitted — and let the user
  turn each off and delete what exists. Folds in the Data Panel (R7.2).
- **Content.** Three groups.
  **Captured** — ambient capture switch (default off), enrolled-speaker-only note, retention
  (7-day default), audio-retention as a separate switch.
  **Saved** — where transcripts live, how much, Delete all with a confirmation sheet that names
  what is deleted.
  **Transmitted** — the egress log: when, stage, provider, host, bytes out, bytes in, purpose, in a
  `Table` with SF Mono host and byte columns, plus today's total. Copy states what left the Mac.
  **It never claims literal zero network bytes** (V3 §9.6): the empty case reads "Nothing has left
  this Mac in the last 30 days", scoped and dated, never "zero bytes, ever".
- **Empty.** Egress log empty: the scoped sentence above. Nothing saved: "Nothing is saved" + what
  would be if history were on.
- **Loading.** Table shows "Loading…"; the switches render immediately from settings.
- **Error.** Log unreadable: banner "The egress log can't be read — Copy diagnostics", switches
  still usable. Delete-all partial failure: banner naming what remains, with Try again.

### 9.6 Settings

- **Purpose.** Everything that is a preference and not a state. Replaces the nine-tab `TabView`
  (`SettingsTab.general/models/personas/dictionary/snippets/flags/connectors/sync/data`).
  **Every setting that exists today stays reachable** (R7.2); the tabs that had a better home move
  there — Data → Privacy, Dictionary/Snippets/Personas → Dictionary / Apps — and the rest become
  groups in this section.
- **Content.** Groups, in order: **Keys** (dictation key, act key, and the honest note about Input
  Monitoring requiring a relaunch); **Behaviour** (hold vs latch, mute, launch at login);
  **Presence** (chin on/off, hide-in-full-screen, with the existing sentence that the quiet states
  hide and listening/working/muted never do); **Models** (per-stage routing; the single stack is not
  a picker — see R6.1); **Providers / Services**; **Sync**; **Feature flags** (with the "risky bets
  ship behind flags the Lab measures" framing and an "overridden" marker); **Updates**.
- **Empty.** No providers connected: "Nothing connected" + what that means (transcription is local
  either way). No flags overridden: the list with none marked, not an empty pane.
- **Loading.** Settings are local: render immediately. Any control awaiting a system answer
  (permission, login item) shows itself disabled with a one-line reason, never a spinner.
- **Error.** A setting that could not be written keeps the user's value on screen with a row error
  "Not saved — Try again". A permission the app cannot obtain shows the honest path to System
  Settings and never pretends a relaunch is unnecessary when it is.

---

## 10. The menu (spec for R7.3, per V3 §9.2–9.3)

One menu. Left-click, right-click and control-click, on **either** the status-item glyph **or** the
idle notch chin, open the same menu — `PresenceClickRouter` already returns `.menu` unconditionally.
Opening it must not take focus from the destination app.

Order and states:

| Item | States |
|---|---|
| Status line | Ready / Listening / Working… / Muted / Paused / one blocked reason — the same words as the chin's `detail` |
| Microphone line | Device name + verdict (`✓` good, warning, or "off") |
| — | separator |
| **Dictate** | "Start dictation" ⌘D when idle; **"Stop"** while capture is open (explicit, per V3 §9.3) |
| **Latch** | Off / On; disabled while muted |
| **Mute** | "Mute microphone (hard)" ⌘M / "Unmute microphone"; the one item that is red-tinted; never auto-unmutes |
| — | separator |
| **Copy last text** | Enabled only when there is a last committed segment |
| **Recover text** | A submenu of `held` items, each with **Insert here / Copy / Discard**; hidden entirely when nothing is held; shows a count when there is ("Recover text (2)") |
| **Start meeting** | "Start meeting" / "Stop meeting"; when Calendar access is missing, the title says so ("Start meeting (asks for Calendar access)") |
| — | separator |
| **Open VoicePlus** | Opens the one window at Today |
| **Settings…** | ⌘, — opens the one window at Settings |
| **Quit VoicePlus** | ⌘Q — **warns first when held text exists**, naming how many items would be lost |

Rules: no item is ever removed to hide a problem — an unavailable action stays visible and disabled
with the reason in its title. Nothing in the menu opens a standalone window; everything lands in the
one window. Diagnostics are not in the menu; they are in Voice › Benchmark. The menu carries no
model name, latency or thermal readout.

**Removed from today's menu** (all reachable in the window): Open the Lab… → Voice › Benchmark;
Data Panel… → Privacy; Feature flags → Settings › Feature flags; Dictation key / Act key submenus →
Settings › Keys; Enroll voice… → Voice; Show indicator under the notch, Launch at login,
Check for updates…, Check permissions… → Settings. Keeping them here as well would make two sources
of truth.

---

## 11. Onboarding (spec for R6.2, per V3 §9.5)

Five steps, in this order, and nothing else:

**Welcome → Microphone → Accessibility → Try the key → Done**

No model picker, no provider setup, no mandatory enrollment, no ambient gate. Target: under two
minutes on a clean account, ending in a dictation that actually landed.

Shape: one non-resizable window, one step at a time, "Step N of 5" as **text** (not only dots), a
single default button bottom-right, Back where going back is meaningful. `↩` activates the default
button on every step. `⎋` never closes onboarding — it is dismissed only by Done or by an explicit
"Set this up later".

**Dead-end rule, applied on every step:** a step may never present a state whose only outgoing edge
requires something the user cannot do from that screen. Every blocked state carries (a) the exact
system path, (b) a button that opens it, (c) a way to continue anyway, and (d) an honest sentence
about what will not work until it is granted. A denied permission must never trap the user, and must
never be re-requested in a loop — after the first denial the copy switches from "Allow" to "Open
System Settings", which is what macOS actually requires.

Today's flow is `welcome, permissions, micCheck, modelChoice, firstDictation, done`
(`OnboardingStateMachine.Step`). `modelChoice` is removed by R6.1; `permissions` splits into
Microphone and Accessibility so each denial has its own honest screen.

### 11.1 Welcome

- **Purpose.** Say what the app does in one sentence and start.
- **Default.** Title, one sentence ("Hold a key, say something, and it lands where you're typing."),
  the dictation-key name it will use, and **Get started**.
- **Permission-denied.** n/a (nothing requested yet).
- **Model still installing.** A single quiet line: "Setting up the speech model — you can keep
  going." Never a blocking progress screen.
- **Success.** → Microphone.
- **Dead-end avoidance.** No prerequisites, so no dead end. There is no "Skip everything" here,
  because the next two steps are what make the app work.

### 11.2 Microphone (real level meter)

- **Purpose.** Get microphone permission and prove the mic actually hears the user.
- **Default.** Device picker (Automatic + devices), a **live level meter driven by real captured
  audio** with a numeric dB readout beside it, and the same verdict words the pill uses. The step's
  own states, which exist in the code today (`waiting`, `noAudio`, `tooQuiet`, `good`, `clipping`,
  `unavailable(reason)`, `permissionRequired`), map to: "Say something", "No audio from this
  microphone", "Mic level is very low", "Sounds good", "Mic is clipping", the honest reason, and the
  permission ask.
- **Permission-denied.** Meter greyed, headline "Microphone access is off", detail naming
  System Settings › Privacy & Security › Microphone, buttons **Open System Settings** and
  **Continue anyway**, plus "Dictation can't hear anything until this is on."
- **Model still installing.** The meter works regardless (it is capture, not recognition). Footer
  line: "Speech model still installing — N%."
- **Success.** `good` for a sustained moment enables **Continue**. Continue is also always enabled
  after a denial, so the step is never a wall.
- **Dead-end avoidance.** Device disconnected mid-step falls back to Automatic and says
  "Microphone disconnected — Choose microphone" (§7.1) rather than freezing on a dead meter.

### 11.3 Accessibility

- **Purpose.** Get the permission that lets text land in other apps, and be honest about the
  relaunch macOS requires.
- **Default.** What it is for in one sentence ("This is how words get typed into other apps"), the
  current state with a glyph, **Open System Settings**, and **Continue**. The sub-states already in
  the code (`explain`, `requesting`, `needsSystemSettings(attempts)`) keep their meaning; after the
  first attempt the copy stops saying "Allow" and starts saying "Open System Settings", and after
  repeated attempts it adds the exact toggle name rather than repeating itself.
- **Permission-denied.** "Accessibility access is off" + the path + Open System Settings +
  **Continue anyway** + "Text will be held for you to paste until this is on." That sentence is
  true — held text is the real fallback (R2.3) — so this is not a threat, it is the plan.
- **Relaunch needed.** When the granted permission needs a relaunch to take effect, say exactly
  that and offer **Relaunch VoicePlus**. Never claim it is active when it is not.
- **Model still installing.** Footer line only.
- **Success.** Granted → glyph and word change, Continue becomes the default button.
- **Dead-end avoidance.** Continue is enabled in every state, including denied. No loop of repeated
  system prompts.

### 11.4 Try the key

- **Purpose.** Choose the dictation key and land one real dictation, through the real commit path.
- **Default.** Key picker (the same list as Settings › Keys, with each option's honest permission
  note), a **practice text field** with focus, and the instruction "Hold <key> and say something."
  The landing uses the **R2 commit path** — the same ordered commit queue, destination check,
  readback rule and `DeliveryOutcome` as the rest of the app. Nothing is simulated.
- **Model still installing.** The step says so plainly and does not pretend, and — this is the part
  amended in R7 (gap **G7**) — it *still lets the user try*. What decides the practice field is not
  "is the stack installed" but "can anything on this Mac transcribe right now", which is
  `RecognizerReadiness` and the pure decision in `GuidedDictationGate.decide`:
  - `ready(name)` — the field is live; the line reads "Using <name>."
  - `fallback(name, awaiting)` — the field is **live**, and the line names both halves: "Using
    <name> for now — <awaiting> is still downloading (N%)." A finished-but-failed download reads
    "Using <name>. The download didn't finish (<why>) — retry it from Settings › Models."
  - `unavailable(reason)` — the field is **disabled**, with the reason, because nothing could
    transcribe what was said into it.
  There is no fake success and no indefinite spinner, and a 900 MB download is never a wall in front
  of the step: disabling the field while a stand-in recogniser is sitting right there would be the
  soft dead end the rule at the top of §11 forbids, and the honest banner is what keeps "Landed"
  truthful. The key picker is live throughout.
- **Permission-denied (carried from 11.2 / 11.3).** If microphone is denied, the practice field is
  disabled with "Microphone access is off — Open System Settings". If Accessibility is denied, the
  practice attempt still runs and its result is a **held** row inside the step, with Copy — proving
  the fallback rather than hiding it.
- **Outcomes**, which mirror the code's existing `landed(app)` / `heard(recognizer)` / `noSpeech` /
  `failed`:
  - **Landed** — the words appear in the practice field, and the step shows the landed row in the
    pill's language (§8.4).
  - **Landed · not confirmed** — the unverified variant, with Copy offered.
  - **Held** — "Held for the practice field" with Insert here / Copy / Discard.
  - **No speech detected — Try again** (§7.1, verbatim).
  - **Didn't land** — the reason plus one action; never a raw error.
- **Success.** One landed (verified or unverified) enables **Finish** as the default button. A user
  who cannot land can still Finish, with a one-line note in Done about what to fix.
- **Dead-end avoidance.** Every key option shows its permission cost before it is chosen; a chosen
  key that cannot be armed says so and offers another; the step is completable in every state.

### 11.5 Done

- **Purpose.** Say what is ready, what is not, and where to go next.
- **Default.** "You're set." + the key + "Hold it anywhere and talk." Two secondary links: Open
  VoicePlus (the window, at Today) and Settings.
- **Anything still missing.** A short list of what is not ready — permission off, model still
  installing, no landing achieved — each with the one action that fixes it, and each phrased as a
  consequence, not a scolding.
- **Model still installing.** "The speech model is still installing (N%). Dictation starts working
  when it finishes."
- **Success.** **Close** dismisses the window. Onboarding never reappears unless the user asks for
  it from Settings.
- **Dead-end avoidance.** Close is always enabled.

---

## 12. Constraints

Non-negotiable for anything built from this document.

1. **No web views.** No `WKWebView`, no `SFSafariViewController`, no HTML, no CSS, no JavaScript, no
   bundled web assets, no Electron, no React Native, anywhere in the app. Every surface is AppKit or
   SwiftUI. This includes onboarding, release notes, privacy copy and help.
2. **No pill redesign.** §8.1–8.3 are a record, not a starting point. Do not change the pill's or
   the chin's geometry, colours, fonts, glyphs, animations, dwell table or click behaviour. R2.4 adds
   the three rows in §8.4 and nothing else.
3. **No new mark, sound or animation** (V3 §9.1). No app icon variants, no new glyph vocabulary
   outside SF Symbols already in use, no audio feedback of any kind, no new motion work. Existing
   animations keep their existing durations.
4. **No third font, no hex colours, no custom controls** where a system control exists. No custom
   focus ring, no `.focusEffectDisabled()`.
5. **No standalone windows** after R7.2: one window, one menu, plus onboarding until it is finished.
6. **No diagnostics in the pill or the menu.** Model names, latency, thermal state and raw errors
   live in Voice › Benchmark.
7. **No dishonest copy.** Never claim literal zero network bytes; never say "Landed" for an
   unverified delivery; never say a permission is active before it is; never label a model available
   until it works.
8. **No telemetry, no plaintext secrets**, and no design element that requires either.
9. **Colour is never the only signal** — every state carries a glyph and a word, in all three
   renderings (default, reduced motion, increased contrast).
10. **Focus is never stolen** from the user's destination app by any surface described here.
