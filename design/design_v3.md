# VoicePlus — Spool V3

Design specification · 20 September 2026 · Final mascot direction · Proposed product behavior

**Your voice, wound into words. Spool is the only mascot.** Keep the current top-center presence. While Right Control is held, live text appears above a continuous magnetic-tape ribbon. On release, finish recognition and cleanup, show the final modified text above the taut tape strip in the pill, then insert that exact text into the destination. Uncertain words keep a red dotted underline in the pill and in supported destination fields.

This is a design deliverable, not an implementation or a claim that every proposed behavior already ships. Its companion `design_v3.html` is a self-contained interactive prototype with simulated speech and local sample data. It requests no microphone, account, network service, or OS permission. The original `design/design.md`, `design/design.html`, both mascot explorations, the root `DESIGN.md`, and all earlier files remain intact. This V3 pair carries forward all 26 pill states, 14 app-screen previews, and 59 recovery cases. Earlier design and mascot files are unchanged. App surfaces retain their existing structure; V3 refines the notch, character, reading interaction and delivery animation. This specification selects the updated `mascot_v1.html#concept-25` Spool direction for the final mascot and pill. VoicePlus remains the working app name; Spool is the mascot, not a silent product rename.

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

The pill is transient and never becomes the main settings window. The status menu is a short route to actions. The main window is the durable home for drafts, history, meetings, vocabulary, diagnostics, and preferences. Visible alternatives and inline corrections belong to the selected word; a recovery sheet belongs to the saved turn.

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
| Secondary ink | #C3AA97 | #786050 | App-surface helper text |
| Notch supporting ink | #A19387 | #A19387 | Regular-weight status and right-aligned footer on the always-dark notch |
| Separator | #554035 | #DFC3AD | 1 px rules |
| Accent | #E9AD83 | #984B23 | Selection / primary action |
| Ready | #69D58B | #21753D | Idle dot / verified icon (never in the hover hint) |
| Attention | #F0C181 | #86540C | Recoverable interruption |
| Uncertainty | #FF8F95 | #B72F40 | Dotted word underline |
| Pill | #080A09 | #080A09 | Always dark against the menu-bar edge |

Use semantic tokens in native implementation; respect system high-contrast settings. This explicit cassette-inspired peach/orange palette is a proposed change from the old system-accent-only document. Do not apply a theme change to existing app settings as part of this design task.

Typography: app title 24/30 semibold; section title 17/24 semibold; body 13/20; compact metadata 11/16; pill transcript 13.5/21 regular; pill status 11/14 regular; key label 11/16; tabular digits for durations. Support text scaling in windows; move overflowing notices to a readable detail surface rather than shrinking text in the pill.

Spacing: 4, 8, 12, 16, 24, 32 pt. Window radius 16; groups 10; inputs/buttons 7; standalone pill 18; attached notch lower corners 18 and upper corners square. One hairline per boundary. No border around every line of content. Use native focus rings, minimum 28 pt compact controls and 32 pt main controls; aim for 44 pt touch targets on companion mobile surfaces.


### 3.1 Spool anatomy and material

Spool is a cassette body with two large tape packs as eyes. The rotating cream hubs are mechanical eye centres; small dark pupils can look toward the phrase independently of rotation. Shutter eyelids and two small brows express attention. The pressure-pad opening below is the mouth: oval while listening, pursed during finalization, attentive in final preview and smiling only after verified insertion, opening into a tape feed slot during insertion, following the outgoing ribbon with its gaze, and restrained concern when text needs help. Corner screws, the Side A label, guide roller, top tabs and feet are secondary details; omit the smallest details at cameo scale.

| Material token | Color | Exact application |
| --- | --- | --- |
| Tape oxide face | #AD714F | Outside ribbon face, visible internal tape face, wound reel pack fill |
| Tape reverse | #704A36 | Reverse surface exposed by a twist; not a different outside tape color |
| Tape cut edge | #D3A582 | Thin edge reflection on the strip and reel rim |
| Tape shadow / grain | #573A2B | Fine longitudinal grain, underside edge and subtle winding rings |
| Cassette housing | #D6A07D | Warm shell with restrained light/shadow |
| Hub / pressure pad | #FFF0D2 | Cream hardware, clearly different from the tape itself |

The strip is a **filled flat ribbon**, not a thick stroked curve. Its two independently projected edges cross as a physical twist turns edge-on; the darker reverse becomes visible briefly. The edge highlight stays at the cut edge, never down the centre as a glowing cord. No film sprocket holes: this is magnetic audio tape. Use the same face token inside, outside and on the wound packs. Width at the cassette inlet must match exactly after scaling; the strip cannot jump from wide tape to a thin line at the housing. Listening, internal cassette tape and inserting all use the same shared face/reverse/edge/shadow constants. Both exposed listening tape and initial insertion ribbon are 6.4 pt wide. The earlier appearance difference came from orientation: the listening roll rarely revealed the dark reverse, while insertion did. Compare matching visible faces, not a copper front against an oxide back. The refined listening and flight share the same ribbon renderer, with slightly gentler 2.35-radian notch turns and 2.05-radian flight turns; insertion then flattens to the established 2.4 pt destination underline. No per-state tint or brightness change is applied.

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

Reel rotation is defined **as viewed from the front**: negative SVG/native rotation = counterclockwise listening; positive = clockwise insertion. Both reels turn the same direction. Reel hubs remain visible through eyelids. Finishing decelerates in the listening direction; it never reverses before commit. Preview, held, paused, mute, blocked, notes processing, unconfirmed and error poses do not spin. Retain accumulated reel angle, wave phase, body tilt and mouth interpolation across state transitions and incremental transcript updates; do not snap back to a fixed orientation on every word.

The cassette is always on the right. Text stays on the left, above the tape lane. Never draw a face underneath readable words, place tape across confidence dots, or make an emotion imply a capture or delivery outcome that did not happen.

## 4. Pill anatomy and placement

Keep the text, Spool, tape and footer at their existing positions below the physical camera / menu-bar safe band, centered horizontally. On a built-in camera notch or island display, extend only the black background upward to the display’s top edge across the full current pill width. Fill the exposed areas to the left and right of the hardware camera shape with the same #080A09 black, so the silhouette is attached rather than hanging below it. The prototype adds a 27 pt background-only cap above its existing 160 pt active content box (187 pt overall silhouette). This cap does not add padding, shift content, enlarge the active controls or move the destination. Use the actual hardware safe-band height in native UI. Do not add this cap on an external/unnotched display; preserve its floating rounded pill. No text or control is drawn behind the camera housing. Use the actual display safe area, not a fixed y offset. The current working display is chosen at key-down and pinned for that turn. If it disappears, move recovery to the remaining active display and require destination revalidation.

```text
NOTCHED DISPLAY                         EXTERNAL DISPLAY
+------------[camera]-------------+     +-------------------------------+
|                                 |     | Apple   App   File ...        |
+-----------+---------+------------+     +-------------------------------+
            |    •    |                          [    •    ]
            +---------+                     8 pt below menu-bar band

ACTIVE ATTACHED PILL — nominal 560 x 160 pt
+------------------------------------------------------------+
| Listening · Mail               |  +---------------------+  |
|                                |  | SIDE A              |  |
| Can we meet with Mira          |  |  ((O))       ((O))   |  |
| on Friday?                     |  |   reel eyes  ↺ ↺    |  |
|   .... confidence word dots    |  |                     |  |
| ======\___/====\___/============[guide]====== tape     |  |
|                                |  |     [mouth]         |  |
|                                |  +---------------------+  |
| [Finish dictation]       Tap Right Control to finish        |
+------------------------------------------------------------+
  16 pt inset    readable text       126 pt character bay
                 lane ~390 pt        top/right inset ~18–22 pt
```

| State geometry | Nominal size | Boundary |
| --- | --- | --- |
| Idle presence | 64 × 14 pt | 6 pt green dot centered in a black chin with 6 pt rounding on all four corners; Spool fully withdrawn |
| Ready hint | 360 × 38 pt | Hover-only text: “Hold or Double Tap Right Control to dictate”. No dot, brand prefix, Ready label, or mascot |
| Starting / listening / preview | 560 × 160 pt | Stable dimensions throughout the turn; Spool ~101 × 92 pt (80% of V1) in a reserved right bay |
| Actionable held / error | 560 × 160 pt | Same height and character bay; actions left, supporting copy right in the shared footer |
| Compact ceiling | min(560 pt, usable width − 32 pt) × 160 pt | No controls behind the character; full payload scrolls within the notch |
| Narrow review viewport | Text lane + 84 pt cameo bay, then action row | At narrow widths keep 13.5/21 pt text, reduce ornament scale; do not shrink the whole product to illegible type |
| Meeting expanded panel | 560 × 360 pt preferred | Explicit expansion; static compact cassette in the header, readable transcript below |

All compact active states are 160 pt tall, including states with no buttons. Reserve the same 32 pt footer slot throughout, so actions never change the height. Use 13.5/21 pt regular transcript type, 0.5 pt smaller than the earlier V3. Spool retains its 80% scale (~101 × 92 pt), with a 6.4 pt tape face. The transcript viewport is 48 pt tall: two complete 21 pt line boxes plus 3 pt clearance above and below. A single line is lowered by 10.5 pt to sit between the status row and ribbon; wrapped text starts at the top of the viewport. Tape centreline is at approximately y=98 pt and cassette centre y=76 pt. Character top/right clearance remains at least about 20 pt through its subtle tilt. Long transcripts keep the same two-line reading window and scroll; there is no transcript expansion or maximize state. The narrow browser preview reserves a 66 pt two-row footer for every active state (194 pt base height), rather than changing height when buttons appear. Keep stable geometry through capture, finishing and preview; scrolling never changes that geometry. Use two neutral shadows: a near edge at 0/4/12 pt and 22% black, plus a soft lower shadow at 0/18/40 pt and 28% black. The top remains visually attached to the camera housing. No orange glow. This remains a proposed native geometry change.

The closed presence ignores ordinary pointer events except its deliberate hover/click target. Listening does not steal keyboard focus. Recovery and correction controls may take focus only on explicit interaction. Mascot artwork is decorative and never the only pointer target for a critical action.


### Hover presence and menu-bar identity

Idle is the default between turns: a centered 6 pt green dot inside a 64 × 14 pt black chin, rounded on all four corners. The tiny idle state has no upward background cap. Pointer entry expands to the 360 × 38 pt text-only hint; pointer exit collapses it. Exact default copy: **Hold or Double Tap Right Control to dictate**. The configurable form is **Hold or Double Tap <hotkey> to dictate**. Do not show a green dot, orange Spool, brand prefix, or the word “Ready” in this hint. Keyboard focus does not open the hover presentation; an accessible description supplies the same shortcut instruction without changing the visual state. Capture, errors and held text take priority over hover.

Use the black-and-white cassette-face outline shown beside VoicePlus in the document header as the macOS menu-bar template glyph: rounded cassette enclosure, two circular eyes, small smiling mouth and lower details. Keep the exact silhouette and proportions at 18 × 16 pt inside the system status-item hit area. Render in system monochrome (white on a dark menu bar, black on a light menu bar); never tint this glyph peach or replace it with the detailed orange mascot. Clicking it opens the status menu. The detailed Spool character appears only in active/recovery surfaces.

### Continuous tape handoff

```text
PREVIEW             TRANSFER                     VERIFIED LANDING
final words         Spool mouth opens            text already inserted
=========[Spool]                 \
                                  \__             first text line
                                      \==========----------------
                                      /            second text line
                                     +============--------
                                      twists settle → thin copper underlines
```

One material moves through the entire sequence. The tape leaves the pressure-pad mouth, flies to the first inserted line, travels horizontally below that line, wraps to the next line, and traces every visible inserted line. The trailing connection feeds from Spool and disappears as the laid-down ribbon becomes a flat 2.4 pt underline. Match actual text-line widths; never draw a full-width box decoration. Keep the oxide face color, reverse, and cut edge through the morph, reducing texture and thickness gradually. Red confidence dots remain separate from the copper line and survive its fade.

Measure the destination text’s rendered line fragments after the insertion transaction, merging same-baseline fragments around styled/uncertain words. This gives the real wrapping, including mixed fonts and uncertain-word spans. The decoration must not delay insertion or readback acknowledgement: text appears when inserted, not when a cartoon reaches it. In the simulation acknowledgement occurs at 140 ms, while the decorative flight continues independently for about 1300 ms. The source then settles and collapses after its short verified hold. Show no settled underline for unconfirmed/partial delivery.

Motion phases: 0–480 ms travel from mouth to first line; approximately 420–940 ms trace text baselines in reading order; 780–1200 ms consume the mouth connection; 880–1300 ms unwind the twist and flatten to 2.4 pt. Continue with the exact same line geometry as a 1-second fading underline, with no jump or second line appearing elsewhere. These are design targets, not measured native timing. Inspection loops are explicitly labelled and never insert text.

The flight is a separate transparent, pointer-transparent overlay. Anchor its source to the transformed mouth, and destinations to verified line rectangles. If geometry changes unexpectedly, verification fails, target becomes secure, or trustworthy rectangles disappear, suppress decoration and use held/unconfirmed recovery. Never paint guessed marks or retry a write. For extremely long text, animate only visible verified lines and retain the entire payload; do not scroll another app merely for decoration. RTL follows actual visual line direction; the browser sample demonstrates LTR only. Reduce Motion omits flight and uses still Spool, immediate normal result labels, and a static destination cue that is removed without animated travel.

### Long text: scroll inside the fixed notch

The transcript is a real, focusable scroll viewport inside the notch. Its 48 pt height shows two complete 21 pt line boxes with 3 pt padding above and below. There is no text-length limit: trackpad/wheel, keyboard navigation and the scroll rail reach the complete transcript. A short single line remains vertically centered. The notch, cassette, ribbon and footer stay in place while text scrolls.

When text overflows, show a slim 16 pt-wide control rail immediately to the right of the text lane: an upward chevron, a narrow copper-brown track/thumb, and a downward chevron. The top arrow is available only when earlier text exists; the bottom arrow only when more text exists. Hide the unavailable arrow while retaining its slot so nothing shifts. Clicking an arrow moves one 21 pt line; dragging the thumb or clicking the track changes position directly. Arrow keys, Page Up/Down and Home/End work on the focusable scrollbar and the text viewport. Expose its position and controlled transcript to assistive technology. All deliberate reading interactions pause automatic insertion. Hide the entire rail when no scrolling is needed. Edge hints sit outside the text and never obscure glyphs or red confidence dots.

Remove the diagonal maximize arrow, **See full text**, **Collapse text**, six-line mode and content-sized expansion. No alternate enlarged transcript view opens from this notch. The scrollable content can be any length; the visible window remains two lines.

Streaming follows the newest words only while the user is following live output. Scrolling up or using reading keys pauses that following behavior; new words do not pull the reader away. Final preview opens at the beginning. Entering the notch area pauses automatic insertion, including when the user scrolls, selects a visible suggestion or edits. Leaving the notch applies completed edits and resumes the remaining countdown automatically; there is no sticky “Insert now required” reading state. Ignore leftover mouse-acquired focus on a scrollbar/button after pointer exit. Keyboard-only reading/editing pauses while focus is in the notch and resumes on leaving it. A minimum 150 ms remainder avoids an instantaneous write at the exit edge. Manual review, an empty draft, an unfinished IME composition, and a hidden app remain paused. Finish composition before committing text. Manual review still requires Insert now.

The default final preview is a fixed **600 ms** for every transcript, independent of word count and confidence. It is a brief visual handoff, not proofreading time. The setting supports 600 ms, 1200 ms, or Manual review; the HTML settings control is connected to playback. A quiet button shows **Insert in 0.6s** while running and **Insert now** while paused; pointer pause says **Paused · move away to insert**. A correction starts a fresh selected preview delay while the pointer remains inside; exit resumes it. Recognition/finalization time is separate. No automatic 1.8-second uncertainty penalty or 10-second paragraph delay remains.

### Footer and correction placement

Use one compact footer with **actions on the left** and **supporting text right-aligned below Spool**. Keep a 32 pt reserved row with or without buttons. Bottom-align the helper text box and the button boxes; both have the same 12 pt padding to the notch’s bottom. Do not align helper text to the button-label baseline or vertically center it against the button. Helper type is 11/16 pt regular in muted #A19387; status text uses the same subdued ink at 11/14 pt regular. Keep transcript contrast strong, and use restrained semantic amber for warnings. Buttons stay 11 pt with at least 30 pt height. A primary peach action sits next to a quiet secondary action; Dismiss and Discard do not compete with recovery. Example: “Check the field before trying again” alongside **Check destination** and **Dismiss**. Hands-free capture pairs its stop instruction with **Finish dictation**. At narrow widths use a consistent two-row footer reservation for all active states: left-aligned buttons first, right-aligned supporting copy second. Do not let only button-bearing states grow.

Show the alternative immediately beside the red dotted word, in red text and red brackets: **Mira [or did you mean Meera]**. The original word remains normal foreground with its dotted underline; the bracket and proposed spelling are red. No click is needed to discover the suggestion and no correction form opens. Clicking the proposed spelling applies it. Clicking the original word lets the user type its replacement in place; Enter or leaving the editor applies it, Escape cancels. Show the same annotation beside the word in the simulated destination and supported native fields. Only provide credible suggestions; if none exist, retain the mark and direct editing without inventing an alternative.

**Edit draft** makes the existing notch transcript editable, with the same two-line scrollable geometry, without another window or expansion. The draft can be selected, pasted into and edited across multiple lines. Done or Cmd/Ctrl+Enter applies edits; Escape or Cancel edits restores the prior draft. Moving the pointer out also applies nonempty completed edits and resumes automatic insertion in an active dictation. Held/error drafts remain held until an explicit delivery action. An empty draft is kept editable and never inserted. Insert actions cannot bypass an active editor or unfinished composition and send the previous draft. Editing uses plain transcript text, with suggestion annotations removed from the editing buffer. Recompute confidence alignment after an edit; preserve unmodified uncertain words and clear corrected spans. Freeze the final edited payload only when insertion begins.

Learn committed corrections automatically. No dictionary checkbox, Save action, confirmation or routine success toast is part of correction. Learning happens quietly; the Dictionary screen reflects the saved terms. The prototype automatically adds newly introduced lexical terms to its learned dictionary and stores them in browser-local storage; it does not save punctuation changes, canceled edits or the suggestion annotation. This is vocabulary learning, not a rule to replace one ordinary word with another everywhere. The Dictionary screen shows learned entries for inspection; native implementation must allow later management/removal. If persistence fails, keep the correction and report that the learned entry is session-only. Native alignment can identify proper names, spelling and pronunciation corrections more accurately than the prototype’s token comparison.

Red brackets are a presentation annotation, never part of the inserted text, clipboard payload, dictionary entry, or model prompt. VoicePlus-owned fields can render inline annotations; external integrations need trustworthy ranges and decoration support. Never literally inject “[or did you mean …]” into someone’s email or document to simulate that UI. If the app cannot position a suggestion reliably, keep it in VoicePlus instead. Replacing text after insertion requires a matching, still-valid target range.

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
4. Publish the final preview with confidence spans. It appears above the taut tape before insertion. Use a 600 ms default dwell, identical for short/long and confident/uncertain text. Hover pauses; leaving resumes. Edit draft enables in-notch editing and the edited revision becomes the immutable payload at commit. Manual review waits for Insert now. Settings can select 1200 ms or Manual review; no word-count scaling applies.
5. At the end of dwell revalidate target identity, selection and relevant text version. If different or unsafe, hold. Never follow a changed cursor automatically. On valid target insert exactly the previewed payload once using a turn ID and commit guard. Record write attempted separately from verified.
6. Spool feeds the tape itself through the mouth, along the actual inserted text-line baselines, then flattens it into matching copper underline segments. Both reel eyes turn clockwise during the feed. Continue the same geometry and material through the inserted state. Delivery acknowledgement remains independent of animation; the flourish cannot trigger a write or postpone a real result. See the continuous handoff contract above.
7. Verified insertion: “Inserted in Mail” with check through the finite handoff and brief settled hold, then green-dot idle. Unverified: “Couldn’t confirm insertion”, no green success claim, no automatic retry. Held: durable recovery actions, no auto-dismiss.

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
| I2 | Muted | Resting closed shutters, flat mouth, no tape motion; voluntary “Muted” state is distinct from blocked setup. No green-ready claim. | Explicit Unmute only |
| I3 | Unavailable | Parked reels, setup latch, “Install a speech model” or named blocker. | Open the named setup pane |
| C0 | Starting | Attentive still cassette; tape lies flat; “Starting microphone…”. | Actual open capture → C1; failure → E0/E1 |
| C1 | Listening | Live words above flat ribbon faces with audio-reactive waves/twists; reel eyes turn counterclockwise; oval mouth and occasional blink. | Key release → F0; Esc → C4 |
| C2 | Listening, quiet | Last words / Listening; flat tape, parked reels, patient open eyes. Label confirms capture is still open. | Speech → C1; release → F0 |
| C3 | Latched | Same live tape and counterclockwise reels; persistent “Latched · tap to finish” plus timer. | Tap stop; Esc cancel; lock stop |
| C4 | Cancelled | Reels brake without reversing; exposed tape retracts into guide; neutral mouth; “Cancelled · nothing inserted”. | 800 ms → idle |
| C5 | Mic quality warning | Capture continues: moving tape and counterclockwise reels, concerned brow; warning never replaces live words. | Continue / Check microphone / Cancel |
| F0 | Finishing | Microphone closed; damp ribbon twists, decelerate reels counterclockwise, purse mouth. Continue the current wave phase while its amplitude damps; no snap to a different waveform. | Final payload → F1; timeout/error → recovery |
| F1 | Final preview | Final modified text above taut tape; stationary reels, attentive shutters and restrained mouth. Stronger satisfaction is reserved for verified delivery. | 600 ms default; hover pauses, exit resumes; Edit draft; Esc |
| F2 | Review uncertain words | Same final text and taut tape; asymmetric shutter/brow looks toward the red dotted word and visible red [or did you mean …] annotation; no reel spin. | 600 ms default or manual review; visible alternatives; inline correction; exit resumes |
| D0 | Inserting | Same immutable payload; pinch roller engages, reels turn clockwise, mouth feeds a continuous wavy/twisting tape ribbon along verified destination text lines, settling into exact-width underlines. No success cue yet. | Verification → D1/D2/D3; no automatic retry |
| D1 | Verified | Verified label appears on acknowledgement; clockwise feed completes, tape settles into text-width underlines, mouth relaxes into a small satisfied smile, then reels park. | 650 ms → idle; field uncertainty survives |
| D2 | Unconfirmed | Reels stop, brake holds tape; level concerned mouth. No smile/check/success flourish. | Check field; dismiss; never auto-reinsert |
| D3 | Partial insertion | Tape held intact, eyes attend to destination, small concern. Never depict a snapped tape or lost payload. | Review result; manual reconciliation |
| H0 | Held | Final words above taut tape; visible guide brake; “Destination changed · text held”. | Insert here / Copy / Discard; persists |
| R0 | Correcting | Stationary tape, asymmetric eye shutter; visible red alternatives and direct word editing keep the correction in context. | Choose alternative / Type replacement / Escape to cancel |
| R1 | Editing selection | Stationary reel eyes; small progress marker on taut ribbon, thoughtful pursed mouth. No recording motion. | Edited final preview before replacement |
| R2 | Undo available | Parked reels, calm mouth, explicit “Updated · Undo”. No rewind until safe undo is confirmed. | Safe undo 5 s; stale range → recovery |
| E0 | Recoverable error | Tape guide brake, stopped reels, gentle concern plus exact problem/consequence/recovery. | Stays until action/dismissal; saved drafts remain |
| E1 | Blocking error | Alert open reel eyes, raised brow and setup latch; no recording or readiness claim. Visually distinct from voluntary mute. | Named setup action; recheck capability |
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
INLINE WORD CORRECTION — visible before any click
Can we meet with Mira [or did you mean Meera] on Friday?
                 ....                 ^ click to accept
                 ^ click to edit the word in place

[Edit draft] → the same notch text becomes editable
[Done] [Cancel edits]             leave notch → resume
Dictionary learns accepted corrections automatically.
```

Use a 2 px red dotted underline, 3 px below the word baseline, across every wrapped fragment. Keep word text normal foreground for legibility; add “1 word to review” and an accessible uncertain-word label. A dot pattern differentiates uncertainty without relying on color. The full-width tape ribbon sits in a separate lane at least 8 pt below transcript marks. Tape copper is never substituted for coral uncertainty dots. The cassette stays in its reserved right bay in every confidence state.

Use the backend’s calibrated uncertain-span decision. The code aggregates word confidence using the minimum member-token probability; do not present that value as a calibrated probability of correctness. A prototype sample marks “Mira” without implying a production threshold. If no confidence exists, show “Confidence unavailable” on review; unmarked text is not certified correct.

Map spans through cleanup, punctuation, formatting and code-switching. Removed fillers lose their marks. A preserved uncertain name retains its mark. If a rewritten phrase cannot be reliably aligned, flag the smallest reliably mapped phrase, or label the whole result for review. Never reuse raw character offsets after rewriting. Corrected or explicitly accepted words clear their marks only for that turn. Committed corrections automatically update the learned dictionary; no separate save step appears.

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

Status menu: Ready/Muted/Blocked, current microphone, Start dictation, Mute, Held text count, Open VoicePlus, Settings, Quit. Start dictation via menu uses explicit click-to-stop capture; it cannot imply a held key. Closing the menu does not change recording. Quit during capture asks Stop and quit / Cancel; held drafts are saved or an unsaved-data warning is shown. Corrections stay inline: visible red bracketed alternatives are immediately actionable; clicking the original word enables direct editing. Escape cancels that edit and returns focus predictably. Selected-text transformations show before/after preview and never replace until target revalidation; undo must be range-safe. Outbound action previews name the destination and proposed action; a dictation is never sent just because it was inserted.

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
| Inline correction | Still attentive cassette; visible alternatives and the editable word retain priority |

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
| P03 · Permissions | Legacy event tap lacks Input Monitoring | The shortcut needs permission | Your shortcut won’t work until Input Monitoring is allowed. | Open Input Monitoring | Keep existing drafts; request relaunch after grant | HotkeyStateMachine; PermissionMatrix | Setup latch |
| P04 · Permissions | Permission granted but process has stale grant | Reopen VoicePlus to finish setup | The new permission takes effect after VoicePlus reopens. | Reopen VoicePlus | Persist recovery first; block relaunch if save fails | PermissionMatrix | Setup latch |
| K01 · Shortcut | Hotkey collision or registration failure | This shortcut is already in use | Your previous shortcut stays active. | Choose another shortcut | Preserve prior binding | SettingsView; HotkeyStateMachine | Setup latch |
| K02 · Shortcut | Missing key-up, lock, sleep or listener interruption | Dictation stopped | Recording is closed. Start again when ready. | Review recovered text | Keep completed segments; label incomplete segment | SessionCoordinator | Held tape |
| K03 · Shortcut | Press shorter than 250 ms | Hold Right Control a little longer | Nothing was typed. | Try again | Discard sub-threshold capture | HotkeyStateMachine | Quiet return |
| K04 · Shortcut | Start while processing or session owned elsewhere | Finishing your previous dictation | A second session has not started. | Wait or cancel | Keep active turn | SessionCoordinator | Keep current turn |
| K05 · Shortcut | Hard mute is enabled | VoicePlus is muted | The microphone stays closed until you unmute. | Unmute | No capture | SessionCoordinator; MuteController | Closed shutters |
| A01 · Audio | No input device | No microphone found | Recording has not started. | Choose microphone | No new audio | AudioCaptureSource | Setup latch |
| A02 · Audio | Device disappears during capture | Microphone disconnected | Recording stopped. Review any words already captured. | Choose microphone | Keep decoded partial text; recover audio only if available | AudioCaptureSource; DeliveryCopy | Held tape |
| A03 · Audio | Input source cannot be selected or opened | Couldn’t start this microphone | Nothing was recorded. | Choose microphone | No new audio | AudioCaptureSource | Setup latch |
| A04 · Audio | Sample-rate or device-format mismatch | This microphone needs reconnecting | Recording could not start with this audio format. | Choose microphone | Keep previous drafts | AudioCaptureSource.formatMismatch | Setup latch |
| A05 · Audio | Recorder opens but receives no samples | No audio is reaching VoicePlus | Check the selected input and its mute switch. | Test microphone | Do not invent transcript | AudioCaptureSource.noAudio | Setup latch |
| A06 · Audio | Samples arrive but no speech is detected | No speech detected | Nothing was typed. | Try again | Discard silence; retain no fake transcript | DeliveryCopy | Quiet return |
| A07 · Audio | Too little usable audio for decoder | That was too short to transcribe | Nothing was typed. Hold the key through the sentence. | Try again | No usable text | EngineErrorMessage; invalidAudioData regression | Quiet return |
| A08 · Audio | Quiet, clipped or noisy input | Your microphone sounds unclear | VoicePlus may miss some of your words. | Check microphone | Capture continues; do not hide transcript | PillState.warning | Live warning |
| A09 · Audio | Another internal recorder owns input | Microphone is in use | Another recording is using it right now. | Open active session | Keep active recording | SessionCoordinator.busy | Setup latch |
| M01 · Models | No usable recognizer installed | Install a speech model | Dictation is off until a model is ready. | Open Models | No capture advertised as ready | EngineFactory; ModelManager | Setup latch |
| M02 · Models | Download incomplete or scratch file missing | The speech model didn’t finish downloading | Dictation needs a complete model. | Download again | Keep a previously working model | ModelManager.incomplete; EngineErrorMessage | Setup latch |
| M03 · Models | Checksum or size verification fails | The model download couldn’t be verified | The incomplete model will not be loaded. | Download again | Quarantine invalid model; preserve working model | HFDownloader; ModelManager | Setup latch |
| M04 · Models | Network or HTTP download failure | Model download paused | Your connection interrupted the download. | Retry download | Resume only verified resumable data | HFDownloader.httpStatus | Setup latch |
| M05 · Models | Disk is full or files cannot be written | Not enough space to finish setup | The current working model stays available. | Manage storage | Keep existing usable files | Defensive coverage: filesystem failures | Setup latch |
| M06 · Models | Model unsupported on this Mac | This model can’t run on this Mac | Choose a model compatible with this system. | Choose another model | Preserve current selection until replacement works | ModelManager.unsupported; RefinementError | Setup latch |
| M07 · Models | Warm-up slow or loading fails | The speech model isn’t ready | The model is installed but hasn’t finished loading. | Retry loading | Hold partial text only if it exists | EngineState.prewarming; EngineFactory | Setup latch |
| M08 · Models | Model disappears during active use | The speech model became unavailable | Recording has stopped. Your completed words are kept. | Open Models | Keep completed text; no silent model switch | ModelManager.notPresent | Held tape |
| T01 · Transcription | Decoder throws or returns invalid output | Couldn’t finish this dictation | Review the words recovered so far, if any. | Review recovered text | Keep valid partial text; Try again if none | EngineErrorMessage; defensive partial recovery | Held tape |
| T02 · Transcription | Final recognition exceeds deadline | This is taking longer than usual | Recording has stopped. Nothing has been inserted yet. | Use available text | Offer available text after 10 s; never insert late result twice | Proposed timeout policy | Held tape |
| T03 · Transcription | Rewrite or provider refinement fails | Cleanup is unavailable | The original transcript is still ready to review. | Use original text | Preserve original and discard invalid rewrite | RefinementSession; RefinementGate | Attentive review |
| T04 · Transcription | Confidence metadata unavailable | Confidence isn’t available for this result | Unmarked words haven’t been checked. | Review text | Preserve transcript; no invented confidence | Defensive coverage: backend capabilities | Attentive review |
| T05 · Transcription | Rewrite changes uncertain word alignment | Review this phrase | VoicePlus isn’t sure about part of this phrase. | Review phrase | Keep source-to-final provenance | WordConfidence; WordAligner | Attentive review |
| D01 · Delivery | Focus, selection or target content changes | Destination changed — text held | Nothing was typed into the new destination. | Insert here | Keep final text and uncertainty spans | PillDelivery; UtteranceLander | Held tape |
| D02 · Delivery | No editable target or read-only field | Choose a text field | Your words are ready here. | Copy text | Keep final text; explicit insertion only | DeliveryCopy; SystemAccess | Held tape |
| D03 · Delivery | Password or secure field | VoicePlus is paused in this field | No dictation is inserted into secure fields. | Dismiss | No new secure-field capture; prior draft remains private | DeliveryCopy; defensive preflight | Closed shutters |
| D04 · Delivery | App excluded by user or never-inject policy | Dictation is off in this app | Your app rule prevents insertion. | Review app rule | Keep already-completed ordinary dictation | PillDelivery; app rules | Held tape |
| D05 · Delivery | All insertion methods fail before writing | Couldn’t insert your text | Your text is kept here. | Copy text | Keep final text; retry only after safe target check | DeliveryCopy; proposed preserved-failure recovery | Held tape |
| D06 · Delivery | Readback unavailable after insertion attempt | Couldn’t confirm insertion | Check the field before trying again. | Check destination | Keep record marked unconfirmed; never auto-retry | LandedPillInfo.verified | Unconfirmed hold |
| D07 · Delivery | Readback shows partial or mismatched insertion | Only part may have been inserted | Check the destination to avoid duplicate text. | Review result | Keep original and readback separately | AppAdapter verification; defensive mismatch handling | Unconfirmed hold |
| D08 · Delivery | Clipboard fallback blocked or clipboard changes | Couldn’t copy your text | Your words are still available for manual selection. | Select text | Keep draft; restore clipboard only if still owned | Defensive clipboard coverage | Held tape |
| D09 · Delivery | Cannot locate trustworthy word rectangles | Word marks aren’t available in this app | The text can be inserted, but review marks stay in VoicePlus. | Review words | Preserve spans in history; no floating inaccurate marks | Inherited destination-overlay risk; proposed capability fallback | Attentive review |
| D10 · Delivery | Destination changes before correction or undo | The text has changed | Your correction has not replaced anything. | Copy correction | Keep proposed correction; invalidate stale range | ReplaceRange; TransformReplace | Attentive review |
| D11 · Delivery | New hotkey while text is held | You have text waiting | Resolve or save this draft before a new dictation. | Review held text | Never overwrite held draft | HeldTextStore; proposed arbitration | Held tape |
| S01 · Storage | History or timeline read fails | History can’t be read | Other working sections remain available. | Try again | Do not clear store or claim it is empty | SectionCopy.timelineUnreadable | Scoped screen notice |
| S02 · Storage | Setting, dictionary or app rule save fails | Changes weren’t saved | Your previous setting is still active. | Try again | Keep entered value and indicate unsaved state | SectionCopy.notSaved | Scoped screen notice |
| S03 · Storage | Draft or transcript persistence fails | This text hasn’t been saved | Keep this window open until you copy it. | Copy text | Keep in memory; do not claim crash-safe recovery | Defensive storage coverage | Held tape |
| S04 · Storage | Deletion succeeds only for some items | Some items couldn’t be deleted | The other items were deleted. | Retry deletion | Preserve accurate count and failure list | SectionCopy.deleteAllPartial | Scoped screen notice |
| S05 · Storage | App quits or crashes during capture | An unfinished recording was found | Only what was saved before VoicePlus closed can be recovered. | Recover | Show retained duration and location; never imply missing audio exists | Recording reference at ~320 s; proposed recovery | Held tape |
| N01 · Services | Remote provider offline or timeout | The service isn’t responding | Local transcription still works when its model is ready. | Retry service | Keep local result; no silent cloud fallback | ProviderError.unavailable/timeout | Scoped screen notice |
| N02 · Services | Credentials rejected | Reconnect this service | The current request was not completed. | Reconnect | Keep local drafts; never show API key in error | ProviderError.unauthorized | Scoped screen notice |
| N03 · Services | Rate limit, quota or billing rejection | This service is temporarily unavailable | The provider isn’t accepting requests right now. | Use local option | Keep local transcript; no automatic paid upgrade | ProviderError.http; defensive classification | Scoped screen notice |
| N04 · Services | Malformed, unsupported or disabled provider response | This service couldn’t complete the request | The original text has been preserved. | Review service settings | No partial rewrite replaces original | ProviderError.malformedResponse/capabilityMissing/flagDisabled | Scoped screen notice |
| X01 · Meetings | System audio or Calendar permission absent | Meeting setup needs attention | Calendar or system audio access is off. Microphone-only recording may still work. | Review permissions | Keep available mic track; label missing track | Meetings SectionCopy; DualCapture | Scoped screen notice |
| X02 · Meetings | Recording interrupted or transcript unreadable | This meeting needs recovery | Saved audio and text are kept. | Recover meeting | Preserve saved audio/text; never fabricate speaker turns | SectionCopy.meetingUnreadableRow; recording reference | Held tape |
| X03 · Voice | Enrollment too short or speaker model unavailable | Couldn’t finish voice setup | Hold-to-talk still works; speaker filtering stays off. | Try voice setup again | Keep prior enrollment until replacement succeeds | SpeakerError; SpeakerFilter | Scoped screen notice |
| X04 · Dictionary | Contacts denied or import malformed | Couldn’t import these words | Existing dictionary entries are unchanged. | Review import | Preview valid entries and list rejected rows | SectionCopy.contactsDenied; BiasVocabulary.LoadError | Scoped screen notice |
| X05 · Sync | Pairing mismatch, bad key or tampered payload | Devices couldn’t be paired safely | Nothing from this transfer was applied. | Pair again | Keep local data; do not weaken verification | PairingError; SyncCryptoError | Scoped screen notice |
| X06 · Sync | Peer offline or concurrent edits conflict | Sync needs attention | Local dictation continues. Review conflicting edits. | Review sync | Keep both versions until resolved | SyncEngine; defensive conflict coverage | Scoped screen notice |
| X07 · System | Update fails or is interrupted | The update didn’t finish | Keep using the installed version. | Retry update | Do not discard drafts or replace working app early | SettingsView Updates; defensive coverage | Scoped screen notice |
| X08 · System | Unexpected unmapped error | VoicePlus couldn’t finish this step | Any text captured so far is kept. Check the result before trying again. | Open recovery | Preserve available data; technical details in diagnostics | EngineErrorMessage; proposed catch-all | Held tape |

**Behaviour rules, not copy (FX4).** The consequence column is shown to users verbatim. Until 1.11.1 some rows carried instructions for the builder there, and the app displayed them. Those rules now live here. The column holds only user-facing text, and `DesignCopyLintTests` enforces this:

- M07: if warm-up takes longer than 2 s, name the wait; after a failure, offer Retry loading.
- K03: the first isolated short tap stays quiet; teach only after repeated misses.
- A08: keep live words visible, with a small quality warning.
- A09: never start a second conflicting audio session.
- T04: never claim unmarked words were checked.
- T05: attach uncertainty to the smallest reliably aligned phrase.
- S04: show exactly which items remain.
- S05: recover only the audio or text that is on disk.
- N03: show a retry time when the provider supplies one.
- X01: name the missing permission.
- X02: keep other meetings visible and isolate the affected row.
- X08: say whether text exists and whether anything may have been inserted.
- P03: only the selected legacy listener needs the grant.
- P04: save held text before relaunching.

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
| ! Couldn’t confirm insertion                               |
| Check Mail before trying again.                         |
| [Check text]    [Copy text]    [Dismiss]                  |
| No automatic Retry button: it could duplicate the text.  |
+---------------------------------------------------------+
```

Retry is never a universal button: no-speech retries a turn, model retry restarts a download, permission action opens the correct setting, held text uses explicit retargeting, and unconfirmed insertion asks for inspection. Clipboard operations acknowledge only verified copy success. A “recover” action is present only when recovery material exists.

## 11. Accessibility, motion, sound, and keyboard behavior

Text contrast target ≥4.5:1; meaningful line, control and focus contrast ≥3:1. Test both themes and high contrast on real displays. Primary actions are labelled; no icon-only critical recovery. VoiceOver announces start, stop, final result availability, uncertainty count and delivery result. Do not announce every streaming token. Respect focus and hover pause of preview dwell. Offer manual preview for users who need time to read. Escape cancels an active inline edit before cancelling a parent operation. Tab reaches actions in reading order; focus returns to the originating word or screen. No global key swallowing in the HTML outside the labelled simulator, and no overriding normal text editing.

Reduce Motion: static flat tape and representative cassette expressions; no reel rotation, twist, travel, spring, grain shimmer or animated progress on the tape. A numeric level readout may replace capture motion. All state labels and dwell/order stay intact. Treat artwork as aria-hidden decoration; announce the semantic state and real outcome, not the animation. Normal motion uses 160–220 ms ease-out geometry transitions and small mechanical anticipation, without elastic bounce. Tape motion uses an 8.4 pt amplitude coefficient (previously 7), a 2.8-cycle primary wave (previously 1.35, adding roughly 1–2 peaks), and a smaller secondary harmonic. It never enters the transcript lane. Cassette listening tilt is about ±1.35° (previously ±0.65°), with a slightly stronger 1.8° insertion anticipation. Notch twists use a 2.35-radian coefficient and 1.6 spatial cycles, slightly reduced from 2.65 / 1.8. The flight uses a 2.05-radian coefficient and 1.2 cycles, with a slower 3.2 phase rate, reducing folds more than in the notch so it reads as a broad ribbon rather than a thin cord. Both begin at 6.4 pt thickness and use identical material tokens; local edge-on turns are brief. The flying strip still flattens to the existing 2.4 pt destination underline. The free left tip drifts 1–2 pt with phase lag; the right inlet stays attached. Broad oxide faces dominate, with occasional edge-on twists. Fine reel rings and printed labels are simplified at 80% scale. Listening reel baseline is about 150°/s counterclockwise, modulated by speech activity; insertion is a finite clockwise turn. An animation freeze must not freeze capture or block recovery controls. Idle never animates; its 6 pt corner radius applies to all four corners, including the top. Suppress the background cap for this tiny idle presence so the top rounding stays visible. Stop requestAnimationFrame when hidden or inactive. Optional quiet start/stop earcons default off; no success sound until insertion is verified. Error information never depends on sound.

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

The prototype’s expression can be exaggerated for inspection, but its active notch uses the specified dimensions. The real engine drives activity and turn outcomes. Reel angle persists across transcript renders; quiet pauses do not reset it. Resume starts from the same angle. A release closes capture immediately; the short damping gesture is explicitly labelled “Microphone closed”. Reduce Motion disables all transport motion while preserving correct state transitions.

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
17. Prototype: test hold/release, full playback, each state chip, uncertainty correction, theme/reduced-motion, all screen previews, state variants, search and every error family. The prototype does not test real ASR, permissions or third-party insertion.

## 14. Prototype guide and known boundaries

Open `design_v3.html` directly; all CSS, JS, sample data and this complete specification are embedded. No CDN or font download is required. The “Spool studio” demonstrates the default sequence and inspection states. Its Short sentence / Long paragraph selector exposes overflow, scrolling, directional scroll controls and multiline tape landing; this selector is a review tool, not product UI. “App surfaces” previews the proposed screens and their content/empty/loading/error/partial-data variants. “Recovery catalogue” filters all error entries and opens an accurate representative pill plus retention/action details. “Full specification” includes this document in full.

Simulated controls change sample data. Learned dictionary entries persist in browser-local storage for this prototype; speech, OS permissions and external insertion remain simulated. A microphone meter, download progress, permission state, clipboard recovery and inserted-field rendering are illustrations; the prototype does not call actual OS APIs. Hold and double-tap can be tried on the simulator button; tap again to finish latched capture. Real hotkey events are handled only while the studio is armed/focused; use the on-screen hold button if VoicePlus already captures Right Control globally. The UI labels this limitation. A deterministic Replay action is provided for review without holding a key. The final-preview delay is fixed at 600 ms by default. The functional Settings duration selector offers 600 ms, 1200 ms and Manual review. Hover pauses and exit resumes; the previous word-count delay and correction form are removed. The Manual review checkbox holds the completed final preview until the explicit Insert now action, so the preview-before-insertion contract can be inspected at leisure.

Implementation validation still required: real ASR word alignment, calibrated uncertainty threshold, field adapter support, accessibility permission behavior, true latency, crash-safe storage, multi-display placement and VoiceOver with native controls. Design completeness is not evidence that those integrations are already implemented.

### V3 validation additions

- Inspect compact/action layouts with a 101 × 92 pt character, right/top clearance and stronger lower shadow. Every compact active state measures 160 pt, actions sit left and supporting copy sits right. Text and controls retain readable sizes.
- Hold, pause speech, release and insert: the free tape tip moves slightly; reel angle and wave phase do not reset; mouth and body settle continuously.
- Short and long fixtures: every word remains reachable by scrolling; The fixed two-line viewport has a draggable scrollbar with applicable up/down arrows; no maximize/expansion control remains. Two fully readable compact lines and one-line vertical centering are required. Verify the black top cap only on built-in-notch displays and unchanged content coordinates in both display modes. Reading never causes surprise insertion.
- Choose a visible red suggestion, edit a word inline, or edit the full draft inside the notch. Verify pointer exit resumes insertion, Escape cancels edits, and accepted corrections are learned automatically. Preserve confidence dots until that word is resolved.
- Observe one-line and multiline flight: mouth → line paths → the same settled underlines. Never draw success underlines for held, partial or unconfirmed outcomes.
- Verify idle/hover, hold/double-tap, manual/automatic preview, cancellation, light/dark, external display, Reduce Motion, all 26 state chips and all inherited recovery cases.

The prototype demonstrates the geometry and interaction with simulated data. It does not certify native accessibility, calibrated confidence, external editor line rectangles, RTL handoff, or real write verification. Those require native integration validation. Earlier design files are preserved.
