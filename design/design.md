# VoicePlus — Underline

Design specification · 18 September 2026 · Proposed product design

**One line carries your voice into your words.** Keep the current top-center presence. While Right Control is held, live text appears above a continuous wavy line. On release, finish recognition and cleanup, show the final modified text above a straight line in the pill, then insert that exact text into the destination. Uncertain words keep a red dotted underline in the pill and in supported destination fields.

This is a design deliverable, not an implementation or a claim that every proposed behavior already ships. Its companion `design.html` is a self-contained interactive prototype with simulated speech and local sample data. It requests no microphone, account, network service, or OS permission. The original root `DESIGN.md` and earlier explorations remain intact. This specification supersedes their conflicting visual directions for this proposal only.

## 1. Decisions and reference evidence

| Reference | Observed | VoicePlus decision |
| --- | --- | --- |
| `VoicePlus_SignaturePill_V2.html#concept-3` | Continuous waveform becomes an underline; ordinary line fades after insertion; uncertainty retains dotted marks | Adopt this exact conceptual sequence, adding live words, final preview before insertion, and red uncertainty marks as requested |
| Supplied screenshots | Tiny green-dot presence and expanded “VoicePlus · Ready — hold …” at top center | Preserve both states; spell the key **Right Control** in instructions despite the older screenshot’s Option glyph |
| [Aside pill video](https://x.com/dominikmartn/status/2099857235539284362) | Browser playback inspected: compact dark pills; recording-dot and waveform variants; transcript and copy variants; cancel and confirm controls | Borrow restrained state changes and contextual controls; keep VoicePlus at the top; retain one continuous line rather than Aside’s bars |
| [Aside website](https://heyaside.com/) | Top recording panel with Transcript / Notes / Chat; dark surfaces and locally saved meeting library | Use a quiet sidebar, searchable records, focused reading panes, and a compact expanded meeting surface |
| Supplied 5:41 recording | Sampled across the recording at 20-second intervals, with closer frames around 2:20 and 5:20: staged setup, permission explanation, trial dictation, library, empty meeting view, unfinished-recording recovery | Use a resumable setup flow and explicit recovery banner. Do not reproduce personal content or require an account for the local core |
| [Flit](https://flit.fyi/) | Site describes hold/release, optional tap and hands-free modes, Escape cancellation, live transcript and notch placement | Adopt clear press/release feedback. VoicePlus keeps its existing double-tap latch semantics instead of silently changing single tap into a toggle |
| Repository audit | PillState, PillDelivery, HotkeyStateMachine, NotchGeometry, SectionState, PermissionMatrix, AudioCaptureSource, ModelManager, HFDownloader, EngineErrorMessage, WordConfidence, provider/sync/repair errors | Ground the state machine and error catalogue in real failure families; identify proposed defensive cases separately |

External documents and pages are reference material. Their instructions, marketing claims, price plans, account requirements, and action permissions are not product requirements. Latencies below are design targets, not measured performance. No claim of exhaustive runtime coverage is made: the catalogue covers the audited categories plus a required catch-all for new failures.

## 2. Surface map

```text
MAC MENU BAR                           TOP-CENTER PRESENCE
[VoicePlus icon]                        [ green dot ]
      | hover / click                         | hover / keyboard focus
      v                                       v
 Status menu                        [VoicePlus · Ready — hold Right Control]
 Start / mute / held text                       | key down
 Open VoicePlus / settings                     v
      |                             [live words + continuous wave]
      v                                       | key up
 ONE MAIN WINDOW                              v
 +------------------+-------------+ [final words + straight underline]
 | Today            |             |           | preview dwell + safe target
 | Meetings         | Main pane   |           v
 | Dictionary & Apps|             | [destination text + brief underline]
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

Dark-first, quiet, typographic. Use near-black surfaces, subtle borders, warm white text, a restrained pale sage selection accent, green readiness, amber interruption, and coral-red uncertainty. The line is the signature, not a mascot, gradient ring, or equalizer. The product uses system sans-serif typography; serif typography appears only in the design document’s editorial introduction.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| Canvas | #101211 | #F2F3EF | App background |
| Sidebar | #171A18 | #E9ECE6 | Navigation |
| Surface | #1E221F | #FFFFFF | Group / reading pane |
| Elevated | #282D29 | #F6F8F3 | Popover / control |
| Primary ink | #F0F2EC | #20251F | Text |
| Secondary ink | #A8B0A7 | #596254 | Helper text |
| Separator | #343B34 | #D2D8CC | 1 px rules |
| Accent | #CFDFB7 | #405B2B | Selection / primary action |
| Ready | #69D58B | #21753D | Ready dot / verified icon |
| Attention | #F0C181 | #86540C | Recoverable interruption |
| Uncertainty | #FF8F95 | #B72F40 | Dotted word underline |
| Pill | #080A09 | #080A09 | Always dark against the menu-bar edge |

Use semantic tokens in native implementation; respect system high-contrast settings. This explicit sage palette is a proposed change from the old system-accent-only document. Do not apply a theme change to existing app settings as part of this design task.

Typography: app title 24/30 semibold; section title 17/24 semibold; body 13/20; compact metadata 11/16; pill transcript 14/20 medium; pill status 11/16; key label 11/16; tabular digits for durations. Support text scaling in windows; move overflowing notices to a readable detail surface rather than shrinking text in the pill.

Spacing: 4, 8, 12, 16, 24, 32 pt. Window radius 16; groups 10; inputs/buttons 7; standalone pill 18; attached notch lower corners 18 and upper corners square. One hairline per boundary. No border around every line of content. Use native focus rings, minimum 28 pt compact controls and 32 pt main controls; aim for 44 pt touch targets on companion mobile surfaces.

## 4. Pill anatomy and placement

Preserve current placement directly below the physical notch / menu-bar safe band, centered horizontally. No content is drawn behind the camera housing. Use the actual display safe area, not a fixed y offset. The current working display is chosen at key-down and pinned for that turn. If it disappears, move recovery to the remaining active display and require destination revalidation.

```text
NOTCHED DISPLAY                         EXTERNAL DISPLAY
+------------[camera]-------------+     +-------------------------------+
|                                 |     | Apple   App   File ...        |
+-----------+---------+------------+     +-------------------------------+
            |    •    |                          [    •    ]
            +---------+                     8 pt below menu-bar band

ACTIVE ATTACHED PILL — nominal 440 x 88 pt
             camera housing (not usable pixels)
       +----------------------------------------+
       |  Listening · Mail                 0:06 |  status row 11 pt
       |  Can we meet with Mira on Friday       |  live text 14 pt
       |  ______/\___/\/\____/\____________   |  continuous 1.5 pt line
       |  Release to finish             Esc    |  contextual helper
       +----------------------------------------+
          16 pt inset                 16 pt inset
```

| State geometry | Nominal size | Boundary |
| --- | --- | --- |
| Idle presence | Match current implementation; about 54 × 10 pt | Keep the small green dot and black chin; no perpetual pulse |
| Ready hint | About 330 × 30 pt | Complete brand + ready + key instruction; expand only when needed |
| Starting / listening / final preview | 440 × 88 pt | Stable width during a turn; one or two transcript lines |
| Actionable held/error | Up to 520 × 120 pt | Headline, retained-text excerpt, up to three actions |
| Absolute compact ceiling | min(560 pt, usable width − 32 pt) × 128 pt | Full details in recovery window; no giant black slab |
| Meeting expanded panel | 560 × 360 pt preferred | Explicit expansion; not automatic during ordinary dictation |

These are proposed geometry updates from the code’s 320×44, 420×64 and 560×96 caps. On a very narrow display use a readable detached recovery panel instead of squeezing controls. Stay inside the visible display, clear system menu items, and support fullscreen Spaces. The closed presence ignores ordinary pointer events except its deliberate hover/click target. Listening does not steal keyboard focus. Recovery and correction controls may take focus only on explicit interaction.

### Transcript layout

Use natural-language text, not monospace. Live text shows the newest two lines with a leading fade or ellipsis when needed; stable words stay in place and only the provisional suffix changes. Reserve the line lane below the last visible line. For long final text show the last two lines plus “42 words · Review all”; the full payload is always retained. Do not confuse clipping in the preview with truncating the inserted text.

During final preview, hover, keyboard focus, selection, or opening Review pauses auto-insertion. Screen reader users can choose manual review. Respect bidirectional scripts and grapheme boundaries; position marks from layout rectangles rather than character-count approximations.

## 5. The press → speak → release → preview → insert contract

```text
RIGHT CONTROL  _____|=========================|____________________________
MICROPHONE          [capture live.............] closed
TEXT                partial → partial → final recognition → final payload
LINE                ~~~~~~ live amplitude ~~~~ settles → __________________
PILL                Starting / Listening       Finishing   FINAL PREVIEW
DESTINATION    unchanged.................................. | insert ONCE
                                                            verify → fade
```

1. Key down acknowledges within 80 ms target; open capture immediately, not after the hold threshold. Snapshot app, field, selection, text version, display, and secure-field status. Preflight microphone, mute, and usable model. The visible word “Listening” begins only when capture is actually open.
2. After 250 ms the gesture is a hold. Live words render above the wave as streaming results arrive. Wave amplitude follows microphone samples with smoothing; silence flattens it. Never loop a canned wave in the real product when no audio is arriving. The HTML uses a labelled simulation.
3. On key up stop capture immediately. No wave that suggests continued recording. Keep the latest words while finishing recognition and optional cleanup; show “Finishing…” with a quiet settling line. No destination write yet.
4. Publish one immutable final text payload with final confidence spans. It must appear in the pill above the fully straight line before insertion. Default dwell: **900 ms**, measured from the first rendered final frame. Settings: 600 / 900 / 1500 ms or manual review. Hover or focus freezes dwell. Low confidence extends default dwell to **1800 ms** with “1 word to review”; it does not force correction. Manual review inserts only after the Insert action.
5. At the end of dwell revalidate target identity, selection and relevant text version. If different or unsafe, hold. Never follow a changed cursor automatically. On valid target insert exactly the previewed payload once using a turn ID and commit guard. Record write attempted separately from verified.
6. The line visually hands off from the pill to the inserted sentence: flatten 180 ms, brief contraction 120 ms, destination underline reveal 180 ms. Do not fly readable text across the whole desktop. The source preview remains until write outcome is known. Ordinary destination underline fades after 900 ms; red dotted uncertain marks remain while their ranges can still be verified.
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

Latch remains optional and explicitly labelled. Ordinary hold dictation never inserts intermediate segments before release. Fn can be selected in Settings, with a conflict test and clear macOS system-key guidance; the default and all ready hints remain Right Control.

## 6. Complete visible state inventory

| ID | State | Pill content and line | Exit / available action |
| --- | --- | --- | --- |
| I0 | Idle | Tiny green dot; no waveform, no text | Hover/focus → I1; hotkey → C0 |
| I1 | Ready | Green dot, “VoicePlus · Ready — hold Right Control” | Pointer leaves → I0; hold → C0 |
| I2 | Muted | Slashed microphone, “Muted”; neutral/amber mark | Explicit Unmute; never green ready |
| I3 | Unavailable | “Install a speech model” or permission blocker | Open named setup pane |
| C0 | Starting | “Starting microphone…”; still line | Real capture → C1; failure → E0 |
| C1 | Listening | Live words above sound-reactive continuous wave | Key release → F0; Esc → C4 |
| C2 | Listening, quiet | “Listening…” / last words; flat or very low line | Speech → C1; release → F0 |
| C3 | Latched | Live words + wave; “Latched · tap to finish”; elapsed time | Tap stop; Esc cancel; lock stop |
| C4 | Cancelled | “Cancelled · nothing inserted”; line retracts | 800 ms → idle |
| C5 | Mic quality warning | Keep words + wave; warning glyph and short label | Continue, check microphone, or cancel |
| F0 | Finishing | Last words, “Finishing…”; wave settles | Final payload → F1; timeout/error → recovery |
| F1 | Final preview | Final modified words above straight line; destination label | Dwell → D0; hover/focus pauses; Review; Esc |
| F2 | Review uncertain words | Same final text; red dotted marks; count and Review | 1800 ms dwell or manual review; correction resets dwell |
| D0 | Inserting | Same payload; “Inserting in Mail…” | Verification → D1/D2/D3; never retry automatically |
| D1 | Verified | “Inserted in Mail”; ordinary line hands off and fades | 650 ms → idle; field uncertainty survives |
| D2 | Unconfirmed | “Inserted · not confirmed”; check-field action | Explicit dismiss or review; no duplicate insert |
| D3 | Partial insertion | “Only part may have been inserted” | Review result; manual reconciliation |
| H0 | Held | Final words + straight line; “Destination changed · text held” | Insert here / Copy / Discard; persists |
| R0 | Correcting | Selected uncertain word and alternatives | Replace verified range; keep original; dismiss |
| R1 | Editing selection | “Editing 18 words…”; straight line with subtle progress segment | Show edited final preview before replacement |
| R2 | Undo available | “Updated · Undo”; exact edit summary | Safe undo 5 s; stale range → recovery |
| E0 | Recoverable error | Plain-language problem, consequence, primary recovery | Stays until action or explicit dismissal; retained drafts stay |
| E1 | Blocking error | No recording claim; specific setup action | Recheck capability before green ready |
| Q0 | Meeting capture | Duration, mic/system-track status; distinct “Meeting” label | Pause / Stop / Expand |
| Q1 | Meeting paused | “Meeting paused”; still line | Resume or Stop; pause never looks like listening |
| Q2 | Meeting processing | “Preparing notes”; transcript remains readable | Open saved meeting; retry notes if service fails |

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
 red word marks = uncertainty          full sentence line fades after 900 ms
 white/sage continuous line = phase    red dots remain until resolved/stale

Click uncertain word / Review
+----------------------------------+
| Review “Mira”                     |
| [Meera] [Mira — keep] [Edit…]      |
| Suggested spelling, not certainty |
| [Remember spelling]  (unchecked)  |
+----------------------------------+
```

Use a 2 px red dotted underline, 3 px below the word baseline, across every wrapped fragment. Keep word text normal foreground for legibility; add “1 word to review” and an accessible uncertain-word label. A dot pattern differentiates uncertainty without relying on color. The full-width signature line sits in a separate lane 8 pt below transcript marks.

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

Subnavigation: General, Shortcuts, Appearance, Models, Providers, Sync, Updates. General includes launch at login, sound cues, preview dwell and manual-review preference. Shortcuts offers a key recorder, conflict result, hold explanation, opt-in latch and test area. Appearance includes follow system/light/dark for windows, Reduce Motion, presence visibility and Larger Text. Pill stays dark; all modes retain top-center location. Models show compatible model, installed size, actual progress, verification, ready state, retry/cancel and last working model. Never show Ready on download completion before verification and loading. Providers show selected route, connectivity and editable credentials in a secure control; secrets never appear in errors. Sync includes pairing comparison, connected devices, paused/offline state and conflict review. Updates includes installed version, checking, available, downloading, install-ready and failure; protect active capture and unsaved drafts before restart.

### 8.7 Onboarding

```text
 Welcome → Microphone → Typing access → Model → Try dictation → Ready
             | denied      | deferred    | interrupted
             v             v             v
          explanation    copy-only      retry / local model selection
             +-------------+-------------+
                    Resume setup at unfinished step
```

A normal closable window, never a full-screen input trap. No mandatory name/email collection. Show progress, Back, Continue, and “Set up later” where safe. Explain permission just before requesting it; use actual macOS prompts. Ask only for the selected backend’s permissions: the default bare-modifier monitor does not justify a blanket Input Monitoring requirement. Test a real microphone level, then guide the user through holding Right Control and seeing words above the wave, releasing, seeing final preview, and insertion into a safe test field. Demonstrate one uncertain word and correction. Ready requires a working recognizer and capture path; copy-only setup is labelled. Meeting/system-audio and Calendar are optional later steps.

### 8.8 Menu, correction and action surfaces

Status menu: Ready/Muted/Blocked, current microphone, Start dictation, Mute, Held text count, Open VoicePlus, Settings, Quit. Start dictation via menu uses explicit click-to-stop capture; it cannot imply a held key. Closing the menu does not change recording. Quit during capture asks Stop and quit / Cancel; held drafts are saved or an unsaved-data warning is shown. Correction popover anchors to a word, shows at most three credible alternatives plus Edit and Keep, closes on Escape, and returns focus predictably. Selected-text transformations show before/after preview and never replace until target revalidation; undo must be range-safe. Outbound action previews name the destination and proposed action; a dictation is never sent just because it was inserted.

### 8.9 Mobile companion scope

The redesign centers on macOS. Existing iOS keyboard surfaces inherit typography, uncertainty pattern, held-text copy and recovery semantics. Use a keyboard-top pill, not a fake camera notch, and an explicit tap-to-start/stop control. Cross-device drafts remain subject to pairing and conflict handling. New mobile screens are not required for adopting this macOS design.

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

| ID / family | Trigger | User-facing headline | Consequence / supporting copy | Primary recovery | Data policy | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| P01 · Permissions | Microphone denied or revoked | Microphone access is off | Recording cannot start. Nothing was typed. | Open Microphone settings | No new audio | PermissionMatrix; AudioCaptureSource |
| P02 · Permissions | Accessibility denied or revoked | Allow VoicePlus to type | Dictation can be reviewed here; automatic insertion is unavailable. | Open Accessibility settings | Keep completed text in recovery | PermissionMatrix; SystemAccess |
| P03 · Permissions | Legacy event tap lacks Input Monitoring | The shortcut needs permission | Only the selected legacy listener needs this grant. | Open Input Monitoring | Keep existing drafts; request relaunch after grant | HotkeyStateMachine; PermissionMatrix |
| P04 · Permissions | Permission granted but process has stale grant | Reopen VoicePlus to finish setup | Save held text before relaunch. | Reopen VoicePlus | Persist recovery first; block relaunch if save fails | PermissionMatrix |
| K01 · Shortcut | Hotkey collision or registration failure | This shortcut is already in use | Your previous shortcut stays active. | Choose another shortcut | Preserve prior binding | SettingsView; HotkeyStateMachine |
| K02 · Shortcut | Missing key-up, lock, sleep or listener interruption | Dictation stopped | Recording is closed. Start again when ready. | Review recovered text | Keep completed segments; label incomplete segment | SessionCoordinator |
| K03 · Shortcut | Press shorter than 250 ms | Hold Right Control a little longer | Nothing was typed. First isolated tap is quiet; teach only after repeated misses. | Try again | Discard sub-threshold capture | HotkeyStateMachine |
| K04 · Shortcut | Start while processing or session owned elsewhere | Finishing your previous dictation | A second session has not started. | Wait or cancel | Keep active turn | SessionCoordinator |
| K05 · Shortcut | Hard mute is enabled | VoicePlus is muted | The microphone stays closed until you unmute. | Unmute | No capture | SessionCoordinator; MuteController |
| A01 · Audio | No input device | No microphone found | Recording has not started. | Choose microphone | No new audio | AudioCaptureSource |
| A02 · Audio | Device disappears during capture | Microphone disconnected | Recording stopped. Review any words already captured. | Choose microphone | Keep decoded partial text; recover audio only if available | AudioCaptureSource; DeliveryCopy |
| A03 · Audio | Input source cannot be selected or opened | Couldn’t start this microphone | Nothing was recorded. | Choose microphone | No new audio | AudioCaptureSource |
| A04 · Audio | Sample-rate or device-format mismatch | This microphone needs reconnecting | Recording could not start with this audio format. | Choose microphone | Keep previous drafts | AudioCaptureSource.formatMismatch |
| A05 · Audio | Recorder opens but receives no samples | No audio is reaching VoicePlus | Check the selected input and its mute switch. | Test microphone | Do not invent transcript | AudioCaptureSource.noAudio |
| A06 · Audio | Samples arrive but no speech is detected | No speech detected | Nothing was typed. | Try again | Discard silence; retain no fake transcript | DeliveryCopy |
| A07 · Audio | Too little usable audio for decoder | That was too short to transcribe | Nothing was typed. Hold the key through the sentence. | Try again | No usable text | EngineErrorMessage; invalidAudioData regression |
| A08 · Audio | Quiet, clipped or noisy input | Your microphone sounds unclear | Keep live words visible with a small quality warning. | Check microphone | Capture continues; do not hide transcript | PillState.warning |
| A09 · Audio | Another internal recorder owns input | Microphone is in use | Do not start a second conflicting audio session. | Open active session | Keep active recording | SessionCoordinator.busy |
| M01 · Models | No usable recognizer installed | Install a speech model | Dictation is off until a model is ready. | Open Models | No capture advertised as ready | EngineFactory; ModelManager |
| M02 · Models | Download incomplete or scratch file missing | The speech model didn’t finish downloading | Dictation needs a complete model. | Download again | Keep a previously working model | ModelManager.incomplete; EngineErrorMessage |
| M03 · Models | Checksum or size verification fails | The model download couldn’t be verified | The incomplete model will not be loaded. | Download again | Quarantine invalid model; preserve working model | HFDownloader; ModelManager |
| M04 · Models | Network or HTTP download failure | Model download paused | Your connection interrupted the download. | Retry download | Resume only verified resumable data | HFDownloader.httpStatus |
| M05 · Models | Disk is full or files cannot be written | Not enough space to finish setup | The current working model stays available. | Manage storage | Keep existing usable files | Defensive coverage: filesystem failures |
| M06 · Models | Model unsupported on this Mac | This model can’t run on this Mac | Choose a model compatible with this system. | Choose another model | Preserve current selection until replacement works | ModelManager.unsupported; RefinementError |
| M07 · Models | Warm-up slow or loading fails | The speech model isn’t ready | After 2 seconds name the wait; after failure offer recovery. | Retry loading | Hold partial text only if it exists | EngineState.prewarming; EngineFactory |
| M08 · Models | Model disappears during active use | The speech model became unavailable | Recording has stopped. Your completed words are kept. | Open Models | Keep completed text; no silent model switch | ModelManager.notPresent |
| T01 · Transcription | Decoder throws or returns invalid output | Couldn’t finish this dictation | Review the words recovered so far, if any. | Review recovered text | Keep valid partial text; Try again if none | EngineErrorMessage; defensive partial recovery |
| T02 · Transcription | Final recognition exceeds deadline | This is taking longer than usual | Recording has stopped. Nothing has been inserted yet. | Use available text | Offer available text after 10 s; never insert late result twice | Proposed timeout policy |
| T03 · Transcription | Rewrite or provider refinement fails | Cleanup is unavailable | The original transcript is still ready to review. | Use original text | Preserve original and discard invalid rewrite | RefinementSession; RefinementGate |
| T04 · Transcription | Confidence metadata unavailable | Confidence isn’t available for this result | Do not claim that unmarked words were checked. | Review text | Preserve transcript; no invented confidence | Defensive coverage: backend capabilities |
| T05 · Transcription | Rewrite changes uncertain word alignment | Review this phrase | Uncertainty belongs to the smallest reliably aligned phrase. | Review phrase | Keep source-to-final provenance | WordConfidence; WordAligner |
| D01 · Delivery | Focus, selection or target content changes | Destination changed — text held | Nothing was typed into the new destination. | Insert here | Keep final text and uncertainty spans | PillDelivery; UtteranceLander |
| D02 · Delivery | No editable target or read-only field | Choose a text field | Your words are ready here. | Copy text | Keep final text; explicit insertion only | DeliveryCopy; SystemAccess |
| D03 · Delivery | Password or secure field | VoicePlus is paused in this field | No dictation is inserted into secure fields. | Dismiss | No new secure-field capture; prior draft remains private | DeliveryCopy; defensive preflight |
| D04 · Delivery | App excluded by user or never-inject policy | Dictation is off in this app | Your app rule prevents insertion. | Review app rule | Keep already-completed ordinary dictation | PillDelivery; app rules |
| D05 · Delivery | All insertion methods fail before writing | Couldn’t insert your text | Your text is kept here. | Copy text | Keep final text; retry only after safe target check | DeliveryCopy; proposed preserved-failure recovery |
| D06 · Delivery | Readback unavailable after insertion attempt | Inserted · not confirmed | Check the field before trying again. | Check text | Keep record marked unconfirmed; never auto-retry | LandedPillInfo.verified |
| D07 · Delivery | Readback shows partial or mismatched insertion | Only part may have been inserted | Check the destination to avoid duplicate text. | Review result | Keep original and readback separately | AppAdapter verification; defensive mismatch handling |
| D08 · Delivery | Clipboard fallback blocked or clipboard changes | Couldn’t copy your text | Your words are still available for manual selection. | Select text | Keep draft; restore clipboard only if still owned | Defensive clipboard coverage |
| D09 · Delivery | Cannot locate trustworthy word rectangles | Word marks aren’t available in this app | The text can be inserted, but review marks stay in VoicePlus. | Review words | Preserve spans in history; no floating inaccurate marks | Concept 3 risk; proposed capability fallback |
| D10 · Delivery | Destination changes before correction or undo | The text has changed | Your correction has not replaced anything. | Copy correction | Keep proposed correction; invalidate stale range | ReplaceRange; TransformReplace |
| D11 · Delivery | New hotkey while text is held | You have text waiting | Resolve or save this draft before a new dictation. | Review held text | Never overwrite held draft | HeldTextStore; proposed arbitration |
| S01 · Storage | History or timeline read fails | History can’t be read | Other working sections remain available. | Try again | Do not clear store or claim it is empty | SectionCopy.timelineUnreadable |
| S02 · Storage | Setting, dictionary or app rule save fails | Changes weren’t saved | Your previous setting is still active. | Try again | Keep entered value and indicate unsaved state | SectionCopy.notSaved |
| S03 · Storage | Draft or transcript persistence fails | This text hasn’t been saved | Keep this window open until you copy it. | Copy text | Keep in memory; do not claim crash-safe recovery | Defensive storage coverage |
| S04 · Storage | Deletion succeeds only for some items | Some items couldn’t be deleted | Show precisely which items remain. | Retry deletion | Preserve accurate count and failure list | SectionCopy.deleteAllPartial |
| S05 · Storage | App quits or crashes during capture | An unfinished recording was found | Recover only audio or text that is actually on disk. | Recover | Show retained duration and location; never imply missing audio exists | Recording reference at ~320 s; proposed recovery |
| N01 · Services | Remote provider offline or timeout | The service isn’t responding | Local transcription still works when its model is ready. | Retry service | Keep local result; no silent cloud fallback | ProviderError.unavailable/timeout |
| N02 · Services | Credentials rejected | Reconnect this service | The current request was not completed. | Reconnect | Keep local drafts; never show API key in error | ProviderError.unauthorized |
| N03 · Services | Rate limit, quota or billing rejection | This service is temporarily unavailable | Show retry time when the provider supplies one. | Use local option | Keep local transcript; no automatic paid upgrade | ProviderError.http; defensive classification |
| N04 · Services | Malformed, unsupported or disabled provider response | This service couldn’t complete the request | The original text has been preserved. | Review service settings | No partial rewrite replaces original | ProviderError.malformedResponse/capabilityMissing/flagDisabled |
| X01 · Meetings | System audio or Calendar permission absent | Meeting setup needs attention | Name the missing permission; microphone-only capture may still work. | Review permissions | Keep available mic track; label missing track | Meetings SectionCopy; DualCapture |
| X02 · Meetings | Recording interrupted or transcript unreadable | This meeting needs recovery | Keep other meetings visible and isolate the affected row. | Recover meeting | Preserve saved audio/text; never fabricate speaker turns | SectionCopy.meetingUnreadableRow; recording reference |
| X03 · Voice | Enrollment too short or speaker model unavailable | Couldn’t finish voice setup | Hold-to-talk still works; speaker filtering stays off. | Try voice setup again | Keep prior enrollment until replacement succeeds | SpeakerError; SpeakerFilter |
| X04 · Dictionary | Contacts denied or import malformed | Couldn’t import these words | Existing dictionary entries are unchanged. | Review import | Preview valid entries and list rejected rows | SectionCopy.contactsDenied; BiasVocabulary.LoadError |
| X05 · Sync | Pairing mismatch, bad key or tampered payload | Devices couldn’t be paired safely | Nothing from this transfer was applied. | Pair again | Keep local data; do not weaken verification | PairingError; SyncCryptoError |
| X06 · Sync | Peer offline or concurrent edits conflict | Sync needs attention | Local dictation continues. Review conflicting edits. | Review sync | Keep both versions until resolved | SyncEngine; defensive conflict coverage |
| X07 · System | Update fails or is interrupted | The update didn’t finish | Keep using the installed version. | Retry update | Do not discard drafts or replace working app early | SettingsView Updates; defensive coverage |
| X08 · System | Unexpected unmapped error | VoicePlus couldn’t finish this step | Say whether text exists and whether anything may have been inserted. | Open recovery | Preserve available data; technical details in diagnostics | EngineErrorMessage; proposed catch-all |

### Recovery anatomy

```text
+---------------------------------------------------------+
| ! Destination changed                                   |
| Your text is held. Nothing was typed into the new field. |
|                                                         |
| Can we meet with Mira on Friday?                         |
|                  ....                                   |
| _______________________________________________________ |
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

Reduce Motion: static amplitude envelope or level readout, instant wave-to-line change, no travel, no spring, no shimmer; all state labels and dwell/order stay intact. Normal motion uses 160–220 ms ease-out geometry transitions, no elastic bounce. Idle never animates. Stop requestAnimationFrame when hidden or inactive. Optional quiet start/stop earcons default off; no success sound until insertion is verified. Error information never depends on sound.

Large text: window reflows; compact pill remains bounded and offers full review. Small external screens use a detached pill below the menu bar. Mixed scripts, CJK, RTL, emoji and long identifiers must not split graphemes or detach marks. The browser prototype is responsive for review on small screens, not a commitment to a mobile macOS UI.

## 12. Engineering handoff and integrity rules

Keep capture state, text state, delivery state and presentation state separate. One observable turn record contains turn ID, destination snapshot, raw transcript, immutable final payload, mapped uncertainty spans, capture timestamps, write-attempt status, verification result and retained-data location. A rendered-final acknowledgment starts dwell; backend completion alone does not. Commit is idempotent per turn and target revision. Clearing a timer is insufficient: stale async callbacks must check turn ID and cancellation state.

Existing integration points: PillState/PillView and PresenceIndicator own rendering; NotchGeometry owns safe placement; HotkeyStateMachine and SessionCoordinator own key/session arbitration; UtteranceLander and PillDelivery own delivery; WordConfidence/WordAligner own spans; SectionState owns window fallback renderings. Add explicit finalPreview, inserting, partial/unconfirmed, and recovery presentation states as needed. Do not overload preview text with error strings. Proposed preservation of failed final text requires a durable recovery path and failure reporting if that save itself fails.

Selection and overlay geometry are permissions/capability-dependent. Treat destination support as a tested app-adapter matrix, not a universal promise. Readback success is distinct from write dispatch. If the underlying insertion method can partially write before throwing, classify it as uncertain rather than “Nothing was typed”. No automatic Enter/Send. No cloud fallback without the configured route and the user’s existing authorization.

Privacy: transient capture is released after the turn according to retention settings. Recovery persistence must be explained independently from optional history. Diagnostics are redacted by default; use deliberate opt-in to include transcript/audio. Do not attach personal screenshots or the supplied recording to support reports.

## 13. Acceptance scenarios

1. Idle screenshot matches current dot and top location; hover reveals brand, Ready and Right Control. No microphone is open merely because the dot is green.
2. Hold produces actual live words above a continuous audio-driven wave. Pauses flatten the line without finalizing the hold.
3. Release closes mic; final modified text is visible above the straight line for the configured dwell before any write. Inserted text exactly equals that payload.
4. Sample uncertain word is red dotted in final preview and supported target; ordinary line fades, uncertainty stays. Correction updates the verified range and removes that mark.
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
16. Prototype: test hold/release, full playback, each state chip, uncertainty correction, theme/reduced-motion, all screen previews, state variants, search and every error family. The prototype does not test real ASR, permissions or third-party insertion.

## 14. Prototype guide and known boundaries

Open `design.html` directly; all CSS, JS, sample data and this complete specification are embedded. No CDN or font download is required. The “Pill studio” demonstrates the default sequence and inspection states. “App surfaces” previews the proposed screens and their content/empty/loading/error variants. “Recovery catalogue” filters all error entries and opens an accurate representative pill plus retention/action details. “Full specification” includes this document in full.

Simulated controls change only page-local state. A microphone meter, download progress, permission state, clipboard recovery and inserted-field rendering are illustrations; the prototype does not call actual OS APIs. Real hold/release events are handled only while the studio is armed/focused; use the on-screen hold button if VoicePlus already captures Right Control globally. The UI labels this limitation. A deterministic Replay action is provided for review without holding a key. The Manual review checkbox holds the completed final preview until the explicit Insert text action, so the preview-before-insertion contract can be inspected at leisure.

Implementation validation still required: real ASR word alignment, calibrated uncertainty threshold, field adapter support, accessibility permission behavior, true latency, crash-safe storage, multi-display placement and VoiceOver with native controls. Design completeness is not evidence that those integrations are already implemented.
