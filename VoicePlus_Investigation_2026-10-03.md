# VoicePlus investigation — 2026-10-03

**Scope.** The owner tested build 1.14.0 (confirmed: `/Applications/VoicePlus.app` is 1.14.0, running as pid 6817) on 2026-10-03, about 10:40–11:47 IST, mostly in the Claude desktop app. This document covers six reported issues (A–F), the new outcome-message vocabulary, the fix list (H1–H25) and the open questions.

**Status.** Investigation only. No code was changed.

**Evidence.** Code at b78cb7e. `voiceplus.sqlite` (turn_records, turn_diagnostics, opened read-only). The unified log for pid 6817. Screenshots 5–9.

**Confidence labels.**
- **Confirmed** means the code, the DB and the log all agree.
- **Likely** means the code mechanism is proven and the data fits.
- **Hypothesis** means it is not yet shown.

**Evidence gap.** The DB has no dictation turns after **10:58:33 IST**, and the log has no turn activity after 10:58:31, although the app kept running. Either dictation stopped then, or fn stopped working. See open question Q1.

---

## 1. Issues

### A. Single tap of fn: a second tap re-shows the hint instead of dismissing it

**What happens.**
1. One tap shows the hint "Hold to talk · double-tap to lock". It stays about 4 s.
2. Tapping again while the hint is up treats the second tap as a brand-new tap.
3. The hint flashes "Starting…", retracts, then comes back for another 4 s.

**Root cause (confirmed).**
- The tap path always schedules a fresh hint 0.35 s after release. Nothing checks whether a hint is already on screen.
  - Code: `App/Services/TurnController.swift:474-487`, `:1967-1970`.
- The hint's on-screen time is the generic 4 s transient-notice dwell.
  - Code: `App/Core/PillPresentation.swift:40`, `App/UI/PillView.swift:309-316`.
- The diagnostics for turn 7F901214 show the pattern: out at 13.412, a new hint at 13.603, out again at 17.845. The tap itself is inferred from this pattern, because info-level logs are not kept.

**Side issue (hypothesis).**
- Whether a short press counts as a "tap" is decided by measuring wall-clock time in the dictation coordinator. It should use the gesture's own classification.
- This may be why one press was stored as a stray "cancelled" turn (F3EFE424).
  - Code: `App/Services/DictationCoordinator.swift:575-577`, `App/Services/SessionCoordinator.swift:340-347`.

**Fix.**
- When the hint is already showing (decided from the pill's own state, on the main thread), a tap dismisses it and schedules nothing new.
- The tap-hint dwell drops to about 1.6 s.
- Every press under 250 ms is forwarded as a tap.
- Double tap is unaffected. The hint only appears after the double-tap window has closed, so a double tap can never meet a visible hint.

**What you will see.**
- Tap once: the hint appears and fades after about 1.6 s.
- Tap again while it is visible: it disappears and nothing new appears.
- Double tap still starts hands-free.

### B. Long press, say nothing, release: the notch stays stuck (screenshot 5)

**What happens.** A silent hold shows "VoicePlus couldn't finish this step… Any text captured so far is kept." The message has a Dismiss button and stays on screen until the next press: 10–22 s in today's data.

**Root cause (confirmed).**
1. The silent-hold path passes the text "Didn't hear anything" as an error message. That text is not a known catalogue headline, so the lookup fails.
   - Code: `TurnController.swift:2058-2062, 2112-2126`, `PillPresentation.swift:605-618`.
2. When the lookup fails, the renderer falls back to the catch-all error X08.
   - Code: `PillPresentation.swift:557-560`.
3. X08 is marked "stay until the user acts", and its release time is "never". The 1.2 s fade asks for the pill to hide, but the pill refuses forever.
   - Code: `PillPresentation.swift:56-57, 118-123, 136-138`.
4. Evidence from today's turns:
   - 42AB638D: up 05:17:19.3, down 05:17:41.5.
   - B2B58F3D (a 0.25 s hold): about 22 s on screen.
   - F97BC017: about 12 s on screen.
5. The existing N17 test only checks the text and never renders the row, so it missed this.
   - Code: `Tests/AppTests/TurnTapOverlapN17N23Tests.swift:58-60`.

**Caution (hypothesis).** Not every empty turn was silent:
- 44D96491 was a 4.6 s hold.
- 7EA1E75A was a 3.1 s hold.
- E3C72C7E was a 52 s hands-free session.

Some of these may be lost speech, for example the selection case in C. Their recordings are checked before the quiet message is made final (H23).

**Fix.**
- Present the real catalogue entry for "no speech" (A06).
- Swap in the friendlier wording only when drawing the quiet row.
- The test asserts the rendered row: never X08, and a short dwell.

**What you will see.** Hold fn, say nothing, release: a small "Didn't hear anything · Nothing was typed." It has no warning icon and no Dismiss button, and it fades by itself in about 1.5 s. X08 appears only for a truly unknown error.

### C. Select text, hold fn, dictate: nothing happens; the next hold flickers

**What happens.**
- Dictating with text selected types nothing, does not replace the selection and does not save the words anywhere.
- The next hold, made without a selection, flickers and sometimes swallows the words too.

**Root cause, in four parts.**

1. **The selection turns your words into an edit instruction (confirmed).**
   - When text is selected, every utterance that is not a clearly worded repair is routed to "edit the selected text". It is never routed to dictation (the Bet 5 behaviour).
     - Code: `Pipeline/Transform/TransformRouter.swift:28-35`, `App/Services/UtteranceLander.swift:280-291`.
   - All eight of today's selection turns in Claude ended as "consumed": nothing typed and nothing saved.
     - Turns: 3D65299F, 307B6275, 5820BA2A, 0A84C2C7, F30AB879, 15E9F3A8, 3EE8F039, 53F4406C.
     - Their texts were ordinary dictation: "Screen shot.", "When I select the a text and then press the function key to dictate.", "Is it going to flicker?" and so on.
   - Each turn matches, to the millisecond, a decision row with owner "edit" and reason "landing:transform".

2. **No AI provider is set up, so the edit cannot do anything (likely).**
   - On-device editing only handles shorten, lists, fix, and upper/lowercase.
   - Anything else returns "no change".
   - A single uncertain word in the instruction aborts the edit with error T05. The log shows four T05 errors: 10:48:40, 10:49:14, 10:49:40, 10:56:41.
     - Code: `Pipeline/Transform/TransformExecutor.swift:53-54, 104-131`.

3. **The flicker (mechanism confirmed; cause of what you saw is likely).**
   - After a failed or no-change edit, the edit pill runs an 8 s "say more" countdown. It redraws itself every 250 ms.
   - Nothing stops the countdown when fn is pressed again.
   - The pill accepts the edit row even while a dictation is listening, so the two rows keep replacing each other.
     - Code: `App/Transform/TransformPillDriver.swift:50-74`, `App/Transform/TransformUXModels.swift:158-175`, `App/UI/PillView.swift:309-325`.
   - Turns 503D8DFE and 47BE1B00 started 2–4 s after a failed edit. Neither has its own "starting" row, so the pill was already up showing the edit row.

4. **"Sometimes it doesn't listen" (likely).**
   - After a "no change" edit, a hold within 8 s with no selection is chained onto the old selection as another edit. Its words are swallowed again.
   - Examples:
     - 3EE8F039 → 53F4406C: caret only, chained, T05.
     - 3D65299F → 307B6275.
   - Code: `App/Transform/TransformLanding.swift:126-141, 228-229`.

**Related problems.**
- **Escape fails to register (likely).** The edit pill and the turn both try to own the Escape key. The log shows "RegisterEventHotKey failed (-9878)" on exactly the six turns that started a new edit.
- **Outcomes are not recorded (confirmed).** Edit outcomes are not saved in the log or the DB, so they cannot be audited.
- **A second source of held text (confirmed).** A failed edit also sends text to the held queue. This is a second source of "Needs you".
  - Code: `App/AppDelegate.swift:337-347`.

**Fix.**
- With text selected, plain speech replaces the selection, the same way typing does.
- Only clearly worded edit commands edit the selection, for example "make this shorter" or "turn this into bullets". With no provider, only the commands VoicePlus can actually carry out on-device count as commands.
- A failed or no-change edit keeps the selection and saves your words to Notes with a message.
  - The password-field check runs first. Today the edit path runs before the password refusal, and a password must never become a note.
- Pressing fn ends the edit pill. The pill ignores edit rows while a dictation is listening.
- A follow-up edit is chained only after an applied edit, and only when the caret is still inside the edited text.
- One owner for the Escape key.
- Each edit outcome is logged and recorded.

**What you will see.**
- Select text, hold fn and speak: your words replace the selection (Cmd-Z undoes it), with "Replaced selection in Claude".
- "Make this shorter" on a selection still edits it.
- An edit that cannot be done shows "Couldn't edit the selection · Saved to Notes".
- The next hold is a steady, normal listening notch.

### D. Hands-free: the notch disappears while inserting, then comes back

**What happens.** After each pause, the text is inserted. The pill fully retracts for 16–550 ms, then reappears as the hands-free row with its timer reset to 0:00.

Evidence (turn_diagnostics, "retracted" then "latched" pairs, UTC):
- 05:20:46.6 / 47.1
- 05:21:17.07 / 17.09
- 05:21:35.83 / 35.99
- 05:22:36.7 / 37.0

**Root cause (confirmed).**
1. Each segment's preview, inserting and inserted rows are drawn over the hands-free row. The turn controller deliberately treats a latched capture as "not open".
   - Code: `TurnController.swift:987, 1391, 1676-1686`.
2. When the inserted row ends, the pill returns to the hands-free row only if a capture is marked open. Segment rows clear that flag.
   - Code: `PillView.swift:744-760, 859-868`.
3. So the pill hides completely, which also wipes the timer.
   - Code: `PillView.swift:832`.
4. Then the next microphone tick brings the hands-free row back.

**Related problems.**
- **Hands-free end and quick re-press (confirmed).**
  - When hands-free ends, nothing summarises what happened.
  - A quick re-press right after the stopping tap is refused with K04. Log: 10:50:50.949.
- **Lost full stops in chat apps (likely).** Hands-free segments of 20 words or fewer lose their full stop.
  - Turns: F544A7DD, 5B3056AA, ECA48A34.
  - Code: `Pipeline/Formatters/ChatFormatter.swift:18, 261-273`.
- **Refuted.** The "missing space before 'while it is'" was not a bug. You had clicked into the middle of the previous sentence (caret 933), and the spacing was correct for that position. No fix is needed.

**Fix.**
- While hands-free is on, the pill never hides between segments.
- Segment rows are not drawn over the hands-free row. Instead, the status line briefly shows the outcome, for example "Inserted in Claude", then goes back to "Hands-free · listening".
- A held, error or Notes outcome is still shown and is never swallowed.
- The final retract at the end of hands-free still happens.
- Hands-free ends with one summary line.
- A re-press within about 300 ms of the stopping tap is folded into the stop.
- Hands-free segments keep their full stops (depends on Q9).

**What you will see.**
- The hands-free notch stays out, at the same size and position, for the whole session, and its timer keeps counting.
- After each pause, its status line flashes where the text went.
- Ending shows, for example, "Hands-free ended · 3 inserted in Claude".

### E. The orange "Needs you" pill and held dictation (screenshots 6–9)

**What the held text is (confirmed).**
- It is turn 7570AEA9, "Testing, testing, one, two, three."
- It was the very first dictation after the fresh 1.14.0 install, spoken while VoicePlus's own setup window was in front. The target was the window itself, not a text field.
- The pull-back check reported "window gone" within 1 ms, so the text was held: "Destination changed. Nothing was inserted." Log: 10:40:11.758 and 10:40:11.761.
- The same sentence was inserted 25 s later into a VoicePlus text area (turn 90154897, verified). **The held copy is a stale duplicate.**

**Why "window gone" (hypothesis).**
- The setup window was not closed, and the next turn in the same app passed the window check.
- So this was most likely a one-off wrong window identity at key-down, while VoicePlus's own panels were changing state.

**Root cause of the UX.**
- Text that cannot be delivered goes into a held queue with an Insert / Copy flow. That queue drives:
  - the orange "Needs you" face, which is a hard-coded system orange that matches no design token;
  - "1 held dictation" in the menu;
  - the "Text waiting for…" card on Today;
  - the Review sheet.
- Code: `Injection/FocusGuard.swift:216-233`, `TurnController.swift:1321-1365`, `App/Settings/TodayHistory.swift:242-260`, `App/UI/PresenceIndicatorView.swift:127-136`.

**Safety gap found (confirmed).**
- Today, a dictation caught by the pre-write check as a password field is held, and its text is written to dictation history.
  - Code: `TurnController.swift:1358`, `UtteranceLander.swift:493-504`.
- Simply redirecting "hold" to Notes would save password-field text to disk.
- This must become a refusal, with nothing saved anywhere.

**Notes cannot do this yet (confirmed).**
- A note does not record why it was saved or which app was intended.
- A failed Notes save can currently lose the text.
- Code: `App/Settings/NotesStore.swift:31-45, 258-280`, `App/Settings/NotesRouting.swift:108-128`.

**Fix (as you asked).**
- Retire the held queue entirely. Every case that held text now saves it to Notes, with a reason and the intended app.
- **Exception:** a password field is refused and nothing is saved.
- If the Notes save itself fails, the text stays in history and on the pill with Copy. It is never lost.
- Remove:
  - the "Needs you" face;
  - the held rows in the menu and on Today;
  - the Review sheet;
  - the held path for failed edits.
- VoicePlus's own windows skip the window-identity check. The in-process writer decides: type into the field, or "Saved to Notes · no text field".
- The "no field → Notes" rule applies only to native apps and VoicePlus itself. Claude, ChatGPT and browsers keep the existing "deliver unverified" behaviour (N3).
- The pull-back rule is unchanged:
  - same window: type;
  - window changed: pull back and type;
  - window gone or refocus failed: Notes. The text never goes into a different window.
- On upgrade, clear the existing held row. It is a duplicate of text that already landed.
- One shared outcome type drives the pill line, the Today row, the menu and turn details (see section 2).

**What you will see.**
- No orange pill.
- No "held dictation" in the menu.
- No Review sheet.
- Every dictation ends with one plain line saying where the words went. Anything that could not be typed is in Notes, labelled with why.

### F. The pill expands from the top of the screen / from a corner

**Root cause, in three parts.**

1. **Hover row (confirmed).** When expanded, the hover row adds a 39 pt cap and fills it with its background colour. That is the orange painted from the top of the screen in screenshot 6, about 77 pt in total. It also covers the menu-bar icons on both sides of the notch.
   - Code: `App/UI/PresenceIndicatorController.swift:363-366`, `PresenceIndicatorView.swift:46-56`.
   - Removing it breaks no design rule. V3 specifies the cap only for the turn pill (design_v3.md:155, :559).

2. **Corner growth (likely).**
   - The hover panel jumps to its final size in one step. SwiftUI then animates the background inside the new bounds, so it appears to grow from a corner.
   - The two frames already share the same centre, so a centred grow is possible.
   - Code: `PresenceIndicatorController.swift:366`, `PresenceIndicatorView.swift:55`.

3. **Turn pill (confirmed in code, by design).**
   - The black cap to the top of the screen is the approved V3 design (design_v3.md:112, DESIGN.md:17). On your dark menu bar it is invisible, so your complaint is almost certainly about the orange hover row.
   - Its open animation is still wrong: it grows from a full-width 1 pt line, and the content slides vertically.
   - Code: `App/Core/NotchGeometry.swift:204-220`, `App/UI/PillPanelController.swift:262-302, 410-427`.

**Related problem (hypothesis).** Every fn press logs "pill: no display to place the pill on" about 8 times: 543 lines in this run. Some placement lookup fails on the first route of each press. It may contribute to jumpiness and flicker.

**Fix.**
- The hover row never paints above the menu bar.
- The hover row grows by animating the window frame from its centre (left, right and down), with the top edge fixed.
  - A guard stops the 5 Hz refresh from restarting the animation mid-flight.
  - On collapse, the dot returns only after the shrink finishes. This avoids the old "shrunken, off-centre dot" bug.
  - With Reduce Motion, it snaps.
- The turn pill opens from a centred, chin-width line, revealing its content outward without sliding.
- Whether the turn pill keeps its black cap is your call (Q10).
- Find and fix the failing display lookup.

**What you will see.** The notch and the hover row grow out from their own centre (left, right and down) and never upward. Nothing is painted into the menu bar, and the menu-bar icons stay visible and clickable.

---

## 2. Outcome messages (new vocabulary)

Every turn ends with exactly one outcome. It is defined once and shown in four places:

1. the **pill** status line (about 1.6–2 s, then it fades);
2. the **Today** row;
3. the **menu** ("Last: …");
4. the **turn detail**.

`<App>` is the app name. For a web app it is the site when it is known (e.g. "ChatGPT"), otherwise the browser name.

| Situation | Exact text |
|---|---|
| Text typed | **Inserted in <App>** |
| Text replaced a selection | **Replaced selection in <App>** |
| Voice edit applied | **<Action> in <App>**, e.g. "Shortened selection in Claude", "Made a bulleted list in Notes", "Uppercased selection in Mail" |
| Spoken command / action done | **<Action> done in <App>** |
| No field to type into | **Saved to Notes · no text field** |
| Original window closed | **Saved to Notes · <App> window closed** |
| Could not return to the original app | **Saved to Notes · couldn't return to <App>** |
| Edit could not be done / changed nothing | **Couldn't edit the selection · Saved to Notes** |
| Password field | **Not typed · password field** (nothing saved anywhere) |
| Nothing heard | **Didn't hear anything · Nothing was typed.** |
| Cancelled (Esc / tap) | **Cancelled · nothing typed** (or "Cancelled · Saved to Notes", depending on Q6) |
| Notes save failed | **Couldn't save to Notes** + Copy button (the text is also kept in history) |
| Hands-free segment | **Inserted in <App>**, shown as a status-line swap on the hands-free row |
| Hands-free end | **Hands-free ended · N inserted in <App>**, plus "· M saved to Notes" if any |

Each Notes item stores the intended app and the reason, and shows them as "Not typed in Claude · window closed".

---

## 3. Fix list

**Priority key.** P0 = fixes a reported bug or the owner's main ask. P1 = needed for a clean result. P2 = hardening or diagnostics.

**Effort key.** S < ½ day, M ≈ 1 day, L > 1 day.

| ID | Pri | Change | Main files | Effort | Risk | Tests |
|---|---|---|---|---|---|---|
| H1 | P0 | A silent hold shows the quiet A06 "Didn't hear anything" row, which fades; never X08 | TurnController, RecoveryPresentation, PillPresentation | S | Low | Rendered-row test (design key, dwell rule `.minimum`, never X08) |
| H2 | P0 | A tap while the hint is visible dismisses it; tap-hint dwell 1.6 s | TurnController, PillView, PillPresentation | S | Low | Tap → hint; tap again → hidden, no new hint; double tap still latches |
| H3 | P1 | A press under 250 ms is always forwarded as a tap (no stray "cancelled" turns) | SessionCoordinator, DictationCoordinator | S | Low | cancelCapture → tapped:true; Esc/menu unchanged |
| H4 | P0 | Plain speech over a selection replaces it; only clear, doable edit commands edit | TransformRouter, UtteranceLander, Bet 5 router tests | M | Med (changes Bet 5 behaviour on purpose) | Router matrix; replace goes through the normal injector (password refusal, newline rule, pull-back) |
| H5 | P0 | A failed or no-change edit never ends silently: keep the selection, words to Notes, message; password check first | UtteranceLander, TransformLanding | M | Med (password safety) | Secure field → nothing in Notes or history; T05/noChange → Notes |
| H6 | P0 | The edit pill cannot hijack the next hold: ended at key-down, ignored while listening, redraws only on change, "say more" only after an applied edit | TransformPillDriver, TransformUXModels, PillView, TurnController | S–M | Low | Hold after a failed edit shows a steady listening row |
| H7 | P1 | Chain a follow-up edit only after an applied edit, with the caret inside the edited range | TransformLanding, TransformReplace | S | Low | noChange → next hold dictates |
| H8 | P2 | One Escape owner for the turn and the edit pill | TransformPillDriver, TurnController, EscapeHotkey | S–M | Low | No -9878; Esc cancels the edit preview |
| H9 | P2 | Log and record edit outcomes (route, selection length, outcome; never the selected text) | UtteranceLander, TurnStore | S | Low | extras_json fields present |
| H10 | P0 | Hands-free: the pill stays out all session; segment outcome is a status-line swap; latch end, cancel and error still retract | PillView, TurnController, AppDelegate | M | Med (latch-end retract) | Segment land → no orderOut; end → retract; held/Notes outcome visible |
| H11 | P1 | Hands-free end summary line; a re-press within 300 ms of the stopping tap is folded into the stop, not K04 | TurnController, HotkeyStateMachine | S–M | Low (keep the busy guard for real writes) | Stop + quick re-press → no K04 |
| H12 | P2 | Hands-free segments keep their full stops in chat apps (depends on Q9) | ChatFormatter, StageContext | S | Low | Latch segment keeps "."; single hold unchanged |
| H13 | P2 | Presence engine does not reset to idle between hands-free segments | PresenceIndicatorController | S | Low | — |
| H14 | P0 | Retire the held queue: one save-to-Notes funnel; password = refuse; edit recovery included; failed save → history + Copy | FocusGuard, TurnController, UtteranceLander, TextInjector, AppDelegate, menu, TodayHistory | L | Med–High (text-loss and password paths) | Every former hold path → Notes; every secure path → nothing saved; Notes failure → text kept |
| H15 | P0 | Notes carry the intended app and the reason (new NoteSource + metadata) | NotesStore, NotesRouting | M | Low (migration) | Schema migration; note shows "Not typed in <App> · <why>" |
| H16 | P0 | One outcome type drives the pill, Today, the menu and turn detail (section 2 strings) | new shared outcome model, PillDelivery copy, TodayHistory, menu | M | Low | One test per outcome string per surface |
| H17 | P1 | VoicePlus's own windows: skip the window-identity check; no field → Notes. The no-field rule applies only to native apps (N3 kept for web/Electron). Log the key-down window token. | TurnController+PullBack, LiveSystemAccess, DeliveryLadder | S–M | Med (must not affect Claude/ChatGPT) | Own window → typed or Notes; Electron no-field → still delivered |
| H18 | P1 | On upgrade, clear the existing held row (duplicate of landed text) | migration in FocusGuard / DB | S | Low | Held rows gone after migration |
| H19 | P1 | The hover row never paints above the menu bar (cap removed) | PresenceIndicatorController, PresenceIndicatorView | S | Low | Panel top ≤ pill top edge in every state |
| H20 | P1 | The hover row grows from its centre (animated window frame, target-frame guard, dot only after collapse, Reduce Motion snaps) | PresenceIndicatorController, PresenceIndicatorView | M | Med (old FX5 dot bug) | Rest/hover frames share centre-x and top edge |
| H21 | P1 | The turn pill opens from a centred line, without sliding; keep or remove the black cap per Q10 | NotchGeometry, PillPanelController, NotchGeometryTests | S–M | Low | Retracted centre-x = shown centre-x |
| H22 | P2 | Fix "no display to place the pill on" (×8 per press) | PillPanelController / PillView placement | S–M | Low | One placement per press, no error lines |
| H23 | P2 | Check the long "empty" turns' recordings (44D96491, 7EA1E75A, E3C72C7E, …) for lost speech before finalising H1's copy | diagnostics only | S | None | — |
| H24 | P1 | Hands-free + app switch: define the rule (Q7) and test it; no segment held or lost | TurnController | S | Low | App switch mid-latch test |
| H25 | P2 | Any remaining attention colour uses the amber design token, not system orange (mostly removed by H14) | PresenceIndicatorView | S | None | — |

**Suggested order.**
1. H1, H2, H6. These are quick and stop the stuck and flickering pill.
2. H4, H5, H7. Selection dictation works again.
3. H14, H15, H16, H18, H17. Retire the held queue and add outcome messages.
4. H10, H11. Hands-free.
5. H19, H20, H21. Pill expansion.
6. The P2 items.

**Guarantees kept throughout.**
- A newline never sends.
- Password fields are always refused.
- Pull-back on app switch.
- No preview pause.

---

## 4. Open questions for the owner

1. **Q1.** Did you dictate after about 10:58 today? VoicePlus recorded nothing after 10:58:33 while it kept running. If you pressed fn later and nothing happened, that is a separate bug to chase.
2. **Q2.** Single tap of fn:
   - (a) show the hint for about 1.6 s, and a second tap dismisses it (recommended);
   - (b) show it only the first few times;
   - (c) show nothing.
3. **Q3.** A very short silent hold (under about 0.6 s): show "Didn't hear anything" briefly, or just vanish?
4. **Q4.** With text selected, should plain speech replace the selection (recommended), with voice edits only for clear commands ("make this shorter", "turn this into bullets")? Or should voice editing use a separate gesture, so fn-hold always dictates?
5. **Q5.** No AI provider is set up. An edit command VoicePlus cannot do on-device: type it as text, or "Couldn't edit the selection · Saved to Notes"?
6. **Q6.** Cancel or Escape after your words were recognised: save them to Notes ("Cancelled · Saved to Notes"), or drop them?
7. **Q7.** Switching apps during hands-free: should new pieces go into the app you are in now, or be pulled back to the app where hands-free started?
8. **Q8.** During hands-free, after each piece:
   - Show "Inserted in Claude" briefly on the status line, or keep the notch unchanged?
   - Keep the "text flies to the cursor" animation, or turn it off?
9. **Q9.** In chat apps, should hands-free keep the full stop at the end of each sentence? A single hold-to-talk message would still drop it.
10. **Q10.** The dictation notch's black strip up to the top of the screen (approved V3, invisible on a dark menu bar): keep it, or remove it so the pill only ever extends below the menu bar?
