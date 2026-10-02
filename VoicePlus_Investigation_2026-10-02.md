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
