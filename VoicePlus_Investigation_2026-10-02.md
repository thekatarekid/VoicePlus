# VoicePlus investigation, 2026-10-02: per-app landing, ribbon accuracy, pill states

Build under test: V5 1.13.0 (`/Applications/VoicePlus.app`, running as pid 12840). Evidence comes from the unified log for that pid, `~/Library/Application Support/VoicePlus/voiceplus.sqlite` (`turn_records`, `turn_diagnostics`, `injection_outcomes`, opened read-only), the code at HEAD `238db35`, and the owner's three Apple Notes screenshots. Times are IST unless marked UTC. **Confirmed** means a log line, a DB row or the code proves it. **Likely** means the evidence fits but one link is inferred. **Hypothesis** means it is not proven.

Today's turns: 36 in total. 13 landed, 8 consumed (sent to VoicePlus Notes), 8 empty, 4 cancelled, 2 held, 1 failed.

---

## 1. Per-app verdicts

| App | What happens | Root cause | Status | Fix |
|---|---|---|---|---|
| **ChatGPT desktop** | Nothing is typed. The text appears in VoicePlus Notes instead. | `/Applications/ChatGPT.app` is an Electron app with a renamed runtime. Its bundle id is `com.openai.codex`, its framework is called `Codex Framework.framework`, its helpers are `Codex (Renderer).app`, and it ships `Resources/app.asar`. `AppAccessibilityEnabler.classify` (Injection/AppAccessibilityEnabler.swift:42-52) only recognises a framework named `Electron Framework.framework` or a known bundle id, so it returns `.native`. As a result `AXManualAccessibility` is never set and the AX tree stays empty. The field reader returns nil, the lander treats nil as "no field" (UtteranceLander.swift:~346), and N2 routes the text to Notes (NotesRouting.swift:99). | **Confirmed.** 8 `landing:notes.no-field` decisions between 03:47 and 04:05 UTC. 8 consumed `com.openai.codex` turns with `writeAttempted=false`. 0 `injection_outcomes` rows for openai. | P0-1: detect Electron by bundle structure and route ChatGPT through `ElectronAdapter`. |
| **Claude desktop** | Types. The ribbon lands somewhere in the input box but not on the caret. | The empty composer's AXValue is exactly `"\n"`. The `textVersion` FNV-1a hash -5808579962898102051 matches `"\n"` on all four Claude turns. The precise rung, AXBoundsForRange, probably comes back with zero width, and `TapeFlightCaretLocator` requires `after.width > 0` (TapeFlightGeometry.swift:185). The ladder then falls back to the element frame, and the coarse rungs aim at the centre of the rect (TapeFlightGeometry.swift:155-158). | **Likely.** The recorded value is confirmed. Which rung answered is not logged, and AX was not probed live. | P1-4: accept a zero-width caret rect with positive height. On coarse rungs, aim at the leading edge of the first line. |
| **x.com (Brave/Chrome)** | Same as Claude. | Same: a Chromium contenteditable whose value is `"\n"` (turn 8672B2E3). | **Likely** | Same as Claude. |
| **Google Docs (Chrome/Brave)** | Types, but no ribbon. | Not yet known. Docs types into a fixed hidden textarea: `textVersion` is identical across turns, sel [1,1], and the landing verdict is "unconfirmed" (keystroke). Q5 says an unconfirmed landing should still fly (TapeFlightController.swift:271-284), so something in locate or plan suppressed the ribbon. Three causes fit the data: (a) the rung-1 rect is off-screen, `usable()` accepts it, then `path()` rejects it with no fallback to a lower rung (TapeFlightController.swift:319-321). (b) Docs resets its hidden textarea, the caret moves outside the expected range, and `verify()` returns targetChanged, which invalidates the flight. (c) Locate takes longer than 1.3 s and finishes silently (TapeFlightController.swift:323-327). | **Hypothesis.** Ribbon suppressions are logged at info level only, so nothing persisted. | P1-5: add ribbon diagnostics first. Then fall through to the next rung when a rect is off-display. |
| **macOS Spotlight** | Types. The ribbon lands exactly on the line. | AppKit text fields answer a zero-length AXBoundsForRange with a real caret rect, so the precise rung wins. | **Likely** (consistent with the code and the records) | None needed. Keep as a regression reference. |
| **Apple Notes** | The ribbon lands exactly on the line. But each dictation waits 16-17 s, and one was dropped and one was held. | Context gathering before formatting stalls. See section 2. | **Confirmed** (timing). Which read causes which gap is **likely**. | P0-2 and P0-3. |

Two side findings:
- 6 of the 15 ChatGPT turns were empty or cancelled with no text: 97D650A3 failed; AD105A9F, 62987E1F and E1F62700 were cancelled; 2A89FC5E, DF355876 and 9376334E were empty. That is a separate short-press or VAD issue. The owner may count these as "nothing landed" too.
- `com.openai.codex` is missing from `AppCategoryTable` (Pipeline/Style/AppCategory.swift:40), so ChatGPT text gets the generic formatting register instead of chat.

---

## 2. Apple Notes: why "Still finishing" and "Destination changed" appeared

**The text was recognised quickly. It waited because of context gathering, not speech.** For each Notes turn, recognition finished in about 0.5 s (`presence engine: landed`). The lander then ran `contextAugmenter` synchronously before formatting (UtteranceLander.swift:216). That covers deixis plus the ranked-context harvest (AppContainer.swift:262-277).

In the logs, each turn shows a Contacts fetch, a gap of about 8.4 s, a second Contacts fetch, another gap of about 8.4 s, and then `landing diff`:

| Turn | Recognised | Contacts #1 | Contacts #2 | Landing diff | Outcome |
|---|---|---|---|---|---|
| 42AB2F4E | 09:46:44.086 | 44.105 | 52.477 | 09:47:01.306 | **Dropped.** Cancelled while being formatted. |
| 07C72312 | 09:47:07.507 | 07.513 | 15.383 | 09:47:23.868 | Written via AX at 09:47:24.577 |
| 0230A62F | 09:47:31.131 | 31.136 | 39.577 | 09:47:46.368 | **Held.** Destination changed. |

The Contacts fetches themselves take only 20-35 ms. The time goes into the accessibility walks of the whole Notes window that follow each one (`AXReaderWindowText.content` → `readFocusedWindow`, then `documentTail(includeScrollback:)`, plus TypedEntity, CodeSymbol and LocalNames sources). Those walks have no time limit, and the AX tree reader never calls `AXUIElementSetMessagingTimeout` (Injection/AXReader). Other readers in the app do set one: CaretBand, TapeFlightTarget, PillDisplayChooser, FieldContextReader and ThreadParticipantsReader. Much of the work is also wasted. The `contextLine` and `ax.windowText` outputs of `DeixisService.augment` are read by no production code, and the app-rule check runs after deixis, not before (DictionaryAppsRules.swift:261-264).

**Screenshot 1, "Still finishing your text … nothing inserted yet", with Use available text / Cancel.**
- The pill draws these buttons from its own 10 s clock (PillPresentation.swift:504-516), whatever the controller is doing.
- By then `TurnController.finalize` had already set `payloadStarted`, so **Use available text does nothing** (TurnController.swift:~583-592).
- **Cancel still works, and it throws away the finished text.** That is how 42AB2F4E was lost: log line `payload dropped — the turn ended while it was formatted` at 09:47:01.306.
- While the turn was stuck, the owner pressed the hotkey **5 times (09:46:48.8-53.0), and every press was refused with K04** (`key down while 42AB2F4E is still in progress`). The next turn opened the mic only after the stall cleared and captured 0 s of audio.

**Screenshot 3, "Destination changed … Nothing was typed into the new field".**
- During the stall for 0230A62F, launchservicesd made Claude frontmost (SETFRONT pid 31165 at 09:47:43.759). It switched back to Notes at 09:47:50.365.
- The pre-insert check ran at 09:47:47.247 (`destination focusChanged during the preview — held (D01)`). It compares the frontmost pid and bundle (FocusGuard.swift:155-161), so it held the text.
- **Holding was the correct behaviour.** VoicePlus must never type into an app the user has moved to. The real problem is that a 16 s wait gave the user time to switch away.
- The previous dictation (07C72312) did land, as the owner saw.

**Also misleading:** the notch reports `presence engine: landed` as soon as recognition finishes, 16-17 s before anything is written. The menu bar says "done" while the pill still says "nothing inserted yet."

**Owner's question: "If the text was recognised and shown, why can't it just land?"** It could. Nothing in the safety path needs those 16 s. The wait is optional context gathering (for resolving words like "this" or "her") that this dictation never used: cleanup was skipped for these mid-note insertions. Put a deadline on that step and the text lands in about 1 s. All the extra states then never appear.

---

## 3. All pill and notch states today

Legend: **[GATE]** means the state blocks or decides insertion. **[shown after]** means the text is already written and the state is informational. Every other state is cosmetic.

**A. Turn lifecycle (`TurnStage`, App/Services/TurnStore.swift), 13 stages.** starting, listening, listeningQuiet, finishing **[GATE: waits]**, finalPreview **[GATE: dwell 0.6 s by default, blocks until clicked in Manual]**, inserting **[GATE: the single write attempt]**, landed, held **[GATE: blocks until an action]**, resolved, failed, cancelled, empty, consumed **[GATE: Notes routing; nothing typed]**.

**B. Pill states (`PillState`, App/Core/PillState.swift), 25 cases.** They render as about 34 distinct visible variants:
1. Idle / pre-capture: `hidden`, `ready(hint)`, `idle`, `starting` ("Warming up…"), `muted`, `unavailable`.
2. Capturing: `listening`, `preview(text)` (live words, or a notice when no capture is open), `listeningQuiet`, `latched(timer)`, `warning(mic quality)`.
3. After the mic closes, before writing:
   - `landing`, `finishing` and `finishing(slow)` ("Still finishing your text" after 2 s). Plus a **10 s offer** sub-state with Use available text / Cancel, drawn by the pill, not by a `PillState` case. **[GATE: waits; Cancel drops text]**
   - `finalPreview`, plus its "uncertain/needs review" variant, with Insert in N s / Edit draft / Cancel. **[GATE]**
   - `inserting`. **[GATE]**
4. Outcome:
   - `landed` in three variants: verified ✓, unreadable (neutral), unconfirmed (warning, sticky until acted on). **[shown after]**
   - `landedPartial`. **[shown after]**
   - `held(reason)`, which uses D01 and other recovery entries; actions are Edit draft / Insert here / Copy / Discard. **[GATE]**
   - `cancelled`.
   - `error(message)`, which maps into the 59-entry recovery catalogue.
   - `undoAvailable`.
5. Editing / commands: `correcting`, `editing`, and `transform` (editing, undo and notice variants).
6. Meeting: `meeting` (recording, paused, preparing notes).
7. Not a `PillState`, but drawn as pill rows: `blocked` (E1, microphone off or a named blocker); the K04 busy refusal **[GATE: rejects new key presses]**; and the Notes-routing claim, which today is nearly silent.

**C. Notch presence (`PresenceState`, App/Ambient/PresenceState.swift), 7 states:** off, ready, listening, processing, muted, paused, blocked. Blocked has 5 reasons: mic denied, hotkey unavailable, relaunch needed, model downloading, model missing. Separately, the presence engine's turn signal (`landed` / `idle`) fires at recognition time, not at write time.

**Headline:** 13 turn stages, 25 pill cases (about 34 visible variants plus a 10 s offer overlay and a K04 refusal), 7 notch states, and 59 recovery entries behind `error`/`held`. Six of these gate insertion: finishing (with the offer), finalPreview, inserting, held, consumed→Notes, and K04. Everything else is cosmetic.

---

## 4. Proposed minimal state model

**Turn-facing pill: 5 states, down from 13 turn-time variants.**

| New state | Absorbs | Copy |
|---|---|---|
| **Listening** | starting, listening, preview (live), listeningQuiet, latched, warning (as a tint/badge, not a separate state) | "Listening" plus live words. A badge shows Quiet, Locked or Mic issue. |
| **Inserting** | landing, finishing, finishing(slow), the 10 s offer, finalPreview (auto-dwell), inserting | "Inserting into <App>" with the final words. No buttons except one Cancel that **only skips optional work and never drops recognised text**. |
| **Done** | landed (verified / unreadable), landedPartial (with a ⚠), undoAvailable | "Inserted in <App>" plus Undo. Unconfirmed gets a small ⚠ and auto-clears like the others. |
| **Needs you** | held (all reasons), the Notes "no field" claim, finalPreview in Manual mode, error with recovered words | One row: "<Why> — Insert here / Copy / Discard". The reason names the app that actually took focus. |
| **Nothing** | cancelled, empty, error with no words | A short fade ("Nothing heard"). |

States that are not about a turn stay separate: Ready/idle, Muted, Blocked (recovery catalogue), Meeting, and Editing/Transform.

**Notch: 5 visible states.** Ready, Listening, Working (shown until the write finishes or the text is held, never "landed" at recognition time), Needs you, and Blocked. Off stays as the hidden state.

**"If we reduce states, will more dictations land?"** Mostly no. The states describe what happened; they don't cause the failures. Today's losses came from three gates:
1. **ChatGPT, 8 turns:** misclassification. No pill state is involved.
2. **Notes, the 16 s stall:** context gathering. The states only reported the stall.
3. **Focus-change hold:** a correct safety check, made likely by the stall.

Two state mechanisms did lose dictations directly, and removing them helps:
- the pill-driven **10 s offer**, whose Cancel dropped 42AB2F4E;
- the **K04 refusal**, which swallowed 5 presses.

So the honest answer: fix the gates (P0-1 and P0-2) and most of the extra states stop appearing on their own. Then collapse the states (P1/P2) so the pill no longer shows choices the controller will ignore. Reducing states without fixing the gates would only hide the same failures behind fewer labels.

---

## 5. Prioritised fixes

| # | Fix | Files | Effort | Risk | Tests |
|---|---|---|---|---|---|
| **P0-1** | **ChatGPT, and any Electron app with a renamed runtime.** `classify()` returns `.electron` when `Contents/Resources/app.asar` exists or any `Frameworks/*.framework/Helpers/*(Renderer).app` exists. Add `com.openai.codex` and `com.openai.chat` to `ElectronAdapter.bundleIDs`. `AdapterRegistry` falls back to `ElectronAdapter` whenever classify says `.electron` (keystrokes, ⇧↩ newlines, submit never allowed, so Q1 is kept). Map `com.openai.codex` to `.chat` in AppCategory. | Injection/AppAccessibilityEnabler.swift, Injection/AppAdapter.swift, Pipeline/Style/AppCategory.swift | S | Low to medium. Unverified whether `AXManualAccessibility` builds the tree in this runtime; `AXEnhancedUserInterface` is the fallback. | AppAccessibilityEnablerTests: a fake bundle laid out like ChatGPT's. Registry test: classify .electron → ElectronAdapter, and SubmitPolicy false. **Manual:** one live ChatGPT dictation. |
| **P0-2** | **Context deadline.** Run `contextAugmenter` under a hard budget of 200-300 ms on its own queue and land with whatever context is ready. Set `AXUIElementSetMessagingTimeout` (about 0.25 s) in the AX tree reader. Read the window once per turn, memoised by turn id. Resolve deixis referents lazily, only when a referent word is present, and drop its unread `windowText` read. Check app rules before running deixis. Log per-step ms (augmenter, field read, pipeline). Keep the field-context read (secure field, caret, Q1) **outside** the budget. | App/Services/UtteranceLander.swift, App/Services/AppContainer.swift, App/Services/DeixisService.swift, App/Services/AXContextProviders.swift, Injection/AXReader/AXWindowReader.swift, AXReading.swift, WindowContentCache.swift | M | Low. It drops only optional context; insertion and revalidation are untouched. | A lander test with a 10 s mock augmenter must land within about 400 ms with no context. A deixis test: no Contacts or AX call without a referent word. **Manual:** a Notes dictation in a long note shows mic close to write in under 1.5 s. |
| **P0-3** | **No dead button and no dropped text.** Drive the pill's offer from `TurnController.offer` and `payloadStarted`, not from the pill's own 10 s clock. After `payloadStarted`, Cancel either skips the remaining optional work and lands the text, or is not offered at all. Change the "nothing inserted yet" wording to "Inserting…" with the final words. | App/Core/PillPresentation.swift, App/Services/TurnController.swift | S | Low | A controller test: Cancel after payloadStarted does not log "payload dropped". A presentation test: no Use available text when payloadStarted is set. |
| P1-1 | The notch reports Working until the write finishes or the text is held; "landed" only after the write. | App/Services/TurnController.swift (presence signal) | S | Low | Presence sequence test |
| P1-2 | Make the Notes claim visible and three-valued. The field read returns field / no keyboard focus / unreadable. Unreadable in an Electron or Chromium app goes to ElectronAdapter (unverified landing). Unreadable in a native app goes to Notes with the row "No text box found in <App>: saved to Notes · Insert here". Raise the log to notice level. **Do not** type blind through DefaultAdapter: it allows Return-to-send and can fire single-key shortcuts. | App/Services/UtteranceLander.swift, App/Services/FieldContextReader.swift, App/Settings/NotesRouting.swift | M | Medium | Routing table tests per kind × readability |
| P1-3 | Held-row UX. Name the app that actually took focus, from the snapshot passed to `hold()`, and persist it. When the original pid, element and text version come back, make Insert here the default. It is confirmed by the hotkey or a click, **never by Return**. | App/Services/TurnController.swift, App/Core/PillDelivery.swift | S | Low | Hold-reason copy test |
| P1-4 | Ribbon aim in empty Chromium fields: accept an after-character rect with width 0 and height > 0 as the caret. On coarse rungs, aim at the leading edge of the first line (trailing edge in RTL), not the centre. | App/Overlay/TapeFlightGeometry.swift, App/Overlay/TapeFlightTarget.swift | S | Low; the ribbon only observes | Geometry tests using the Notes and Spotlight cases as regression references |
| P1-5 | Ribbon diagnostics: a geometry-only Q13 event `ribbon(rung, suppression or invalidation reason, onDisplay, locateMs)` at notice level. Then fall through to the next rung when a rect is off-display. | App/Overlay/TapeFlightController.swift, App/Diagnostics/TurnDiagnostics.swift | S | Low | Controller test: an off-display rung-1 rect falls to rung 3 |
| P1-6 | K04: show "Previous text still landing" instead of refusing silently. | App/Services/TurnController.swift | S | Low | Busy-copy test |
| P1-7 | Use the same turnID in `turn_diagnostics` and `turn_records`, so a turn can be traced end to end. | App/Diagnostics, App/Services/TurnStore.swift | S | Low | Join test |
| P2-1 | Collapse the pill to the 5-state model in section 4 and the notch to 5 states. | App/Core/PillState.swift, PillPresentation.swift, PillDelivery.swift, App/Ambient/PresenceState.swift | M-L | Medium (DesignCopyParityTests and the design fixtures change) | Update the parity fixtures, plus a state-mapping table test |
| P2-2 | Prefetch window context at key-down, in parallel with capture. | App/Services/UtteranceLander.swift, AppContainer.swift | M | Low | Timing test |
| P2-3 | Allow a new key press once the previous turn's text is final. Order the gate by turn start sequence, not arrival, so dictations never land out of order. | App/Services/TurnController.swift (acquireGate) | M | Medium | Ordering test with a slow first turn |
| P2-4 | An OCR caret-band rung for the ribbon (Q14 opt-in). Correct the CaretBand comment, which claims the ribbon uses it today. | App/Services/CaretBand.swift, App/Overlay/TapeFlightTarget.swift | M | Low | Rung test |
| P2-5 | A separate cleanup-skip key, so that turning style off for mid-document insertions does not also silently turn off LLM cleanup (CleanupStage.swift:130, FieldRolePipeline.swift:35-37). | Pipeline/Cleanup, App/Services/FieldRolePipeline.swift | S | Low | Stage test |
| P2-6 | Investigate the 6 empty or cancelled ChatGPT turns, starting with E1F62700: a 4.8 s capture that was cancelled with no text. | — | S | — | — |

Rejected proposals:
- "Type or paste into the frontmost app whenever no field can be read." VoicePlus would lose the secure-field check and Q1, and could fire app shortcuts.
- "Write via AX into the original element while another app is frontmost." That types into an app the user has left.
- "Return confirms Insert here." It risks sending a message.
- A global mouse-down monitor for ribbon aim. It is new input observation.

---

## 6. Still unconfirmed, and what to log next

- **ChatGPT:** whether `AXManualAccessibility` actually exposes a focused composer in the Codex/owl runtime. Probe it live (axprobe) before shipping P0-1. Whether keystrokes reach the composer has not been tested.
- **Notes:** which read is responsible for each 8.4 s gap is inferred from call order. Add per-source millisecond logging in `land()` and in each context source.
- **Docs ribbon:** which of the three causes (off-display rect, targetChanged invalidation, late locate) applies. Needs the P1-5 ribbon event.
- **Claude/x.com:** which rung answered and whether Chromium answers AXBoundsForRange after text lands. Needs the P1-5 event and an axprobe run.
- **ChatGPT turn linkage:** `turn_records` and `turn_diagnostics` use different turn ids, and the ChatGPT `turn_records` were partly pruned, so the bundle-to-decision link rests on timestamps.
- **Empty or cancelled ChatGPT turns (6):** cause unknown, possibly gating or VAD on short presses.
- **Things that are never persisted today:** ribbon outcomes (info-level only), the Notes-routing claim (info), the actual frontmost app at a hold, and per-step lander timing. Move all four to notice level or Q13 events.
