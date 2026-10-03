# VoicePlus — DESIGN.md (v3 · Spool)

Design source of truth for **the pill and its presence, Spool, the one window, the menu, and
onboarding**. Item R0.1, rewritten for V4 Wave 1 by G0.3 (release 1.11.0).

v1 of this file documented the 1.10.0 pill "as-is" and forbade redesigning it. That is over: the
owner has verified a complete redesign — **Spool** — in `design/design_v1.md` and its prototype
`design/design_v1.html`. This file restates that design in the terms the Swift code uses, records the
few decisions the owner made on top of it, and keeps the v1 rules that still hold (§5 focus, §7.1 copy
voice, and most of §12). Section numbers are unchanged from v1 so existing code comments still point at
the right place.

---

## 0. Authority, sources and owner decisions

**2026-09-20 V3 update:** `design/design_v3.html` and `design/design_v3.md` supersede the V1 visual and interaction rules quoted below. Current implementation uses a fixed 560 × 160 pt active notch, 80% Spool, an attached black cap without moving content, rounded idle corners, a two-line scroll-only transcript, and footer boxes bottom-aligned 12 pt above the edge. Context chips share the header. Inline alternatives are annotations, never inserted words; Edit draft edits inside the notch. Completed corrections learn quietly. The earlier V1 narrative below remains implementation history wherever V3 replaces it.

**Order of authority for anything visible:** `design/design_v3.html` → `design/design_v3.md` → `VoicePlus_ImplementationBuild_V4_Wave1+Design.md` → this file → `VoicePlus_Improvements_V4.md`.

- Where this file disagrees with the prototype or `design_v1.md`, this file is wrong and gets fixed.
- Where the prototype *simulates* something that `design_v1.md` specifies for the real product (live
  audio driving the tape, real insertion, real permissions), the markdown's real-product rule applies.
  That is the design, not a deviation.
- For *why* the product exists and behaves as it does: `PRODUCT-SPEC.md`, then
  `VoicePlus_Improvements_V4.md`. `VoicePlus_Improvements_V3.md` §1 rules still apply.

**Sources that are data, not prose.** Copy and art are never retyped by hand. `node
Scripts/spool_golden.mjs` reads `design/design_v3.html` and writes:

| Fixture | Holds | Checked by |
|---|---|---|
| `Fixtures/spool/spool_spec.json` | Spool material colours, state → pose map, reel-angle rules, scene geometry, menu-bar glyph, 59 error → pose mappings | S1, S6, `DesignTokenTests` |
| `Fixtures/spool/spool_golden.json` | Golden SVG frames of every pose and the tape flight | S1, S4 |
| `Fixtures/design/design_copy.json` | Pill copy for 26 states, 12 screen titles/subtitles, 14 empty states, per-screen error mapping, the 26-row state inventory, the 59-entry recovery catalogue | S2, S7, S9, `DesignTokenTests` |

Re-run the script whenever `design_v3.html` changes. Every colour, type size, spacing step and radius
in the app comes from `App/Core/DesignTokens.swift` (`enum Tokens`), which `DesignTokenTests` compares
with the prototype's CSS, `design_v1.md` §3/§3.1 and `spool_spec.json` on every run.

### 0.1 Owner decisions (the only permitted differences from the verified design)

| Topic | Verified design | Owner decision | How it is applied |
|---|---|---|---|
| Default key | Right Control | **fn / 🌐** | Every string containing "Right Control" in the copy fixture is rendered with the configured key's label instead; nothing else in the string changes. "Hold or Double Tap Right Control to dictate" → "Hold or Double Tap fn / 🌐 to dictate". |
| Voice enrollment | optional, in the Voice section | **also a step in onboarding**, skippable | Inserted after "Try dictation", before "Ready" (§11); uses the Voice section's enrollment view and copy. |
| Deixis box | not in the design | **box + screenshot, thumbnail in the pill** | Drawn in the pill's text lane under the transcript and above the tape lane, never in the character bay, never over Spool; uses the design's chip (tag) styling (§8.5). |
| Menu: Recent dictations (H32) | "Copy last text" is not a menu item | **last 5 dictations at the top of the menu, click = Copy** | §10: a "Recent" section header and up to 5 rows (any destination: inserted, saved to Notes, cancelled to Notes; a hands-free session is one row; edit commands read "Edit · <command>"); each row is the destination app's icon, one tail-truncated line and a relative time ("2 m"); the full words are the tooltip. Click copies through the verified copy and the row reads "Copied" with a check only when the pasteboard read the words back. Password-field turns are never listed (filtered on the outcome reason). |
| V4 settings (latch pause, spacing, unknown-caret style, draw-without-key, recordings retention, screen text) | not in the design | required by V4 Wave 1 | Added as ordinary rows in the design's existing subpages with the design's row, toggle and select components; no new subpage (§9.6). |

Everything else follows the design exactly. In particular: hold lands once on release; Escape cancels
during a turn; a settled readback that ran and does not show the text is **⚠ Couldn’t confirm
insertion** (sticky), while a field whose readback cannot run at all lands as a neutral **Inserted in
<app>** (no ✓) that clears after the normal landed dwell (V5 Q4 / D06 — revives V4.20); error and held notices stay until the user acts (no timed dismissal); the latch pill shows
the design's timer only (the V4.38 countdown ring is withdrawn); the Settings subnav has exactly the
design's seven subpages.

---

## 1. Typography

The product uses the **system sans-serif** (SF Pro) for everything a person reads as language —
including transcripts, in the pill and in the window (design §4 "Use natural-language text, not
monospace"). **SF Mono** appears only where the prototype uses `--mono`: key caps, tags, and machine
identifiers (bundle IDs, hosts, model IDs, paths, byte counts, raw diagnostics). Serif type appears
only in the design document's editorial introduction, never in the product. No third face, no
downloaded font, no icon font.

### 1.1 Roles (`Tokens.Typography`)

| Role | Token | Size / line height | Weight | Where |
|---|---|---|---|---|
| Page title | `title` | 24 / 30 pt | semibold | One per window page |
| Section title | `section` | 17 / 24 pt | semibold | Group and section headings |
| Body | `body` | 13 / 20 pt | regular | Prose, rows, controls, sidebar |
| Compact metadata | `meta` | 11 / 16 pt | regular | Helper sentences, timestamps, counts |
| Pill transcript | `pillTranscript` | 14 / 20 pt | medium | Live and final words in the pill |
| Pill status | `pillStatus` | 11 / 16 pt | regular | The pill's status and helper lines |
| Key label | `key` | 11 / 16 pt, SF Mono | regular | Key caps ("fn / 🌐", "Esc"), tags |
| Durations | `duration` / `pillTimer` | as `meta` / `pillStatus` | regular | **Tabular digits** for timers, durations and counts that tick |

- Line heights are exact: `TypeRole.lineSpacing()` / `paragraphStyle()` add the leading that brings
  the face's natural line up to the role's line height.
- **Text scaling.** Window text scales with Settings › Appearance › Larger Text
  (`TypeRole.nsFont(scale:)`). The pill never shrinks or scales its text; overflowing notices move to a
  readable detail surface (Review, the recovery sheet) instead (design §3).
- The prototype's browser CSS draws the pill status at 10 px and the helper at 9 px inside a scaled
  mock-up. The native pill uses the typography roles above (11 / 16 pt), which `design_v1.md` §3 names
  as the product roles; copy and geometry parity with the prototype are unaffected.
- Rules kept from v1: never more than three type sizes visible in one pane; never bold a whole
  paragraph; no italics for emphasis; never centre a paragraph of prose.

---

## 2. Colour

**Dark-first, warm, quiet.** Warm charcoal and brown-black surfaces, subtle borders, warm white text,
peach/orange selection and primary actions drawn from the cassette housing, a green idle indicator,
amber interruption, coral-red uncertainty (design §3). Spool and its tape are the signature; the chrome
stays restrained so the mascot never competes with the words.

Window colours are dynamic `NSColor(name:dynamicProvider:)` values that follow the window's appearance
(Settings › Appearance: follow system / light / dark) and the system's Increase Contrast. The pill is
always dark and never follows the window theme. **No hex value appears anywhere in the app outside
`App/Core/DesignTokens.swift`.**

### 2.1 Window tokens (`Tokens.Role`, `Tokens.Colors`)

| Token | Code | Dark | Light | Use |
|---|---|---|---|---|
| Canvas | `canvas` | #181310 | #FFF6EE | App background |
| Sidebar | `sidebar` | #211914 | #F4E3D5 | Navigation |
| Surface | `surface` | #2B211B | #FFFBF7 | Group / reading pane |
| Elevated | `elevated` | #382A21 | #F8EADC | Popover / control |
| Primary ink | `ink` | #FFF0E3 | #35251C | Text |
| Secondary ink | `secondaryInk` | #C3AA97 | #786050 | Helper text |
| Separator | `separator` | #554035 | #DFC3AD | 1 px rules between regions (decorative, §3.3) |
| Control border | `controlBorder` | #8A7364 | #967C6B | A line that identifies a control or a state (adjusted, §3.3) |
| Accent | `accent` | #E9AD83 | #984B23 | Selection, primary action, focus ring |
| On accent | `onAccent` | #352014 | #FFFFFF | Text on an accent fill (prototype `--accent-ink`) |
| Ready | `ready` | #69D58B | #21753D | Idle dot, verified icon — never in the hover hint |
| Attention | `attention` | #F0C181 | #86540C | Recoverable interruption (held, unconfirmed, partial, mic warning) |
| Uncertainty | `uncertainty` | #FF8F95 | #B72F40 | Dotted word underline |
| Pill | `pill` | #080A09 | #080A09 | Always dark against the menu-bar edge |

Increase Contrast changes exactly two roles (§3.3): `secondaryInk` becomes #CDB6A4 (dark) / #5A4539
(light), and `separator` becomes `controlBorder`.

### 2.2 Pill tokens (`Tokens.Pill`, fixed; prototype `.notch` rules)

| Token | Value | Use |
|---|---|---|
| `background` | #080A09 | Pill and presence chin fill |
| `ink` | #FFF0E3 | Transcript words |
| `secondaryInk` | #C3AA97 | Status and helper lines |
| `ready` | #69D58B | Idle dot, verified mark |
| `attention` | #F0C181 | ⚠ notices |
| `uncertainty` | #FF8F95 | Dotted underline in the pill |
| `control` | #382A21 | Action button fill |
| `controlBorder` | #634B3A | Action button border (decorative; the fill and label identify the button) |
| `primary` | #E9AD83 | Primary action fill |
| `onPrimary` | #352014 | Primary action label |

### 2.3 Spool material (`Tokens.SpoolMaterial`, design §3.1, `spool_spec.json`)

| Material | Value | Exact application |
|---|---|---|
| `tapeFace` — tape oxide face | #AD714F | Outside ribbon face, visible internal tape face, wound reel pack fill |
| `tapeReverse` — tape reverse | #704A36 | Reverse surface exposed by a twist; not a different outside tape colour |
| `tapeEdge` — tape cut edge | #D3A582 | Thin edge reflection on the strip and reel rim |
| `tapeShadow` — tape shadow / grain | #573A2B | Fine longitudinal grain, underside edge and subtle winding rings |
| `housing` — cassette housing | #D6A07D | Warm shell with restrained light/shadow |
| `hub` — hub / pressure pad | #FFF0D2 | Cream hardware, clearly different from the tape itself |

The shell's shading steps (`housingShades` in `spool_spec.json`) belong to the Spool art (S1) and are
read from the fixture, not duplicated here.

### 2.4 Rules

- **The accent is the cassette peach**, not the system accent. This replaces v1 §2.1: the design's
  palette is an explicit change from the old system-accent-only document. Accent budget is kept: one
  accented element per pane (the selected row, or the one primary button, or the focus ring).
- **Meaning of colour.** Green = ready / verified only. Amber = a recoverable interruption the user
  can act on. Coral-red = an uncertain word only — never "recording", never "destructive". Tape copper
  is never substituted for uncertainty dots. Destructive actions are words with an ellipsis and a
  confirmation ("Discard…", "Delete all…"), not a colour.
- **Colour is never the only carrier of meaning** (kept from v1): every coloured state also carries a
  glyph (✓, ⚠, ⊘) and a word, and uncertainty is a *dotted* line plus "N words to review".
- Appearance setting changes windows only; the pill stays dark and top-centred in every mode.

---

## 3. Spacing, radii, contrast

### 3.1 Spacing (`Tokens.Spacing`, `Tokens.ControlSize`)

Scale: **4, 8, 12, 16, 24, 32 pt.** Nothing off-scale in the window.

| Use | Value |
|---|---|
| Page outer padding | 24 |
| Between sections / groups | 24 (the design's 20–24 range, on-scale) |
| Between rows in a group | 8 |
| Between a control and its helper sentence | 4 |
| Between a heading and its first row | 12 |
| Compact control minimum height | 28 |
| Main control minimum height | 32 |
| Touch target (companion mobile surfaces) | 44 |

One hairline per boundary. No border around every line of content. Pill insets and lanes are pill
geometry, in §8.3.

### 3.2 Corner radii (`Tokens.Radius`)

| Surface | Radius |
|---|---|
| Window | 16 |
| Group | 10 |
| Input / button | 7 |
| Pill, floating (external display, standalone) | 18, all four corners |
| Pill, attached under the notch / menu-bar band | 18 on the lower corners; upper corners square |
| Idle presence chin (64 × 14) | 6, lower corners only |
| Hover hint (360 × 38) | 10, lower corners only |
| Key cap, tag | 4 |

### 3.3 Contrast (WCAG 2.x, computed by `DesignTokenTests`)

| Content | Required |
|---|---|
| Text and meaningful glyphs, every theme | **≥ 4.5 : 1** on every background it can sit on |
| Lines that identify a control or a state (control outlines, focus ring, uncertainty underline, idle dot) | **≥ 3 : 1** |
| Increase Contrast: primary and secondary ink | **≥ 7 : 1** |
| Increase Contrast: every line, including separators | **≥ 3 : 1** |
| Decorative 1 px rules between regions already told apart by space and fill | exempt (WCAG 1.4.11 does not apply) |

**Adjusted and recorded pairs.** The audit found exactly one sub-threshold pair family: the design's
**`separator` (1.34–1.91 : 1)** on every background, both themes. It is kept exactly as verified
because it is a decorative hairline — the design's "subtle borders", and the platform's own separator
convention. Three adjustments make that honest:

1. **`controlBorder`** (new; #8A7364 dark, #967C6B light) is the separator mixed toward secondary ink
   until it reaches 3 : 1 on every background (min 3.10 / 3.11). Any line a user must see to find or
   read a control — a text-field outline, an unselected segment, a toggle or checkbox outline — uses
   `controlBorder` or a native control, never `separator`. The prototype draws its inputs with `--line`;
   the native build uses `controlBorder` there because design §11 requires control contrast ≥ 3 : 1.
2. Under **Increase Contrast**, `separator` resolves to `controlBorder`: hairlines become real lines.
3. Under **Increase Contrast**, `secondaryInk` is mixed toward primary ink until it reaches 7 : 1
   (#CDB6A4 dark, #5A4539 light). Primary ink already exceeds 11 : 1 in both themes.

The pill's action-button border (#634B3A, 2.46 : 1) is likewise decorative: the button is identified by
its fill and its label (≥ 12 : 1).

Measured ratios, window tokens on canvas / sidebar / surface / elevated (generated; the test fails if a
row here is missing or stale):

| Theme · contrast | Token | canvas | sidebar | surface | elevated | Needs |
|---|---|---|---|---|---|---|
| dark · standard | `ink` #FFF0E3 | 16.52 | 15.51 | 14.09 | 12.37 | ≥ 4.5 |
| dark · standard | `secondaryInk` #C3AA97 | 8.35 | 7.84 | 7.12 | 6.26 | ≥ 4.5 |
| dark · standard | `separator` #554035 | 1.91 | 1.79 | 1.62 | 1.43 | decorative |
| dark · standard | `controlBorder` #8A7364 | 4.14 | 3.89 | 3.53 | 3.10 | ≥ 3 |
| dark · standard | `accent` #E9AD83 | 9.45 | 8.87 | 8.06 | 7.08 | ≥ 4.5 |
| dark · standard | `ready` #69D58B | 10.08 | 9.47 | 8.60 | 7.55 | ≥ 4.5 |
| dark · standard | `attention` #F0C181 | 11.10 | 10.42 | 9.47 | 8.32 | ≥ 4.5 |
| dark · standard | `uncertainty` #FF8F95 | 8.44 | 7.92 | 7.20 | 6.32 | ≥ 4.5 |
| light · standard | `ink` #35251C | 13.73 | 11.72 | 14.23 | 12.42 | ≥ 4.5 |
| light · standard | `secondaryInk` #786050 | 5.48 | 4.68 | 5.68 | 4.96 | ≥ 4.5 |
| light · standard | `separator` #DFC3AD | 1.57 | 1.34 | 1.63 | 1.42 | decorative |
| light · standard | `controlBorder` #967C6B | 3.65 | 3.11 | 3.78 | 3.30 | ≥ 3 |
| light · standard | `accent` #984B23 | 5.84 | 4.99 | 6.06 | 5.29 | ≥ 4.5 |
| light · standard | `ready` #21753D | 5.35 | 4.57 | 5.55 | 4.84 | ≥ 4.5 |
| light · standard | `attention` #86540C | 5.98 | 5.11 | 6.20 | 5.41 | ≥ 4.5 |
| light · standard | `uncertainty` #B72F40 | 5.63 | 4.81 | 5.84 | 5.09 | ≥ 4.5 |
| dark · increased | `secondaryInk` #CDB6A4 | 9.50 | 8.92 | 8.10 | 7.11 | ≥ 7 |
| dark · increased | `separator` #8A7364 | 4.14 | 3.89 | 3.53 | 3.10 | ≥ 3 |
| light · increased | `secondaryInk` #5A4539 | 8.39 | 7.16 | 8.70 | 7.59 | ≥ 7 |
| light · increased | `separator` #967C6B | 3.65 | 3.11 | 3.78 | 3.30 | ≥ 3 |

Rows not listed under "increased" do not change with Increase Contrast; their standard ratios apply.

Text on fills, and the always-dark pill:

| Where | Pair | Ratio | Needs |
|---|---|---|---|
| dark · on accent | `onAccent` #352014 on `accent` #E9AD83 | 7.87 | ≥ 4.5 |
| light · on accent | `onAccent` #FFFFFF on `accent` #984B23 | 6.24 | ≥ 4.5 |
| pill | `ink` #FFF0E3 on `background` #080A09 | 17.80 | ≥ 4.5 |
| pill | `secondaryInk` #C3AA97 on `background` #080A09 | 9.00 | ≥ 4.5 |
| pill | `attention` #F0C181 on `background` #080A09 | 11.96 | ≥ 4.5 |
| pill | `ready` #69D58B on `background` #080A09 | 10.86 | ≥ 3 |
| pill | `uncertainty` #FF8F95 on `background` #080A09 | 9.09 | ≥ 3 |
| pill | `ink` #FFF0E3 on `control` #382A21 | 12.37 | ≥ 4.5 |
| pill | `onPrimary` #352014 on `primary` #E9AD83 | 7.87 | ≥ 4.5 |
| pill | `primary` #E9AD83 on `background` #080A09 | 10.18 | ≥ 3 |
| pill | `controlBorder` #634B3A on `background` #080A09 | 2.46 | decorative |

These are sRGB token values. Test both themes and high contrast on real displays too (design §11);
that is hardware verification, not something this table proves.

---

## 4. State vocabulary

The words on screen and the identifiers in code. **The user-facing words are the verified design's
words** (`design_copy.json`); the code name is the only name allowed in identifiers, log lines and test
names.

| User-facing | Meaning | Code name |
|---|---|---|
| **Hold** | Push-to-talk while the key is down; lands once on release | `hold` |
| **Hands-free · listening** (pill status), "Tap <key> to finish" | Double-tap; listening continues across pauses, one landing per segment | `latched` |
| **Muted** ("⊘ VoicePlus is muted") | Persistent hard mute; survives relaunch, never auto-clears | `muted`, `MuteController` |
| **Held** ("⚠ Destination changed · text held") | Committed text waiting for an explicit destination | `held` |
| **Recent dictations** (Today) | Retained dictation turns, newest first | `TurnRecord` / `TurnStore` |
| **Timeline** | Ambient transcript history (kept from v1; the verified design has no separate word for it) | `AmbientTimeline` |
| **Ambient · Off / Listen & note / Listen & act** (menu row + segmented control, Settings › Privacy) | V5 L1 ambient settings. Ambient speech may dictate or act **only in Listen & act**, only from the user's voice, only in the act band, never self-confirming an irreversible step (V5 L2, amends V3 §8); Listen & note only stores Notes | `AmbientMode` (`off`, `listenAndNote`, `listenAndAct`), `AmbientGuarantees` |

**"Hands-free" in UI copy.** v1 forbade the words "hands-free" anywhere in UI copy. That rule is
replaced by the verified latched copy: the latched pill status is **Hands-free · listening**, its helper
is "Tap <key> to finish", and Settings › Shortcuts reads "Double-tap to latch — Tap twice, speak
hands-free, then tap to finish." Those are the only places the phrase appears. Identifiers stay
`latched`; never add a `handsFree` symbol.

Delivery outcomes read as the design's pill statuses:

| Outcome | Pill status | Today tag |
|---|---|---|
| `delivered(verified: true)` | ✓ Inserted in <app> | Inserted |
| `delivered(verified: false)`, verdict `.unconfirmed` — a settled readback ran and the text is absent (sticky) | ⚠ Couldn’t confirm insertion | Unconfirmed |
| verdict `.unreadable` of `delivered(verified: false)` — readback could not run (V5 Q4, revives V4.20) | Inserted in <app> (no ✓, auto-clears after the landed dwell) | Unconfirmed |
| `partial` | ⚠ Only part may have been inserted | Unconfirmed |
| `held` | ⚠ Destination changed · text held | Held |
| `failed` | ⚠ Couldn’t finish this dictation | — (recovery row) |

Kept from v1: `InputTimeline` is an internal deixis structure and is never shown to a user as history.
Never write "paused" where the state is `muted`, or "muted" where it is `paused` (a meeting pause).
Held text is **held**, never "queued", "pending", "buffered" or "saved".

---

## 5. Focus and keyboard navigation (kept from v1)

### 5.1 One window

There is one window (`R7.1`). It is a `NavigationSplitView`: sidebar + detail. It is resizable,
remembers its frame and its selected section, and is **not** a modal or a panel. No standalone
Settings window, no standalone Data Panel, no standalone Lab window, no standalone enrollment
window (`R7.2`). Onboarding is the one exception: a separate, normal closable window that exists only
until it is finished (§11; design §8.7 "never a full-screen input trap").

### 5.2 Keyboard map

| Key | Effect |
|---|---|
| `⌘,` | Open the window at **Settings** |
| `⌘1` … `⌘6` | Jump to sidebar section 1–6 in the order listed in §9 |
| `⇥` / `⇧⇥` | Move focus through focusable controls in reading order: header → sidebar → detail |
| `⌃⇥` | Move focus between the two panes (sidebar ⇄ detail) without walking every control |
| `↑` / `↓` | Move the selection within the focused list (sidebar, Today, Meetings, Dictionary) |
| `↩` | Activate the focused row's primary action, or the pane's default button |
| `Space` | Toggle the focused checkbox/switch; preview the focused Today row |
| `⌘F` | Focus the search field of the section that has one (Today, Meetings, Dictionary) |
| `⎋` | Close a popover before a sheet, a sheet before anything else; clear a search field; never closes the window while a sheet is open. During a dictation turn, before the write begins, `⎋` cancels the turn (§8.7) |
| `⌘W` | Close the window (the app keeps running; it is a menu-bar app) |
| `⌫` | Delete the selected row in Today / Meetings / Dictionary, with confirmation for destructive scope |

### 5.3 Focus rules

- **Full Keyboard Access must work.** Every actionable thing is reachable by `⇥` with no dead ends.
  Nothing is click-only. Nothing depends on hover to be discoverable — hover may only *reveal
  affordances that are also reachable by keyboard* (the presence hint is a convenience; the same
  shortcut instruction is the chin's accessible description, and a click always opens the menu).
- The focus ring is the **system** ring (`.focusEffectDisabled()` is banned). Never draw a custom
  ring; never suppress it because it "looks noisy".
- On opening a section, initial focus is the detail pane's **first interactive control**, not the
  sidebar, except when the section is empty, where focus lands on the empty state's single call to
  action.
- Focus never moves on its own while the user is typing, and never moves because an async load
  finished. A late-arriving result may update content; it may not steal focus.
- **Dictation focus is sacred.** Neither the window nor the menu may take keyboard focus away from
  the user's destination app during capture. The menu is opened from a non-activating panel/status
  item; the pill panel is a non-activating panel that ignores the pointer except for its hover-pause
  area and its action row (§8.9). Recovery and correction controls take focus only on explicit
  interaction. Any new affordance that could activate the app during capture is a bug.
- Sheets are used only for a genuine either/or (delete-all confirmation, model integrity failure) and
  for the recovery sheet the design specifies. Everything else is inline in the detail pane.
- VoiceOver: every section has a `.accessibilityLabel`; every state row carries the state word in
  its label, not only a colour; list rows are rotor-navigable with a label of
  "time, destination, first words". Spool artwork is `accessibilityHidden`; the semantic state and the
  real outcome are announced, never the animation.

---

## 6. Reduced motion and increased contrast — every state

Two system settings drive these: `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` /
`@Environment(\.accessibilityReduceMotion)` (plus Settings › Appearance › Reduce Motion), and
`accessibilityDisplayShouldIncreaseContrast` / `@Environment(\.colorSchemeContrast)` (the token
provider resolves the high-contrast appearances itself, §3.3).

**Normal motion** (design §11): 160–220 ms ease-out geometry transitions, small mechanical
anticipation, no elastic bounce. Tape amplitude is bounded to 12 pt and never enters the transcript
lane. Listening reels turn counterclockwise at about 150°/s, modulated by real speech activity;
insertion is a finite clockwise turn. Reel angle is accumulated state that persists across states and
transcript updates — never snapped back. Idle never animates. The frame loop stops when the pill is
hidden or reduced (`spool_spec.json` › `loopStops`). An animation freeze never freezes capture or
blocks recovery controls.

**Reduce Motion:** static flat tape and representative still Spool expressions; no reel rotation,
twist, tape flight, spring, grain shimmer or animated progress on the tape. A numeric level readout may
replace capture motion. Every state label, the dwell and the order of events stay exactly the same.

**Increase Contrast:** `separator` becomes `controlBorder`, `secondaryInk` rises to ≥ 7 : 1 (§3.3),
materials become opaque, and every state that leans on colour already carries a glyph and a word.

### 6.1 Pill states (Spool; design §11.1)

| States | Tape | Reels | Mouth | Reduce Motion |
|---|---|---|---|---|
| C0 Starting | flat, no feed | still | attentive | unchanged (already still) |
| C1 Listening, C3 Latched, C5 Mic warning, Q0 Meeting | broad face → twist → face, audio-driven | counterclockwise | oval, subtle pulse, occasional blink | flat still tape, still reels; numeric level readout |
| C2 Listening, quiet | flat, connected | still (parked) | neutral | unchanged |
| F0 Finishing | twists unwind, slack taken up | decelerate counterclockwise, never reverse | purse | still pose; label "Finishing…" |
| F1 Final preview, F2 Review | flat, taut, full width | still | small smile / attentive review | unchanged |
| D0 Inserting | twisting ribbon feeds from the mouth to the caret (tape flight) | clockwise, finite | tape emerges | no flight, still Spool; insertion label and outcome unchanged |
| D1 Inserted, R2 Undo available | returns to rest | still | satisfied / calm | unchanged |
| H0 Held, E0 Error, D2 Unconfirmed, D3 Partial | brake secures intact tape | still | concerned | unchanged |
| C4 Cancelled | exposed tape retracts into the guide | brake without reversing | neutral | still pose |
| I2 Muted, E1 Blocking, I3 Unavailable | parked, no feed | covered / still | closed | unchanged |
| R0 Correcting, R1 Editing, Q1 Meeting paused, Q2 Preparing notes | stationary; labelled progress marker where the design shows one | still | thoughtful / asymmetric shutter | progress marker static, progress as text |
| I0 Idle, I1 Ready hint | none (Spool withdrawn) | — | — | hint expands instantly |

### 6.2 Presence (idle chin and hover hint)

| State | Motion | Reduce Motion | Increase Contrast |
|---|---|---|---|
| I0 Idle — 64 × 14 chin, 6 pt green dot | none; never pulses | none | dot unchanged; chin already opaque |
| I1 Ready hint on pointer hover | 160–220 ms ease-out expand to 360 × 38; collapse on exit | expand / collapse instantly | text is `Pill.ink` on the pill fill (17.8 : 1) |
| Muted, blocked, capture, held | take priority over hover; the pill shows the state (§8.6) | unchanged | unchanged |

### 6.3 Window and onboarding states

| State | Motion | Reduced motion | Increased contrast |
|---|---|---|---|
| Sidebar selection change | Detail content replaces with no transition | unchanged | Selected row: accent fill **plus** a leading accent bar, so selection is not colour-only |
| Loading a section | Static "Loading <section>…" text; determinate bar only with a true denominator | unchanged (never a spinner that is the only signal) | Text at `ink` |
| Determinate progress (model install, enrollment, benchmark) | Bar animates to each new value | Bar jumps to each new value | Track uses `controlBorder`; percentage always shown as text |
| Empty state appearing | No animation; still Spool cameo | unchanged | Body at `ink` |
| Scoped error banner appearing | No animation | unchanged | Amber glyph + words; 1 pt `controlBorder` outline |
| Row insert in Today / Meetings | List insert, system default | `.animation(nil)` | 1 pt separators on (`controlBorder`) |
| Mic level meter (Voice, onboarding) | Continuous level | Updates without interpolation; the numeric dB readout is always present | Meter fill ≥ 3 : 1 against its track |
| Voice test / enrollment Spool | Moves only during real capture; parks while analyzing | Still | unchanged |
| Onboarding step change | Content replaces; no slide | unchanged | "Setup · N of 7" as text, not only a bar |

If a state is added later and does not appear in one of these three tables, it is not finished.

---

## 7. Errors: sizing and copy voice

### 7.1 Copy voice (kept from v1)

- **Name what happened, then name the action.** `Problem — Action`, action in the imperative and
  matching a control the user can actually reach.
- Plain English. No jargon, no error codes, no exception text, no bundle IDs, no "unexpected". No raw
  enum tokens (`invalidAudioData`) or filenames (`weight.bin.partial`) in a headline.
- Never blame the user; never blame "the system". Say what the app observed.
- One sentence for the headline, one for the detail. No paragraphs.
- No exclamation marks. No "Oops". No apologies. No "please".
- Never claim success that was not verified — this is why **⚠ Couldn’t confirm insertion** exists.
- Never claim zero network bytes; say what left the Mac.
- Sentence case. Serial commas. No trailing period on a headline; a period on the detail sentence.
  These rules govern copy written for this app; the verified design's own strings are used verbatim,
  punctuation included (for example the page titles "Your text is still here." and "You’re ready.",
  and typographic apostrophes and ellipses: "Couldn’t", "Finishing…").

**How the voice renders in the verified design.** The recovery catalogue (design §10;
`design_copy.json` › `errors`, 59 entries) gives every error a **headline** (the problem), a
**consequence**, one **primary recovery** (the action, rendered as the primary button), and a **data
policy**. Where headline and action share one line (a row error, the menu), they are joined as
`Problem — Action`. Headlines, consequences and actions are used verbatim from the fixture, with the
one owner substitution (§0.1). The three canonical V3 strings map to catalogue entries:

| V3 string | Catalogue | Headline · consequence · action |
|---|---|---|
| Destination changed — Copy text | D01 | "Destination changed — text held" · "Nothing was typed into the new destination." · **Insert here** (with Copy text, Discard…) |
| Microphone disconnected — Choose microphone | A02 | "Microphone disconnected" · "Recording stopped. Review any words already captured." · **Choose microphone** |
| No speech detected — Try again | A06 | "No speech detected" · "Nothing was typed." · **Try again** |

Further rules from design §10: "Nothing was typed" is only valid when no write attempt could have
changed the field. Unconfirmed and partial writes never auto-retry and never offer a universal Retry.
Error, held and blocking notices stay until the user acts; dismissed retained text remains in Today.
D06 (V5 Q4): the sticky "⚠ Couldn’t confirm insertion" is only for `.unconfirmed`; an `.unreadable`
landing is the neutral, timed "Inserted in <app>" — never a ✓, never a warning (revives V4.20).
Only transient cancellation / too-short hints fade, after 800–1600 ms. Error strings never masquerade
as transcript text.

### 7.2 Error sizing

| Surface | Sizing rule |
|---|---|
| Pill notice | The 560 × 204 actionable layout (§8.3): status line, helper line, full-width action row below the character bay. Text keeps its size; anything that does not fit opens in Review / the recovery sheet. The panel's frame is placement math, never content: `NSHostingView.sizingOptions = []`, and **never** `fixedSize(vertical:)` inside pill content (the 1.7.9 black-slab bug). |
| Window scoped banner | Full detail-pane width, glyph + headline + consequence + up to two actions; grows vertically, never scrolls internally, never truncates. Partial data stays readable under it. |
| Row-level error | One line in the row; the full text is the row's accessibility label and tooltip. |
| Onboarding step error | Inline under the control that failed; stay on the failed step, keep completed steps (§11). |
| Sheet | Recovery sheet, destructive confirmation, or an integrity failure that blocks use. Title ≤ 6 words, body ≤ 2 sentences, two buttons max (the recovery sheet's three actions excepted). |

Raw errors (`Error.localizedDescription`, OSStatus, AX codes) go to `Log` and to diagnostics behind a
Copy action. They never reach a user-facing sentence.

---

## 8. Spool and the pill

Replaces v1 §8 ("the existing pill and notch chin — documented as-is"). Sources: design §3.1, §4, §5,
§6, §11.1; prototype `function art / face / lens / rig / limb / tapeRibbon` (ported by S1, not
redrawn).

### 8.1 Spool anatomy and material

Spool is a cassette body with two large tape packs as eyes. The rotating cream hubs are mechanical eye
centres; small dark pupils can look toward the phrase independently of rotation. Shutter eyelids and
two small brows express attention. The pressure-pad opening below is the mouth: oval while listening,
pursed during finalization, smiling in final preview, opening into a tape feed slot during insertion,
and restrained concern when text needs help. Screws, the Side A label, guide roller, top tabs and feet
are secondary details, omitted at cameo scale. Materials are §2.3.

- The strip is a **filled flat ribbon**, not a stroked curve. A twist turns it edge-on and briefly
  shows the darker reverse; the edge highlight stays at the cut edge. No sprocket holes. The same face
  token is used inside, outside and on the wound packs; the width at the cassette inlet is continuous.
- **Reel direction, as viewed from the front:** counterclockwise while listening, clockwise while
  inserting; both reels turn the same way. Finishing decelerates in the listening direction and never
  reverses before commit. Preview, held, paused, mute, blocked, notes, unconfirmed and error poses do
  not spin.
- **The cassette is always on the right.** Text stays on the left above the tape lane. Never draw a
  face under readable words, never put tape across confidence dots, never let an expression imply a
  capture or delivery outcome that did not happen.
- Spool is the only mascot: no alternates, no plain-wave theme, no picker, no skins, no pet mechanics.

### 8.2 Placement

Directly below the physical notch / menu-bar safe band, centred horizontally — the v1 rule is kept:
**the pill's top edge is the bottom of the display's forbidden top band** (`ScreenMetrics.topBand`),
so nothing is drawn behind the camera housing. Use the display's real safe area, not a fixed offset.
The working display is chosen at key-down and pinned for the turn; if it disappears, recovery moves to
the remaining display and the destination is revalidated.

```text
NOTCHED DISPLAY                         EXTERNAL DISPLAY
+------------[camera]-------------+     +-------------------------------+
|                                 |     | Apple   App   File ...        |
+-----------+---------+-----------+     +-------------------------------+
            |    •    |                          [    •    ]
            +---------+                    8 pt below menu-bar band

ACTIVE ATTACHED PILL — nominal 560 x 164 pt
+------------------------------------------------------------+
| Listening · Mail               |  +---------------------+  |
|                                |  | SIDE A              |  |
| Can we meet with Mira          |  |  ((O))       ((O))  |  |
| on Friday?                     |  |   reel eyes  ↺ ↺    |  |
|   .... confidence word dots    |  |                     |  |
| ======\___/====\___/============[guide]====== tape     |  |
|                                |  |     [mouth]         |  |
| Release fn / 🌐   Esc          |  +---------------------+  |
+------------------------------------------------------------+
  16 pt inset    readable text       132 pt character bay
                 lane ~390 pt        top inset ~12–18 pt
```

### 8.3 Geometry (design §4; replaces `NotchGeometry.absoluteMaximumSize` 560 × 96)

| State geometry | Nominal size | Boundary |
|---|---|---|
| Idle presence | 64 × 14 pt | 6 pt green dot centred in a black chin, lower radius 6; Spool fully withdrawn |
| Ready hint | 360 × 38 pt | Hover-only text "Hold or Double Tap <key> to dictate"; no dot, brand prefix, Ready label or mascot; lower radius 10 |
| Starting / listening / preview | 560 × 164 pt | Stable dimensions throughout the turn; Spool ~126 × 115 pt in a 132 pt right bay |
| Actionable held / error | 560 × 204 pt | Same character bay; actions in a separate full-width row below it |
| Compact ceiling | min(560 pt, usable width − 32 pt) × 204 pt | No controls behind the character; full payload opens in Review |
| Narrow review viewport | text lane + 84 pt cameo bay, then action row | Below 460 pt keep 14 pt text, reduce ornament scale (0.69); never shrink the product to illegible type |
| Meeting expanded panel | 560 × 360 pt preferred | Explicit expansion; static compact cassette in the header, readable transcript below |

Upper corners square when attached, all four rounded when floating below an external display's menu
bar (§3.2). Content inset 16 pt; the status and words lanes are the content width minus 144 pt
(≈ 384 pt at 560), so no text reaches the character bay; the tape lane starts at (16, 104) in the
164 pt scene and the ribbon is 8 pt wide (`spool_spec.json` › `sceneGeometry` › `tapeStart`,
`tapeWidth`).
Very narrow displays use a detached review panel. The v1 panel rules that prevented the black slab are
kept: borderless non-activating `NSPanel` above the status bar, `sizingOptions = []`, frame is
placement math.

### 8.4 Hover presence and menu-bar identity

- **Idle (I0)** is the default between turns: the 64 × 14 chin with the 6 pt green dot. A green dot
  never means the microphone is open.
- **Pointer entry** expands to the 360 × 38 text-only hint: **Hold or Double Tap <key> to dictate**
  ("Hold <key> to dictate" when latch is off). No dot, no Spool, no brand prefix, no "Ready". Pointer
  exit collapses it. Keyboard focus does not open the hover presentation; the chin's accessible
  description carries the same instruction. Capture, errors and held text take priority over hover.
- **The hover target is the drawn surface only** — the 64 × 14 chin at rest (plus 2 pt slop), the
  expanded row once it is open — never the camera housing and never the width the hint *would* need.
  The chin takes the mouse only inside that target, so a window, tab or context menu beside it stays
  clickable and nothing expands while the pointer is merely passing near the notch.
- **Menu-bar glyph:** the black-and-white cassette-face outline (`spool_spec.json` › `menuGlyph`:
  32 × 24 viewBox, rounded rect, two eye circles, smiling mouth) at 18 × 16 pt, template image, system
  monochrome. Never tinted peach, never replaced by the detailed mascot. Clicking it opens the menu (§10).

### 8.5 Text lane, confidence marks, tape lane, deixis chip

- Natural-language text (`pillTranscript`), never monospace. Live text shows the newest two lines with a
  leading fade; stable words stay put and only the provisional suffix changes. Long final text shows the
  last two lines plus "N words · Review all"; the full payload is always retained and inserted.
- Uncertain words: 2 px dotted underline in `uncertainty`, 3 px below the baseline, on every wrapped
  fragment; word text stays normal foreground; "N words to review" plus an accessible label. The tape
  lane sits at least 8 pt below the marks.
- **Deixis chip (owner decision §0.1):** the box-and-screenshot thumbnail sits in the text lane, under
  the transcript and above the tape lane, styled as the design's tag/chip (`Radius.keyCap`, `key` type,
  `Pill.controlBorder` outline). Never in the character bay, never over Spool.
- Key-hint row: the state's fixture helper ("Release <key> to finish" while listening, "Tap <key> to
  finish" while latched) in `pillStatus`, with the Esc key cap beside it (design §4 diagram); key names
  in `key` type.

### 8.6 State inventory (I0–Q2)

Every visible pill/presence state, with the fixture key (`design_copy.json` › `states`), the design's
Spool treatment (design §6), and the status line and actions from `design_copy.json` › `pill`
("<key>" is the configured key, "<app>" the destination, counts and timers are real).

| ID | Key | State | Spool, tape and pill content | Status (fixture) · actions | Exit |
|---|---|---|---|---|---|
| I0 | `idle` | Idle | 64 × 14 pt black chin, centred 6 pt green dot; Spool and tape absent. Microphone closed. | — | Pointer hover → I1; key → C0 |
| I1 | `ready` | Ready | Only on pointer hover over idle. Text only; no green dot, brand prefix, Ready label or cassette. | Hold or Double Tap <key> to dictate | Leave → I0; hold → C0 |
| I2 | `muted` | Muted | Closed eye shutters, flat mouth, no tape motion. No green ready. | ⊘ VoicePlus is muted · **Unmute** | Explicit Unmute only |
| I3 | `unavailable` | Unavailable | Parked reels, setup latch, "Install a speech model" or the named blocker. | ⚠ Dictation is unavailable · **Open Models** | Open the named setup pane |
| C0 | `starting` | Starting | Attentive still cassette; tape lies flat. | Starting microphone… | Capture actually open → C1; failure → E0/E1 |
| C1 | `listening` | Listening | Live words above flat ribbon faces with audio-reactive waves/twists; reels counterclockwise; oval mouth, occasional blink. | Listening · helper "Release <key> to finish" | Key release → F0; Esc → C4 |
| C2 | `quiet` | Listening, quiet | Last words; flat tape, parked reels, patient open eyes. Label confirms capture is still open. | Listening · quiet | Speech → C1; release → F0 |
| C3 | `latched` | Latched | Same live tape and counterclockwise reels; persistent latched label plus timer. | Hands-free · listening · helper "Tap <key> to finish" · Finish dictation | Tap stop; Esc cancel; lock stop |
| C4 | `cancelled` | Cancelled | Reels brake without reversing; exposed tape retracts into the guide; neutral mouth. | Cancelled · "Nothing inserted" | 800 ms → idle |
| C5 | `warning` | Mic quality warning | Capture continues: moving tape, counterclockwise reels, concerned brow; never replaces live words. | ⚠ Microphone sounds unclear · Check microphone | Continue / Check microphone / Cancel |
| F0 | `finishing` | Finishing | Microphone closed; twists damp, reels decelerate counterclockwise, mouth purses. No new live-wave motion. | Finishing… · "Microphone closed · nothing inserted yet" | Final payload → F1; 2 s "Still finishing your text"; 10 s "Use available text" / "Cancel" |
| F1 | `preview` | Final preview | Final modified text above flat taut tape; stationary reels, relaxed shutters, pressure-pad smile. | Ready for <app> · manual review: **Insert now**, **Edit draft**, Cancel | 600 ms dwell; hover/focus pauses; completed edits resume on exit with at least 150 ms remaining; Esc cancels |
| F2 | `uncertain` | Review uncertain words | Same text and taut tape; asymmetric shutter/brow looks toward the dotted word; no spin. | Ready for <app> · N words to review · manual review: **Insert now**, **Edit draft**, Cancel | Same 600 ms dwell; inline alternatives and in-notch editing; uncertainty adds no delay |
| D0 | `inserting` | Inserting | Same immutable payload; reels clockwise; the mouth feeds a continuous twisting ribbon to the verified caret. No success cue yet. | Inserting in <app>… | Verification → D1/D2/D3; no automatic retry |
| D1 | `inserted` | Verified | Small satisfied mouth; reels parked; destination cue. Tape withdraws only after the known outcome. | ✓ Inserted in <app> | 650 ms → idle; field uncertainty survives |
| D2 | `unconfirmed` | Unconfirmed | Reels stop, brake holds tape; level concerned mouth. No smile, check or flourish. | ⚠ Couldn’t confirm insertion · **Check destination**, Dismiss | Check field; dismiss; never auto-reinsert |
| D3 | `partial` | Partial insertion | Tape held intact, eyes attend to destination, small concern. Never a snapped tape. | ⚠ Only part may have been inserted · **Review inserted text** | Review; manual reconciliation |
| H0 | `held` | Held | Final words above taut tape; visible guide brake. | ⚠ Destination changed · text held · **Insert here**, Copy text, Discard… | Persists until the user acts |
| R0 | `correcting` | Correcting | Stationary tape, asymmetric shutter; the correction popover owns alternatives and focus. | Review one word · **Review word** | Replace verified range / Keep / Dismiss |
| R1 | `editing` | Editing selection | Stationary reels; small progress marker on the taut ribbon; thoughtful pursed mouth. | Editing N words… | Edited final preview before replacement |
| R2 | `undo` | Undo available | Parked reels, calm mouth. No rewind until safe undo is confirmed. | ✓ Updated in <app> · **Undo** | Safe undo 5 s; stale range → recovery |
| E0 | `error` | Recoverable error | Tape guide brake, stopped reels, gentle concern, exact problem / consequence / recovery. | ⚠ Couldn’t finish this dictation · **Review text**, Copy text | Stays until action/dismissal; drafts remain |
| E1 | `blocked` | Blocking error | Closed shutters and setup latch; no recording or readiness claim. | Microphone access is off (or the named blocker) · **Review permissions** | Named setup action; recheck capability |
| Q0 | `meeting` | Meeting capture | Counterclockwise reels and audio-reactive tape only while capture is really open; timer, track status. | Meeting · recording · Pause, Stop, Expand | Pause / Stop / Expand |
| Q1 | `paused` | Meeting paused | Stationary reels, flat tape, pause bars on the latch. | Meeting paused · **Resume**, Stop | Explicit Resume / Stop |
| Q2 | `notes` | Meeting processing | Parked reels, thoughtful mouth, small labelled progress marker; no transport motion. | Preparing meeting notes · **Open meeting** | Open transcript; retry Notes independently |

**State priority:** secure-field / mute > permission / device interruption > capture status > final /
commit outcome > held recovery > ready / idle. Warnings annotate live transcription rather than
replacing the words. Durable recovery is queued in Today when a higher-priority state needs the pill.

### 8.7 The turn contract (design §5; S3 implements)

Key down acknowledges within an 80 ms target and opens capture immediately; "Listening" appears only
when capture is actually open. Key up closes the microphone immediately. One immutable final payload
is shown above the flat, taut tape for the **dwell** — 600 ms default from the first rendered final
frame, with no extra delay for uncertain words or long text. Hover, keyboard focus, selection and
editing pause it. Leaving the notch applies nonempty completed edits and resumes with at least
150 ms remaining; an active composition or empty editor stays paused. Manual review remains
explicit. The final edited payload is frozen when insertion starts, the target is revalidated, and
the payload is inserted **exactly once**, guarded by turn ID. Animation completion is never a write trigger. Escape before the write
cancels with nothing inserted; Escape after the write resolves the outcome truthfully, then offers a
range-safe Undo. Latch: every segment passes the same preview gate, serialized; hold never inserts
intermediate segments. Nothing revises text after it lands.

### 8.8 Mouth-to-caret tape flight (design §4; S4 implements)

A separate transparent, pointer-transparent overlay draws the ribbon from Spool's mouth slot to the
verified pre-insertion caret rectangle while the reels turn clockwise. It is suppressed — normal label
and outcome, no flight — when the caret rect is unavailable, the target changed or became secure, the
target is on another display, or Reduce Motion is on. It clears immediately on interruption and never
delays or triggers the write.

### 8.9 What the pill never does

- Never takes keyboard focus during capture; readable transcripts accept pointer scrolling and selection.
  Explicit final-draft editing may take keyboard focus. Startup placeholders remain click-through.
- Never shows diagnostics: no model names, latency, thermal state or raw errors (they live in Voice ›
  benchmarks and the Privacy diagnostics disclosure).
- Never draws behind the camera housing, never shows a green success claim for an unverified write,
  never loops a canned ribbon or spinning reels when no audio is arriving.

---

## 9. The one window (amended with design §8)

`NavigationSplitView`, preferred **1080 × 720 pt**, minimum **820 × 560 pt**, sidebar **208–240 pt**,
detail takes the rest. One clear page title (`title`), 24 pt outer padding, 24 pt section gaps.
The toolbar holds only relevant actions. Scroll position and selection are preserved per section.
`⌘1`–`⌘6` select the six sections in this order; `⌘,` opens Settings; `⌘F` focuses local search. The
sidebar footer is the green `ready` dot plus "Ready · On this Mac" over "Hold <key> to speak" (prototype
`<footer>`); Today's page foot reads "Hold <key> to speak. Release to preview, then insert." with the
key in a key cap (`key` type), beside a still Spool cameo.

1. Today
2. Meetings
3. Dictionary & Apps
4. Voice
5. Privacy
6. Settings

**Titles and subtitles** (`design_copy.json` › `screens`, verbatim):

| Screen | Title | Subtitle |
|---|---|---|
| Today | Today | Your words, right where you left them. |
| Turn detail | <turn title> | <app> · <day>, <time> · N words |
| Meetings | Meetings | Thoughts worth coming back to. |
| Dictionary & Apps | Dictionary & Apps | Your spellings. Your way of writing. |
| Voice | Voice | Make sure we hear you clearly. |
| Privacy | Privacy | Know what is kept, and what leaves this Mac. |
| Settings | Settings | Small adjustments. A familiar flow. |
| Shortcuts | Shortcuts | One key. A clear beginning and end. |
| Models | Models | Ready means verified and loaded. |
| Providers & Sync | Providers & Sync | Local first. Connections when you choose. |
| Menu (review surface) | A small, useful menu | Status and direct actions, one click away. |
| Recovery sheet | Your text is still here. | Destination changed · held for <app> |

**Four renderings.** Every screen shows exactly one base rendering — **content**, **empty**,
**loading** or **error** — plus a scoped banner for partial data (design §9). Loading never
masquerades as empty ("Loading <section>…"; no empty-state claim while data is still loading).
Progress is determinate only with a true denominator. Retry affects the failed scope and is disabled
while retrying. Success appears only after verification. A failed save keeps the entered value and the
previous active value. Empty and loading states carry the still `ready` Spool cameo.

**Empty states** (`design_copy.json` › `emptyCopy`: headline · body · action; "Right Control" rendered
as the configured key):

| Screen | Headline | Body | Action |
|---|---|---|---|
| Today | Nothing dictated yet | Hold <key> and say something. Your recent words will appear here. | Try dictation |
| Turn detail | No saved text here | History may be off or this turn may have been deleted. | Open Today |
| Meetings | No meetings yet | Start a recording whenever you need notes. Calendar connection is optional. | Start recording |
| Meeting detail | No speech captured | Check the microphone and system-audio tracks before your next meeting. | Check capture |
| Dictionary | Make it sound like you | Add a word VoicePlus keeps getting wrong. | Add a word |
| Voice | No voice enrolled | Enrollment is optional. Hold-to-talk works without it. | Set up my voice |
| Privacy | Nothing is saved | Your history is off. Recovery text has its own clearly labelled retention policy. | Review retention |
| Settings | Using your defaults | Personalize your shortcut and preview when you are ready. | Open shortcuts |
| Shortcuts | No custom shortcuts | <key> is your default hold-to-talk key. | Try default shortcut |
| Models | Install a speech model | Dictation becomes available when a compatible model has been verified and loaded. | Choose a model |
| Providers & Sync | Nothing connected | Local transcription works without a connected service or paired device. | Explore options |
| Onboarding | Welcome to VoicePlus | A few short steps, then hold a key and let your words arrive. | Begin setup |
| Menu | VoicePlus is ready | The menu is available even before your first dictation. | Open VoicePlus |
| Recovery | No text waiting | Every completed turn has been resolved. | Back to Today |

**Each screen's error example** is a catalogue entry (`design_copy.json` › `screenError`): Today S01,
Turn detail S03, Meetings X02, Meeting detail N01, Dictionary S02, Voice A02, Privacy S04, Settings
S02, Shortcuts K01, Models M02, Providers & Sync N02, Onboarding P01, Menu K05, Recovery S03.

### 9.1 Today and turn detail

- Held / recoverable text first ("Text waiting for <app>", with **Review text** and Copy), then recent
  dictations in time order. Each row: destination, time, short excerpt, and an explicit **Inserted /
  Held / Unconfirmed / "1 to review"** tag. No vanity counters as the default home.
- Search works on retained history only. History off is its own explanatory empty state, not
  "No results".
- Turn detail: final text (selectable), uncertainty count, optional original transcript (segmented
  Final text / Original transcript), destination, delivery evidence, Copy / Review / Delete; still
  held-tape Spool beside the delivery status.
- Recovery sheet: the complete payload and current destination preview; **Insert here** is an explicit
  re-target that revalidates after a field is selected; Copy is acknowledged only when the copy is
  verified; Discard… confirms when it destroys the only saved copy; closing keeps the draft. History
  off → "Kept until resolved"; persistence prohibited → "Kept for this session only".
- Loading: "Loading recent dictations…". Error: "History can’t be read" + Retry, with held drafts still
  shown.

### 9.2 Meetings

- List / detail only where it aids browsing. Detail header: title · date · duration · Local. Tabs:
  **Notes** (Summary, Decisions, Action items) / **Transcript** (speaker labels, timestamps, search,
  uncertainty marks; audio seeking only when audio is retained) / **Ask** (only with a configured
  service or local model, route disclosed before use).
- Expanded capture panel (560 × 360): Transcript / Notes / Ask, Pause, Stop, timer, explicit microphone
  and system-audio track indicators; paused and partial captures are labelled; system-audio denial
  offers microphone-only capture with a visible missing-track notice. Calendar is optional and never
  blocks manual recording.
- An unfinished-recording banner sits above the affected list with retained duration and
  Recover / Discard…; recovery never hides unaffected records; a Notes failure keeps the transcript.
- Loading: "Loading meetings…", "Preparing transcript…".

### 9.3 Dictionary & Apps

- Two segmented subviews. **Dictionary:** search, term, spoken variant, language, source, add/edit,
  import preview; duplicate or conflicting terms resolve inline; Contacts import is optional with a
  permission explanation, preview and explicit commit. Snippets and personas live here as rows.
- **Apps:** inherited default plus per-app style, insertion eligibility (never-insert), the
  contextual-reading switch (screen text) and an overlay capability badge. "Uses default" is shown
  distinctly from an override. The code/terminal profile is verbatim and never auto-sends Return.
- A failed save is inline; the prior value stays active; no silent policy change.

### 9.4 Voice

- Input selector, real level meter with a numeric readout, test sentence and quality guidance. Test
  states: idle, capturing, analyzing, result, no samples, too short, device removed; Stop testing
  releases the microphone. Spool moves only during a real test or enrollment capture and parks while
  analyzing.
- Optional speaker enrollment (the same view onboarding reuses, §11); failure never blocks hold
  dictation. Language choice with a model-capability explanation and mixed-script preview; never promise
  unsupported languages.
- Advanced benchmarks live in a disclosure (stage, result, diagnostics). This is where model names,
  latency and thermal diagnostics live — never the pill or the menu.
- "No voice enrolled" and "No microphones found" are distinct; loading "Looking for microphones…".

### 9.5 Privacy

- Rows: microphone, typing access, optional context from other apps (**screen text**, Screen Recording
  permission), history retention, audio retention, **recordings retention** (keep the last 100 / keep
  all; folder size; Reveal in Finder; Delete all…), meeting capture, optional sync.
- Show what stays on device and what a selected service may send. A dated network-activity list shows
  destination, purpose, time and allowed / blocked status. If the log cannot be read, show an error —
  never "Nothing left this Mac". Never claim literal zero network bytes; the empty result is scoped and
  dated.
- Delete controls state scope and count; partial deletion lists what remains. Hard mute closes all
  capture and clears latch, with the closed-shutter Spool beside it; it never resumes on wake.
- A **Diagnostics** disclosure hosts feature flags and the data panel; diagnostics omit transcript and
  audio by default and preview anything an export includes.

### 9.6 Settings

Subnavigation, exactly the design's seven: **General, Shortcuts, Appearance, Models, Providers, Sync,
Updates.** No other subpage; existing subpages are re-homed — `benchmark` → Voice › benchmarks
disclosure; `flags`, `data` → Privacy › Diagnostics; `snippets`, `personas` → Dictionary & Apps. Every
setting that exists today stays reachable.

| Subpage | Rows (design §8.6) | V4 rows added here (owner decision §0.1) |
|---|---|---|
| General | Launch at login; sound cues (off by default; no success sound before verified insertion); final preview 600 ms default / 1200 ms / manual review; low confidence adds no extra wait | Spacing: automatic / always / never (D6); unknown-caret style (D3) |
| Shortcuts | Key recorder with conflict result; hold explanation; "Double-tap to latch" (Tap twice, speak hands-free, then tap to finish); shortcut test | **Latch pause** 1–5 s (B2); fn system-action prompt + "Open Keyboard settings" (I1); draw-without-key while latched (G1) |
| Appearance | Follow system / light / dark (windows only; the pill stays dark); Reduce Motion; presence visibility; Larger Text. No mascot picker | — |
| Models | Compatible model, installed size, real byte progress → Verifying → Loading → Ready, retry / cancel, last working model. Never Ready before verification and loading | Speaker-embedding model row (H3) |
| Providers | Selected route, connectivity, credentials in a secure control; secrets never in errors | — |
| Sync | Pairing comparison, connected devices, paused / offline, conflict review | — |
| Updates | Installed version, checking, available, downloading, install-ready, failure; protects capture and unsaved drafts before restart | — |

Recordings retention and screen text are Privacy rows (§9.5), per the same owner decision.

### 9.7 Spool across app surfaces (design §8.9)

| Surface | Spool treatment |
|---|---|
| Today / empty history | One small still cameo beside the hold hint; never spins for loading |
| Turn detail / recovery sheet | Still held-tape pose beside delivery status; text stays selectable |
| Meetings library, detail, Notes, Ask | Static mark; progress uses labelled UI |
| Meeting capture / expanded panel | Reels and tape mirror actual capture only |
| Dictionary & Apps, Settings, Models, Providers, Sync, Updates | Static identity; native progress; no spinning tape |
| Voice test / enrollment | Moves only during real capture; parks while analyzing |
| Privacy / mute | Closed-shutter pose may accompany hard mute; the text stays authoritative |
| Onboarding | Still welcoming cameo; the sample capture follows the real live → preview → insert sequence |
| Status menu | The monochrome cassette glyph and explicit status text; opening the menu does not record |
| Correction popover | Optional still attentive cameo; alternatives, Edit and Keep keep priority |

Spool never plays continuously beside long-form reading.

---

## 10. The menu (amended with design §8.8)

One menu. Left-, right- and control-click on the **menu-bar glyph** (§8.4) or the idle chin open the
same menu (`PresenceClickRouter` returns `.menu`). Opening it never takes focus from the destination
app and never records; closing it never changes recording.

Row titles, helper lines and control labels in quotes are the prototype's menu review surface
(`case'menu'` in `design_v1.html`) verbatim; the two rows marked *design §8.8* are listed by the
specification but not drawn in the prototype.

| Item | Prototype row (title · helper · control) | States |
|---|---|---|
| **Recent** (*owner decision §0.1, H32*) | Section header "Recent" · up to 5 rows: app icon, one truncated line, relative time; tooltip = full words | Click = Copy (verified; "Copied" only on read-back); password-field turns never listed; a hands-free session is one row; hidden when there is nothing to list |
| Status line | Glyph + "VoicePlus · Ready" · "Microphone is closed." · green `ready` dot | Ready / Muted / the blocked reason; the dot only when ready |
| Microphone line (*design §8.8*) | — | Current input device and its state |
| **Start dictation** | "Start dictation" · "Menu capture has an explicit Stop control." · **Start** | Explicit click-to-stop capture ("Stop" while menu capture is open); it cannot imply a held key |
| **Mute microphone** | "Mute microphone" · "Close every active capture." · Muted toggle | Toggle; closes every active capture; never auto-unmutes |
| **Held dictations** | "1 held dictation" · "Saved until you resolve it." · **Review** | "N held dictation(s)"; Review opens the recovery sheet / Today; hidden when nothing is held |
| **Open VoicePlus** | "Open VoicePlus" · "Today and all settings." · **Open** | Opens the one window at Today |
| **Settings…** (*design §8.8*) | — | `⌘,` — opens the one window at Settings |
| **Quit VoicePlus** | "Quit VoicePlus" · "Protect active capture and unsaved text." · **Quit…** | During capture asks **Stop and quit** / Cancel; held drafts are saved or an unsaved-data warning names what would be lost |

Rules kept from v1: no item is removed to hide a problem — an unavailable action stays visible and
disabled with the reason in its title. Nothing in the menu opens a standalone window. The menu carries
no model name, latency or thermal readout. Latch and meeting start are not menu items
in the verified design; they live in Settings › Shortcuts and Meetings. Copy is in the menu only as
the Recent rows (owner decision §0.1, H32); Today keeps its own Copy.

**Hover opens the menu (H33).** Resting the pointer on the idle chin for 250 ms widens it from its
centre (H34; no cap above the menu bar) and drops this same menu straight down from it, centred, at one
shared width W = min(max(pill, menu natural width), widest row on the display) — the pill animates to W
and `menu.minimumWidth = W`. Never while a turn, capture or hands-free session is live; Option key-down
closes it and starts dictation; the pointer away from both pill and menu for 300 ms closes it; a closed
menu does not reopen until the pointer has left the pill. No row is pre-selected, so Quit is never the
default. The zero-edit counter, "Why did it write that?" and the ambient mode control are rows of the
spec (custom-view slots), not items added after it.

---

## 11. Onboarding (amended with design §8.7 and the owner's Voice step)

**Welcome → Microphone → Typing access → Model → Try dictation → Voice → Ready**

A normal closable window, never a full-screen input trap. "Setup · N of 7" as text plus a progress
bar; Back, Continue, and **Set up later** wherever safe; setup resumes at the unfinished step, and a
failed step keeps the user there with completed steps preserved. No mandatory name / email. Explain each
permission just before requesting it and use the real macOS prompt. Ask only for the selected
backend's permissions: the default bare-modifier monitor does not justify Input Monitoring. Still
Spool cameo on Welcome and Try; motion only during the real dictation test.

Heading, body and primary action are the prototype's onboarding `steps` verbatim (`case'onboarding'`
in `design_v1.html`), with "Right Control" rendered as the configured key (§0.1). The prototype's
step counter reads "Setup · N of 6"; with the owner's Voice step it is "Setup · N of 7".

| Step | Heading (prototype) | Body (prototype) | Primary |
|---|---|---|---|
| Welcome | Your voice, a little closer. | Hold a key. Speak naturally. See the sentence before it reaches your app. | Begin setup |
| Microphone | Let VoicePlus hear you. | Microphone access is needed only to capture your voice. | Allow microphone |
| Typing access | Let your words reach the page. | Accessibility lets VoicePlus insert text into your focused field. You can set this up later and use Copy. | Allow typing access |
| Model | Bring speech recognition on device. | Choose a compatible model. Dictation is ready only after download, verification and loading. | Install model |
| Try dictation | Try your first sentence. | Hold <key>. Watch Spool’s reels turn counterclockwise and words appear above the tape. Release, review, then watch a clockwise feed place your sentence. | Try dictation |
| **Voice** (owner addition, skippable) | The Voice section's enrollment copy ("No voice enrolled — Enrollment is optional. Hold-to-talk works without it.") | Read four lines (~30 s) with the Voice section's enrollment view; skipping leaves hold dictation fully working | Set up my voice · Skip |
| Ready | You’re ready. | A small green dot means VoicePlus is available. The microphone opens when you start dictating. | Open VoicePlus |

- The prototype's Microphone body continues "The real app requests the macOS permission here." That
  sentence annotates the simulation; the real step shows the real macOS prompt and a real level meter
  instead (§0: the markdown's real-product rule applies).
- Try dictation inserts into a safe test field and demonstrates one uncertain word and its correction
  (design §8.7).

Rules kept from v1 (they do not conflict with the design):

- **Dead-end rule on every step:** a blocked state carries the exact system path, a button that opens
  it, a way to continue anyway, and an honest sentence about what will not work until it is granted.
  After the first denial the copy switches from "Allow" to "Open System Settings"; never loop prompts.
- Typing access denied: "Text will be held for you to paste until this is on" — held text is the real
  fallback. A permission that needs a relaunch says so and offers the relaunch; never claim it is active
  when it is not.
- The trial dictation uses the real turn path (§8.7) — nothing simulated. "Ready" requires a working
  recognizer and capture path; a copy-only setup is labelled as such.
- fn key: the system-action conflict prompt ("Open Keyboard settings") comes before the key test; if no
  fn event arrives in three presses, offer Right ⌥ (I1).
- Optional later steps: meeting / system audio, Calendar.

---

## 12. Constraints

Non-negotiable for anything built from this document.

1. **No web views.** No `WKWebView`, no `SFSafariViewController`, no HTML, CSS or JavaScript at
   runtime, no bundled web assets, no Electron, no React Native. Every surface is AppKit or SwiftUI.
   The HTML prototype is a design reference only.
2. **The pill is the Spool pill (§8)**, built from the prototype's geometry, the copy fixture and the
   Spool port. It is not "improved" beyond the design; changes go through the design first.
3. **One mark.** Spool is the only mascot, the cassette outline the only menu-bar glyph; everything
   else is SF Symbols already in use. No sound by default (earcons are opt-in; no success sound before a
   verified insertion). Motion only where §6 and §8 specify it.
4. **No hex colour outside `App/Core/DesignTokens.swift`**, no third font, no custom control where a
   system control exists, no custom focus ring, no `.focusEffectDisabled()`.
5. **No standalone windows**: the one window, the menu and onboarding — plus the design's own
   transient surfaces (the pill, the meeting capture panel, the correction popover, the recovery sheet,
   the tape-flight overlay).
6. **No diagnostics in the pill or the menu.** Model names, latency, thermal state and raw errors live
   in Voice › benchmarks and Privacy › Diagnostics.
7. **No dishonest copy.** Never claim literal zero network bytes; never show ✓ or "Inserted" for an
   unverified write; never say "Ready" before a model is verified and loaded; never say a permission is
   active before it is.
8. **No telemetry, no plaintext secrets**, and no design element that requires either.
9. **Colour is never the only signal** — every state carries a glyph and a word, in default, reduced
   motion and increased contrast.
10. **Focus is never stolen** from the user's destination app by any surface described here.
11. **Nothing revises text after it lands.** Insertion is once per turn, guarded by turn ID; animation
    is never a write trigger.
