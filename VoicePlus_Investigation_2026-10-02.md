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

---

## Round 2 (same day): Terminal, app-aware input, coverage, context latency, Cancel, short presses

Same build (V5 1.13.0, pid 12840), code at HEAD `7eb07bc`, the same read-only DB and the same unified log. Four parallel investigations (terminal, Kivi comparison, app coverage, context latency) were each cross-checked against the code, the DB and the log before they went into this section. Confidence labels are the same as in round 1. Nothing was edited, and no app was controlled.

### R2.0 Corrections to round 1

1. **ChatGPT is not a renamed Electron app.** It is a Chromium browser runtime with OpenAI's "Owl" Electron-compatibility layer. Its framework is `com.openai.codex.framework` (Chromium 154 branch 8037), it ships `app.asar`, and its 272 MB framework binary contains `AXEnhancedUserInterface` but **no `AXManualAccessibility` string**. Round 1's P0-1 would have set an attribute this runtime does not read. The corrected fix is F3 below. **Confirmed.**
2. **ChatGPT text gets code formatting, not generic formatting.** The bundle id contains "codex", and AppCategory's substring rule maps "code" to `.code` (Pipeline/Style/AppCategory.swift:97). The DB shows it: "Code two and three" became "Code 2 and 3", and the first letter was lowercased. An auto persona saying "Terse, technical voice" was also generated for it. **Confirmed.**
3. **"Allow submit" protects nothing today.** `allowSubmit` is computed (UtteranceLander.swift:325), but no production code reads it, and nothing ever presses Return to send. The only way a dictation can send a message early is the keystroke fallback typing a bare line break in an app whose adapter is not newline-safe (TextInjector.swift:290-294). **Confirmed.**
4. **Brave did not "promote" paste.** Paste has only 2 samples and promotion needs 3. Keystrokes fell to 1 success in 4 and were demoted below paste (MethodRouter.swift:16-18, 41-44). The effect is the same: Brave now pastes first in every tab. **Confirmed.**
5. **The Notes stall is about four window walks per turn, not two** (section C2). **Likely.**
6. **The "6 empty or cancelled ChatGPT turns" are four different things.** Only one is a real engine bug (section C7). **Confirmed / likely per item.**

---

### A. The Terminal case: what happened to "cd documents/voiceplus"

Turn **AD658237**, 11:34:36 IST, Terminal (`com.apple.Terminal`, AXTextArea, not secure). What landed was `c didi reputation. docube akash voice plus.`, written by the terminal adapter. It was verified, and no Return was pressed.

| Stage | What it produced | Verdict |
|---|---|---|
| 1. Speech | 7.46 s recording (`2026-10-02-113444-118-raw.wav`) with 3-4 bursts and pauses of up to 2.4 s. | Long pauses make the recogniser end sentences, so it adds periods. **Likely.** |
| 2. Recogniser (TDT) | Offline repro: "C Dinda reputation. Document slash voice plus." "cd" was heard as "C" plus the start of the next word. | Recogniser miss. Nothing app-specific could fix "C Dinda" at this point. **Confirmed (repro).** |
| 3. Vocabulary boosting (CTC) | Swapped Dinda→**Didi**, Document→**DOCUBE**, slash→**Akash**, giving "C Didi reputation. DOCUBE Akash voice plus." | **This is the main damage.** All three are Contacts names imported at 09:16. The boost list is the dictionary's first 400 terms in alphabetical (uppercase-first) order (AppDatabase+Queries.swift:116-118, BoostVocabulary.swift:25-46). The swap guard accepted each pair at similarity ≥ 0.6 (VocabularyBooster.swift:171-185). **Confirmed.** |
| 4. Confidence | Each swapped word inherited the *highest* confidence of the words it replaced (VocabularyBooster.swift:130-138). So "Didi" and "Akash" were stored as confident. | Mistakes were hidden from every later repair step. **Confirmed.** |
| 5. Terminal formatter | Lowercased the text, but left "reputation." and the final period. Low-confidence words are never rewritten (TerminalFormatter.swift:12-13, 51-80), and a word's confidence includes its attached period (WordConfidence.swift:27-52). | Formatter ran correctly by its own rules, but those rules are wrong for a shell. **Confirmed.** |
| 6. Spoken symbols | "plus" is always turned into "+" in terminals (TerminalFormatter.swift:132-133). Even a perfect transcript would have become `cd documents/voice+`. | Formatter bug. **Confirmed.** |
| 7. Injection | Bracketed paste, no Return. 3.25 s from key-up to write. | Correct. **Confirmed.** |

Also worth knowing:
- **There is no `~/Documents/voiceplus` folder.** The repo is `~/Documents/VoiceInput`. So even a perfect `cd documents/voiceplus` would fail in the shell. VoicePlus should type what you said. Offering "did you mean VoiceInput?" as a choice is fine, but it must never silently change "voice plus" to "VoiceInput".
- **The Contacts boost list damages dictation in every app, not only Terminal.** Since the 09:16 import, stored transcripts include "There is no **Bucket**" (budget, Codex 09:18:22), "which **Cab** it this is" (tab, Brave 09:34:09), "google dot **Comp**" (com, Brave 09:37), "Is there any **Cleaning** happening" (Codex 09:30:17) and "both **Code** two and three" (Codex 09:35:13). Bucket, Cab, Comp, Cleaning and Code are all Contacts name parts inside the first 400 boost terms. **Likely** (each swap passes the guard's arithmetic; offline replay of these recordings is the confirming step). This is the top fix (F1).
- Because the 1,466 Contacts terms fill the 400-term cap first, corrections and learned words are never boosted (BoostVocabulary.swift:37-44). There are no corrections yet, so this has no effect today. **Confirmed.**
- "Teach the recogniser cd and ls" cannot work through boosting: terms shorter than 3 letters are dropped (BoostVocabulary.swift:14-16). Short commands have to be recovered after recognition, in the terminal formatter. **Confirmed.**

---

### B. App-aware input: "input profiles"

**Goal.** The same words should land differently in a terminal, a sheet, a document, a chat box and so on, in native apps and in browser tabs alike.

**What VoicePlus already has.** Most of the pieces exist but disagree with each other:
- an app category table (Pipeline/Style/AppCategory.swift);
- field roles and browser routes by URL or window title (Pipeline/Formatters/FieldRole/, BrowserSubApp.swift:57-125);
- a terminal formatter;
- per-app personas (19 rows in the `personas` table);
- injection adapters chosen by bundle id (Injection/AppAdapter.swift:343-359);
- a field reader that knows 12 browsers (FieldContextReader.swift:160-164).

There are three separate lists of terminals and browsers, and they disagree. For example, WezTerm is a "terminal" for formatting but gets the default adapter for typing. Dia and Comet are not known as browsers at all.

**The design: one profile per turn, decided in two steps.**

1. **At key-down (free, no window read):** use the frontmost app's bundle id, plus a runtime kind (native, Electron, Chromium app, browser) sniffed once per app version from its bundle on disk, plus the profile that app's window had on the previous turn. This gives a **provisional profile**. It picks the boosting vocabulary, because boosting is set up at key-down (AppContainer.swift:493-498; DictationCoordinator.swift:364). It also starts the bounded context read (section C2).
2. **At key-up (the focus snapshot is already taken here, DictationCoordinator.swift:472):** add the focused element's role and subrole, whether it sits inside a web area, the page URL (from the web area or the address bar), the window title as a fallback, single- or multi-line, and the secure flag. This gives the **final profile**. It drives symbol conversion, punctuation, cleanup, line-break keys and the write method. If it differs from the provisional profile, only boosting used the wrong guess; that is acceptable.
3. **Persist the profile and the signals that chose it** in `turn_records`, so a wrong choice can be traced.

**Signal priority:** secure field (always wins: refuse) > focused element role and web-area URL > window title > bundle id > runtime kind > unknown. An unknown app falls back to **prose with safe line breaks**.

**What each profile changes:**

| Profile | Typical surfaces | Boost vocabulary | Spoken symbols | Punctuation and caps | Cleanup / LLM | Line break / submit | Write method |
|---|---|---|---|---|---|---|---|
| Terminal / shell | Terminal, iTerm, Ghostty, Warp, WezTerm, kitty, VS Code terminal | Commands of 3+ letters (git, npm, grep, brew); never Contacts | slash, dot, dash, tilde, pipe, "dash dash"; "plus" only as in c++ | Lowercase; no sentence punctuation at all; recover cd/ls in command position | None | Never Return; bracketed paste strips line breaks | Bracketed paste |
| Code editor | VS Code, Xcode, Cursor, Zed, JetBrains | Identifiers from the user's dictionary and corrections | Same as terminal, plus brackets and "camel case" / "snake case" | Keep identifier casing as spoken; no trailing period | Light; never rewrite identifiers | Bare line break is fine inside the editor | AX, then keystroke |
| Spreadsheet cell | Sheets, Excel, Numbers | Numbers, units, months | "equals" only at the start means a formula | No trailing period; numbers as digits | None | ⌥↩ inside a cell; never Return (moves cell) | Keystroke; table paste later (P2) |
| Document / notes prose | Notes, Docs, Pages, Word, Notion page, Bear | Dictionary, corrections; Contacts only as full names | Symbols only when spoken as commands | Full sentence punctuation and caps | Full cleanup with the doc template | Paragraph break allowed only when the role proves a document body | AX, then keystroke |
| Chat / message | Slack, WhatsApp, Telegram, Messages, Discord, ChatGPT, Claude, Gemini | Contacts (thread participants first), dictionary | Emoji words, @mentions | Casual; trailing period optional | Light chat template | **Always ⇧↩; Return never sends** | Keystroke for web composers |
| Email | Mail, Gmail, Outlook | Contacts, dictionary | Email addresses ("at", "dot") | Full prose; greeting and sign-off on their own lines | Email template | Body: line break; subject: none | AX, then keystroke |
| Search / URL bar | Address bar, Spotlight, in-app search | Site names, dictionary | "dot com", slashes | No trailing period, no capitalised first letter | None | Never Return | AX |
| Form field (single line) | Name, phone, address fields | Contacts for name fields | Digits, "at", "dot" | No trailing period | None | Never a line break | AX |
| Canvas apps | Figma, Slides, Canva, Miro, FigJam | Dictionary | As prose | As prose | Light | ⇧↩ in comments; plain line break only in a text layer | **Hold unless a text box is being edited**; on canvas, letters are tool shortcuts |

**Browser tabs.** A tab is classified by its URL first and by its window title second (BrowserSubApp.swift:91-125, FieldRole.swift:77-80). Missing today:
- **No URL route:** Slides (`docs.google.com/presentation` falls into the Docs prose route), figma.com, canva.com, linear.app, miro.com.
- **No window-title name:** Google Slides, Notion, Gemini, Canva. `gemini.google.com` does have a URL route.
- **Web content anywhere** (any browser, any web view inside a native app) should get safe line breaks by structure: if the focused element sits inside a web area, use ⇧↩ and the keystroke path. That one rule covers Safari, Firefox, Dia, Comet, Vivaldi, Opera, Gemini desktop and unknown wrapper apps.

**Lessons from Kivi.** This comparison comes from the installed `/Applications/Kivi.app` bundle (strings and type names). The YouTube demo was not reviewed.
- *Worth copying:*
  - One "surface profile" from several signals.
  - A persona per app with 2-3 named presets per category. VoicePlus has the per-app table; it lacks the presets.
  - Context capture that starts while you speak and stops at a budget.
  - Rich paste per surface: an HTML table into Sheets, Markdown into Notion.
  - A browser list paired with an accessibility switch. This is plausible but inferred.
- *Not copying:*
  - Cloud recognition and server-side formatting.
  - Bundled analytics and crash reporting (PostHog, PLCrashReporter). These are against VoicePlus's no-cloud, no-telemetry rules.
  - Screen text fed into the recogniser. VoicePlus deliberately bans this: Engine/Biasing/README.md:5 says "never screen text", and decode-time context biasing was removed in V5 A1 after the Lab measured no gain. Reversing that is an owner decision (F27).

---

### C. Owner questions, answered plainly

#### C1. Does the ChatGPT/Electron fix also cover Gemini, Figma, other native apps, and web apps in Brave or Chrome?

**No.** It only fixes ChatGPT and other Chromium-based apps that hide their runtime. Everything else needs its own fix:

| Surface | Does the ChatGPT fix help? | Today | What fixes it |
|---|---|---|---|
| ChatGPT desktop | **Yes**, this is what it is for | Nothing typed; text goes to Notes | F3 (with a live probe first) |
| Unnamed Electron apps (Antigravity, ClickUp, Granola, Littlebird, Factory, Wispr Flow) | **Partly.** The "route by runtime kind" part sends them to the safe Electron path | Default adapter, keystroke fallback can type a bare Return | F3 + F6 |
| Claude desktop | Not needed (already Electron and typing) | Types; ribbon aims at the box, not the caret | F17 (ribbon aim) |
| **Gemini desktop** (`com.google.GeminiMacOS`) | **No.** It is a native SwiftUI app with a WebKit view, not Electron | Default adapter. AX insert is safe; the keystroke fallback could send early. Not tested live (no Gemini turns today) | F6 (web-area rule), add to chat category (F9) |
| Other native apps (Notes, Mail, Messages, Telegram, Spotlight) | Not relevant | Type correctly; Notes is slow | F4 (context) |
| **Figma desktop** | **No.** Already detected as Electron, but its own adapter is checked first and is not newline-safe | Line break in a comment box could post it; on the canvas, letters trigger tools | F11 |
| Brave / Chrome / Edge / Arc: Docs, Sheets, Gmail, x.com | **No**, and not needed for line breaks: these are already newline-safe (⇧↩, ⌥↩ in Sheets) | Type; Docs shows no ribbon; Brave now pastes first in every tab | F12 (router), F18 (ribbon) |
| **Google Slides (web)** | No | No route: treated as Docs prose; canvas | F10 + F11 canvas rule |
| **Figma web** | No | No route; canvas shortcut risk | F10 + F11 |
| Notion / Gemini web / Canva / Linear / Miro | No | Missing routes or title names | F10 |
| Safari, Firefox, Dia, Comet, Vivaldi, Opera | No | Default adapter: not newline-safe | F6 + F10 (one shared browser list) |
| Terminal, iTerm | No | Typing is fine; the words were wrong (ASR plus boosting) | F1, F7, F8, F9 |
| WezTerm, Hyper, Tabby, Termius, Warp (`dev.warp.Warp`) | No | Default adapter: **a multi-line dictation can run commands line by line** | F5 |

#### C2. Why did the context step take 17 seconds?

After recognition finished (in about 0.5 s), VoicePlus gathered "context" before formatting, synchronously, with no time limit (UtteranceLander.swift:216).
- **Where the time went:** in Notes that meant about four accessibility walks of the whole window. Two came from the "this/her" lookup and two from the ranked-context harvest (AXContextProviders.swift:88-94; AppContainer.swift:228-236).
- **Why each walk is slow:**
  - The walker has no clock limit, only a 5,000-node cap (AXReading.swift:63-69).
  - It sets no accessibility timeout (LiveAXNodeAccess.swift:87-90).
  - In "tail" mode it reads every text node in full before trimming to 2,000 characters (AXWindowReader.swift:50-55).
- **Why walks repeat:** the cache lasts 2 s, but it is stamped at the *end* of a roughly 4 s walk, so the next read often misses (WindowContentCache.swift:23, 45, 117-121).
- **Result:** two gaps of about 8.4 s each. The Contacts reads in between take only 25-30 ms.
- **Ruled out:** cleanup (0.5 s deadline) and the recogniser.
- **Confidence:** the overall cause is **confirmed** (log thread silence between the two Contacts fetches and `landing diff`). The four-walk split is **likely**; per-walk timing is not logged.
- **Separate:** ChatGPT turn E1F62700's 17.6 s was the speech engine, not context (C7).

#### C3. What does "read the window once per dictation" mean?

- **A dictation** is one turn: one hold-and-release of the hotkey, or one segment in Latch mode, from key-down until the text lands, is held or is dropped.
- **When the window is read today:**
  - A small, fast read of just the focused field at key-up and again just before typing (secure field, caret, safety checks). This stays as it is.
  - Several whole-window walks *after* recognition and *before* formatting. That is where the 17 s went.
- **The fix (F4):** one bounded snapshot per turn, shared by everything that wants context.
  - It starts at key-down, so it runs while you speak.
  - It is tied to the app and window you started in. Today it reads whatever app is frontmost when landing, which can be the wrong app (AXContextProviders.swift:24).
  - It reads the text around the caret first and the window second.
  - It stops at about 250 ms and lands with whatever it has.
- **Dictating again in the same window:**
  - Today: yes, everything is re-read (the cache lives only 2 s).
  - After the fix: each new dictation takes a fresh snapshot, started at key-down. It may reuse the previous one if the window's text has not changed, and it is thrown away on cancel, an empty turn, an app switch or idle.

#### C4. Is "only look up when you say 'this' or 'her'" enough?

**No, not on its own.** You are right that references take many forms: "reply saying yes", "fix the error above", "send it to the team", "isko bhej do". Screen context also does more than resolve pronouns. The better design separates three jobs:
1. **Recognition biasing** (which words the recogniser favours). This comes from the input profile and your own words: dictionary, corrections, the profile's command list, and chat participants for chat. It does not depend on trigger words. Screen text stays out unless you decide otherwise (F27).
2. **Formatting and cleanup context** (text before the caret, field role, thread). One bounded snapshot is **always** taken for every dictation, at key-down, under the deadline.
3. **Referent resolution** (working out what "this", "her" or "the error above" points to). It uses the same snapshot. Only the *extra* expensive lookups, the Contacts scan and the full on-screen item list, are gated on a broad trigger list. That list covers pronouns, "above/below/that error/this message", and Hinglish forms (isko, usko, ye, woh). The LLM or agent path can also request one.

Missing a trigger then costs a little accuracy, never 17 s.

One more catch: the agent ("act") path currently reuses the last "this/her" result as a side effect (DeixisService.swift:361-378 → ActStack.swift:287-288). If the lookup becomes lazy, that path must do its own lookup, or it will use stale screen lines from an earlier turn. **Confirmed.**

#### C5. What does the pill-button fix mean?

- **Today:** after about 10 s the pill shows "Still finishing your text … nothing inserted yet" with **Use available text** and **Cancel**. It does this on its own timer (PillPresentation.swift:504-516), regardless of where the turn actually is.
- **The problem:** by then the text has usually been recognised and is being formatted. At that point "Use available text" does nothing (TurnController.swift ~583-592), and "Cancel" ends the turn and **throws the recognised text away**.
- **The fix (F2):**
  - The pill shows only buttons that the turn's real stage can honour.
  - Before recognition finishes, Cancel means "stop, there is nothing to keep".
  - After recognition, Cancel means "**don't type it here**". The text is still saved to history (and to VoicePlus Notes if that setting is on), with Insert and Copy actions.
  - "Use available text" appears only while recognition itself is slow, and it lands the unboosted text.

#### C6. Does Cancel still send the text to Notes today?

**No.** Notes turn 42AB2F4E has its recognised text in `turn_records` ("Is the dictation working in Apple notes?"), but nothing was written, and it is in neither dictation history nor Notes. The cancelled ChatGPT turn E1F62700 is missing from history too. The text is lost. **Confirmed.**

#### C7. The "6 empty or cancelled ChatGPT dictations": root cause, investigated now

| Turn | What happened | Cause | Confidence |
|---|---|---|---|
| 97D650A3 (09:13:35) | Failed, no audio | First run: microphone permission had not been requested yet. Log 09:13:36.127 says "engine start failed: microphone access is not requested yet". Permission was granted at 09:13:39. | **Confirmed.** A one-off. |
| AD105A9F (09:16:54) and 62987E1F (09:17:16) | Cancelled about 100 ms and 220 ms after starting | **Key held for less than 250 ms.** By design, a press shorter than the hold threshold cancels, and a very quick tap arms the double-tap Latch (HotkeyStateMachine.swift:7-11, 82-99). Each tap is stored as a "cancelled" turn, with no on-screen hint about why. | **Likely** (timing from the log; the actual key-up times are not logged) |
| 2A89FC5E, DF355876, 9376334E | Empty | Holds of about 0.6-2.7 s with **no speech in the audio**. The no-speech gate logged "speech 0.00 s", and the recordings sit at about -50 dBFS of room noise (real speech today is about -35 to -25). The mic was working. Most of these came right after ChatGPT failed to type or right after a refused press, so these were retry presses. The same pattern appears in Claude and Notes. | **Likely** |
| **E1F62700** (09:17:59) | Cancelled after speech was recognised | **The real bug.** The words were recognised (pill "previewing"), but the final pass took 17.6 s, you pressed Cancel, and the text was dropped as a "late final pass" (TurnController.swift:632-634). The final pass mapped a ~100 MB model into memory at 09:18:01.851. That was the first such load in this app session. It is most likely the CTC boosting model, which loads only once the dictionary is non-empty. The Contacts import at 09:16 had just made it non-empty, and the load and the 400-term setup run inside the final pass with no deadline (CTCVocabularyBooster.swift:49-58, 123-132, 151-153). | Stall and loss **confirmed**; the model-load cause is **likely** |

The same ~100 MB model was mapped again at 09:29, 09:45, 10:25 and 11:34. That suggests it is unloaded when idle and reloaded on demand, which adds roughly 1 s to the first dictation after a pause (**likely**).

**So:** two were taps that were too short, three were silent presses, one was a first-run permission, and one was a real engine stall plus text loss. Fixes: F2 (Cancel keeps text), F14 (engine deadline and warm model), F15 (tap and silence feedback).

---

### D. Final consolidated fix list (round 1 + round 2)

Effort: S is under a day, M is 1-3 days, L is more than 3 days. "Symptom" names what you saw.

#### P0: stop losing or corrupting text

| # | Problem | Change | Files | Effort | Risk | Tests | Symptom fixed |
|---|---|---|---|---|---|---|---|
| **F1** | Contacts names swap ordinary words in every app | Keep Contacts-sourced terms out of the boost list now (filter on `dictionary_term_meta.source`). **Ship this alone, first.** | App/Services/BoostingWiring.swift, Engine/Biasing/BoostVocabulary.swift | S | Low (Contacts names lose boosting until F7) | Boost list has no Contacts terms; offline replay of the 11:34:44, 09:18:22 and 09:34:09 recordings no longer shows Akash/DOCUBE/Bucket/Cab | Terminal garble; "Bucket", "Cab", "Comp" in Codex/Brave |
| **F2** | Cancel throws away recognised text; pill offers buttons that do nothing | Pill buttons follow the turn's real stage (TurnController offer + payloadStarted), not the pill's 10 s timer. After recognition, Cancel = "don't type here": save to history (and Notes if enabled) with Insert / Copy. Discard only by Esc during capture. (Round-1 P0-3, extended.) | App/Core/PillPresentation.swift, App/Services/TurnController.swift, dictation history writer | S-M | Low | Cancel after recognition never logs "payload dropped"; the text appears in history; no "Use available text" after payloadStarted | Lost Notes text (42AB2F4E), lost ChatGPT text (E1F62700), dead button |
| **F3** | ChatGPT gets nothing typed | New runtime kind "Chromium app" (Chromium framework + app.asar, not a browser). Route it, and every Electron app, by runtime kind to the safe Electron path (⇧↩, keystrokes first). Turn on its accessibility with `AXEnhancedUserInterface` (try `AXManualAccessibility` too). Check success by probing the focused element, not the call's return code, and cache the result per process. Respect the visible "Expose text in Chromium" setting. Map `com.openai.codex` to chat and regenerate its persona. (Round-1 P0-1, corrected.) | Injection/AppAccessibilityEnabler.swift, Injection/AppAdapter.swift, Pipeline/Style/AppCategory.swift | M | Medium: unproven that the attribute builds the composer tree; costs some Chromium CPU | Fake ChatGPT-like bundle → Chromium app → safe adapter; registry routes unnamed Electron apps correctly. **Live probe first** | ChatGPT nothing typed / sent to Notes; code formatting in ChatGPT |
| **F4** | 17 s context stall in Notes; wrong-app reads; privacy rule checked too late | One bounded **turn context**: started at key-down, tied to the starting app and window, caret text first, about 250 ms deadline. AX timeout 0.1-0.25 s, node cap about 800, a per-node cancel check, one walk at a time per window, tail mode reads only the end of the focused text. Check the app's "contextual reading" rule *before* any read. Contacts and full lookups only on the broad trigger list (C4). The agent path does its own lookup and receives screen lines as labelled data, not inside its goal text. Throw the snapshot away on cancel, empty turn, app switch or idle. (Round-1 P0-2 + P2-2.) | App/Services/UtteranceLander.swift, AppContainer.swift, DeixisService.swift, AXContextProviders.swift, ActStack.swift, Injection/AXReader/AXWindowReader.swift, AXReading.swift, WindowContentCache.swift | M-L | Medium: a stop-waiting deadline without cancellation would leave walks running and slow the safety reads | A mock 10 s context source lands within about 400 ms; no Contacts or window read when the rule is off; a read is bound to the target pid; no stale act lines. **Manual:** Notes in a long note lands in under 1.5 s | "Still finishing", "Destination changed", K04 refusals, lost Notes dictation |
| **F5** | WezTerm, Hyper, Tabby, Termius, Warp get the default adapter: line breaks can run commands | The terminal adapter matches every app the category table calls a terminal, from one shared list | Injection/AppAdapter.swift, Pipeline/Style/AppCategory.swift | S | Low | Every terminal id resolves to the terminal adapter. **Live:** WezTerm | Safety (no symptom reported yet) |
| **F6** | Web content outside known browsers can get a bare Return (Gemini, Safari, Dia, Comet, Vivaldi, Opera, unnamed wrapper apps) | Structural rule: if the focused element sits inside a web area, or the app is Electron or Chromium, type line breaks as ⇧↩ and never post a bare line break from the keystroke fallback | Injection/TextInjector.swift, Injection/AppAdapter.swift | S | Low | Default adapter in a web area emits ⇧↩. **Live:** Gemini, Safari | Early-send risk in Gemini and other browsers |

#### P1: right words and right format per app

| # | Problem | Change | Files | Effort | Risk | Tests | Symptom fixed |
|---|---|---|---|---|---|---|---|
| **F7** | Boost list is alphabetical; one list for all apps | Rank terms: corrections and learned words first, then dictionary terms by use, then Contacts (full names and uncommon name parts only, chat/mail/prose profiles only). Choose the list at key-down from the frontmost app's provisional profile. Keep one cached rescorer per profile class (terminal/code, prose, chat) so switching apps does not rebuild it | Engine/Biasing/BoostVocabulary.swift, App/Services/BoostingWiring.swift, AppContainer.swift, Engine/Decoder/CTCVocabularyBooster.swift | M | Medium | Ranking tests; corrections survive a full cap; per-class cache | Contacts noise; future corrections never boosted |
| **F8** | Boosting can eat spoken symbols and hide its own mistakes | Protect symbol words (slash, dot, dash, plus, at, colon, tilde) from swaps unless the letters are identical ("voice plus" → "VoicePlus" still allowed). A swapped word takes the *lower* confidence and is tagged as boosted, so later stages and the UI treat it as uncertain | Engine/Decoder/VocabularyBooster.swift | S-M | Low | slash→Akash rejected; compound merge still works; boosted words appear in uncertain spans | "Akash" for "slash"; hidden errors |
| **F9** | Terminal formatting leaves periods, misses cd, turns "plus" into + | In terminal and code profiles only: strip sentence punctuation from every word, including low-confidence ones; recover "C D"/"see dee"/"CD" as `cd` (and ls etc.) in command position; "plus" is + only after a single letter or when spoken twice (c++). Never Return. Add Gemini to the chat category | Pipeline/Formatters/TerminalFormatter.swift, Pipeline/Style/AppCategory.swift | S | Low (scoped to terminal and code) | Replay of the 11:34:44 recording; c plus plus → c++; "voice plus" stays words | Terminal output |
| **F10** | Three disagreeing app lists; missing web routes | One **input profile resolver** (section B) that formatting, cleanup, personas and injection all read. One shared browser list (add Dia, Comet, Vivaldi, Opera, Chromium, Safari, Firefox). Add routes and titles for Slides, figma.com, Notion, Gemini title, Canva, Linear, Miro. Persist profile and signals in `turn_records` | Pipeline/Formatters/FieldRole/BrowserSubApp.swift, FieldRole.swift, Pipeline/Style/AppCategory.swift, App/Services/FieldContextReader.swift, Injection/AppAdapter.swift, App/Services/TurnStore.swift | M | Medium | Table test: every known app and URL maps to one profile; no list disagrees | Wrong format per app and tab |
| **F11** | Figma and canvas apps: line breaks can post comments; letters can trigger tools | Figma adapter becomes newline-safe. In Figma, Slides, Canva and Miro, hold with "Click into a text box first" unless an active text edit is detected | Injection/AppAdapter.swift | M | Medium | Adapter tests. **Live:** Figma desktop and web | Figma and Slides safety |
| **F12** | Brave learned "paste first" for every tab | Never move paste ahead of keystrokes in a newline-safe adapter; an "unconfirmed" landing counts as neutral, not as a failure | Injection/MethodRouter.swift, Injection/AppAdapter.swift | S | Low | Router test | Paste into Sheets/Figma web |
| **F13** | Unreadable field + no secure check | Before any write with no readable field, refuse or hold if macOS secure input is on (password fields turn it on). Prerequisite for F3 and F19 | Injection/TextInjector.swift | S | Low | Unit test with a fake secure-input flag | Safety |
| **F14** | Engine final pass can take 17 s; model reloads add about 1 s | Load the boosting model in the background (at launch or key-down), never inside the final pass. Put a deadline (about 1.5 s) on boosting and land the unboosted text if it runs over. Log per-stage engine ms (recognise, model load, rescore) and store the pre-boost raw text in `turn_records` | Engine/Decoder/CTCVocabularyBooster.swift, FluidAudioTDTDecoder.swift, App/Services/TurnController.swift, TurnStore.swift | M | Low | A slow fake booster lands unboosted text within the deadline | E1F62700 stall and loss; slow first dictation |
| **F15** | Short taps and silent presses look like failures | A tap under 250 ms shows "Hold to talk · double-tap to lock" and is not stored as a cancelled turn. A no-speech turn shows "Didn't hear anything". Log key down/up times with the turn id. Optional: a "tap to start / tap to stop" setting for people used to toggle-style apps | App/Core/HotkeyStateMachine.swift (copy only), App/Services/DictationCoordinator.swift, TurnController.swift | S | Low | Tap → hint and no turn record | "Empty/cancelled" ChatGPT turns |
| **F16** | Clipboard managers record every pasted dictation | Mark VoicePlus's paste as transient and auto-generated (standard pasteboard markers) | Injection/ClipboardPaster.swift | S | Low | Pasteboard types test | Privacy |
| F17 | Ribbon lands mid-box in empty Claude/x.com fields | Round-1 P1-4: accept a zero-width caret rect; aim at the leading edge on coarse rungs | App/Overlay/TapeFlightGeometry.swift, TapeFlightTarget.swift | S | Low | Geometry tests | Claude/x.com ribbon |
| F18 | No ribbon in Docs; ribbon failures never logged | Round-1 P1-5: ribbon diagnostics event, then fall through to the next rung when a rect is off-display | App/Overlay/TapeFlightController.swift, App/Diagnostics | S | Low | Controller test | Docs ribbon |
| F19 | Silent Notes routing when no field is found | Round-1 P1-2: field / no focus / unreadable. Unreadable in Electron or Chromium apps → safe Electron path (after F13). Visible "Saved to Notes · Insert here" row | App/Services/UtteranceLander.swift, FieldContextReader.swift, App/Settings/NotesRouting.swift | M | Medium | Routing table tests | ChatGPT text in Notes |
| F20 | Notch says "landed" at recognition time | Round-1 P1-1: Working until the write finishes or the text is held | App/Services/TurnController.swift | S | Low | Presence sequence test | "Done" while nothing typed |
| F21 | Held row names the wrong app | Round-1 P1-3: name the app that took focus; Insert here confirmed by hotkey or click, never Return | App/Services/TurnController.swift, App/Core/PillDelivery.swift | S | Low | Copy test | "Destination changed" confusion |
| F22 | Presses refused silently while busy | Round-1 P1-6: "Previous text still landing" | App/Services/TurnController.swift | S | Low | Copy test | K04 swallowed presses |
| F23 | Turn ids differ between tables | Round-1 P1-7: one turn id in diagnostics and records | App/Diagnostics, App/Services/TurnStore.swift | S | Low | Join test | Debuggability |

#### P2: polish and owner decisions

| # | Change | Effort | Notes |
|---|---|---|---|
| F24 | Collapse pill and notch to the 5-state models (round-1 P2-1) | M-L | Do it after F2, F4 and F20, so fewer states hide fewer failures |
| F25 | Allow a new press once the previous text is final, in start order (round-1 P2-3) | M | After F4 |
| F26 | Terminal folder-name completion from the shell's current folder. Use the cwd of the foreground shell process, offer a match as a suggestion, never trigger a Files & Folders prompt, never press Return | M | Listing `~/Documents` would trigger a macOS permission prompt (not sandboxed). If wanted, ask once in Settings. **Owner decision** |
| F27 | Feed a small, profile-scoped set of screen terms (chat participants, file names) into boosting | M | Reverses the documented "never screen text" rule; the Lab measured no gain before. **Owner decision**; default no |
| F28 | Rich paste: an HTML/TSV table into Sheets when the output is a table; Markdown into Notion | M | Formula guard only when you did not say "equals". Keep secure-field and no-send checks first |
| F29 | 2-3 named presets per app category in the Apps rules UI (Kivi-style) | S-M | Uses the existing personas table |
| F30 | Separate "skip cleanup" from "style off" for mid-document inserts (round-1 P2-5) | S | |
| F31 | OCR caret-band ribbon rung (round-1 P2-4) | M | Opt-in |

#### Order and dependencies

1. **F1 now, on its own.** It is a one-line filter, it stops the word corruption everywhere, and it may also make E1F62700-style stalls rarer.
2. **F2, F14, F23, and the logging parts of F4 and F18** next, so every later change can be measured: per-stage engine ms, per-walk context ms, ribbon outcome, pre-boost text.
3. **F5, F6 and F13** together. They are small safety changes, and F13 must land before anything types into an unreadable field (F3, F19).
4. **Live probes, then F3.** ChatGPT, Gemini and Figma first need a read-only accessibility probe.
5. **F4**, then **F10** (the profile resolver reads the same turn snapshot), then **F7, F9, F11, F12**.
6. **F24** (state collapse) last.

#### Still needs a live test (cannot be proven from logs or code)

- **ChatGPT:** does `AXEnhancedUserInterface` (or `AXManualAccessibility`) expose a focused composer, and do keystrokes reach it?
- **Gemini desktop:** is the composer web content (inside a web area) or a native text view?
- **Figma desktop and web:** what does the focused element look like on the canvas versus in a text layer versus in a comment box?
- **WezTerm:** what does it expose over accessibility, and does F5 bracketed paste behave?
- **Contacts damage:** replay the 09:18:22, 09:34:09 and 11:34:44 recordings with and without F1.
- **E1F62700:** confirm the stall was the first boosting-model load, using F14's timing logs.
- **Notes:** per-walk node count and ms, to confirm the four-walk model and size the deadline.
- **Short presses:** key down/up times per turn (F15 logging), to confirm the tap explanation.

---

## Round 3 (same day): FluidVoice, ChatGPT ground truth, Kivi, model residency, the context rubric

Same build (V5 1.13.0, pid 12840), code at HEAD `9b86614`, the same read-only DB and unified log. Six investigations ran: FluidVoice source, the installed ChatGPT.app, Kivi (binary and demo), model residency, and the context rubric. A second agent re-checked each one against the source, the bundles, the DB and the log, and only the parts that survived that check are reported here. Nothing in VoicePlus was edited, and no app was controlled or typed into. FluidVoice is GPLv3, so this section describes its design and copies none of its code. Confidence labels are the same as in earlier rounds.

**Your direction for this round.** Intelligent input must be general, not a list of per-app or per-site rules that breaks on any app nobody listed. VoicePlus should work out three things: which app or web app you are in, what you are likely to type there, and what is already on screen. It should then weigh those sources with one cascading rubric, in which Contacts are one source among many. F26 (folder names in Terminal) and F27 (on-screen words) are approved in principle. Live tests are deferred until the confidence gate at the end of this section is met.

### R3.0 Corrections to rounds 1 and 2

1. **Contacts do more than fill the boost list. They fill every context channel.** All 1,466 Dictionary rows on this Mac are Contacts imports (`dictionary_term_meta`: contacts = 1466, nothing else). They are tagged as Dictionary terms (Engine/Biasing/Sources.swift:106-108). That puts them in the top "authored" tier, which never decays (ContextRanker.swift:124; Ranker.swift:34), so the lower 0.4 weight meant for Contacts never applies. The result is that Contacts fill all three channels ahead of anything on screen: the 400-term boost list (BoostVocabulary.swift:37-44), the 60-word "spell exactly" list (Personalisation.swift:25) and the 1,000-character cleanup context (PromptBuilder.swift:32). Tiers are strict: a lower tier is used only after every higher one is exhausted. This is the concrete case of "Contacts trump everything" that you objected to. **Confirmed.**
2. **Round 2 said the Lab "measured no gain" from screen text. That is inaccurate.** The pre-V5 test fed 18 proper nouns as a *participants* list into the old decode-time booster (DECISIONS.md:22-55). Screen text has never been measured through today's CTC rescorer. F27 is therefore untested, not disproven. **Confirmed.**
3. **The Kivi YouTube demo has now been reviewed.** You were right that the in-app browser could do it. In round 3 the page loaded, the transcript was read, and frames were captured (the Sarvam Epoch 2026 livestream at about 3:06:43, the "made for you" and "hey kivi" slides, and the Sheets joining form). Round 2's line "The YouTube demo was not reviewed" is withdrawn. **Confirmed.**
4. **Round 2's F14 said "load the boosting model at launch or key-down". Key-down is the wrong place, and the model does not even load there today.** Only the word list is built at key-down (AppContainer.swift:493-498). The ~100 MB model load and the rescorer build both run inside the final recognition pass. Also, "key-down" in this document always means pressing the dictation hotkey, never any key. Section D replaces this with load-at-launch. **Confirmed.**
5. **A pasted line break is safe in a terminal only when bracketed paste is on.** That is the shell's or app's setting, not a general property of terminals. zsh turns it on by default. Some REPLs, vim's normal mode and ssh into older shells do not, and there a pasted newline runs the line. VoicePlus's terminal adapter already wraps multi-line text in bracketed-paste markers (Injection/AppAdapter.swift:171-176), so keep it. **Likely** (general terminal behaviour, not tested live).
6. **The "structural" field classifier is still a substring list.** FieldRole decides "terminal" from hints such as "console", "repl" and "shell" (FieldRole.swift:247), and the first match wins. A web dev console, or a chat *about* consoles, can flip a field to terminal. It puts the signals in the right order of authority, but it is not yet general. **Confirmed.**
7. **New: most of the delay you feel comes after recognition.** From "recognised" to "typed into the app" took a median of **1.25 s** across 16 turns today, with tails of 4.4 s (Claude), 4.7 s (Brave) and 17.1 s (Notes). That costs more on every dictation than the boosting-model reload does. The cause is not yet traced. **Confirmed** (log parse); cause unknown.

---

### A. How FluidVoice handles "any app"

**Short answer: it doesn't try to understand the app. It delivers text in a way that works almost everywhere, and checks afterwards.** All of the following is confirmed from `FluidVoice-main/Sources`.

| Mechanism | What FluidVoice does | Where |
|---|---|---|
| Default delivery | **Clipboard paste for every app.** It puts the text on the clipboard as a temporary item, posts a system-level ⌘V, waits 500 ms, then restores the old clipboard. The temporary item is marked Transient, AutoGenerated and Concealed, so clipboard managers skip it. | SettingsStore.swift:6028-6074 (forced to "Clipboard Paste (Recommended)"); PasteDeliveryCoordinator.swift:246-256, 566-577, 612 |
| Other mode | Types the text as Unicode keystroke events into the focused app's process. If that fails, it uses Accessibility insertion, then system-level keystrokes. The mode is labelled "Direct Paste" but it actually types. | TypingService.swift:797-818, 1188-1204 |
| Gate before writing | Refuses only when the focused element is **certainly** not editable (a button, a menu and so on). Groups, web areas, windows and unknown roles all go ahead. | DeliveryTargetAssessment.swift:25-36 |
| Target | Remembers the focused app (PID) and window at the start, and delivers there. No readable text field is required. | TypingService.swift:158-206, 268-365 |
| Verification | After pasting, it reads the field back. It reports "not landed" only when the same element's value, length and caret are all unchanged. If the field can't be read, or you clicked or typed in the meantime, the result is "unknown" and treated as fine. | PasteVerifier.swift:77-120 |
| Line breaks | No special handling: they travel inside the pasted text. The only synthetic Return is the opt-in "Spoken Send", which is blocked in apps whose name contains terminal, iterm, warp, ghostty, kitty or alacritty. | TypingService.swift:860; ContentView.swift:2296-2306 |
| App-specific rules | Few, but they exist. Ghostty is forced onto paste. Slash commands get special handling when the app name, bundle id or window title contains codex, chatgpt, claude, cursor or windsurf, and @mentions when it contains slack, discord or teams. Its earlier per-app and per-site prompts are commented out ("using general processing only"). Users can bind their own prompt to an app. | TypingService.swift:387, 528-529; ASRService+DictationLiteralFormatting.swift:399-417; ContentView.swift:2490-2575 |
| Context | App name, bundle id and window title go to its AI step on one path. It does not read screen text, use OCR or use Contacts, and does not enable Chromium accessibility (0 hits for AXManualAccessibility or AXEnhancedUserInterface). | ContentView.swift:2709-2713 |
| Spoken symbols | Converted only after an explicit cue word ("literal", configurable), and the feature is off by default. | ASRService+SpokenPunctuationFormatting.swift:136-138; SettingsStore.swift:4536-4544 |
| Boosting | One global list of words the user adds by hand, capped at 256 by weight, with similarity and confidence thresholds (0.72 / 0.64). | ParakeetVocabularyStore.swift:76-83, 336-345 |
| Model loading | Loads the recogniser and the boost model together at app launch and keeps them loaded. It preloads again at record start, and as a last resort loads at stop if still cold. Boost *rescoring* still runs in the final pass. | ASRService.swift:2353-2367, 3547-3555; FluidAudioProvider.swift:365-385 |

**Contrast with VoicePlus.** VoicePlus needs to *read* the focused field before it writes. When it can't (ChatGPT), the text goes to Notes. FluidVoice writes to the remembered app and window, and checks afterwards. So FluidVoice wins on reaching any app, and VoicePlus has the better parts everywhere else: context, formatting, refusal on secure fields and readback. FluidVoice also confirms there is no "magic understanding" behind its reach. It is a better delivery fallback.

**What VoicePlus should adopt (design only):**
1. **A delivery ladder that does not need a readable field.** If the app and window that were focused at key-up are still focused, and macOS secure input is off, deliver anyway: paste for multi-line text or web content, keystrokes otherwise. Check afterwards when the field is readable, and treat "can't tell" as neutral. Send to Notes only when focus actually moved, there is no window, or the field is secure. (New fix N3.)
2. **Refuse only when certain.** Block known non-text roles. Hold on canvas-like focus (N15). Never refuse just because the role is unfamiliar.
3. **Transient clipboard markers and clipboard restore** whenever VoicePlus pastes (N18).
4. **Spoken symbols need structure or a cue.** Convert "slash", "dot" and "plus" only when the words around them form a path, URL, command or formula, or when you say a cue word. This replaces fixed per-app tables (N12).
5. **Load the core models at launch and keep them loaded** (section D).

**What not to adopt:**
- No screen context.
- A boost list the user builds by hand.
- Name-substring app rules (the same brittleness you're worried about).
- Treating an unreadable paste as success without telling anyone. VoicePlus should log it as "unverified".

**Limits of paste-first.** Paste is not universal either. Sheets splits pasted multi-line text into rows. Some editors paste rich text. Terminals depend on bracketed paste. So the write method still comes from the surface kind (section E), and paste is the fallback for unreadable fields, not the new default everywhere.

---

### B. ChatGPT ground truth

**The installed ChatGPT.app is Chromium all the way through, not SwiftUI, and Chromium is not just its in-app browser.** **Confirmed** from the app's own files on disk. No outside sources were used.

| OpenAI app | On this Mac? | What it is built on | Evidence |
|---|---|---|---|
| `/Applications/ChatGPT.app`, bundle **`com.openai.codex`**, v26.928.31416 (build 12553) | Yes (pid 57054) | OpenAI's **Codex desktop app, shipped under the ChatGPT name**. Its runtime is "**Owl**": Electron's API on top of a renamed **Chromium 154** framework. The whole UI is web content. | Info.plist: `BundleSigningBaseName=Codex`, `ChromiumBaseVersion=154.0.8037.57`, `NSPrincipalClass=BrowserCrApplication` (Chrome's class), `ElectronAsarIntegrity`, `electron.icns`. `owl-electron-app.json`: packaged from `codex-apps/electron/out/ChatGPT-darwin-arm64`, runtime "owl". `app.asar` is 538 MB; its `package.json` says `openai-codex-electron`, productName Codex, Electron 42.3.0 tooling. The main binary is a 70 KB stub that links only libSystem and loads `Codex Framework.framework` (272 MB, `Chrome/154.0.8037.57`, built from `owl/browser/api/electron_api_*` sources). Helpers: Codex (Renderer), (GPU), (Service). There is **no SwiftUI** link and no `NSHostingView` in the framework. |
| `com.openai.chat`, the older native ChatGPT Mac app | **No** (mdfind finds nothing) | Native, not Chromium. This is most likely the "SwiftUI" app you remember. | Its history was not checked locally. **Likely.** |

**Why the two of us disagreed.** Both products are called "ChatGPT". What you remember fits the older native app. What is installed is the Codex app under the ChatGPT name. Round 1 called it "a renamed Electron app" from its `app.asar` and Electron markers. Round 2 corrected that to Chromium plus Owl. Both came from reading the bundle on disk.

**Is the composer an "in-app browser" field?** No. The chat UI itself is web content. `contenteditable` appears in 48 of its JS files, including the conversation page and the composer controls. ProseMirror (the editor ChatGPT web uses) appears in 11 files, including the shared app bundles. `<textarea` appears 0 times. So the composer is very likely a ProseMirror contenteditable. Setting its value directly through Accessibility may not update the editor's own state, so typing or pasting, then reading back, is safer. **Confirmed** for the strings; the composer's accessibility role is a **hypothesis** until a live, read-only probe.

**Why it fails today.**
- VoicePlus classifies the app as plain native. Its Electron check looks for a framework named `Electron Framework.framework`, but this one is `Codex Framework.framework` (Injection/AppAccessibilityEnabler.swift:42-66). So the app's accessibility tree is never switched on.
- No field can be read, so all 15 `com.openai.codex` turns today have `writeAttempted:false`, and 0 rows in `injection_outcomes`.
- Its bundle id contains "codex", so the substring rule `"code" → .code` (Pipeline/Style/AppCategory.swift:97) gives it code formatting. A "Terse, technical voice" auto persona was then saved for it.
- **Confirmed.**

**Two causes, not one.** FluidVoice inserts into this exact app (its own test fixture uses `com.openai.codex`, DictationE2ETests.swift:456-457) without ever enabling accessibility. So VoicePlus's "no readable field → Notes" policy causes the failure as much as the missing accessibility attribute does. **Likely.**

**Corrected F3, now split into three fixes:**
- **Delivery (N3).** With the delivery ladder in section A, ChatGPT gets text even before its accessibility tree is on. Routing apps "by runtime kind to the safe Electron path" is no longer needed for delivery. Line-break safety comes from structure instead (N5).
- **Accessibility for context and verification (N10).** Turning on Chromium accessibility is still worth doing, because it is what makes on-screen words (F27), text before the caret, caret geometry for the ribbon, and readback possible.
  - **Detect the runtime from the bundle, not a list of ids.** Signals: an `app.asar` file or `ElectronAsarIntegrity` key, a `BrowserCrApplication` or `ElectronApplication` principal class, a Chromium framework of any name, or `* (Renderer).app` helpers.
  - **Then try `AXManualAccessibility` first**, which has no known side effects. Kivi uses only this attribute, with a per-app off switch. **If a probe of the focused element still finds no editable element, try `AXEnhancedUserInterface`.** This ChatGPT build contains only that string (2 hits, against 0 for AXManualAccessibility).
  - **Judge success by the probe** (an editable element, or one whose selected text range can be set, inside a web area), not by the call's return code. Cache the result per process and app version.
  - **Respect the existing "Expose text in Chromium browsers" setting** (`injection.exposeChromiumText`, App/Settings/InsertionSettings.swift:7-13) and add a per-app off switch.
  - **Known cost:** `AXEnhancedUserInterface` makes window managers (Rectangle, yabai) animate or lag on window moves, and a full Chromium accessibility tree costs CPU and memory (**hypothesis**, general knowledge). So enable it lazily, only on the app you are dictating into, and measure the cost.
- **Category (N9).** **Dropped:** "map `com.openai.codex` to chat". That swaps one wrong per-bundle label for another, because the same app is a chat box in one window and a coding agent in another. Instead:
  - Fix the generic `"code"` substring rule.
  - Decide chat or code from the surface: the window title, a composer inside a web area, and the text around the caret.
  - Reset the stored auto persona for this app.

---

### C. Kivi: what it does, how, and what to copy

**How it was examined.** The installed `/Applications/Kivi.app` (ai.sarvam.Kivi 2026.09.25.1212) was examined statically, read-only: its strings, linked frameworks and bundle contents, its local store and its saved settings. The YouTube demo was reviewed separately (R3.0 #3). No code was disassembled and no network traffic was captured. Going that far would raise terms-of-service questions, and it wouldn't reveal much more, because Kivi's speed lives on Sarvam's server.

**Confirmed findings:**
- **Recognition is cloud-only.** No speech models ship in the app, and there is no CoreML, Speech or Vision linkage. Audio streams to `wss://kivi.sarvam.ai/v1/dictate/stream`. "Offline" mode only records audio for later. It bundles PostHog analytics and a crash reporter.
- **Why it feels fast:**
  - a warm microphone (`WarmCaptureHolder`);
  - a pre-opened connection with buffered audio (`PreConnectBuffer`);
  - streaming while you speak, so recognition is nearly done when you let go;
  - screen context captured *during* speech under a time budget.
- **Screen context runs on every dictation, not only "hey kivi".**
  - It reads visible text through Accessibility only: no screenshots, no OCR. Strings include `captureFrontmostVisibleText`, `AXVisibleChildren`, `perAppMaxNodes` and `maxTermsPerCapture`.
  - It sorts what it finds into **file names, people's names, technical terms and links** ("%ld terms (raw / files / names / tech / links)").
  - It sends the result with the end-of-speech signal. If capture overruns its budget, it sends an empty context ("produced nothing within the %ldms EOS budget").
  - It throws the capture away if the frontmost app changed.
  - It records which screen terms ended up in the transcript (`matchedScreenContextTerms`).
  - Whether the server uses these terms in recognition itself or only in the AI clean-up step cannot be seen from the app: **unknown**.
- **A general resolver, with known-app tables underneath.**
  - The general resolver: `SurfaceProfileResolver`, `SurfaceSignals`, `SurfaceContextResolver`.
  - The tables: about 45 bundle ids are built in (terminals including WezTerm, Ghostty, Warp and kitty; com.openai.chat and com.openai.codex; Figma, Slack, Excel), plus one URL (`docs.google.com/spreadsheets`).
  - Surface-specific helpers: `SheetsFormulaGuard`, `NotionMarkdownPasteBuilder`, Discord Markdown and terminal handling.
  - Every app gets a persona, and an unlisted app falls back to "general".
  - Some of the per-app persona mapping on this Mac comes from your own Kivi settings (`appAssignments`), not from Kivi's built-in rules.
- **Chromium accessibility:** `AXManualAccessibility` only, with a per-app kill switch (`electronAccessibilityPrimer.disabledBundleIDs`). There is no `AXEnhancedUserInterface` at all. That means Kivi's primer most likely does nothing for the installed ChatGPT build, so Kivi probably gets text in by pasting and reading back.
- **Delivery:** paste with readback (`PasteLandingVerifier`), transient and concealed clipboard markers, and an event tap with Unicode typing in the main binary.
- **Learning:** corrections are stored as "heard aliases" next to the raw recognised text, per app, with full-text and phonetic search. It also imports the Wispr Flow dictionary.
- **Your Kivi Terminal history is only 3 rows.**
  - "CD documents." became `cd documents`.
  - "CD documents slash voice plus." became `cd documents/voice+`. Kivi turns "plus" into "+" too.
  - "are about to end up." became "Are about to end up." (period kept).
  - Kivi never looks at the disk, so F26 would put VoicePlus ahead here.
  - Three rows are too few to rank its terminal quality.

**From the demo** (frames and transcript checked):
- The "made for you" slide lists dictionary, shortcuts, styles and shared terms.
- The "hey kivi" assistant slide marks "factual answers and reasoning" as *not available yet*.
- The Sheets joining-form demo filled a column. The claim that it "inferred Father without being told" is **unverified**: the transcript does not show that the word wasn't spoken.
- No public speed or accuracy numbers were given.
- **Cross-check against the owner-supplied transcript (3:06–3:18):**
  - **Form fill:** the speaker said "my dad's details" aloud, so filling a "Father" field is a light dad→Father mapping, not inference from nothing.
  - **Stated features:**
    - Their own ASR "with intelligence on top".
    - Translating on-screen text ("Kiwi understands context").
    - Custom dictionary, "speed dials" (shortcuts), personalised output, and a style chosen per app.
    - Shareable term lists, and voice commands on selected text (for example a tone change).
  - **Labelled "not there yet" / vision:** open a message, summarise and translate it, reply and send, email plus calendar invite, flight booking.
  - **Platforms:** Mac now; Windows and Android later; a developer API and MCP.
  - **Not covered:** the talk says nothing about terminals, spreadsheets as formula input, URL bars, or on-device vs cloud. So the architecture below comes from the client bundle, not from the talk.

**Kivi's architecture, as far as the client shows it:**
1. **Hotkey down.** Warm mic → audio streams to the server at once. In parallel, a budgeted Accessibility capture of the frontmost window yields typed terms.
2. **Surface resolver.** Signals (role, URL, window title, field signature, known-app table) → a surface profile and persona.
3. **Hotkey up.** Send end-of-speech with the screen terms. The server returns recognised and formatted text.
4. **Delivery.** Surface-specific builders (Sheets formula guard, Notion Markdown), then paste, then readback.
5. **Learning.** Store raw and formatted text per app; keep heard aliases from corrections.

**What VoicePlus should copy (all local, no cloud, no telemetry):**
- Context capture that starts at key-down, is cut off by a hard budget, and is discarded on an app switch. This is N7.
- Screen text as *typed terms* (names, files, tech, links), with a cap, rather than raw text (N11).
- Recording which context terms matched, so the weights can learn (N28).
- A general resolver, plus known-app tables as high-confidence hints, plus a general fallback (N9).
- Raw text stored next to final text, and heard aliases from corrections (N6, N28).
- A per-app off switch for accessibility enabling (N10).

**Do not copy:** cloud recognition, analytics, or AXManualAccessibility-only priming.

**Where Kivi's speed comes from, and VoicePlus's local equivalent:** keep the models loaded (D); the live preview already streams while you speak; start context at key-down (N7); and fix the 1.25 s from "recognised" to "typed" (N8).

---

### D. Model residency: when models load, and what should stay loaded

**Your question: can the models load when the app opens and stay loaded while it's idle?** **Yes, and that is the recommendation.** "Key-down" in round 2 meant pressing the dictation hotkey, never any key. It was still the wrong place, because the first-ever compile of the boosting model took 13.8 s, which no key-down warm-up can hide. Today it doesn't even load at key-down: it loads inside the final pass, which is how E1F62700 took 17.6 s.

**What happened in E1F62700.** **Confirmed** from the log and the code.
1. 09:16:13: the Contacts import made the dictionary non-empty.
2. 09:17:25-30: the CTC boosting model, which is not in the installer, downloaded in the background.
3. 09:18:01.209: your next dictation started its final pass.
4. 09:18:01.851: the final pass mapped the model into memory (100,778,304 bytes).
5. 09:18:04.350 to 09:18:18.181: the Neural Engine compiled it.
6. 09:18:15.280: you pressed Cancel.
7. 09:18:18.831: the late result was dropped.

The code path is FluidAudioTDTDecoder.swift:97 → CTCVocabularyBooster.swift:152 → :199-208, which loads the model as `.onDemand`, with no time limit.

**Today's residency, and the proposal:**

| Model | Job | Size on disk | Loaded today | Unloaded today | Proposed |
|---|---|---|---|---|---|
| Parakeet TDT 0.6B v3 | Final recognition | 461 MB (bundled) | At launch, always resident (Engine/ASRRuntime/ModelResidency.swift:13) | Never | Unchanged |
| Parakeet EOU 120M | Live preview, end-of-utterance | 214 MB (bundled) | At launch, always resident | Never | Unchanged |
| Silero VAD | Speech detection | 1 MB (bundled) | At launch | Never | Unchanged |
| Speaker model | Speaker check | 13 MB (bundled) | At launch | Never | Unchanged |
| **Parakeet CTC 110M** | **Vocabulary boosting** | **98 MB, not bundled** (downloaded to ~/Library/Application Support/VoicePlus/Models) | **Inside the final pass, on first use** (`.onDemand`, CTCVocabularyBooster.swift:201) | **After 5 min idle** (Shared/Services/ModelResidency.swift:120), **or on any macOS memory warning** (:270), and those warnings reach VoicePlus every 30 min on this Mac | **Bundle it, or fetch it during onboarding. Compile it at launch and right after a download. Make it always resident with a stable key. Exempt it from idle and memory-warning unloads, and drop it only under critical pressure, before the recogniser.** |
| Cleanup LLM | Optional AI clean-up | not measured | Warmed up at hotkey-down (AppDelegate.swift:157); 0.5 s deadline (CleanupStage.swift:51) | Per its own settings | Unchanged. A cold LLM already can't stall a turn. |

**Measured memory.**
- Idle VoicePlus uses **998 MB**. Of that, about **800 MB is working memory** (dirty `MALLOC_SMALL`), not memory-mapped files, so macOS cannot simply drop it: it can only compress it or move it to swap.
- Swap on this Mac is **94% full** (16.4 of 17.4 GB).
- The CTC model's mapping is 100.8 MB.
- Per-model RAM was not measured; the sizes in the table are disk sizes.
- So keeping models loaded is the right call, but it is not free. Adding the booster costs roughly another 100 MB. That was **likely** the case before, and should be measured with Instruments before release.
- Reading the models back in after 4.8 h idle was fast: the 16:24 turn finished its final pass in 1.27 s, including the booster reload.

**Reloads seen today:** five, each after a gap of more than 5 minutes, each adding about 1 s (1.27-1.58 s against 0.17-0.60 s warm). The 09:45 reload came 0.16 s after a memory warning, so it could have been caused by either the warning or the idle timer.

**Recompiles after updates.**
- The Neural Engine compile cache (`~/Library/Caches/in.adityakatare.voiceplus/com.apple.e5rt.e5bundlecache/25G83`) was created fresh at this morning's launch, even though macOS had not changed.
- So every VoicePlus update probably costs about 17 s of compiling at launch, plus about 14 s for the booster. **Likely.**
- Do this compile at launch, behind a visible "Preparing speech models" state, never during a dictation.

**The policy:**
1. **At app launch:** load and compile every dictation model, including the booster, and keep them loaded while the app runs, idle or not.
2. **When the word list changes** (a new dictionary term or correction, a new surface class): rebuild the *stable* rescorer in the background, never in a turn.
3. **At hotkey-down:** build only the small per-turn layer (screen, folder and participant terms) and start the context snapshot. Load a model here only if it is somehow still cold.
4. **In the final pass:** run the rescoring with a **1.5 s deadline**. If it runs over, land the unboosted text, which is already in hand.
5. **Log every stage:** recognise ms, model wait ms, rescore ms, and the time from "landed" to "written". Store the raw text from before boosting in `turn_records`.

This replaces round 2's "at launch or key-down" (N6).

---

### E. The context rubric: general intelligent input

**Principle.** VoicePlus should never need an app to be on a list to behave sensibly. App knowledge lives in two places:
- general **surface kinds**, such as terminal, spreadsheet cell, chat composer or URL bar;
- **lexicons** of what each kind accepts.

Known-app tables only raise confidence. Every decision records the signals that made it, so mistakes can be traced and learned from.

#### E1. Step 1: what surface is this? (surface resolver, N9)

Evidence is **added up**, not decided by a first match:

| Signal | Weight (starting point) | Notes |
|---|---|---|
| Secure field or macOS secure input | Veto | Refuse or hold; never read |
| Focused element: role, subrole, editable, single- or multi-line, placeholder, label, description | High | "Search", "Address", "Email", "Formula bar", "Message" labels are strong |
| Inside a web area, plus the page URL (domain, path) | High | URL patterns are data (for example `/spreadsheets/`), not code |
| The focused app owns a shell process on a pty (a terminal emulator, VS Code terminal, Claude's terminal pane) | Medium-high, combined with AX evidence | Also gives the folder the shell is in (F26) |
| Window title | Medium | |
| Runtime kind (native, Electron/Chromium, browser), sniffed from the bundle once per version | Medium | |
| Built-in seed table (bundle id → likely kind) | Medium | Hint only. An unlisted app loses nothing |
| Your per-app override, and what this app's previous turns resolved to | Medium-high | Learned |

The output is a surface kind with a confidence. Below the confidence threshold, the turn falls back to **plain prose with safe line breaks**, which is never wrong in a dangerous way.

#### E2. Step 2: what could you be saying? (context providers)

Each provider returns **typed candidates** (person name, file or folder, command, technical term, link or domain, formula function, ordinary word), each with its source, distance from the caret and freshness:
- **Field:** the text before and after the caret, the selection, the field's placeholder and label.
- **Screen:** visible text through Accessibility, under a budget. Reuse `visibleStrings` and `visibleArtifacts` (App/Services/AXContextProviders.swift:55, 93). Read the focused window first, then the rest of the window. Cap nodes, time and terms, Kivi-style, and sort terms into names, files, tech and links (F27).
- **What this kind of surface accepts:**
  - Terminal: commands on your `$PATH`, aliases, subcommands (`git checkout`), and entries in the shell's current folder (F26).
  - Spreadsheet: function names (SUM, XLOOKUP) and the column headers visible on screen.
  - Markdown editor: heading, list and link syntax.
  - Code editor: symbols in the open file (the existing `codeSymbols` source).
  - URL bar: domains of links and tabs visible on screen, plus domains you dictated before.
  - Email and form fields: the address and number formats the label implies.
- **You:** your dictionary terms, your corrections, and recent dictations *in this app*.
- **People:** Contacts and thread participants, used **only** when the surface is chat, email or a name field. Participants come before the whole address book. Use full names, plus uncommon name parts only on a strong match.

#### E3. Step 3: the rubric (scoring)

Every candidate is scored on one scale instead of strict tiers:

**score = source weight × surface fit × closeness × freshness × evidence − collision penalty**

| Source | Starting weight | Fit rule |
|---|---|---|
| Your corrections | 1.0 | Everywhere; a guaranteed share of the budget |
| Your dictionary (used recently) | 0.9 (0.6 if never used) | Everywhere |
| Terms visible near the caret or in the active thread | 0.8 | Everywhere except secure fields |
| Surface lexicon (commands, folder entries, formula names) | 0.8-0.9 | Only on the matching surface, scaled by its confidence |
| Other visible terms in the window | 0.5 | Everywhere |
| Recent dictations in this app | 0.6 | This app |
| Thread participants | 0.9 | Chat and email only |
| Contacts | 0.6 in chat, email and name fields; **0 elsewhere** | Never in terminal, code, sheets or URL bars |

**Rules on top of the scores:**
- **Collision penalty.** A term that is also a common word (Bucket, Cab, Code, Cleaning, Comp) only enters the boost list with strong evidence, such as being on screen right now. This one rule would have stopped today's Contacts damage, even without N1.
- **Per-source quotas.** No single source can take more than about half of the budget.
- **These weights are starting points.** They must be tuned in the Lab (N11). The learning loop then adjusts them per surface from what actually matched (N28).

#### E4. Step 4: where the ranked context goes

| Output | What it receives | Budget |
|---|---|---|
| **Recognition boosting** | A **stable layer** (about 200 terms: corrections, dictionary, surface lexicon), cached per surface class and rebuilt in the background. Plus a **per-turn layer** (about 50 terms: screen, folder and participant terms). A swapped word takes the *lower* confidence and is tagged "boosted", so later steps and the UI treat it as uncertain. | 1.5 s rescoring deadline; land unboosted on overrun |
| **Deterministic formatting** | The surface kind plus its lexicon (N12). | No model; milliseconds |
| **Cleanup prompt** | Field kind and surface name. The text before the caret. A "spell exactly" list chosen by the rubric (not dictionary-first). The top screen terms. Each section has its own share of the 1,000 characters (N14). | Existing 0.5 s deadline |
| **Write method** | The surface kind (keystrokes, paste or Accessibility; ⇧↩ or bracketed paste) plus the delivery ladder (N3). | |

#### E5. Surface grammars in place of hardcoded rules (N12)

Each grammar is general for its kind of surface and does not depend on the app.
- **Spoken symbols.**
  - "slash", "dot", "dash", "plus", "at" and "colon" become symbols only when the words around them form a path, URL, email, command flag or formula, or when you say a cue word.
  - Otherwise they stay words. "voice plus" stays "voice plus"; "c plus plus" becomes `c++` because of its structure.
  - This replaces "plus is always +" (TerminalFormatter.swift:132-133) and the fixed symbol table.
- **Terminal.**
  - Treat the text as a command line, not prose: no sentence punctuation and no capitals.
  - The first word is matched against your real commands, so "CD" / "see dee" becomes `cd` because `cd` is a valid command (not because of a hardcoded list).
  - Paths are matched against the shell's current folder (F26). The match is applied silently only when it is close: "documents" → `Documents/`, and "voice input" → `VoiceInput`.
  - Otherwise your words are kept and a suggestion is offered. "voice plus" is never silently turned into `VoiceInput`.
  - Never press Return.
- **Spreadsheet cell.**
  - Saying "equals" at the start makes a formula. Function names are matched against the lexicon, and cell references are normalised.
  - Without "equals", it is plain text with no trailing period.
- **URL or search bar.** If what you said parses as a domain or URL, write a URL. Otherwise write a search phrase with no period and no capital letter.
- **Form fields.** The label decides the format: email, phone, number, name.
- **Markdown-aware editors.** Spoken "heading", "bullet" and "link" become Markdown only where the surface accepts Markdown.

#### E6. F26 and F27, approved, and how they fit

- **F26, folder names in Terminal (N13).**
  - **Finding the folder.** Find the shell running in the focused terminal tab: the child process of the terminal app on that tab's terminal device. Read its current folder, and list that one folder (not its subfolders).
  - **Permission.** Listing Documents, Desktop or Downloads triggers a macOS permission prompt, so ask once in Settings ("Use folder names in Terminal"), never during a dictation.
  - **Which apps.** It works the same in Terminal, iTerm, WezTerm, Ghostty and VS Code, because it relies on the process tree, not a terminal list.
  - **What it touches.** It feeds both the stable and per-turn boost layers and the path matcher.
- **F27, on-screen words in recognition (N11).**
  - **How.** Screen terms go into the per-turn boost layer through the rubric (typed, capped, with the collision penalty) and into the cleanup prompt.
  - **Lab test first.** Before it is on by default, run a Lab test: the existing entity suite plus distractor screens, comparing accuracy with and without screen terms, through the current CTC rescorer.
  - **Privacy.** Accessibility text only; no screenshots or OCR in this path. It respects the per-app "contextual reading" rule *before* any read, never reads secure fields, and nothing leaves the Mac.

#### E7. Rules from earlier rounds that stay, as safety-only

These stay because they prevent harm, not because they encode app knowledge:
- Refuse or hold on secure fields and when macOS secure input is on.
- **Never press Return** to send or run anything.
- Line breaks as ⇧↩ when typing into any web area or Electron/Chromium app.
- Bracketed paste for multi-line text in terminals.
- ⌥↩ inside spreadsheet cells, never Return.
- Hold on canvas focus unless a text edit is active.
- Discard the context snapshot when the app changes.
- Honour each app's contextual-reading opt-out.

The known-app tables (terminals, browsers, chat apps) **stay only as seed hints** for the resolver, merged into one list.

---

### F. Revised fix list (supersedes round 2's F1-F31)

Effort: S is under a day, M is 1-3 days, L is more than 3 days. The new numbers are **N1-N28**. The mapping from old to new comes after the tables.

#### P0: stop losing or corrupting text, and make speed predictable

| # | Problem | Change | Files | Effort | Risk | Tests | Symptom fixed |
|---|---|---|---|---|---|---|---|
| **N1** | Contacts fill the boost list, the spell-exactly list and the cleanup context, and swap ordinary words everywhere | Carry each Dictionary row's real source (contacts, personal, imported) into the context entries. Keep Contacts out of all three channels except on chat, email and name-field surfaces (until N11, simply exclude them everywhere). **Ship first, alone.** | Engine/Biasing/Sources.swift, BoostVocabulary.swift, App/Services/BoostingWiring.swift, Pipeline/Personas/Personalisation.swift, Engine/Biasing/PromptBuilder.swift | S | Low | No Contacts terms in any channel; offline replay of the 11:34:44, 09:18:22, 09:34:09, 09:30:17 and 09:35:13 recordings shows no Akash, DOCUBE, Bucket, Cab, Cleaning or Code | Terminal garble; "Bucket", "Cab", "Comp" |
| **N2** | Cancel throws away recognised text; pill buttons do nothing | Unchanged from F2: buttons follow the turn's real stage; after recognition, Cancel = "don't type here", and the text is saved to history with Insert / Copy | App/Core/PillPresentation.swift, App/Services/TurnController.swift, history writer | S-M | Low | Cancel after recognition never drops the payload | Lost Notes and ChatGPT text |
| **N3** | No readable field → text goes to Notes (ChatGPT) | **Delivery ladder:** if the app and window from key-up are still focused and secure input is off, deliver by paste (multi-line or web) or keystrokes, and verify when readable. "Unverified" is neutral and logged. Notes only on a real focus change, no window, or a secure field. Replaces the delivery half of F3, and F19 | App/Services/UtteranceLander.swift, FieldContextReader.swift, App/Settings/NotesRouting.swift, Injection/TextInjector.swift | M | Medium: could type into a non-text target; guarded by N4, N15 and refuse-when-certain roles | Routing table tests; a fake unreadable Chromium app gets a write | ChatGPT nothing typed, text in Notes |
| **N4** | A blind write could hit a password field | Check macOS secure input before any write with no readable field (was F13) | Injection/TextInjector.swift | S | Low | Fake secure-input flag refuses | Safety |
| **N5** | Line breaks can send or run in unlisted apps | Merges F5 and F6, by structure. Inside a web area or any Electron/Chromium runtime, type line breaks as ⇧↩ and never let the fallback post a bare one. On any surface the resolver calls a terminal, use the terminal adapter (bracketed paste). Never press Return | Injection/AppAdapter.swift, TextInjector.swift | S-M | Low | Default adapter in a web area emits ⇧↩; every terminal id and pty-backed field gets the terminal adapter | Early send in Gemini, Safari; commands run in WezTerm, Warp |
| **N6** | Final pass can take 17 s; about 1 s reloads after idle | Section D: bundle or onboard the CTC model, compile at launch and after updates ("Preparing speech models"), always resident with a stable key, exempt from idle and warning unloads. Stable rescorer rebuilt in the background. 1.5 s rescoring deadline → land unboosted. Per-stage ms and pre-boost raw text in `turn_records`. Replaces F14 (the key-down load is dropped) | Engine/Decoder/CTCVocabularyBooster.swift, FluidAudioTDTDecoder.swift, ResidencyPlan.swift, Shared/Services/ModelResidency.swift, App/Services/TurnController.swift, TurnStore.swift, Packaging/make_app.sh | M | Low-medium: about 100 MB more resident on a Mac with nearly full swap; installer grows by 98 MB | A slow fake booster lands within the deadline; no model load inside a turn; residency tests | E1F62700; slow first dictation after a pause |
| **N7** | 17 s context stall; reads from the wrong app | Unchanged from F4: one bounded turn snapshot started at key-down, tied to the starting app and window, about 250 ms. It now also feeds the rubric (E2) | App/Services/UtteranceLander.swift, AppContainer.swift, AXContextProviders.swift, DeixisService.swift, ActStack.swift, Injection/AXReader/* , WindowContentCache.swift | M-L | Medium | A mock 10 s source lands in about 400 ms; no read when contextual reading is off | "Still finishing", lost Notes text |
| **N8** | 1.25 s median (up to 17 s) from "recognised" to "typed" | New. Time every step between landing and the write (formatting, cleanup, focus checks, adapter, readback), find the tails, fix. **Round 4: the first cause is found.** The fixed 0.6 s preview dwell takes a median 0.63 s of it, on every dictation. Proposal: insert as soon as the text is ready, keep the preview for Manual mode, and merge the pre-write checks into one (R4 Q1). The dwell default is an **owner decision** | App/Services/UtteranceLander.swift, TurnController.swift, Injection/* | M | Low | Timing in `turn_records`; target a median under 0.4 s | General slowness compared with Kivi |

#### P1: general intelligent input

| # | Problem | Change | Files | Effort | Risk | Tests | Symptom fixed |
|---|---|---|---|---|---|---|---|
| **N9** | Three disagreeing app lists; first-match substrings ("codex" → code, "console" → terminal) | **Surface resolver** (E1): evidence added up, confidence, safe fallback, seed tables as hints, your per-app override, profile and signals saved in `turn_records`. Fix the `"code"` substring and the first-match field hints. Reset the auto persona for `com.openai.codex`. Replaces F10, the category part of F3 and the Gemini line of F9 | Pipeline/Style/AppCategory.swift, Pipeline/Formatters/FieldRole/*, App/Services/FieldContextReader.swift, Injection/AppAdapter.swift, App/Services/TurnStore.swift | M-L | Medium | Table test across known and **unknown** apps; an unknown app gets safe prose; no list disagreement | Wrong format per app and tab; code style in ChatGPT |
| **N10** | Chromium apps hide their text (ChatGPT, Dia, Comet, unnamed wrappers) | **Revised in round 4 (R4 Q2): turn accessibility on by trying, not by recognising the app.** (1) At key-down, set the harmless `AXManualAccessibility` on any app, once per app version; native apps ignore it. (2) Probe the focused element: is it editable, and is it inside an `AXWebArea`? (3) Only if nothing editable is found *and* the bundle contains a "… (Renderer).app" helper (one cached structural check, no lists), set `AXEnhancedUserInterface` and probe again. (4) "Web content" (keystrokes, ⇧↩, read the URL) comes from the `AXWebArea` ancestor, not from the runtime. (5) If the tree stays empty, use the safe defaults (N3, N4, N5). Cache per process and version; honour the Chromium setting plus a per-app off switch; log which switch worked; measure CPU and window-manager side effects | Injection/AppAccessibilityEnabler.swift, App/Services/FieldContextReader.swift | M | Medium: side effects of the enhanced attribute, now limited to apps where the probe proves it is needed | Fake bundles in the ChatGPT/Owl, Dia (ArcCore) and Comet layouts → enhanced only after a failed probe; a native app never gets the enhanced attribute; web-area detection drives ⇧↩. **Read-only live probe first (S0)** | No screen context or readback in ChatGPT; Dia and Comet unrecognised |
| **N11** | Strict tiers; one list for every app; screen words never used | **Context rubric** (E2-E4): typed candidates, one scoring formula, per-source quotas, collision penalty, stable plus per-turn boost layers, boosted words tagged and lower-confidence. Includes F27 (on-screen words) behind a Lab measurement. Replaces F7 and the confidence part of F8 | Engine/Biasing/ContextRanker.swift, Ranker.swift, BoostVocabulary.swift, ContextHarvester.swift, Engine/Decoder/VocabularyBooster.swift, Lab | L | Medium | Ranking tests; corrections survive a full budget; Lab accuracy with and without screen terms; collision words need evidence | Contacts noise; screen words ignored |
| **N12** | Hardcoded terminal and symbol tables | **Surface grammars** (E5): symbols need structure or a cue; command-line grammar validated against your real commands; formulas; URL versus search; label-typed form fields; Markdown where accepted. Replaces F8's symbol list and F9 | Pipeline/Formatters/TerminalFormatter.swift, Pipeline/Formatters/* | M-L | Low-medium | Replay 11:34:44; "c plus plus" → c++; "voice plus" stays words; "equals sum a one to a ten" → formula; "google dot com" in a URL bar → google.com | Terminal output; "Akash" for slash |
| **N13** | Terminal can't use the folder you're in (approved) | F26: the focused shell's current folder through the process tree; one-time permission in Settings; silent match only when close, otherwise suggest; never Return | new App/Services/ShellContextProvider.swift, Engine/Biasing/Sources.swift, TerminalFormatter.swift | M | Low-medium (permission prompt; ask once in Settings) | Fake process tree and folder listing; no listing without permission | `cd documents/voiceplus` |
| **N14** | Cleanup ignores the surface; Contacts fill its context | Prompt gets field kind, surface, text before the caret, a rubric-chosen spell list and screen terms, each with its own budget | Pipeline/Cleanup/CleanupPrompt.swift, Engine/Biasing/PromptBuilder.swift | S-M | Low | Prompt snapshot tests per surface | Generic clean-up everywhere |
| **N15** | Canvas apps: letters trigger tools; comment line breaks | F11 made structural: hold with "Click into a text box first" when the focused element is not editable text in a canvas-like window. Figma's line-break safety comes from N5 | Injection/AppAdapter.swift, UtteranceLander.swift | M | Medium | Role-based hold tests. **Live:** Figma | Figma and Slides safety |
| **N16** | Brave learned "paste first" for every tab | Unchanged from F12: "unconfirmed" counts as neutral; never promote paste above keystrokes in newline-safe adapters | Injection/MethodRouter.swift | S | Low | Router test | Paste into Sheets or Figma web |
| **N17** | Taps and silent presses look like failures | Unchanged from F15 | App/Services/DictationCoordinator.swift, TurnController.swift | S | Low | Tap → hint, no turn record | "Empty or cancelled" turns |
| **N18** | Clipboard managers record dictations; clipboard not restored | Transient, auto-generated and concealed markers; restore the previous clipboard after a settle. More important now that N3 pastes more often (was F16) | Injection/ClipboardPaster.swift | S | Low | Pasteboard type and restore tests | Privacy |
| **N19** | Ribbon misses (Claude, x.com, Docs) | F17 and F18 merged | App/Overlay/TapeFlight*.swift, App/Diagnostics | S | Low | Geometry and controller tests | Ribbon |
| **N20** | Notch says "landed" too early; wrong app on the held row; refused presses are silent | F20, F21 and F22 merged | App/Services/TurnController.swift, App/Core/PillDelivery.swift | S | Low | Copy and sequence tests | "Done" while nothing typed |
| **N21** | Turn ids differ between tables | Unchanged from F23 | App/Diagnostics, TurnStore.swift | S | Low | Join test | Debuggability |

#### P2: later

| # | Change | Effort | Notes |
|---|---|---|---|
| N22 | Collapse pill and notch to 5 states (was F24) | M-L | After N2, N7 and N20 |
| N23 | Allow a new press once the previous text is final (was F25) | M | After N7 |
| N24 | Rich paste: a table into Sheets, Markdown into Notion (was F28) | M | Uses N9's surface kind, not app names |
| N25 | 2-3 named presets per surface kind (was F29) | S-M | Per surface kind, with per-app overrides |
| N26 | Separate "skip cleanup" from "style off" (was F30) | S | |
| N27 | OCR caret-band ribbon rung (was F31) | M | Opt-in; never feeds context |
| N28 | **Learning loop:** record which context candidates matched the final text and which you corrected; adjust source weights per surface within bounds; keep heard aliases and per-app overrides | M | Needs N6 (raw text stored) and N11 |

#### What happened to F1-F31

| Old | New | Change |
|---|---|---|
| F1 | N1 | **Widened:** Contacts out of all three channels, not just boosting |
| F2 | N2 | Same |
| F3 | N3 + N10 + N9 | **Split.** Delivery → ladder (N3). Accessibility → probe-chosen attribute (N10). **Dropped:** "map com.openai.codex to chat" and "route by runtime kind to the Electron path" for delivery |
| F4 | N7 | Same, now feeds the rubric |
| F5, F6 | N5 | **Merged**; terminals found by structure (pty shell + AX), not only a list |
| F7 | N11 | **Replaced** by the rubric (no fixed "corrections > dictionary > Contacts" ranking) |
| F8 | N12 (symbols) + N11 (confidence) | **Replaced:** no fixed list of protected words; structure decides |
| F9 | N12 | **Replaced:** command-line grammar plus your real commands, not hardcoded cd/ls and "plus" rules. "Add Gemini to chat" dropped (N9 handles it) |
| F10 | N9 | **Replaced:** an evidence-adding resolver; the URL and title additions become seed hints |
| F11 | N15 | Made structural (focused-role hold) |
| F12 | N16 | Same |
| F13 | N4 | Same; now P0 |
| F14 | N6 | **Corrected:** load at launch, keep resident; the key-down load is dropped |
| F15 | N17 | Same |
| F16 | N18 | Plus clipboard restore |
| F17, F18 | N19 | Merged |
| F19 | N3 | Absorbed by the delivery ladder |
| F20, F21, F22 | N20 | Merged |
| F23 | N21 | Same |
| F24, F25 | N22, N23 | Same |
| F26 | N13 | **Approved; promoted to P1** |
| F27 | N11 | **Approved; promoted to P1**, behind a Lab measurement |
| F28-F31 | N24-N27 | Same |
| — | N8, N14, N28 | **New** |

#### Order and dependencies

1. **N1 alone, now.**
2. **Measurement first:** N21, the logging parts of N6, N7, N8 and N19, plus N2. Every later change must be measurable from one `turn_records` row.
3. **N6** (models loaded at launch, deadline).
4. **N4 + N5 + N18, then N3.** The safety checks must exist before anything writes into an unreadable field.
5. **N8** (post-landing latency) once its timings exist.
6. **N7, then N9.** The resolver reads the same snapshot.
7. **N10** after a read-only probe. Then **N11 → N12 → N13 → N14**, which share the rubric's candidate types.
8. **N15-N17 and N20**, then P2. **N28** last, once there is data to learn from.

**Live tests in this order (added in round 4; the full plan is in R4 Q4):**
- **S0, the read-only accessibility probe, can run now** with your OK. It feeds N10 (step 7) and N9 (step 6).
- **S1a, the scripted landing, safety and speed tests,** runs after steps 1-6 and the confidence gate below, plus your decision on the preview dwell (N8).
- **S1b, the format, canvas, ribbon and terminal-folder tests,** runs after steps 7-8.
- **S2, the dogfood day,** runs after S1b passes. N28 starts from its data.

#### Confidence gate: what must be true before the live tests in ChatGPT, Gemini, Figma and WezTerm

You were right to defer them. A live test is only worth running when a failure points to one cause. All of the following must hold first:

1. **Built and passing.** N1, N3, N4, N5, N6, N9 and N21 are in one build, with their unit and table tests green, including the **unknown-app** cases (an app on no list gets safe prose, ⇧↩ in web content, no Return).
2. **Offline replay is clean.** Today's recordings (09:18:22, 09:30:17, 09:34:09, 09:35:13, 09:37, 11:34:44) show no Contacts swaps. The Lab entity and WER suite is no worse than with boosting off.
3. **Every turn explains itself.** `turn_records` holds the surface kind and the signals that chose it, the field role, the write method, the verification result ("verified" / "unverified" / "not landed"), per-stage ms and the pre-boost raw text.
4. **Speed.** In a 20-dictation local run:
   - from "recognised" to "typed", median under 0.4 s and p95 under 1 s;
   - no final pass over 1.5 s;
   - the first dictation after 30 minutes idle adds under 0.2 s;
   - no model load inside any turn.
5. **A read-only probe has been run in each app.** It only reads the focused element's role, whether it sits in a web area, and which accessibility attribute exposes it; it does not type. Results are written down, and N10's attribute choice matches them. This needs your OK, but it changes nothing in those apps.
6. **Pass criteria are written before testing**, about 10 scripted utterances per app:
   - **ChatGPT:** lands in the composer, never sends, verified or neutral, chat style rather than code.
   - **Gemini:** ⇧↩ line breaks, no early send.
   - **Figma:** canvas → hold with a hint; text layer and comment box → text lands, no post.
   - **WezTerm:** multi-line text never runs; `cd` plus a real folder name comes out right.

Only then run the live session, with you present.

#### Still open after round 3

- The composer's accessibility role in ChatGPT, and which attribute exposes it (gate item 5).
- What the 1.25 s between "recognised" and "typed" is spent on (N8).
- Per-model RAM, and whether the 800 MB of working memory is mostly CoreML buffers (Instruments).
- The cause of the memory-pressure warnings every 30 minutes on this Mac.
- Whether `AXEnhancedUserInterface` slows window movement or costs noticeable CPU in practice.

---

## Round 4: owner questions and live test plan

Same build (V5 1.13.0), code at HEAD `fe6f23e`, the same read-only DB. Evidence comes from the code, the installed app bundles (Info.plist, framework and helper names, string counts in the binaries; nothing was launched), the FluidVoice source and the `turn_records` timestamps. No app was controlled or typed into, and no VoicePlus code was changed. Confidence labels are the same as in earlier rounds.

### R4.0 New facts found while answering

1. **Every dictation waits 0.6 s on purpose before it types.** The "final preview" dwell defaults to 0.6 s (App/Settings/SettingsStore+Turns.swift:17-32), and this Mac has no override. In all 16 landed turns, the gap from "preview drawn" to "write sent" was 0.61-0.64 s (median 0.63 s; one outlier at 4.37 s, when the dwell was paused). That is about half of round 3's 1.25 s median from "recognised" to "typed" (N8). From key-up: text ready after a median of 1.02 s (p90 2.63 s), written after a median of 1.77 s (p90 4.94 s). **Confirmed** (`turn_records` capture timestamps).
2. **Dia and Comet are invisible to VoicePlus's browser logic.** Neither is on the browser list (App/Services/FieldContextReader.swift:160-164) or the Chromium adapter's list (Injection/AppAdapter.swift:245-246). The runtime check also misses both: Comet's engine is "Comet Framework", and Dia's Chromium sits inside "ArcCore.framework" (AppAccessibilityEnabler.swift:42-52 looks only for "Electron Framework"). So in Dia and Comet: no accessibility switch, no URL or page title, and the default adapter, whose keystroke fallback can type a bare Return. Code and bundles: **confirmed**. Whether dictations there end up in Notes the way ChatGPT's did: **hypothesis**, because there are no Dia or Comet turns in the DB.
3. **Chromium-based apps respond only to `AXEnhancedUserInterface`.** The engine binaries of Chrome, Brave, Comet, Dia (ArcCore) and ChatGPT (Codex Framework) contain that string and contain `AXManualAccessibility` 0 times. Claude's Electron Framework contains both. **Confirmed** (string counts).
4. **One bundle marker identifies every app on this Mac that ships a Chromium engine:** a helper named "… (Renderer).app". It is present in Chrome, Brave, Comet, Dia, ChatGPT and Claude, and absent in Gemini, Telegram, Warp and WezTerm. **Confirmed.**
5. **Kivi also has a small web-app layer.** This corrects round 3's "plus one URL". See Q3. **Confirmed** for the mechanism; the exact host list is **likely**.
6. **VoicePlus already declares the Apple Events permission but never uses it.** The usage string is in App/Resources/Info.plist:58-60, and the signed app has the automation entitlement, but no code sends Apple Events. **Confirmed.**
7. **FluidVoice pulls you back when focus has moved.** It raises the remembered window, re-focuses the element (activating the app if needed), then pastes (FluidVoice TypingService.swift:311-330). It checks for a password field only before its optional spoken "send" action (TypingService.swift:47-74). Its editability gate even lists `AXSecureTextField` as editable (DeliveryTargetAssessment.swift). So a plain paste into a password field is not blocked. **Likely**: the plain path was read but not traced end to end.

---

### Q1. "Is ours not simple?"

**No, it is not.** Between "final text ready" and "text in the app", VoicePlus runs about **12 decisions and 5 waits**. FluidVoice runs about **4 decisions and no deliberate wait before the text appears**. Most of our extra steps were added one incident at a time: Brave double-typing, a chat message sent early, the preview, the hold. A few of them really protect you. Several are ceremony that costs time on every dictation.

**VoicePlus today, in order (happy path, readable native field):**

| # | Step | Kind | Where | Verdict |
|---|---|---|---|---|
| 1 | Drop the result if the turn was cancelled or already claimed | Gate | TurnController.swift:624-635 | Keep (cheap) |
| 2 | Context gathering ("this/her" lookup, ranked harvest) | **Wait, unbounded** (0 to 17 s) | UtteranceLander.swift:216 | Keep, with a hard deadline (N7) |
| 3 | Read the focused field: role, caret, labels, URL, title, participants | Read | UtteranceLander.swift:220; FieldContextReader.swift:128-157 | Keep (it decides format and safety) |
| 4 | Formatting pipeline, including an LLM cleanup capped at 0.5 s | Wait (bounded) | UtteranceLander.swift:235 | Keep |
| 5 | Four possible diversions: act, transform, undo of a correction, repair | Gates | UtteranceLander.swift:250-297 | Keep (they are features, and cheap) |
| 6 | Password field → refuse (check 1 of 3) | Gate | UtteranceLander.swift:327-338 | Keep **one** password check, the last one |
| 7 | Notes routing: 8 possible reasons, including "no field found" | Gate | NotesRouting.swift:77-103; UtteranceLander.swift:345-353 | Shrink: "no field" goes away with the delivery ladder (N3) |
| 8 | Dropped if the turn ended while formatting | Gate | TurnController.swift:655-659 | Keep, but Cancel must keep the text (N2) |
| 9 | One turn at a time through the gate | Wait (queue) | TurnController.swift:790-817 | Keep (it keeps dictations in order) |
| 10 | Preview: wait for the pill to draw it (up to 1 s, median 0.02 s) | Wait | TurnController.swift:180, 844-876 | Fold into step 11 |
| 11 | **Dwell 0.6 s**; frozen by 6 pause reasons (hover, focus, selection, review, editing, composition); Manual mode waits for a click | **Wait, fixed** | SettingsStore+Turns.swift:27-28; TurnController.swift:137-141, 914-938 | **Remove by default** (see below) |
| 12 | Revalidation: same app, not a password field (check 2), text unchanged, caret unchanged → else hold | Gate | FocusGuard.swift:187-195; TurnController.swift:1157-1161 | Keep "same app and window" and the password check. The text- and caret-changed holds are only worth it when there is a dwell |
| 13 | One insert per turn | Gate | TextInjector.swift:382-413 | Keep (cheap; stops double typing) |
| 14 | Injector: focus still matches (again), a frontmost app exists, not on the never-inject list, turn the accessibility switch on, password field (check 3) | Gates | TextInjector.swift:117-134 | Merge with step 12 into **one** pre-write check |
| 15 | Pick 1 of 7 adapters by bundle id, then reorder methods by what worked in this app before | Decision | AppAdapter.swift:348-359; MethodRouter.swift:16-18, 41-44 | Replace with a write plan chosen from the surface kind (N5, N9); keep the history only as a tie-break (N16) |
| 16 | Per method: focus check (again); read the page URL for the line-break key; write | Gate + read | TextInjector.swift:143-166 | Keep the write; the URL comes from step 3 |
| 17 | Readback: poll every 30 ms for up to 400 ms | Wait (after the text is in) | ReadbackSettler.swift:43-58; TextInjector.swift:180-183 | Keep, but take "Done" off its critical path; "can't tell" stays neutral |

On screen, the pill steps through finishing → "Still finishing" (after 2 s) → the 10 s offer (PillPresentation.swift:504-516) → final preview → inserting → landed (verified, neutral or warning), held, or consumed. That is 5 to 8 states for one dictation.

**FluidVoice, in order** (design only, GPLv3, nothing copied):
1. Optional AI cleanup.
2. Is the remembered app, window and element still focused? If not, raise and re-focus them (TypingService.swift:311-330).
3. Refuse only when the focused element is *certainly* not text: a button, a menu (DeliveryTargetAssessment.swift).
4. Paste with ⌘V, wait 500 ms, restore the clipboard. Read back; "unknown" counts as fine (PasteVerifier.swift:77-120).

**What earns its keep:**
- **Never send by accident.** VoicePlus never presses Return. When it types, a line break is ⇧↩ (⌥↩ in a sheet cell), and in a terminal multi-line text goes in as bracketed paste. One wrongly sent message costs more than every millisecond this list saves. Note that it only matters on the keystroke path: inserting through Accessibility posts no key at all, so it cannot send.
- **The password-field refusal, and macOS secure input (N4).** FluidVoice most likely does not block a plain paste into a password field (R4.0 #7). We should.
- **Hold when you have moved to another app.** VoicePlus is right not to copy FluidVoice here. FluidVoice yanks you back to the old window and types there. Holding and naming the app is the safer behaviour.
- **One insert per turn, and readback that treats "can't tell" as neutral.** Both are cheap and stop double typing.
- **Ordering:** one dictation lands at a time, in order.

**What should go, or shrink:**
- **The fixed 0.6 s dwell** costs about 0.6 s on every dictation. It is half of the delay you feel, and the ≤0.4 s target in the confidence gate cannot be met while it exists. Proposal: insert as soon as the text is ready. Keep the preview for Manual mode, and optionally as a non-blocking display that still offers Undo. **Owner decision.** It belongs to N8.
- **Three password checks and three focus checks** become one check right before the write: same app and window as key-up, not a password field, secure input off. Merge into N3/N4.
- **The holds for "text changed" and "caret changed".** They protect the dwell window. With no dwell, that window is milliseconds long, and they cause false holds in apps that redraw their own field (Docs' hidden text target is a likely case). Keep them only in Manual mode.
- **Seven adapters chosen by bundle id, with learned method order,** become four write plans chosen by surface kind: native text (Accessibility, then keystrokes), web or Chromium content (keystrokes with ⇧↩, paste for long text), terminal (bracketed paste), sheet cell (⌥↩). This is N5 plus N9; N16 stays as a tie-break only.
- **The unbounded context step** gets a hard deadline (N7).
- **"No field, so it goes to Notes"** becomes "deliver anyway when the same app and window are still focused" (N3).
- **The 10 s offer and the "Still finishing" states** go (N2, N22).

**Simplified target path:** final text (context and formatting have already run under deadlines) → **one pre-write check** (same app and window as key-up? not a password field? secure input off?) → **write by surface kind** (never a bare Return) → readback in the background → Done. That is 3 decisions and no deliberate wait. **Likely** to bring the median from "recognised" to "typed" under 0.4 s, once the dwell is gone and N7 is in. It has to be measured in S1 below.

---

### Q2. "Why do we need to recognise how the app is built?"

**What knowing the runtime is used for today. Three things, all decided from bundle names or lists:**
1. **Which accessibility switch to flip.** Electron and Chromium apps build no accessibility tree until someone asks for one. Without the tree, VoicePlus cannot read the field, the caret, the URL or the text around the caret. Electron listens to `AXManualAccessibility`. Chromium browsers and the ChatGPT/Owl runtime listen only to `AXEnhancedUserInterface` (R4.0 #3). Today the choice comes from a framework-name check plus bundle-id lists (AppAccessibilityEnabler.swift:42-52).
2. **How to write.** Web editors (React, ProseMirror, Draft.js) keep their own copy of the text. An Accessibility write changes what is on screen but not the editor's copy, so it gets lost or garbled. So web content gets keystrokes or paste, not an Accessibility write. And in web content Return usually *sends* (chat) or *submits* (forms), so line breaks must be ⇧↩. Today both rules hang off bundle-id lists (AppAdapter.swift:189-272).
3. **Formatting category.** Bundle id substrings, for example "codex" → code. That one is already being replaced by the surface resolver (N9).

**The two switches and their costs:**

| Switch | Who listens | Side effects | Confidence |
|---|---|---|---|
| `AXManualAccessibility` | Electron apps only | The Electron app builds its full accessibility tree, which costs some CPU and memory in that app. Electron added this attribute precisely so that tools could switch accessibility on without the side effects of the other one. Native apps ignore it (the call simply fails), so trying it on any app is harmless. | **Likely** (general knowledge; harmlessness on native apps follows from the AX API) |
| `AXEnhancedUserInterface` | Chromium browsers, ChatGPT/Owl, and Electron | It tells the app "a screen reader is running." Known effects: **window managers (Rectangle, Magnet, yabai, Amethyst) see laggy, animated or wrongly sized window moves**, and some of them switch the attribute off around every move for this reason. Chromium switches to full accessibility for every tab and frame, which costs CPU and memory on heavy pages such as Docs and Sheets. VoicePlus sets it and never sets it back (AppAccessibilityEnabler.swift:103-124), so it stays on until the app quits. | Window-manager effect: **likely** (well known in window-manager projects; not measured here; this Mac runs no window manager). CPU cost: **likely**, not measured. Never reset: **confirmed** |

**How line breaks behave in web content:** a page sees a synthetic Return as a real Enter key. Chat apps send on it, forms submit on it, and Sheets commits the cell. ⇧↩ is a line break in text areas and in almost every rich editor. In Docs and Notion it is a *soft* break rather than a new paragraph, which is a small formatting difference, not a safety problem. In Sheets the in-cell break is ⌥↩. Accessibility inserts send no key, so native fields never have this problem. **Likely** (general web behaviour; checked live in S1).

**Can we avoid recognising the runtime? Mostly yes.** The minimal approach:
1. **At key-down, try the harmless switch on every app** the first time VoicePlus sees that app version: set `AXManualAccessibility`. Native apps ignore it. Cache the result per process.
2. **Probe the focused element** with one bounded read: is there an editable element, and does it sit inside an `AXWebArea`?
3. **Only if the probe finds nothing editable *and* the app ships a Chromium engine,** set `AXEnhancedUserInterface` and probe again. "Ships a Chromium engine" is one cached check for a "… (Renderer).app" helper anywhere in the bundle (R4.0 #4). That check needs no list of names, and it covers Dia's and Comet's unusual layouts, which today's framework-name check misses. Honour the "Expose text in Chromium browsers" setting (App/Settings/InsertionSettings.swift:7-13), add a per-app off switch, and log which switch worked.
4. **Decide "web content" from the tree, not from the runtime.** The rule is "the focused element has an `AXWebArea` ancestor." That covers browsers, Electron apps, Gemini's WebKit view and unknown wrapper apps alike, and it drives keystroke-not-Accessibility, ⇧↩, and reading the page URL.
5. **When the tree stays empty, use the safe default:** deliver as for web content (keystrokes, ⇧↩, never Return), under the N3 ladder's same-app check and the N4 secure-input check. In practice an unreadable field in a native app is rare. Those apps almost always draw their own text (terminals, canvases), and the terminal and canvas rules (N5, N15) still apply.

So the runtime is kept for exactly one decision: whether to flip the switch that has side effects. It is decided by structure, not by a list. N10 in round 3's fix list is reworded to match.

---

### Q3. "Do Kivi's ~45 built-in apps include web apps? Can we recognise which website is open and act on it? Using what?"

**Kivi: yes, a small number.** **Confirmed** from strings in KiviKit:
- It has a `BrowserDocumentDetection` component.
- Per-site detectors: `googleDocsAXURL`, `googleSheetsAXURL`, `notionAXURL`, plus title fallbacks `googleDocsTitleHeuristic` and `googleSheetsTitleHeuristic`.
- A diagnostic, `browser_place_expected_but_no_url_or_title_found`.
- Rich-copy probes for Gmail, Sheets and Linear.
- Visible host strings: `docs.google.com/spreadsheets`, `coda.io`, `outlook.live.com`, `outlook.office.com`, `teams.microsoft.com` and `web.whatsapp.com`, plus fragments of Slack, Discord, Linear and Notion hosts.

So Kivi reads the page URL from the web area's `AXURL` and falls back to the window title. That is the same method VoicePlus uses. It knows about a dozen web apps. Swift keeps short strings inside the code, which hides some names, so the exact list is **likely**, not complete. There is no AppleScript or Apple Events code, and no Firefox, Comet, Vivaldi or Opera strings. It does know Safari, Chrome, Brave, Edge, Arc and Dia.

**VoicePlus today already knows more web apps than Kivi.** **Confirmed** from code:
- **How the URL is read.** The reader walks up from the focused element, at most 40 parents, to the first node that has an `AXURL`, which is the web area (Injection/LiveSystemAccess.swift:286-301). If there is no URL, it uses the web area's title or the window title (FieldContextReader.swift:369-380).
- **When.** Only when the frontmost app is on a 12-browser list (FieldContextReader.swift:137-143, 160-169). The same URL read also runs at write time, to choose ⌥↩ for a Sheets cell (TextInjector.swift:150-153; AppAdapter.swift:262-264).
- **What it maps to.** 56 host-and-path routes and 13 title names lead to a sub-app category: mail, chat, sheet, document, code or terminal (Pipeline/Formatters/FieldRole/BrowserSubApp.swift:57-103). That category picks the persona and the field role.
- **Gaps:**
  - Dia and Comet are not on the list (R4.0 #2).
  - Chromium browsers expose `AXURL` only when the enhanced switch is on, so turning off "Expose text in Chromium" also turns off site recognition.
  - Web views inside other apps (Gemini, Electron apps) are never asked for a URL, because they are not "browsers".

**Options for knowing the site:**

| Option | What it gives | Permission cost | Pros | Cons |
|---|---|---|---|---|
| `AXURL` on the web area (today's method) | Full URL of the page holding the focused field | None beyond Accessibility, which VoicePlus already has | Exact; reads the frame the caret is actually in; no prompts; already built | Chromium needs the enhanced switch on; Firefox is weak (below) |
| Web area or window title | Page title ("Inbox - Gmail") | None | Always there | Titles vary, are localised and are user content; good only as a fallback |
| Address bar value | What the toolbar shows | None | Works when the web area hides its URL | Brittle: Safari shows only the domain by default; the bar holds your half-typed text while focused; layouts differ per browser and version, and Arc/Dia hide the bar; finding the bar needs a tree walk. Not recommended |
| Apple Events ("URL of the active tab") | Front tab URL | **One macOS prompt per browser** ("VoicePlus wants to control Brave"); revocable in Privacy & Security → Automation | Works with the tree off | It asks the *front window*, which may not be the one with the caret; a call can stall if the browser is busy, so it needs a timeout; a prompt during a dictation would steal focus, so it could only be enabled from Settings; Dia, Firefox and Opera are unreliable or unsupported |

**Per-browser coverage:**

| Browser | On this Mac | Engine | URL through Accessibility | URL through Apple Events |
|---|---|---|---|---|
| Safari | Yes | WebKit | Yes, tree always on | Yes (scripting dictionary present) |
| Chrome, Brave | Yes | Chromium | Yes, once the enhanced switch is on | Yes (dictionary present) |
| Comet | Yes | Chromium 148 | Yes once the switch is on, **but VoicePlus doesn't treat it as a browser** | Yes (dictionary present) |
| Dia | Yes | Chromium inside ArcCore | Same as Comet | **No** (no scripting dictionary in the bundle) |
| Edge, Arc, Vivaldi | No | Chromium | Yes once the switch is on (**likely**) | Yes (**likely**) |
| Opera | No | Chromium | Same (**likely**) | Partial (**likely**) |
| Firefox | No | Gecko | Weak: Firefox builds its tree only when it detects assistive software, and many fields are poorly exposed (**likely**) | No URL |

**What the field itself tells us, inside the page.** This is what should decide the behaviour:
- **Role and subrole:** text field or text area (one line or several), search field, password field. Already read.
- **The field's name:** aria-label (exposed as its description), placeholder, attached label, help text. For example "Message", "Search", "To", "Subject", "Email", "Ask anything". Already read for text roles (FieldContextReader.swift:134-137).
- **Is it rich-text editable (contenteditable)?** WebKit and Chromium expose an "editable ancestor" attribute. Not read today.
- **The element's id and class names in the page** (`AXDOMIdentifier`, `AXDOMClassList`, exposed by WebKit and Chromium). Examples: ChatGPT's composer id, a "ProseMirror" class, Docs' editor classes, Sheets' cell editor. Strong but site-specific, so a hint only and never required. Not read today. **Likely** available; S0 confirms.
- **Inside a grid with column headers** → a spreadsheet cell. Already read (column header).
- **Inside an `AXWebArea` or not.** This is also how the URL bar (a toolbar field, outside any web area) is told apart from page fields.

**Canvas apps** draw their own text, so Accessibility sees little:
- **Google Docs:** the page is drawn on a canvas, and keys go to a hidden text target. That is why round 1 saw an unchanging value and no ribbon. Its text becomes readable only when Docs' own screen-reader support is turned on (Tools → Accessibility). VoicePlus should not flip that for you, because it changes Docs' behaviour. Typing still works; only reading the context and aiming the ribbon suffer.
- **Sheets:** the grid is a canvas, but the cell editor and the formula bar are real editable elements while you edit.
- **Slides, Figma, Canva, Miro:** canvas. A text box being edited has a focused editable target. With nothing being edited, typed letters are tool shortcuts. That is N15's hold.
- **Status:** the Docs and Sheets mechanics are **likely**; Figma and Slides need the S0 probe (**hypothesis**).

**Recommendation:**
1. **The domain is a hint, not the decision.** It feeds the surface resolver (N9) with medium weight, as section E1 already says. The field's own signals decide: role, multi-line, label and placeholder, editable, grid, inside a web area. An unknown site with a "Message" box behaves like a chat box. An unknown site's search box behaves like a search box. Anything else gets safe prose with ⇧↩.
2. **Read `AXURL` whenever the focused element sits inside a web area, in any app.** No browser list. That fixes Dia, Comet, Gemini and future browsers at once.
3. **Store only the host and the first path segment** in `turn_records`, never full URLs.
4. **Keep the 56 routes as seed hints.** Add Slides, Figma, Canva, Linear and Miro as round 2 proposed.
5. **No Apple Events for now.** Accessibility covers every installed browser once the switch is on. Revisit only if S0 shows `AXURL` missing in a browser you use.
6. Add `AXDOMIdentifier`, `AXDOMClassList` and the editable-ancestor attribute to the field read, as low-weight hints.

---

### Q4. Live test plan

**Goal.** Prove, app by app, that text lands in the right field, in the right format, never sends or runs anything, and is fast. Every failure must trace to one cause in one `turn_records` row.

#### Stages

| Stage | When | What | Who |
|---|---|---|---|
| **S0: read-only probe** | **Now.** Needs your OK; needs no P0 code | For each app and field in the matrix, you click into the field; a small read-only probe tool records the field's role, subrole, label and placeholder, editable ancestor, page id and class, whether it sits in a web area, the URL host, the caret rectangle, and **which switch was needed** (none / manual / enhanced). It never types, and never reads text values (lengths and hashes only). Its only change to an app is flipping that app's accessibility switch, which VoicePlus already does today. | Agent writes the probe (new tooling) and reads the output; you focus each field |
| **S1a: scripted landing and safety** | After the round-3 confidence gate items 1-4 (N1, N3, N4, N5, N6, N7, N8, N9, N21 built, unit and table tests green, replay clean) and your dwell decision | About 10 scripted utterances per matrix cell, delivered by a **replay harness** (new, debug-only: after a 3 s countdown it plays a recorded utterance through the real engine and landing path into whatever is focused, as if the hotkey were held). Without the harness, you read the script aloud. Checks: lands, safety, latency, surface picked | You open scratch documents and place the caret; the agent triggers replays and scores from the DB and logs |
| **S1b: format and polish** | After N10, N12, N13, N15, N17, N19, N20 | Same harness. Checks: format grammar per surface, canvas hold, ribbon, terminal folder names, tap and silence hints, Chromium switch choice | Same |
| **S2: dogfood day** | After S1b passes | One normal working day of your real use. Logging on; text logging off unless you opt in. The agent reviews `turn_records` at the end of the day and files each miss with its traced cause | You use it; the agent reviews |

#### Safety rules (all stages)

- **Scratch only.** Use a new Notes note called "VoicePlus test", a new TextEdit document, scratch Google Doc, Sheet and Slides files, a scratch Figma file, a scratch Notion page and a scratch folder `~/VoicePlusTest` for terminals. You trash them afterwards.
- **No sending.** VoicePlus never presses Return, and the tests never press it either.
  - Chat composers: a new, empty chat. Messages: a new message with **no recipient**. Gmail: a draft with no recipient. x.com: a draft, discarded afterwards.
  - Slack web and Telegram only if you choose a conversation with yourself.
  - **Any send, any command that runs, or any text typed into a password field stops the session.** It is fixed before testing continues.
- **No real accounts beyond what you open.** The agent never clicks, types or logs in anywhere. It only triggers VoicePlus and reads its own DB and logs.
- **Password and form tests use a local test page** (a file on disk with name, email, phone, search, text area and password fields), never a real login page.
- **Terminals:** only harmless commands (`echo`, `cd`, `ls`) in the scratch folder; never `rm` or anything with sudo.
- **Clipboard:** the paste path uses the clipboard. N18 restores it; check that in X11.

#### Checked in every cell

| Check | Pass bar (per cell, 10 utterances) | Logged in |
|---|---|---|
| C1 Lands in the field the dictation started in, or is held with the right app named | 10/10 never in the wrong app; ≥ 9/10 landed, with any miss traced to one logged cause | `turn_records`: destination, outcome, verification verdict |
| C2 Surface kind picked | ≥ 9/10 as expected for that field | Surface kind, top signals and confidence (N9) |
| C3 Format matches the surface's grammar (S1b) | ≥ 8/10, with no forbidden output (a period in a URL, a capital in a command, a trailing period in a cell) | Pre-boost raw text and final text (scratch content only, text logging on in S1) |
| C4 Line-break safety | **10/10**: nothing sent or run; breaks appear as breaks | Write method and line-break key used |
| C5 Ribbon on the caret line (S1b) | ≥ 8/10 where the field exposes a caret | Ribbon event: which method placed it, or why it was suppressed (N19) |
| C6 Speed | Across all of S1: from "recognised" to "written", **median ≤ 0.4 s and p95 ≤ 1 s**; no final pass over 1.5 s; no model load inside a turn | Per-stage ms (N6, N7, N8) |

**Script (scratch content):**
- U1 a plain sentence.
- U2 two paragraphs ("… new paragraph …").
- U3 money and numbers.
- U4 a Contacts name plus collision words ("Ask Akash about the budget in the next tab").
- U5 "google dot com slash maps".
- U6 an email address.
- U7 "cd documents slash voice input" (terminals only).
- U8 "equals sum a one to a ten" (sheets only).
- U9 a 60 s dictation.
- U10 a Hinglish line.

Each cell uses the subset that fits it.

#### App matrix

Stage marks show the earliest stage at which a check can run. "Validates" lists the fixes the cell proves.

**A. Native AppKit and SwiftUI**

| # | App and field | Specific checks | Stage | Validates |
|---|---|---|---|---|
| A1 | Notes: a new empty note, and a long note | Lands in the long note in under 1.5 s from key-up (the 17 s case); real paragraph breaks | S1a | N7, N8, N3 |
| A2 | TextEdit: a plain and a rich document | Verified Accessibility write; ribbon exactly on the line (reference case) | S1a / S1b | Regression reference |
| A3 | Mail compose (no recipient): To, Subject, body | Address format in To; no line break in Subject; paragraphs in the body | S1a lands; S1b format | N9, N12 |
| A4 | Messages, new message, no recipient | Two paragraphs never send | S1a | N5 |
| A5 | Spotlight search field | No trailing period, no capital; ribbon exactly on the line | S1b | N12 |
| A6 | Telegram (native), a chat with yourself only if you choose | Never sends | S1a | N5 |

**B. Chromium and Electron apps**

| # | App and field | Specific checks | Stage | Validates |
|---|---|---|---|---|
| B1 | ChatGPT (Codex app), new chat composer | Lands, **not in Notes**; never sends; verified or neutral; chat style, not code style; which switch was needed | S1a delivery; S1b style and switch | N3, N4, N5, N9, N10 |
| B2 | Claude, new chat composer | Lands; empty-composer ribbon at the caret | S1a; S1b ribbon | N5, N19 |
| B3 | Cursor: a scratch file, the AI composer, the built-in terminal | Composer: ⇧↩, never submits. Editor: identifiers kept, no trailing period. Terminal pane: command grammar, bracketed paste | S1a safety; S1b format | N5, N9, N12 |
| B4 | VS Code: a scratch file and the built-in terminal | As B3 | S1a; S1b | N5, N9, N12 |
| B5 | Figma desktop, scratch file: canvas with nothing being edited, a text layer being edited, a comment box | Canvas → held with "Click into a text box first", and no tool shortcut fires; text layer → lands; comment → line break does not post | S1b | N15, N5 |
| B6 | Obsidian (Electron), scratch note | Prose with Markdown cues | S1b | N9, N12 |
| — | Slack and Notion desktop | **Not installed.** Covered by the web rows; untested as desktop apps | — | — |

**C. Native app with a web view**

| # | App and field | Specific checks | Stage | Validates |
|---|---|---|---|---|
| C1 | Gemini, new chat composer | Web area detected without any switch (WebKit); ⇧↩; no early send; chat style | S1a safety; S1b style | N5, N9, N10 |

**D. Terminals**

| # | App | Specific checks | Stage | Validates |
|---|---|---|---|---|
| D1 | Terminal, zsh at an empty prompt in `~/VoicePlusTest` | A one-line command lands with no Return; two lines never run (bracketed paste); "cd documents" comes out as `cd Documents/`; folder names matched only after your Settings OK | S1a safety; S1b grammar and folders | N5, N12, N13 |
| D2 | Warp | As D1 (Warp's input box is its own editor, not a classic prompt) | S1a; S1b | N5, N12 |
| D3 | WezTerm | As D1; it uses the default adapter today | S1a | N5 |
| — | iTerm, Ghostty | **Not installed.** Table tests only; untested live | — | N5 |

**E. Browsers and web apps.** The full set runs in **Brave** (your main browser). The rows marked ★ also run in **Safari, Chrome, Comet and Dia**, to show that the behaviour does not depend on the browser. Firefox, Arc, Edge, Vivaldi and Opera are not installed and are untested live.

| # | Web app and field | Specific checks | Stage | Validates |
|---|---|---|---|---|
| E1 ★ | Google Docs, scratch document | Prose; paragraph breaks; a ribbon appears | S1a; S1b ribbon | N9, N19 |
| E2 | Google Sheets, scratch sheet: a selected cell, the cell editor, the formula bar | No trailing period; a break inside a cell is ⌥↩ and never commits the cell; "equals sum…" becomes a formula | S1a ⌥↩; S1b formula | N5, N12 |
| E3 | Google Slides, scratch deck: nothing being edited, and a text box | Nothing being edited → held with a hint; text box → lands | S1b | N15 |
| E4 ★ | Gmail draft, no recipient: To, Subject, body | Never sends; email format in To | S1a; S1b format | N5, N9, N12 |
| E5 | x.com compose box (draft, discarded) | Never posts; empty-box ribbon | S1a; S1b ribbon | N5, N19 |
| E6 ★ | ChatGPT web, new chat | Never sends; chat style | S1a | N5, N9 |
| E7 | Figma web, scratch file | As B5 | S1b | N15 |
| E8 | Notion web, scratch page | ⇧↩ gives a soft break (noted, not a failure); Markdown cues | S1b | N9, N12 |
| E9 ★ | Local test form: name, email, phone, search, text area | The label decides the format | S1b | N9, N12 |
| E10 ★ | Address bar | "google dot com" becomes `google.com`; a search phrase has no capital and no period; Return is never pressed | S1b | N12 |
| E11 | Slack web, a chat with yourself (optional) | Never sends | S1a | N5 |
| E12 | Brave with "Expose text in Chromium" **off** | Still lands (unverified); safe line breaks; no URL, so generic surface | S1b | N3, N10 |

#### Edge cases

Each runs in the 2-3 surfaces named, not in every cell.

| # | Case | Where | Pass | Stage | Validates |
|---|---|---|---|---|---|
| X1 | Password field | Local form in Safari and Brave | Refused; nothing typed, held or recorded | S1a | N4 |
| X2 | Empty field | Claude, x.com, a new note, Spotlight | No leading space; correct capital; ribbon at the start | S1a; S1b ribbon | N19 |
| X3 | Two paragraphs into a chat | ChatGPT app and web, Claude, Gemini, Messages, Gmail body, x.com | Breaks present; **nothing sent** | S1a | N5 |
| X4 | Switching apps mid-dictation, (a) before releasing the key and (b) after releasing it but before the text lands | Notes → Claude; Brave → Terminal | Never typed into the new app; held, naming the app that took focus; Insert here works when you return | S1a | N3, N20 |
| X5 | Cancel after recognition | Notes, ChatGPT | Nothing typed; text kept in history with Insert and Copy | S1a | N2 |
| X6 | A tap under 250 ms, and a 2 s silent press | Any | Hint shown; no "cancelled" or "empty" turn stored | S1b | N17 |
| X7 | 60 s dictation | Notes, Docs | All the text lands; final pass ≤ 1.5 s; no context stall | S1a | N6, N7 |
| X8 | First dictation after 30 min idle | Notes | Adds ≤ 0.2 s | S1a | N6 |
| X9 | Two dictations back to back | TextEdit, Claude | Both land, in order; the second press is never silently refused | S1b | N20, N23 |
| X10 | Escape during the write | TextEdit | Undo is offered and removes exactly the inserted text | S1a | Existing |
| X11 | Clipboard restore | Any paste-path cell, after copying a known string | The known string is still on the clipboard afterwards | S1a | N18 |
| X12 | Contacts collision words (U4) | Brave, Terminal | "budget", "tab", "code" and "slash" come out right | S1a | N1 |

#### Order, and where it sits in the fix list

1. **S0 now**, after your OK. Its results settle N10's switch choice (gate item 5) and seed N9's field signals.
2. **Build P0 and N9 → confidence gate items 1-4 → your dwell decision → S1a.**
3. **Build the P1 items → S1b.**
4. **S1b passes → S2 dogfood day.**
5. **N28** (the learning loop) starts from S2's data.

S1a must not start before the gate. A failure would then have several possible causes, which is exactly what the gate prevents.

**Tooling this needs.** Both are new, small, debug-only and outside the product path:
- the read-only probe, for S0;
- the replay harness, for S1. Without it, S1 still works with you reading the script aloud, but it is slower and less repeatable.

**Untested after this plan:** iTerm, Ghostty, Firefox, Arc, Edge, Vivaldi, Opera, and the Slack and Notion desktop apps (none installed). The window-manager side effect of the enhanced switch (no window manager on this Mac). Its CPU cost is measured only if you keep Activity Monitor open during E1 and E2.

## Owner decisions (2026-10-02, after Round 4)
- **Switched apps mid-dictation → pull back.** Re-focus the original app and window, then type, as FluidVoice does. This replaces the "hold the text" behaviour. Fall back to holding (Insert / Copy) only if:
  - the original window is gone;
  - the target field is now a password field;
  - the pull-back fails its focus check.
- **No preview pause.** Type as soon as the final text is ready; remove the ~0.6 s dwell. The preview may still show, but it never delays insertion.
- **Live tests run at the end.** S0–S2 run after all of N1–N28 are built and the confidence gate passes. Until then, validation uses unit tests and replays of recorded dictations (the replay tool) only.

## Build status (N1–N28)

Gate 2026-10-02. Format: id · status · what · tests. Live checks S0–S2 deferred by owner decision 3; "unit" = met in unit tests only.

- N1 · done · Dictionary rows carry origin; Contacts out of boost, spell-exactly, cleanup context and (gate fix) voice-repair alternates · ContactsChannelExclusionTests, PersonalisationTests; gate T-replay of all 41 recordings: 0 swaps, 0 Contacts terms in any channel
- N2 · done · Cancel after recognition keeps text (held, history, Insert/Copy); pill buttons follow the turn's offer · L3 lane tests
- N3 · done (unit) · DeliveryLadder in TextInjector + lander: unreadable field in same app with window → deliver unverified; Notes only with no window · ladder, AdapterMatrix, ClaudeDesktop tests
- N4 · done (unit) · SecureInputGuard before stack and each method; password-label veto refuses, never holds · SecureInputGuardTests, InferredSurfaceVerifyTests
- N5 · done (unit) · WritePlanner: web → shift-Return, terminal → bracketed paste, never bare Return · WritePlanN5Tests, NewlineSafety
- N6 · done (unit) · CTC booster resident at launch, never loaded in a turn, 1.5 s rescoring deadline; per-stage final-pass ms + pre-boost raw text in turn_records · FinalPassTimingRecorderN6, BoostDeadlineResidencyN6, CTCBoostingResidency
- N7 · done (unit) · Per-turn context snapshot at key-down (250+150 ms), app-bound, ended on every turn end with open-turn lease; AXReader per-node deadlines; participants walk capped 0.25 s · TurnContextSnapshotN7Tests, AXReaderDeadlineN7Tests
- N8 · done (unit) · No preview dwell (Manual review still waits); one pre-write check; pull-back to key-down window on app switch, hold only if window gone/password/refocus fails · L3 lane tests
- N9 · done · Evidence-weighted SurfaceResolver, one seed table, secure veto, safe prose for unknown apps; consumed by TurnSurfaceContext, injector inference, boost/prompt rubric, FieldRole; codex persona reset at startup · SurfaceLaneVerifyTests, Surface*/FieldRole suites
- N10 · done (unit) · App accessibility enabler at key-down; enhanced attribute only for Renderer-helper bundles · AppAccessibilityEnablerTests
- N11 · done (unit) · ContextRubric quotas + collision rule + learned weights in live boost list; screen-terms Lab gate (off until a passing report) · ContextRubricN11Tests, ScreenTerms/Lab gate tests
- N12 · done · Spoken-symbol, command-line, formula, URL/search, form-field, Markdown grammars via FieldRoleFormatterStage · SurfaceGrammarN12Tests
- N13 · done (unit) · ShellContextProvider (process tree, PATH, opt-in aliases/folder listing) + PathMatcher in TerminalFormatter · ShellContextProviderN13Tests, PathMatcherN13Tests
- N14 · done · Surface-aware cleanup prompt (field kind, caret text, spell list, screen terms; 1,000-char split; none for secure) wired live via contextPrompt.rubric · CleanupPromptN14Tests, CleanupContextListsN14Tests
- N15 · done (unit) · Canvas with nothing editable focused → hold, no write · SurfaceWritePlanN9N15Tests
- N16 · done · Unconfirmed readback neutral; paste never jumps ahead of keystrokes in newline-safe plans · MethodRouterN16Tests
- N17 · done (unit) · Tap < 250 ms → hint after double-tap window, no turn record; "Didn't hear anything" · L3 lane tests
- N18 · done (unit) · Transient/concealed pasteboard markers, 200 ms restore with changeCount guard · TransientPasteboardTests, ClipboardRestoreTests
- N19 · done (unit) · Ribbon: zero-width caret, leading-edge coarse rungs, off-display fall-through, geometry-only diagnostics · RibbonN19Tests, TapeFlight*
- N20 · done · Notch Working until write/held; held row names app that took focus; "Previous text still landing" · L3 lane tests
- N21 · done · One full-UUID turn id across turn_diagnostics and turn_records · TurnDiagnostics tests
- N22 · done · Pill 5 faces / notch 5 faces state model · state-mapping table + parity tests
- N23 · done (unit) · New press allowed once previous text is final; lands in start order; older turn never takes pill/Escape/deixis · L3 lane tests
- N24 · done (unit) · Rich paste (TSV+HTML sheet cell, Markdown editor) after focus/secure/ladder checks; formula guard always on · RichPasteN24Tests
- N25 · done · 2–3 presets per surface kind, per-app override wins · SurfacePresetsN25Tests, SurfacePresetRulesN25
- N26 · done · cleanup.skip separate from style off; mid-document insert keeps edges · CleanupSkipN26Tests
- N27 · done (unit) · Opt-in OCR caret-band ribbon rung, geometry only, 0.8 s deadline · RibbonOCRRungN27Tests
- N28 · partial · SourceWeightLearner fed live by ContextLearningTap (offered vs landed); learned weights feed boost + prompt rubric · ContextLearningTapN28Tests, SourceWeightLearnerN28Tests
- Tools: T-replay (`--replay`, never injects), T-probe (`--ax-probe`, read-only), T-schema (surface + stage ms in turn_records) · ReplayHarnessTests, AXProbeTests

**Deviations / open:** N28 "corrected away" learning and heard aliases from later corrections not wired (tap records empty corrections). N24 "equals" command that frees formulas has no live caller. N7: if turn 2 starts before turn 1 lands in the same app, turn 1 reads turn 2's snapshot. N6: a rescore past the deadline keeps running on the runtime actor; only the key-release final pass is timed. N9-integrate: lander passes no surface; injector infers its own (TurnSurfaceContext's shell/placeholder detail not forwarded). Injection/AppAdapter keeps its own bundle-id sets. T-replay copies AppContainer's stage list (no act key/latch/wake verb); 3 s "play into field" mode not built. No live S0–S2 validation (owner decision 3).

**Gate (99378d9):** fixes — pull-back AX roots via AXGuard (K18 audit), Contacts out of voice-repair alternates, bundle-path test expects the N6 CTC model, onboarding mock install set locked (torn-read SIGABRT in the full suite). Full suite (--no-parallel): 4799/4799 passed, 455 s. Integration: N9 resolver consumed by TurnSurfaceContext → boost rubric (N11), FieldRole grammars (N12), cleanup prompt rubric (N14), injector plan/ladder/N24; pull-back (SystemFocusPullBack.live) and no-dwell live in TurnController; CTC booster prepared at launch (N6). T-replay over 41 recordings (~/Library/Application Support/VoicePlus/Recordings): 35 with speech, 6 silent/empty, 0 boost swaps, boost/spell/cleanup channels empty on every turn (no Contacts). Observed: "one, two, three." → "123  " (number run collapsed, trailing spaces, period lost) — open, not an N item.

**Release 1.14.0:** `Packaging/releases/VoicePlus_N-fixes_1.14.0.dmg`, 779 MB, SHA256 `c398e91cf42871f2a8af633efe5cb90f391cfc07f94ca4e24d636f708c575bc8`; full installer (TDT v3, EOU, speaker, N6 CTC, Silero VAD, llama.framework); `FULL_INSTALLER=1 verify_install.sh` OK. CTC inference in a fresh install, first-launch compile time and Gatekeeper not verified.
