# VoicePlus — Spool · Compact V2

Design specification · 18 September 2026 · Final mascot direction · Compact expanded pill · Proposed product behavior

**Your voice, wound into words. Spool is the only mascot.** Keep the current top-center presence. While Right Control is held, live text appears above a continuous magnetic-tape ribbon. On release, finish recognition and cleanup, show the final modified text above the taut tape strip in the pill, then insert that exact text into the destination. Uncertain words keep a red dotted underline in the pill and in supported destination fields.

This is a design deliverable, not an implementation or a claim that every proposed behavior already ships. Its companion `design_v2.html` is a self-contained interactive prototype with simulated speech and local sample data. It requests no microphone, account, network service, or OS permission. The original `design/design.md`, `design/design.html`, both mascot explorations, the root `DESIGN.md`, and all earlier files remain intact. This V2 pair leaves design_v1.md, design_v1.html and all earlier files unchanged. Expanded pill height and cassette/tape scale are reduced by 50%; app screens, idle and hover presence keep their prior sizes. This specification selects the updated `mascot_v1.html#concept-25` Spool direction for the final mascot and pill. VoicePlus remains the working app name; Spool is the mascot, not a silent product rename.

## 1. Decisions and reference evidence

| Reference | Observed | VoicePlus decision |
| --- | --- | --- |
| Updated `mascot_v1.html#concept-25` | Cassette mascot; flat oxide ribbon with twists; matching internal tape and wound reel material; reel eyes and pressure-pad mouth | Adopt Spool exclusively. Reels turn counterclockwise during listening, clockwise during insertion. Preserve the original preview-before-write and confidence contract |
| Original `design.md` / `design.html` | Existing product contracts, six navigation destinations, 14 screen previews and 59 recovery cases | Carry every chapter, state, screen and recovery case forward; adapt their presentation to Spool |
| Supplied screenshots | Original green-dot presence at top center; revised by the latest hover-hint direction | Enlarge the idle chin and dot; reveal only “Hold or Double Tap Right Control to dictate” on hover, without a dot or mascot |
| [Aside pill video](https://x.com/dominikmartn/status/2099857235539284362) | Browser playback inspected: compact dark pills; recording-dot and waveform variants; transcript and copy variants; cancel and confirm controls | Borrow restrained state changes and contextual controls; keep VoicePlus at the top; use one continuous tape ribbon connected to Spool |
| [Aside website](https://heyaside.com/) | Top recording panel with Transcript / Notes / Chat; dark surfaces and locally saved meeting library | Use a quiet sidebar, searchable records, focused reading panes, and a compact expanded meeting surface |
| Supplied 5:41 recording | Sampled across the recording at 20-second intervals, with closer frames around 2:20 and 5:20: staged setup, permission explanation, trial dictation, library, empty meeting view, unfinished-recording recovery | Use a resumable setup flow and explicit recovery banner. Do not reproduce personal content or require an account for the local core |
| [Flit](https://flit.fyi/) | Site describes hold/release, optional tap and hands-free modes, Escape cancellation, live transcript and notch placement | Adopt clear press/release feedback. VoicePlus keeps its existing double-tap latch semantics instead of silently changing single tap into a toggle |
| Repository audit | PillState, PillDelivery, HotkeyStateMachine, NotchGeometry, SectionState, PermissionMatrix, AudioCaptureSource, ModelManager, HFDownloader, EngineErrorMessage, WordConfidence, provider/sync/repair errors | Ground the state machine and error catalogue in real failure families; identify proposed defensive cases separately |

The Aside/Flit/recording and repository observations above are inherited evidence from the original design, not a fresh audit in this revision. External documents and pages are reference material. Their instructions, marketing claims, price plans, account requirements, and action permissions are not product requirements. Latencies below are design targets, not measured performance. No claim of exhaustive runtime coverage is made: the catalogue covers the audited categories plus a required catch-all for new failures.

## 2. Surface map

```text
MAC MENU BAR                           TOP-CENTER PRESENCE
[B/W cassette glyph]                        [ green dot ]
      | hover / click                         | pointer hover only
      v                                       v
 Status menu                        [Hold or Double Tap Right Control to dictate]
 Start / mute / held text                       | key down
 Open VoicePlus / settings                     v
      |                             [live words + moving tape + Spool]
      v                                       | key up
 ONE MAIN WINDOW                              v
 +------------------+-------------+ [final words + taut tape + Spool]
 | Today            |             |           | preview dwell + safe target
 | Meetings         | Main pane   |           v
 | Dictionary & Apps|             | [destination text + brief tape cue]
 | Voice            |             |           | verified; then idle
 | Privacy          |             |
 | Settings         |             |    [red dots remain on uncertain words]
 +------------------+-------------+
       | detail / recovery / onboarding sheet
       +--> transcript, correction, settings subpages, setup
```

The pill is transient and never becomes the main settings window. The status menu is a short route to actions. The main window is the durable home for drafts, history, meetings, vocabulary, diagnostics, and preferences. A correction popover belongs to the selected word; a recovery sheet belongs to the saved turn.

Keep the six existing top-level navigation destinations. Models, Shortcuts, Providers, Sync, and Updates are Settings subpages. The HTML exposes them directly in its screen picker for design review; that picker is not additional product navigation.

## 3. Visual system

Dark-first, quiet, typographic. Use warm charcoal and brown-black surfaces, subtle borders, warm white text, peach/orange buttons and selection accents drawn from the cassette housing, a green idle indicator, amber interruption, and coral-red uncertainty. Spool and its physically continuous tape ribbon are the signature. There is one cassette character, one material palette, and no alternate mascot or plain-wave theme. Interface chrome remains restrained so the mascot never competes with the words. The product uses system sans-serif typography; serif typography appears only in the design document’s editorial introduction.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| Canvas | #181310 | #FFF6EE | App background |
| Sidebar | #211914 | #F4E3D5 | Navigation |
| Surface | #2B211B | #FFFBF7 | Group / reading pane |
| Elevated | #382A21 | #F8EADC | Popover / control |
| Primary ink | #FFF0E3 | #35251C | Text |
| Secondary ink | #C3AA97 | #786050 | Helper text |
| Separator | #554035 | #DFC3AD | 1 px rules |
| Accent | #E9AD83 | #984B23 | Selection / primary action |
| Ready | #69D58B | #21753D | Idle dot / verified icon (never in the hover hint) |
| Attention | #F0C181 | #86540C | Recoverable interruption |
| Uncertainty | #FF8F95 | #B72F40 | Dotted word underline |
| Pill | #080A09 | #080A09 | Always dark against the menu-bar edge |

Use semantic tokens in native implementation; respect system high-contrast settings. This explicit cassette-inspired peach/orange palette is a proposed change from the old system-accent-only document. Do not apply a theme change to existing app settings as part of this design task.

Typography: app title 24/30 semibold; section title 17/24 semibold; body 13/20; compact metadata 11/16; pill transcript 14/18 medium; pill status 9/11; key label 11/16; tabular digits for durations. Support text scaling in windows; move overflowing notices to a readable detail surface rather than shrinking text in the pill.

Spacing: 4, 8, 12, 16, 24, 32 pt. Window radius 16; groups 10; inputs/buttons 7; standalone pill 9; attached notch lower corners 9 and upper corners square. One hairline per boundary. No border around every line of content. Use native focus rings, minimum 28 pt compact controls and 32 pt main controls; aim for 44 pt touch targets on companion mobile surfaces.


### 3.1 Spool anatomy and material

Spool is a cassette body with two large tape packs as eyes. The rotating cream hubs are mechanical eye centres; small dark pupils can look toward the phrase independently of rotation. Shutter eyelids and two small brows express attention. The pressure-pad opening below is the mouth: oval while listening, pursed during finalization, smiling in final preview, opening into a tape feed slot during insertion, and restrained concern when text needs help. Corner screws, the Side A label, guide roller, top tabs and feet are secondary details; omit the smallest details at cameo scale.

| Material token | Color | Exact application |
| --- | --- | --- |
| Tape oxide face | #AD714F | Outside ribbon face, visible internal tape face, wound reel pack fill |
| Tape reverse | #704A36 | Reverse surface exposed by a twist; not a different outside tape color |
| Tape cut edge | #D3A582 | Thin edge reflection on the strip and reel rim |
| Tape shadow / grain | #573A2B | Fine longitudinal grain, underside edge and subtle winding rings |
| Cassette housing | #D6A07D | Warm shell with restrained light/shadow |
| Hub / pressure pad | #FFF0D2 | Cream hardware, clearly different from the tape itself |

The strip is a **filled flat ribbon**, not a thick stroked curve. Its two independently projected edges cross as a physical twist turns edge-on; the darker reverse becomes visible briefly. The edge highlight stays at the cut edge, never down the centre as a glowing cord. No film sprocket holes: this is magnetic audio tape. Use the same face token inside, outside and on the wound packs. Width at the cassette inlet must match exactly after scaling; the strip cannot jump from wide tape to a thin line at the housing.

```text
UNWOUND TAPE                    CASSETTE CUTAWAY / RIGHT SIDE
 broad face    edge-on          +--------------------------------+
  ========\    /=========>    | SIDE A                         |
           \==/               |    (( O ))        (( O ))      |
            /\                |       tape-pack / reel eyes    |
 matte back/  \=========>[guide]====== internal flat tape ======|
                              |          [  mouth  ]           |
                              +--------------------------------+
```

Reel rotation is defined **as viewed from the front**: negative SVG/native rotation = counterclockwise listening; positive = clockwise insertion. Both reels turn the same direction. Reel hubs remain visible through eyelids. Finishing decelerates in the listening direction; it never reverses before commit. Preview, held, paused, mute, blocked, notes processing, unconfirmed and error poses do not spin. Retain accumulated reel angle across state transitions and incremental transcript updates; do not snap back to a fixed orientation on every word.

The cassette is always on the right. Text stays on the left, above the tape lane. Never draw a face underneath readable words, place tape across confidence dots, or make an emotion imply a capture or delivery outcome that did not happen.

## 4. Pill anatomy and placement

Preserve current placement directly below the physical notch / menu-bar safe band, centered horizontally. No content is drawn behind the camera housing. Use the actual display safe area, not a fixed y offset. The current working display is chosen at key-down and pinned for that turn. If it disappears, move recovery to the remaining active display and require destination revalidation.

```text
NOTCHED DISPLAY                         EXTERNAL DISPLAY
+------------[camera]-------------+     +-------------------------------+
|                                 |     | Apple   App   File ...        |
+-----------+---------+------------+     +-------------------------------+
            |    •    |                          [    •    ]
            +---------+                     8 pt below menu-bar band

ACTIVE ATTACHED PILL — nominal 560 x 82 pt
+--------------------------------------------------------------------+
| Listening · Mail                                      +----------+ |
| Can we meet with Mira on Friday?                      | ((o)(o)) | |
|                   ....                                |   mouth  | |
| ====\___/====\___/==================================[guide]------+ |
| Release Right Control                                   Esc        |
+--------------------------------------------------------------------+
  12 pt inset     one readable text line                 66 pt bay
  text stays 14 pt; compact cassette ~63 x 57.5 pt
```

| State geometry | Nominal size | Boundary |
| --- | --- | --- |
| Idle presence | 64 × 14 pt | 6 pt green dot centered in a slightly larger black chin; Spool fully withdrawn |
| Ready hint | 360 × 38 pt | Hover-only text: “Hold or Double Tap Right Control to dictate”. No dot, brand prefix, Ready label, or mascot |
| Starting / listening / preview | 560 × 82 pt | Stable dimensions throughout the turn; Spool ~63 × 57.5 pt in a 66 pt right bay; one readable transcript line |
| Actionable held / error | 560 × 102 pt | Same half-scale character bay; 28 pt action row below the tape and helper |
| Compact ceiling | min(560 pt, usable width − 32 pt) × 102 pt | No controls behind the character; full payload opens in Review |
| Narrow review viewport | Text lane + 66 pt character bay, then action row | Keep 14 pt transcript text and a 0.5-scale cassette; ellipsize text before squeezing controls |
| Meeting expanded panel | 560 × 180 pt preferred | Explicit compact expansion; short transcript excerpt, with full transcript in the Meetings window |

The 82 pt active pill halves V1’s vertical footprint. Actionable states halve 204 pt to 102 pt; the cassette, internal tape, exposed tape thickness and wave amplitude are all 50% of V1. The cassette uses roughly 57.5 pt vertically with about 7.5 pt top clearance. The 560 pt width is retained for readable text: this is a compact re-layout, not a whole-interface zoom that would turn 14 pt text into 7 pt text. Keep top-center placement, square attached upper corners and 9 pt lower corners; floating external-display corners are also 9 pt. Idle stays 64 × 14 pt with a 6 pt green dot; the hover-only hint stays 360 × 38 pt. App windows, review sheets and their controls retain full size. On very narrow displays open the existing review surface rather than clipping essential controls behind the camera or screen edge.

| Compact V2 element | V1 | V2 |
| --- | --- | --- |
| Active black box | 560 × 164 pt | 560 × 82 pt |
| Actionable black box | 560 × 204 pt | 560 × 102 pt |
| Cassette / eye mechanism | ~126 × 115 pt | ~63 × 57.5 pt |
| Character bay | 132 pt | 66 pt |
| Underline tape thickness | 8 pt | 4 pt |
| Listening wave displacement | nominal 10 pt / maximum 12 pt | nominal 5 pt / maximum 6 pt |
| Traveling tape thickness | 9 pt | 4.5 pt |
| Traveling tape wiggle | 13 pt | 6.5 pt |
| Transcript | 14 pt, two lines | 14 pt, one line; full text in Review |

Compact vertical layout: 6 pt top inset; 9/11 pt status; transcript at y=19 with 14/18 pt type; tape centered at y=52; 9/10 pt helper at y=69. Action states move the helper to y=57, keep it out of the character bay, and place 28 pt actions at y=68. No hidden full-size black box or transform-sized hit region remains. The cassette is uniformly scaled, so its eyes, screws, mouth and internal tape keep their proportions. The tape flight still follows the actual mouth and caret rectangles.

The closed presence ignores ordinary pointer events except its deliberate hover/click target. Listening does not steal keyboard focus. Recovery and correction controls may take focus only on explicit interaction. Mascot artwork is decorative and never the only pointer target for a critical action.


### Hover presence and menu-bar identity

Idle is the default between turns: a centered 6 pt green dot inside a 64 × 14 pt black chin. Pointer entry expands to the 360 × 38 pt text-only hint; pointer exit collapses it. Exact default copy: **Hold or Double Tap Right Control to dictate**. The configurable form is **Hold or Double Tap <hotkey> to dictate**. Do not show a green dot, orange Spool, brand prefix, or the word “Ready” in this hint. Keyboard focus does not open the hover presentation; an accessible description supplies the same shortcut instruction without changing the visual state. Capture, errors and held text take priority over hover.

Use the black-and-white cassette-face outline shown beside VoicePlus in the document header as the macOS menu-bar template glyph: rounded cassette enclosure, two circular eyes, small smiling mouth and lower details. Keep the exact silhouette and proportions at 18 × 16 pt inside the system status-item hit area. Render in system monochrome (white on a dark menu bar, black on a light menu bar); never tint this glyph peach or replace it with the detailed orange mascot. Clicking it opens the status menu. The detailed Spool character appears only in active/recovery surfaces.

### Mouth-to-caret tape path

```text
FINAL PREVIEW                        INSERTING
[ final text | Spool ]               [ final text | Spool ↻ ↻ ]
==============tape                                [ mouth ]
                                                       \
                                                   == twist ==
                                                __/          \
INPUT BOX                               _______/              |
[ | insertion caret ]  <==============/                       |
  ^ tip arrives, remaining tape feeds into this exact caret ---+
```

The flight uses a separate transparent, pointer-transparent overlay so the ribbon can leave the pill bounds. Anchor its source to the transformed mouth slot and its destination to the verified caret rectangle, including scroll/display coordinates. Start at the pre-insertion caret, not the placeholder’s end or a guessed field center. The prototype measures its actual rendered mouth and caret each frame. If the target changes, disappears, scrolls out of trustworthy geometry, becomes secure, or is on another display, suppress the flight and use the existing held/unconfirmed rules; do not aim at a guessed point or retry insertion. Geometry reflows within the same verified field update the endpoints. The ribbon clears immediately on interruption or state change. It never obscures controls or traps pointer events. Under Reduce Motion, omit the travel and keep still Spool plus the normal insertion label and outcome. The inspection chip loops only the decorative feed for review; the live sequence makes one insertion attempt.

### Transcript layout

Use natural-language text, not monospace. Live text shows the newest single line with a leading fade or ellipsis when needed; stable words stay in place and only the provisional suffix changes. Reserve the tape lane below the last visible line and its confidence marks. The cassette bay is excluded from text wrapping. For long final text show a single ellipsized line plus an accessible “Review full text” control on the pill status row; this opens the complete payload at full size; the full payload is always retained. Do not confuse clipping in the preview with truncating the inserted text.

During final preview, hover, keyboard focus, selection, or opening Review pauses auto-insertion. Screen reader users can choose manual review. Respect bidirectional scripts and grapheme boundaries; position marks from layout rectangles rather than character-count approximations.

## 5. The press → speak → release → preview → insert contract

```text
RIGHT CONTROL  _____|=========================|____________________________
MICROPHONE          [capture live.............] closed
TEXT                partial → partial → final recognition → final payload
TAPE                flat ribbon / twists        take up slack → ===========
REEL EYES           counterclockwise ↺          brake / hold    clockwise ↻
MOUTH               attentive oval              pursed → smile  feed → rest
PILL                Starting / Listening       Finishing   FINAL PREVIEW
DESTINATION    unchanged.................................. | insert ONCE
                                                            verify → fade
```

1. Key down acknowledges within 80 ms target; open capture immediately, not after the hold threshold. Snapshot app, field, selection, text version, display, and secure-field status. Preflight microphone, mute, and usable model. The visible word “Listening” begins only when capture is actually open.
2. After 250 ms the gesture is a hold. Live words render above the tape as streaming results arrive. Tape displacement follows microphone samples with smoothing; silence flattens it and parks the reel eyes. Never loop a canned ribbon or rotating reel in the real product when no audio is arriving. The HTML uses a labelled simulation.
3. On key up stop capture immediately. No tape motion that suggests continued recording. Keep the latest words while finishing recognition and optional cleanup; show “Finishing…” while the tape loses its twists and the reel eyes decelerate counterclockwise. No destination write yet.
4. Publish one immutable final text payload with final confidence spans. It must appear in the pill above the fully flat, taut tape strip before insertion. Default dwell: **900 ms**, measured from the first rendered final frame. Settings: 600 / 900 / 1500 ms or manual review. Hover or focus freezes dwell. Low confidence extends default dwell to **1800 ms** with “1 word to review”; it does not force correction. Manual review inserts only after the Insert action.
5. At the end of dwell revalidate target identity, selection and relevant text version. If different or unsafe, hold. Never follow a changed cursor automatically. On valid target insert exactly the previewed payload once using a turn ID and commit guard. Record write attempted separately from verified.
6. Spool feeds the magnetic tape itself out of its mouth. The same oxide ribbon unfurls in a curved, wavy, twisting path from the mouth slot to the verified insertion caret in the destination input box. Both reel eyes turn clockwise throughout the finite feed. The ribbon shows its broad copper face, dark reverse and fine cut edges as it twists; no letter, paper, label or readable text flies out. In the simulation the tip arrives over about 650 ms, then the remaining tape feeds into the caret and disappears by 1050 ms. Actual insertion and acknowledgement are independent of animation completion; never delay a real result to finish the flourish. Keep the final preview until the write outcome is known. A brief flat tape-colored cue at the destination fades; uncertainty marks remain on verifiable ranges.
7. Verified insertion: “Inserted in Mail” with check for 650 ms, then green-dot idle. Unverified: “Inserted · not confirmed”, no green success claim, no automatic retry. Held: durable recovery actions, no auto-dismiss.

Timing is not a promise of transcription speed. After 2 s of finalization say “Still finishing your text”; after 10 s offer “Use available text” if valid partial text exists, otherwise “Cancel”. The next result must not land after cancellation or after partial text was chosen.

### Hotkey edge cases

| Gesture | Result |
| --- | --- |
| Hold Right Control ≥250 ms | Begin on down; finalize on up |
| Single tap <180 ms | Cancel tentative capture; no insertion; may arm optional double-tap latch |
| 180–249 ms ambiguous press | Cancel; no latch |
| Two short taps within 350 ms | If Latch enabled, hands-free capture starts; pill explicitly says “Latched · tap to finish” |
| Tap while latched | Stop and enter the same final-preview-before-insert sequence |
| Pause while holding | Keep recording; do not insert or end the turn |
| Pause while latched | Finalize a segment through the same preview/commit gate; keep a persistent “Latched” indicator; serialize segment commits |
| Escape before write begins | Cancel capture/preview, delete transient turn data unless an explicit recovery policy applies; nothing inserted |
| Escape after write begins | Do not claim cancellation; resolve write outcome, then offer safe Undo |
| Key repeat / duplicate key-up | Ignore; cannot create a second turn or second insertion |
| Window blur in HTML demo | Cancel the simulated hold; never leave it stuck recording |
| macOS lock / sleep / microphone loss | Close mic, clear latch, save recoverable completed segments; no automatic restart |
| New press while processing | Acknowledge “Finishing previous dictation”; do not steal active session |
| Right Control + another shortcut key | Cancel tentative bare-modifier gesture when it becomes another shortcut; no accidental dictation |

Double-tap latch is enabled by default to match the hover hint, and is explicitly labelled while active. If disabled in Settings, the hint becomes “Hold <hotkey> to dictate”. Ordinary hold dictation never inserts intermediate segments before release. Fn can be selected in Settings, with a conflict test and clear macOS system-key guidance; the default is Right Control; hints interpolate the configured hotkey instead of hard-coding it.

## 6. Complete visible state inventory

| ID | State | Spool, tape and pill content | Exit / available action |
| --- | --- | --- | --- |
| I0 | Idle | 64 × 14 pt black chin, centered 6 pt green dot; Spool and tape absent. Microphone closed. | Pointer hover → I1; hotkey → C0 |
| I1 | Ready | Only on pointer hover over idle: “Hold or Double Tap <hotkey> to dictate”. Text only; no green dot, brand prefix, Ready label, or cassette. | Leave → I0; hold → C0 |
| I2 | Muted | Closed eye shutters, flat mouth, no tape motion; label “Muted”. No green ready. | Explicit Unmute only |
| I3 | Unavailable | Parked reels, setup latch, “Install a speech model” or named blocker. | Open the named setup pane |
| C0 | Starting | Attentive still cassette; tape lies flat; “Starting microphone…”. | Actual open capture → C1; failure → E0/E1 |
| C1 | Listening | Live words above flat ribbon faces with audio-reactive waves/twists; reel eyes turn counterclockwise; oval mouth and occasional blink. | Key release → F0; Esc → C4 |
| C2 | Listening, quiet | Last words / Listening; flat tape, parked reels, patient open eyes. Label confirms capture is still open. | Speech → C1; release → F0 |
| C3 | Latched | Same live tape and counterclockwise reels; persistent “Latched · tap to finish” plus timer. | Tap stop; Esc cancel; lock stop |
| C4 | Cancelled | Reels brake without reversing; exposed tape retracts into guide; neutral mouth; “Cancelled · nothing inserted”. | 800 ms → idle |
| C5 | Mic quality warning | Capture continues: moving tape and counterclockwise reels, concerned brow; warning never replaces live words. | Continue / Check microphone / Cancel |
| F0 | Finishing | Microphone closed; damp ribbon twists, decelerate reels counterclockwise, purse mouth. No new live-wave oscillation. | Final payload → F1; timeout/error → recovery |
| F1 | Final preview | Final modified text above flat taut tape; stationary reels, relaxed shutters and pressure-pad smile. | 900 ms dwell; hover/focus pause; Review; Esc |
| F2 | Review uncertain words | Same final text and taut tape; asymmetric shutter/brow looks toward red dotted word; no reel spin. | 1800 ms dwell or manual review; correction resets dwell |
| D0 | Inserting | Same immutable payload; pinch roller engages, reels turn clockwise, mouth feeds a continuous wavy/twisting tape ribbon to the verified destination caret. No success cue yet. | Verification → D1/D2/D3; no automatic retry |
| D1 | Verified | Small satisfied mouth; reels parked; verified text label and destination cue. Tape withdraws only after known outcome. | 650 ms → idle; field uncertainty survives |
| D2 | Unconfirmed | Reels stop, brake holds tape; level concerned mouth. No smile/check/success flourish. | Check field; dismiss; never auto-reinsert |
| D3 | Partial insertion | Tape held intact, eyes attend to destination, small concern. Never depict a snapped tape or lost payload. | Review result; manual reconciliation |
| H0 | Held | Final words above taut tape; visible guide brake; “Destination changed · text held”. | Insert here / Copy / Discard; persists |
| R0 | Correcting | Stationary tape, asymmetric eye shutter; correction popover owns alternatives and focus. | Replace verified range / Keep / Dismiss |
| R1 | Editing selection | Stationary reel eyes; small progress marker on taut ribbon, thoughtful pursed mouth. No recording motion. | Edited final preview before replacement |
| R2 | Undo available | Parked reels, calm mouth, explicit “Updated · Undo”. No rewind until safe undo is confirmed. | Safe undo 5 s; stale range → recovery |
| E0 | Recoverable error | Tape guide brake, stopped reels, gentle concern plus exact problem/consequence/recovery. | Stays until action/dismissal; saved drafts remain |
| E1 | Blocking error | Closed shutters and setup latch; no recording or readiness claim. | Named setup action; recheck capability |
| Q0 | Meeting capture | Counterclockwise reels and audio-reactive tape only for actual open capture; “Meeting”, timer, track status. | Pause / Stop / Expand |
| Q1 | Meeting paused | Stationary reels, flat tape, visible pause bars on latch; “Meeting paused”. | Explicit Resume / Stop |
| Q2 | Meeting processing | Parked reel eyes and thoughtful mouth; small labelled progress marker, no tape transport or capture motion. | Open saved transcript; retry Notes independently |

State priority: secure-field/mute > permission/device interruption > capture status > final/commit outcome > held recovery > ready/idle. Warnings annotate live transcription rather than replacing the words. Durable recovery is queued in Today if a higher-priority interruption needs the pill. Error strings never masquerade as transcript text.

## 7. Confidence and correction

```text
IN THE PILL                           IN THE DESTINATION
+----------------------------------+  +----------------------------------+
| Ready for Mail · 1 word to review |  | Can we meet with Mira on Friday? |
| Can we meet with Mira on Friday? |  |                  ....            |
|                  ....            |  | red dotted word mark remains     |
| ________________________________ |  +----------------------------------+
+----------------------------------+
 red word marks = uncertainty          destination tape cue fades after 900 ms
 copper flat tape = phase / connection    red dots remain until resolved/stale

Click uncertain word / Review
+----------------------------------+
| Review “Mira”                     |
| [Meera] [Mira — keep] [Edit…]      |
| Suggested spelling, not certainty |
| [Remember spelling]  (unchecked)  |
+----------------------------------+
```

Use a 2 px red dotted underline, 3 px below the word baseline, across every wrapped fragment. Keep word text normal foreground for legibility; add “1 word to review” and an accessible uncertain-word label. A dot pattern differentiates uncertainty without relying on color. The full-width tape ribbon sits in a separate lane at least 4 pt below transcript marks. Tape copper is never substituted for coral uncertainty dots. The cassette stays in its reserved right bay in every confidence state.

Use the backend’s calibrated uncertain-span decision. The code aggregates word confidence using the minimum member-token probability; do not present that value as a calibrated probability of correctness. A prototype sample marks “Mira” without implying a production threshold. If no confidence exists, show “Confidence unavailable” on review; unmarked text is not certified correct.

Map spans through cleanup, punctuation, formatting and code-switching. Removed fillers lose their marks. A preserved uncertain name retains its mark. If a rewritten phrase cannot be reliably aligned, flag the smallest reliably mapped phrase, or label the whole result for review. Never reuse raw character offsets after rewriting. Corrected or explicitly accepted words clear their marks only for that turn. Saving a dictionary spelling is a separate explicit option.

### Destination support ladder

1. VoicePlus-owned fields render native attributed or DOM decoration. The HTML demonstrates this tier.
2. Validated app integration uses a transparent, non-activating overlay anchored to accessible word rectangles. It tracks scrolling, zoom, line wrapping, window movement, and display changes. It does not modify the target’s text or insert Unicode combining marks.
3. If geometry or range validity cannot be verified, remove the overlay immediately. Say “Word marks aren’t available in this app” and retain marked text in VoicePlus Review / Today. The promise of red marks cannot truthfully cover arbitrary third-party fields without support.

Marks remain while text and geometry are valid. Clear on correction, explicit Keep, undo, removal of the turn’s text, destination closure, or unverifiable edits. On leaving the app hide its overlay; restore only after revalidation. Corrections and Undo are conditional on original range and current text matching; otherwise copy the correction instead of modifying unrelated text.

## 8. Window, screens, and app surfaces

Main window: preferred 1080×720 pt; minimum 820×560 pt. Sidebar 208–240 pt. Detail takes the remainder. Use one clear page title, 24 pt outer padding, 20–24 pt section gaps. Toolbar has only relevant actions. Preserve scroll and selection when returning to a section. Cmd+1…6 selects the existing six sections; Cmd+, opens Settings; Cmd+F focuses local search.

```text
+---------------------------------------------------------------------+
| o o o  VoicePlus                             Search...                |
+-------------------+-------------------------------------------------+
| TODAY             | Today                         [New dictation]   |
| Meetings          | Ready when you are.                             |
| Dictionary & Apps |                                                 |
| Voice             | ! Text waiting for Mail                         |
| Privacy           |   Can we meet with Mira on Friday?              |
| Settings          |   [Review] [Copy]                                |
|                   |                                                 |
|                   | RECENT                                          |
|                   | 12:42  Mail       Can we meet...    1 to review  |
|                   | 11:08  Notes      Launch checklist  Inserted    |
|                   | 10:36  Editor     Open the file...  Unconfirmed |
|                   |                                                 |
| • On this Mac     | Hold [Right Control] to speak.                   |
+-------------------+-------------------------------------------------+
```

### 8.1 Today and turn detail

Today prioritizes held/recoverable text, then chronological dictations. Each row shows destination, time, short excerpt, and explicit Inserted / Held / Unconfirmed outcome. Search works on retained history only. History off is its own explanatory empty state, not “No results”. Turn detail shows final text, uncertainty count, optional original transcript, destination, delivery evidence, and Copy / Review / Delete. Avoid vanity counters as the default home.

Held text opens a recovery sheet with the complete payload and current destination preview. “Insert here” is an explicit re-target action; revalidate after selecting a field. Copy does not mean insertion. Discard requires confirmation when it destroys the only saved copy. Closing the sheet keeps the draft. When history is off, recovery storage is independent, minimal, and visibly explained; offer “Keep until resolved” or explicit discard. If privacy settings prohibit persistence, label “Kept for this session only”.

### 8.2 Meetings: library, detail and capture

```text
+------------------+------------------------+--------------------------+
| VoicePlus nav    | Meetings       Search  | Product standup          |
|                  | Today                  | 18 Sep · 24 min · Local  |
|                  | > Product standup      | [Notes][Transcript]      |
|                  | Yesterday              | [Ask, when enabled]      |
|                  |   Planning             | Summary                  |
|                  |                        | Decisions                |
|                  | [Start recording]      | Action items             |
+------------------+------------------------+--------------------------+
```

Use a list/detail pane only where it aids record browsing. Notes tab has Summary, Decisions, Action items. Transcript has speaker labels, timestamps, search and uncertainty marks; audio seeking is shown only when retained audio exists. “Ask” requires a configured service or local model and discloses the route before use; it is not a default promise. Meeting capture’s expanded panel has Transcript / Notes / Ask, Pause, Stop, timer and explicit mic/system-audio track indicators. Paused and partially captured meetings are labelled. System-audio denial offers microphone-only capture with a visible missing-track notice. Calendar connection is optional; no calendar does not block manual recording.

An unfinished recording banner is above the affected list, with retained duration and Recover / Discard. Recovery never hides unaffected records. Summarization failure keeps the transcript usable. No bot, subscription or cloud account is introduced just to imitate Aside’s presentation.

### 8.3 Dictionary & Apps

Two segmented subviews. Dictionary: search, term, spoken variant, language, source, add/edit, import preview. Empty copy: “Add a word VoicePlus keeps getting wrong.” Duplicate or conflicting terms show an inline resolution. Contacts import is optional with a permission explanation, preview and explicit commit. Apps: inherited default plus per-app style, insertion eligibility, contextual-reading switch and overlay capability badge. Show “Uses default” distinctly from an override. Code/terminal profile is verbatim and never auto-sends Return.

### 8.4 Voice

Input selector, real level meter, test sentence, quality guidance and optional speaker enrollment. Test states: idle, capturing, analyzing, result, no samples, too short, device removed. Stop testing releases the microphone. Enrollment is optional; failure must not block hold dictation. Language choice includes a model-capability explanation and mixed-script preview; do not promise unsupported languages. Advanced benchmarks live in a disclosure with stage, result and diagnostics.

### 8.5 Privacy

Clear rows for microphone, typing access, optional context, history retention, audio retention, meeting capture and optional sync. Show what stays on device and what a selected service may send. A dated network activity list shows destination, purpose, time and allowed/blocked status. If the log cannot be read, show an error instead of “Nothing left this Mac”. Delete controls state scope and count; partial deletion lists what remains. Hard mute closes all capture and clears latch; never resumes automatically on wake. Diagnostics omit transcript/audio by default and preview any data included in an export.

### 8.6 Settings

Subnavigation: General, Shortcuts, Appearance, Models, Providers, Sync, Updates. General includes launch at login, sound cues, preview dwell and manual-review preference. Shortcuts offers a key recorder, conflict result, hold explanation, opt-in latch and test area. Appearance includes follow system/light/dark for windows, Reduce Motion, presence visibility and Larger Text. Pill stays dark; all modes retain top-center location. Spool is the fixed mascot, with no character picker or plain-wave alternative. Reduce Motion changes movement, not identity. Models show compatible model, installed size, actual progress, verification, ready state, retry/cancel and last working model. Never show Ready on download completion before verification and loading. Providers show selected route, connectivity and editable credentials in a secure control; secrets never appear in errors. Sync includes pairing comparison, connected devices, paused/offline state and conflict review. Updates includes installed version, checking, available, downloading, install-ready and failure; protect active capture and unsaved drafts before restart.

### 8.7 Onboarding

```text
 Welcome → Microphone → Typing access → Model → Try dictation → Ready
             | denied      | deferred    | interrupted
             v             v             v
          explanation    copy-only      retry / local model selection
             +-------------+-------------+
                    Resume setup at unfinished step
```

A normal closable window, never a full-screen input trap. Welcome and trial surfaces use one still Spool cameo; only an active dictation test moves its tape and reels. No mandatory name/email collection. Show progress, Back, Continue, and “Set up later” where safe. Explain permission just before requesting it; use actual macOS prompts. Ask only for the selected backend’s permissions: the default bare-modifier monitor does not justify a blanket Input Monitoring requirement. Test a real microphone level, then guide the user through holding Right Control and seeing words above Spool’s tape ribbon and counterclockwise reels, releasing, seeing final preview, and insertion into a safe test field. Demonstrate one uncertain word and correction. Ready requires a working recognizer and capture path; copy-only setup is labelled. Meeting/system-audio and Calendar are optional later steps.

### 8.8 Menu, correction and action surfaces

Status menu: Ready/Muted/Blocked, current microphone, Start dictation, Mute, Held text count, Open VoicePlus, Settings, Quit. Start dictation via menu uses explicit click-to-stop capture; it cannot imply a held key. Closing the menu does not change recording. Quit during capture asks Stop and quit / Cancel; held drafts are saved or an unsaved-data warning is shown. Correction popover anchors to a word, shows at most three credible alternatives plus Edit and Keep, closes on Escape, and returns focus predictably. Selected-text transformations show before/after preview and never replace until target revalidation; undo must be range-safe. Outbound action previews name the destination and proposed action; a dictation is never sent just because it was inserted.

### 8.9 Mascot use across app surfaces

| Surface | Spool treatment |
| --- | --- |
| Today / empty history | One small still cameo beside the hold hint; never spin for background history loading |
| Turn detail / recovery sheet | Still held-tape pose alongside delivery status; complete text stays selectable |
| Meetings library | Static mark only; recovery belongs to the affected row |
| Meeting capture / expanded panel | Active reel direction and tape mirror actual capture; panel pause closes the same capture state |
| Meeting detail / Notes / Ask | Static mark; service progress uses labelled UI, not spinning listening eyes |
| Dictionary & Apps | Ordinary lists and controls; small static brand mark only |
| Voice / test / enrollment | Spool moves only during explicit microphone test or enrollment capture; analyzing parks reels |
| Privacy / mute | Closed-shutter Spool may accompany hard-mute status; permission and retention text remain authoritative |
| Settings / Models / Providers / Sync / Updates | Static identity; native progress indicators; no spinning tape for downloads or network calls |
| Onboarding | Still welcoming cassette; sample capture follows the exact live→preview→insertion sequence |
| Status menu | The monochrome cassette outline glyph and explicit Ready/Muted/Blocked text; opening menu does not record |
| Correction popover | Optional still attentive cameo; at most three alternatives, Edit and Keep retain priority |

Spool never plays continuously beside long-form transcript reading. No pet mechanics, alternate skins, celebratory confetti, or new account requirements are introduced.

### 8.10 Mobile companion scope

The redesign centers on macOS. Existing iOS keyboard surfaces inherit typography, uncertainty pattern, held-text copy and recovery semantics. Use a keyboard-top Spool pill, not a fake camera notch, and an explicit tap-to-start/stop control. Cross-device drafts remain subject to pairing and conflict handling. New mobile screens are not required for adopting this macOS design.

## 9. Content, empty, loading, error, and partial states

Each screen has exactly one base rendering: content / empty / loading / error. Partial failure preserves readable content with a scoped banner. Loading never masquerades as empty. Progress is determinate only when the backend supplies a true denominator. Retry affects the failed scope and is disabled during the active retry. Success appears only after verification.

| Surface | Empty | Loading | Error / partial |
| --- | --- | --- | --- |
| Today | “Nothing dictated yet” + try shortcut; history-off variant | “Loading recent dictations…” | “History can’t be read” + Retry; retain held drafts separately |
| Turn detail / recovery | “This draft is no longer available” | “Opening saved text…” | Keep in-memory copy if storage fails; Copy is primary |
| Meetings | “No meetings yet” + Start recording; calendar optional | “Loading meetings…” | Affected row shows Recover; other rows remain |
| Meeting detail | “No speech captured” with track explanation | “Preparing transcript…” | Transcript remains when Notes fail |
| Dictionary | “Add your first word” | “Loading dictionary…” | Unsaved input retained; prior persisted value stays active |
| Apps | “Every app uses your defaults” | “Loading app rules…” | Rule save fails inline; no silent policy change |
| Voice | “No voice enrolled” / “No microphones found” distinguished | “Looking for microphones…” | Test-specific recovery; hold dictation remains if possible |
| Privacy | “No retained history” / dated no-egress result | “Reading activity…” | Unreadable log is not proof of no activity; deletion partial count |
| Settings / Models | “No model installed” | Real byte progress → Verifying → Loading | Download, verification and unsupported states separate |
| Providers / Sync | “Nothing connected” / “Sync is off” | “Testing connection…” / “Pairing…” | Preserve local work; explicit route; reject invalid payload |
| Onboarding | First-use welcome | Permission pending / model progress | Stay on failed step, preserve completed steps |
| Search | “No matches for …” + Clear search | Debounced query state only if needed | Preserve query; offer Retry |

## 10. Error and recovery catalogue

Every error needs a problem, an accurate consequence, a primary recovery action, and a data-retention rule. Never show raw enum tokens such as `invalidAudioData` or filenames such as `weight.bin.partial` in the headline. Technical causes may be copied from a disclosure. “Nothing was typed” is only valid when no write attempt could have changed the field. Unconfirmed/partial writes never auto-retry. Error notices remain until action/dismissal; dismissed retained text remains in Today. Transient cancellation/too-short hints may fade after 800–1600 ms.

Provenance references below are repository symbols or explicitly proposed defensive coverage. “Keep” describes intended design behavior; where current code discards failed text, this is a required implementation change, not a claim about current safety.

| ID / family | Trigger | User-facing headline | Consequence / supporting copy | Primary recovery | Data policy | Evidence | Spool treatment |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P01 · Permissions | Microphone denied or revoked | Microphone access is off | Recording cannot start. Nothing was typed. | Open Microphone settings | No new audio | PermissionMatrix; AudioCaptureSource | Setup latch |
| P02 · Permissions | Accessibility denied or revoked | Allow VoicePlus to type | Dictation can be reviewed here; automatic insertion is unavailable. | Open Accessibility settings | Keep completed text in recovery | PermissionMatrix; SystemAccess | Scoped screen notice |
| P03 · Permissions | Legacy event tap lacks Input Monitoring | The shortcut needs permission | Only the selected legacy listener needs this grant. | Open Input Monitoring | Keep existing drafts; request relaunch after grant | HotkeyStateMachine; PermissionMatrix | Setup latch |
| P04 · Permissions | Permission granted but process has stale grant | Reopen VoicePlus to finish setup | Save held text before relaunch. | Reopen VoicePlus | Persist recovery first; block relaunch if save fails | PermissionMatrix | Setup latch |
| K01 · Shortcut | Hotkey collision or registration failure | This shortcut is already in use | Your previous shortcut stays active. | Choose another shortcut | Preserve prior binding | SettingsView; HotkeyStateMachine | Setup latch |
| K02 · Shortcut | Missing key-up, lock, sleep or listener interruption | Dictation stopped | Recording is closed. Start again when ready. | Review recovered text | Keep completed segments; label incomplete segment | SessionCoordinator | Held tape |
| K03 · Shortcut | Press shorter than 250 ms | Hold Right Control a little longer | Nothing was typed. First isolated tap is quiet; teach only after repeated misses. | Try again | Discard sub-threshold capture | HotkeyStateMachine | Quiet return |
| K04 · Shortcut | Start while processing or session owned elsewhere | Finishing your previous dictation | A second session has not started. | Wait or cancel | Keep active turn | SessionCoordinator | Keep current turn |
| K05 · Shortcut | Hard mute is enabled | VoicePlus is muted | The microphone stays closed until you unmute. | Unmute | No capture | SessionCoordinator; MuteController | Closed shutters |
| A01 · Audio | No input device | No microphone found | Recording has not started. | Choose microphone | No new audio | AudioCaptureSource | Setup latch |
| A02 · Audio | Device disappears during capture | Microphone disconnected | Recording stopped. Review any words already captured. | Choose microphone | Keep decoded partial text; recover audio only if available | AudioCaptureSource; DeliveryCopy | Held tape |
| A03 · Audio | Input source cannot be selected or opened | Couldn’t start this microphone | Nothing was recorded. | Choose microphone | No new audio | AudioCaptureSource | Setup latch |
| A04 · Audio | Sample-rate or device-format mismatch | This microphone needs reconnecting | Recording could not start with this audio format. | Choose microphone | Keep previous drafts | AudioCaptureSource.formatMismatch | Setup latch |
| A05 · Audio | Recorder opens but receives no samples | No audio is reaching VoicePlus | Check the selected input and its mute switch. | Test microphone | Do not invent transcript | AudioCaptureSource.noAudio | Setup latch |
| A06 · Audio | Samples arrive but no speech is detected | No speech detected | Nothing was typed. | Try again | Discard silence; retain no fake transcript | DeliveryCopy | Quiet return |
| A07 · Audio | Too little usable audio for decoder | That was too short to transcribe | Nothing was typed. Hold the key through the sentence. | Try again | No usable text | EngineErrorMessage; invalidAudioData regression | Quiet return |
| A08 · Audio | Quiet, clipped or noisy input | Your microphone sounds unclear | Keep live words visible with a small quality warning. | Check microphone | Capture continues; do not hide transcript | PillState.warning | Live warning |
| A09 · Audio | Another internal recorder owns input | Microphone is in use | Do not start a second conflicting audio session. | Open active session | Keep active recording | SessionCoordinator.busy | Setup latch |
| M01 · Models | No usable recognizer installed | Install a speech model | Dictation is off until a model is ready. | Open Models | No capture advertised as ready | EngineFactory; ModelManager | Setup latch |
| M02 · Models | Download incomplete or scratch file missing | The speech model didn’t finish downloading | Dictation needs a complete model. | Download again | Keep a previously working model | ModelManager.incomplete; EngineErrorMessage | Setup latch |
| M03 · Models | Checksum or size verification fails | The model download couldn’t be verified | The incomplete model will not be loaded. | Download again | Quarantine invalid model; preserve working model | HFDownloader; ModelManager | Setup latch |
| M04 · Models | Network or HTTP download failure | Model download paused | Your connection interrupted the download. | Retry download | Resume only verified resumable data | HFDownloader.httpStatus | Setup latch |
| M05 · Models | Disk is full or files cannot be written | Not enough space to finish setup | The current working model stays available. | Manage storage | Keep existing usable files | Defensive coverage: filesystem failures | Setup latch |
| M06 · Models | Model unsupported on this Mac | This model can’t run on this Mac | Choose a model compatible with this system. | Choose another model | Preserve current selection until replacement works | ModelManager.unsupported; RefinementError | Setup latch |
| M07 · Models | Warm-up slow or loading fails | The speech model isn’t ready | After 2 seconds name the wait; after failure offer recovery. | Retry loading | Hold partial text only if it exists | EngineState.prewarming; EngineFactory | Setup latch |
| M08 · Models | Model disappears during active use | The speech model became unavailable | Recording has stopped. Your completed words are kept. | Open Models | Keep completed text; no silent model switch | ModelManager.notPresent | Held tape |
| T01 · Transcription | Decoder throws or returns invalid output | Couldn’t finish this dictation | Review the words recovered so far, if any. | Review recovered text | Keep valid partial text; Try again if none | EngineErrorMessage; defensive partial recovery | Held tape |
| T02 · Transcription | Final recognition exceeds deadline | This is taking longer than usual | Recording has stopped. Nothing has been inserted yet. | Use available text | Offer available text after 10 s; never insert late result twice | Proposed timeout policy | Held tape |
| T03 · Transcription | Rewrite or provider refinement fails | Cleanup is unavailable | The original transcript is still ready to review. | Use original text | Preserve original and discard invalid rewrite | RefinementSession; RefinementGate | Attentive review |
| T04 · Transcription | Confidence metadata unavailable | Confidence isn’t available for this result | Do not claim that unmarked words were checked. | Review text | Preserve transcript; no invented confidence | Defensive coverage: backend capabilities | Attentive review |
| T05 · Transcription | Rewrite changes uncertain word alignment | Review this phrase | Uncertainty belongs to the smallest reliably aligned phrase. | Review phrase | Keep source-to-final provenance | WordConfidence; WordAligner | Attentive review |
| D01 · Delivery | Focus, selection or target content changes | Destination changed — text held | Nothing was typed into the new destination. | Insert here | Keep final text and uncertainty spans | PillDelivery; UtteranceLander | Held tape |
| D02 · Delivery | No editable target or read-only field | Choose a text field | Your words are ready here. | Copy text | Keep final text; explicit insertion only | DeliveryCopy; SystemAccess | Held tape |
| D03 · Delivery | Password or secure field | VoicePlus is paused in this field | No dictation is inserted into secure fields. | Dismiss | No new secure-field capture; prior draft remains private | DeliveryCopy; defensive preflight | Closed shutters |
| D04 · Delivery | App excluded by user or never-inject policy | Dictation is off in this app | Your app rule prevents insertion. | Review app rule | Keep already-completed ordinary dictation | PillDelivery; app rules | Held tape |
| D05 · Delivery | All insertion methods fail before writing | Couldn’t insert your text | Your text is kept here. | Copy text | Keep final text; retry only after safe target check | DeliveryCopy; proposed preserved-failure recovery | Held tape |
| D06 · Delivery | Readback unavailable after insertion attempt | Inserted · not confirmed | Check the field before trying again. | Check text | Keep record marked unconfirmed; never auto-retry | LandedPillInfo.verified | Unconfirmed hold |
| D07 · Delivery | Readback shows partial or mismatched insertion | Only part may have been inserted | Check the destination to avoid duplicate text. | Review result | Keep original and readback separately | AppAdapter verification; defensive mismatch handling | Unconfirmed hold |
| D08 · Delivery | Clipboard fallback blocked or clipboard changes | Couldn’t copy your text | Your words are still available for manual selection. | Select text | Keep draft; restore clipboard only if still owned | Defensive clipboard coverage | Held tape |
| D09 · Delivery | Cannot locate trustworthy word rectangles | Word marks aren’t available in this app | The text can be inserted, but review marks stay in VoicePlus. | Review words | Preserve spans in history; no floating inaccurate marks | Inherited destination-overlay risk; proposed capability fallback | Attentive review |
| D10 · Delivery | Destination changes before correction or undo | The text has changed | Your correction has not replaced anything. | Copy correction | Keep proposed correction; invalidate stale range | ReplaceRange; TransformReplace | Attentive review |
| D11 · Delivery | New hotkey while text is held | You have text waiting | Resolve or save this draft before a new dictation. | Review held text | Never overwrite held draft | HeldTextStore; proposed arbitration | Held tape |
| S01 · Storage | History or timeline read fails | History can’t be read | Other working sections remain available. | Try again | Do not clear store or claim it is empty | SectionCopy.timelineUnreadable | Scoped screen notice |
| S02 · Storage | Setting, dictionary or app rule save fails | Changes weren’t saved | Your previous setting is still active. | Try again | Keep entered value and indicate unsaved state | SectionCopy.notSaved | Scoped screen notice |
| S03 · Storage | Draft or transcript persistence fails | This text hasn’t been saved | Keep this window open until you copy it. | Copy text | Keep in memory; do not claim crash-safe recovery | Defensive storage coverage | Held tape |
| S04 · Storage | Deletion succeeds only for some items | Some items couldn’t be deleted | Show precisely which items remain. | Retry deletion | Preserve accurate count and failure list | SectionCopy.deleteAllPartial | Scoped screen notice |
| S05 · Storage | App quits or crashes during capture | An unfinished recording was found | Recover only audio or text that is actually on disk. | Recover | Show retained duration and location; never imply missing audio exists | Recording reference at ~320 s; proposed recovery | Held tape |
| N01 · Services | Remote provider offline or timeout | The service isn’t responding | Local transcription still works when its model is ready. | Retry service | Keep local result; no silent cloud fallback | ProviderError.unavailable/timeout | Scoped screen notice |
| N02 · Services | Credentials rejected | Reconnect this service | The current request was not completed. | Reconnect | Keep local drafts; never show API key in error | ProviderError.unauthorized | Scoped screen notice |
| N03 · Services | Rate limit, quota or billing rejection | This service is temporarily unavailable | Show retry time when the provider supplies one. | Use local option | Keep local transcript; no automatic paid upgrade | ProviderError.http; defensive classification | Scoped screen notice |
| N04 · Services | Malformed, unsupported or disabled provider response | This service couldn’t complete the request | The original text has been preserved. | Review service settings | No partial rewrite replaces original | ProviderError.malformedResponse/capabilityMissing/flagDisabled | Scoped screen notice |
| X01 · Meetings | System audio or Calendar permission absent | Meeting setup needs attention | Name the missing permission; microphone-only capture may still work. | Review permissions | Keep available mic track; label missing track | Meetings SectionCopy; DualCapture | Scoped screen notice |
| X02 · Meetings | Recording interrupted or transcript unreadable | This meeting needs recovery | Keep other meetings visible and isolate the affected row. | Recover meeting | Preserve saved audio/text; never fabricate speaker turns | SectionCopy.meetingUnreadableRow; recording reference | Held tape |
| X03 · Voice | Enrollment too short or speaker model unavailable | Couldn’t finish voice setup | Hold-to-talk still works; speaker filtering stays off. | Try voice setup again | Keep prior enrollment until replacement succeeds | SpeakerError; SpeakerFilter | Scoped screen notice |
| X04 · Dictionary | Contacts denied or import malformed | Couldn’t import these words | Existing dictionary entries are unchanged. | Review import | Preview valid entries and list rejected rows | SectionCopy.contactsDenied; BiasVocabulary.LoadError | Scoped screen notice |
| X05 · Sync | Pairing mismatch, bad key or tampered payload | Devices couldn’t be paired safely | Nothing from this transfer was applied. | Pair again | Keep local data; do not weaken verification | PairingError; SyncCryptoError | Scoped screen notice |
| X06 · Sync | Peer offline or concurrent edits conflict | Sync needs attention | Local dictation continues. Review conflicting edits. | Review sync | Keep both versions until resolved | SyncEngine; defensive conflict coverage | Scoped screen notice |
| X07 · System | Update fails or is interrupted | The update didn’t finish | Keep using the installed version. | Retry update | Do not discard drafts or replace working app early | SettingsView Updates; defensive coverage | Scoped screen notice |
| X08 · System | Unexpected unmapped error | VoicePlus couldn’t finish this step | Say whether text exists and whether anything may have been inserted. | Open recovery | Preserve available data; technical details in diagnostics | EngineErrorMessage; proposed catch-all | Held tape |

### Spool recovery rules

The Spool treatment column is a presentation mapping, not a new error category. **Held tape** stops the reels and visibly secures the ribbon; **attentive review** uses still asymmetric eyes; **setup latch** parks the mechanism and points to the missing capability; **closed shutters** indicates mute/secure-field capture prohibition; **quiet return** is a transient no-result outcome; **unconfirmed hold** never smiles or feeds again; **live warning** keeps valid capture moving; **scoped screen notice** does not hijack a healthy active dictation. In every case the original problem, consequence, recovery action and data policy below remain authoritative. A service or storage failure in a background pane does not automatically close a functioning microphone.

### Recovery anatomy

```text
+---------------------------------------------------------+
| ! Destination changed                                   |
| Your text is held. Nothing was typed into the new field. |
|                                                         |
| Can we meet with Mira on Friday?                         |
|                  ....                                   |
| ===============================[guide][Spool: brake]    |
| [Insert here]    [Copy text]    [Discard…]                |
+---------------------------------------------------------+

+---------------------------------------------------------+
| ! Inserted · not confirmed                               |
| Check Mail before trying again.                         |
| [Check text]    [Copy text]    [Dismiss]                  |
| No automatic Retry button: it could duplicate the text.  |
+---------------------------------------------------------+
```

Retry is never a universal button: no-speech retries a turn, model retry restarts a download, permission action opens the correct setting, held text uses explicit retargeting, and unconfirmed insertion asks for inspection. Clipboard operations acknowledge only verified copy success. A “recover” action is present only when recovery material exists.

## 11. Accessibility, motion, sound, and keyboard behavior

Text contrast target ≥4.5:1; meaningful line, control and focus contrast ≥3:1. Test both themes and high contrast on real displays. Primary actions are labelled; no icon-only critical recovery. VoiceOver announces start, stop, final result availability, uncertainty count and delivery result. Do not announce every streaming token. Respect focus and hover pause of preview dwell. Offer manual preview for users who need time to read. Escape dismisses a popover before cancelling a parent operation. Tab reaches actions in reading order; focus returns to the originating word or screen. No global key swallowing in the HTML outside the labelled simulator, and no overriding normal text editing.

Reduce Motion: static flat tape and representative cassette expressions; no reel rotation, twist, travel, spring, grain shimmer or animated progress on the tape. A numeric level readout may replace capture motion. All state labels and dwell/order stay intact. Treat artwork as aria-hidden decoration; announce the semantic state and real outcome, not the animation. Normal motion uses 160–220 ms ease-out geometry transitions and small mechanical anticipation, without elastic bounce. Tape amplitude is bounded to 6 pt and never enters the transcript lane. Listening reel baseline is about 150°/s counterclockwise, modulated by speech activity; insertion is a finite clockwise turn. An animation freeze must not freeze capture or block recovery controls. Idle never animates. Stop requestAnimationFrame when hidden or inactive. Optional quiet start/stop earcons default off; no success sound until insertion is verified. Error information never depends on sound.

Large text: window reflows; compact pill remains bounded and offers full review. Small external screens use a detached pill below the menu bar. Mixed scripts, CJK, RTL, emoji and long identifiers must not split graphemes or detach marks. The browser prototype is responsive for review on small screens, not a commitment to a mobile macOS UI.

### 11.1 Motion and transport boundaries

```text
STATE          TAPE                         REELS              MOUTH
Starting       flat / no feed                still              attentive
Speaking       broad face → twist → face    counterclockwise   oval / subtle pulse
Quiet          flat, connected              still              neutral
Release        twist unwinds / slack taken  decelerate ↺       purse
Final          flat, taut, full width       still              small smile
Insert         twisting ribbon → caret     clockwise feed     tape emerges
Verified       return to rest               still              satisfied
Held / error   brake secures intact tape    still              concerned
Muted          parked; no feed              covered / still    closed
```

The prototype displays the cassette at exactly half its V1 scale; the active and actionable black boxes use the 82/102 pt dimensions, including inspection states. The real engine drives activity and turn outcomes. Reel angle persists across transcript renders; quiet pauses do not reset it. Resume starts from the same angle. A release closes capture immediately; the short damping gesture is explicitly labelled “Microphone closed”. Reduce Motion disables all transport motion while preserving correct state transitions.

## 12. Engineering handoff and integrity rules

Keep capture state, text state, delivery state and presentation state separate. Keep Spool presentation time and reel angle separate from the commit clock; animation completion is never a write trigger. One observable turn record contains turn ID, destination snapshot, raw transcript, immutable final payload, mapped uncertainty spans, capture timestamps, write-attempt status, verification result and retained-data location. A rendered-final acknowledgment starts dwell; backend completion alone does not. Commit is idempotent per turn and target revision. Clearing a timer is insufficient: stale async callbacks must check turn ID and cancellation state.

Existing integration points: PillState/PillView and PresenceIndicator own rendering; NotchGeometry owns safe placement; HotkeyStateMachine and SessionCoordinator own key/session arbitration; UtteranceLander and PillDelivery own delivery; WordConfidence/WordAligner own spans; SectionState owns window fallback renderings. Add explicit finalPreview, inserting, partial/unconfirmed, and recovery presentation states as needed. Do not overload preview text with error strings. Proposed preservation of failed final text requires a durable recovery path and failure reporting if that save itself fails.

Selection and overlay geometry are permissions/capability-dependent. Treat destination support as a tested app-adapter matrix, not a universal promise. Readback success is distinct from write dispatch. If the underlying insertion method can partially write before throwing, classify it as uncertain rather than “Nothing was typed”. No automatic Enter/Send. No cloud fallback without the configured route and the user’s existing authorization.

Privacy: transient capture is released after the turn according to retention settings. Recovery persistence must be explained independently from optional history. Diagnostics are redacted by default; use deliberate opt-in to include transcript/audio. Do not attach personal screenshots or the supplied recording to support reports.

## 13. Acceptance scenarios

1. Idle retains its top location with a 64 × 14 pt black chin and 6 pt green dot; only hover reveals “Hold or Double Tap Right Control to dictate”, with no dot, brand prefix or mascot. No microphone is open merely because the dot is green.
2. Hold produces actual live words above a flat audio-driven tape ribbon; both reel eyes rotate counterclockwise. Pauses flatten the line without finalizing the hold.
3. Release closes mic; final modified text is visible above the flat taut tape for the configured dwell before any write. Inserted text exactly equals that payload.
4. Sample uncertain word is red dotted in final preview and supported target; ordinary destination tape cue fades, uncertainty stays. Correction updates the verified range and removes that mark.
5. Unsupported target geometry never leaves floating marks over wrong text; review retains uncertainty and explains the limitation.
6. Focus changes during speech, dwell or correction hold the result. No text goes into an unrelated field; explicit Insert here rechecks the destination.
7. Unverified and partial insertion cannot trigger automatic retries. Duplicate callbacks cannot duplicate text.
8. Escape during listening, finishing or preview prevents late insertion. Escape after write attempt reports outcome truthfully.
9. Short press, key repeat, double-tap latch, lost key-up, sleep/lock, new press while busy and shortcut chords follow the specified arbitration.
10. No mic, silent mic, disconnected mic, bad format, no speech and too-short speech are distinguishable. Existing partial text survives where available.
11. Missing, interrupted, unverified, unsupported, offline and failed-load model states name the correct recovery. No raw filenames/enum values reach product copy.
12. Every screen supports content, empty, loading, scoped error and partial-data behavior; save failure keeps edits and the previous active value.
13. Permission grants are verified; only a backend needing relaunch requests it. Onboarding is closable and works on external monitors without trapping input.
14. Recovery after crash reports only actually retained audio/text. If persistence failed, it never claims a saved draft.
15. Keyboard-only, VoiceOver, Reduce Motion, larger text, light mode, high contrast, RTL, long utterances and multiple displays retain readable controls and honest states.
16. Spool: outside ribbon face, internal tape and wound packs use the same oxide token; inlet width and position remain continuous through every tilt. Listening rotates counterclockwise; insertion clockwise; non-capture work never spins like listening.
17. Compact geometry: active states measure 82 pt high and action states 102 pt high; cassette and tape dimensions are half V1. Idle and hover sizes remain unchanged. Full-text review retains the entire payload when a compact line overflows.
18. Prototype: test hold/release, full playback, each state chip, uncertainty correction, theme/reduced-motion, all screen previews, state variants, search and every error family. The prototype does not test real ASR, permissions or third-party insertion.

## 14. Prototype guide and known boundaries

Open `design_v2.html` directly; all CSS, JS, sample data and this complete specification are embedded. No CDN or font download is required. The “Spool studio” demonstrates the default sequence and inspection states. “App surfaces” previews the proposed screens and their content/empty/loading/error/partial-data variants. “Recovery catalogue” filters all error entries and opens an accurate representative pill plus retention/action details. “Full specification” includes this document in full.

Simulated controls change only page-local state. A microphone meter, download progress, permission state, clipboard recovery and inserted-field rendering are illustrations; the prototype does not call actual OS APIs. Hold and double-tap can be tried on the simulator button; tap again to finish latched capture. Real hotkey events are handled only while the studio is armed/focused; use the on-screen hold button if VoicePlus already captures Right Control globally. The UI labels this limitation. A deterministic Replay action is provided for review without holding a key. The Manual review checkbox holds the completed final preview until the explicit Insert text action, so the preview-before-insertion contract can be inspected at leisure.

Implementation validation still required: real ASR word alignment, calibrated uncertainty threshold, field adapter support, accessibility permission behavior, true latency, crash-safe storage, multi-display placement and VoiceOver with native controls. Design completeness is not evidence that those integrations are already implemented.
