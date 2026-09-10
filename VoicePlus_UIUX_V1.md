# VoicePlus — UI / UX v1

Supersedes VoicePlus_UIUX.md. DESIGN.md follows approval.

Decisions taken from review: ⌥⌥ = hands-free latch only · ambient **on by default** · green = active ·
Timeline and Meetings are separate · glyph click (either button) opens a menu · Start meeting in that menu.

On ambient default-on: the reason for opt-in was that stored *audio* of other people is a consent
problem in two-party jurisdictions. Resolution: ambient stores **transcript, not audio**, by default.
Audio retention is the opt-in. The mic indicator and hard mute carry the rest.

---

## 0. One thing to remember

> **It never leaves your Mac, and you never touch the keyboard.**

Not "to fix it." At all. Dictate, edit, point, act, capture, ask. The keyboard is optional.

## 1. The brand: the caret

Every competitor's icon is a microphone or a waveform. Ours is where the words **land**.

```
   app icon                    the plus, rebuilt

   ┌───────────┐               vertical   = text caret  (where words land)
   │     │     │               horizontal = the voice line (waveform baseline)
   │  ▁▃─┼─▅▂  │
   │     │     │               the "+" in VoicePlus was already this. Now it means it.
   └───────────┘

   one mark, four states, everywhere (icon · glyph · pill · onboarding):

        │               ▁▃▅│▂▁             ▁▃▅│▂▁              ·
     ───┼───           ───┼───            ───┼───              ▼
        │                  │                  │             ───┼───
      idle             listening          holding             land
   caret breathes     line becomes       ring around       caret drops out of
   (2 s, no CPU)      waveform           caret = latched   the pill into the field
```

Signature motion, **the land**: on commit, the text slides *down* out of the pill and the caret
blinks once in the target field. Direction tells you where it went. Nothing else in the app moves
unless it is telling you something.

## 2. Surfaces

```
  ┌────────────────────────────────────────────────────────────────────────────┐
  │  ▂▂▂▂[ PILL ]▂▂▂▂            ┌──────────────┐          ┼  glyph → MENU     │
  │   primary. 95% of use        │   WINDOW     │             (9 rows, status  │
  │                              │  sidebar +   │              card on top)    │
  │  ┌────────────────┐          │  detail      │                              │
  │  │ inline repair  │          │              │      ┌──────────────────┐    │
  │  │ inline edit    │          └──────────────┘      │ consent card /   │    │
  │  │ ink + agent    │                                │ undo toast       │    │
  │  │ cursor         │          ┌──────────────┐      └──────────────────┘    │
  │  └────────────────┘          │ ONBOARDING   │                              │
  │  on-screen, transient        │ (once, 3 min)│                              │
  └──────────────────────────────┴──────────────┴──────────────────────────────┘
  killed: tabbed Settings · Data Panel window · Lab window · Enrollment window · dock icon
```

## 3. Keys

```
   TEXT KEY  Right ⌥                              ACT KEY  Right ⌘
   ──────────────────                             ─────────────────
   hold ──► dictate ─────► release = land         hold ──► say it ──► release
   hold + selection ──► transform                            │
   hold over a word ──► repair                               ├─ reversible ──► done
   tap-tap ──► LATCH (hands-free)                            ├─ semi ────────► done + 5 s undo
   tap while latched ──► stop                                └─ irreversible ► card: "confirm"

   NO KEY (ambient on)
   ─────────────────────
   "type …" / "send …" / "note …" / "VoicePlus, …"  ──► wake-verb grammar (Phase 5)
   anything else ──► Timeline only, never injected
```

Hold vs. tap by duration. Latch is ⌥⌥ and nothing else is.

## 4. The pill

One line tall, under the notch. Anatomy:

```
   ▂▂[ ◐ │ ▁▃▅▂▁  send the deck to Priya on Thurs   EN·हि  ◷0.3s ]▂▂
        │ │  │      │                                │      │
        │ │  │      │                                │      └ pass-2 latency, only when >0.5 s
        │ │  │      │                                └ script badge, only when code-switched
        │ │  │      └ text: gray = provisional · white = final · dotted = low confidence
        │ │  └ voice line (waveform while speaking)
        │ └ caret (the brand mark)
        └ mic quality: ◐ good ◔ weak ○ bad, shown BEFORE you speak
```

States (superset of today's `PillState`):

```
   idle          ▂▂[ │ ]▂▂                                   caret breathing
   listening     ▂[ │▁▃▅▂  send the deck to Pr… ]▂            gray tail streams
   landing       ▂[ ✓  send the deck to Priya. ]▂  ──▼──      snaps white, drops out
   latched       ▂[ (│)▁▃▅▂  …still on it ]▂                  ring = hands-free
   transform     ▂[ ✎ editing 42 words · make it shorter ]▂   tinted, echoes selection size
   chained       ▂[ ✎ still on it · 8s ]▂                     after an edit, keeps warm
   repairing     ▂[ ① Priya ② Preya ③ Freya ]▂                mirrors the inline fan-out
   corrected     ▂[ ✓ fixed "Prya" behind you · show ]▂       dual-path ledger, 1.5
   learned       ▂[ ★ I'll remember Kothari ]▂                once per word, ever
   thinking      ▂[ ◌ thinking… ]▂                            agent fallback only
   acting        ▂[ ▸ open PR ✓ · scroll ● · find check ○ ]▂  step chips
   which one?    ▂[ ? which one — point or say ]▂             reverse elicitation
   regions       ▂[ ✎ 3 regions ]▂                            ink bundle across displays
   ambient       ▂[ ◎ ]▂                                      hollow: hearing, not typing
   directed      ▂[ ◎ → │ ]▂                                  warms one beat: "that was for me"
   noted         ▂[ ◎ noted ]▂                                "note: …" landed in Timeline
   meeting       ▂[ ● 2 speakers · 12:04 · ⏸ · ★ ]▂           live bar
   muted         ▂[ ⊘ ]▂                                      hard latch, persists
   weak mic      ▂[ ◔ weak signal · switch mic? ]▂
   held          ▂[ ⏸ held · 1 sentence ]▂                    focus lost mid-utterance
   error         ▂[ ✕ couldn't land · ⌘Z ]▂
```

Color rules: **green** = mic open. Nothing else is green. Mute is a shape, not red.
Confidence is opacity + dotted underline. Provisional vs. final is gray vs. white.

## 5. Text, edit, repair, point

```
                    TEXT KEY held
                         │
          ┌──────────────┼──────────────────┐
     no selection    selection exists    key held over a word
          │               │                    │
       DICTATE        TRANSFORM              REPAIR
          │               │                    │
   ┌──────┴───────┐  "make this shorter"   ① ② ③ fan-out
   plain      cursor     "bold the number"      "no, Priya"
   speech     command    "answer: …" ▼          "not that one"
      │          │        types below,          "scratch that"
      │     "delete last  attributed
      │      sentence"
      │     "replace Friday
      │      with Thursday"
      │     "new paragraph"
      ▼          ▼
   formatter per destination: email · chat · code · prose · terminal
```

Inline edit = cursor commands, no selection needed. Same morph as transform (old collapses,
new expands, 320 ms). "↩ try again" ghost for 5 s. Chained turns for 8 s without re-selecting.

Point and speak (Phase 3):

```
    "move  this   over  there"
            │            │
            ▼            ▼
     ┌─────────┐    ┌─────────┐
     │ ░░░░░░░ │    │         │      pointer path is on the same clock as the words.
     │ ░pulse░ │ ~~~│  pulse  │      each deictic word binds to where you were pointing.
     └─────────┘    └─────────┘      bound region pulses once. drag = hand-drawn stroke, fades.
```

## 6. Act (Phase 4)

```
   ACT KEY ─► "open the PR tab and scroll to the failing check"
                    │
          deterministic (AX tree, offline, instant)  ── covers ~200 verbs
                    │ miss
          agent (planner LLM, visible plan) ──► ▂[ ▸ open PR ✓ · scroll ● · find check ○ ]▂
                    │
          its own cursor:  ⊹~~~   tinted, wisp trail, never your pointer
                    │
     ┌──────────────┼──────────────────┐
  reversible      semi               irreversible
  just happens   ┌────────────┐     ┌───────────────────────┐
                 │ Sent · ◔ ↩ │     │ Delete 3 files?       │
                 └────────────┘     │ say "confirm" or click│
                  5 s draining      └───────────────────────┘
   "stop" kills anything mid-flight. Always. Visible halt.

   Connectors (API beats robot-clicking):  Slack · Gmail · Calendar · Linear · Notion · GitHub
```

## 7. Ambient — what happens when

Mic never auto-stops. Injection has the guards. Speaker gate + directed-speech detector route.

| Situation | Pill | Stored | Injects / acts |
|---|---|---|---|
| Latched, field focused, you speak | `(│)` + text | transcript | yes |
| Latched, colleague talks to you | `(│)` dims | Timeline "other" | no (speaker gate) |
| Not latched, you say "type reply saying I'll review tonight" | `◎ → │` warms, text | transcript | yes (wake-verb) |
| Not latched, you say "note: ask Priya about pricing" | `◎ noted` | Timeline note, timestamped | no |
| Not latched, "VoicePlus, open Linear" | act chips | action log | yes, tiered consent |
| Not latched, "what did Priya say about the deck" (act key) | answer in pill + types below cursor | — | answer only |
| Podcast / TV / video playing | `◎` steady | nothing (speaker ≠ you, AEC on system audio) | no |
| Colleague talks, you're silent | `◎` | Timeline "other" (transcript only) | no |
| Zoom / Meet / camera starts | meeting prompt | on accept: diarized | no |
| Focus lost mid-sentence | `⏸ held · 1 sentence` | buffered 30 s → then Timeline | paused; resumes on refocus |
| Screen lock / sleep | glyph hidden | nothing | — |
| Another app takes the mic | `◎ sharing mic` | — | — |
| AirPods connect | `◐ AirPods` 2 s | — | — |
| Do Not Disturb | glyph dims; no toasts | as normal | as normal |
| You click mute | `⊘` badge, persists | **nothing, guaranteed** | no |
| "not you" / "forget that" | `◎ ✓` | last segment deleted; teaches gate | — |
| 2 h of silence | `◎` unchanged | — | — |

Wake-verb grammar is printed inside the pill the first ten times, then fades.

## 8. Meetings

```
   detect ──► ▂[ ● Zoom started · Record ▾  │  Ignore ]▂        (camera / calendar signal)
                             │ Record
                             ▼
   live   ──► ▂[ ● 2 speakers · 12:04 · ⏸ · ★ ]▂                 ★ = mark this moment
                   "note: follow up on pricing"  ──► pinned to 12:04
                             │ call ends
                             ▼
   after  ──► ▂[ ✓ Notes ready · Open ]▂   +  notification
```

Meeting page (window ▸ Meetings ▸ one meeting):

```
 ┌────────────────────────────────────────────────────────────────────────────┐
 │  Pricing sync · Tue 09:00 · 41 min · Priya, Sam, you                        │
 │  ┌──────────┬────────────┬──────────┐                                       │
 │  │  Notes   │ Transcript │ Actions  │                                       │
 │  └──────────┴────────────┴──────────┘                                       │
 │  ┌──────────────────────────────┐  ┌─────────────────────────────────────┐ │
 │  │ your skeleton, typed or      │  │ 12:04 ★  Priya  we can't do $49 …   │ │
 │  │ spoken during the call       │  │ 12:31    Sam    what about annual?   │ │
 │  │  • pricing                   │  │ 13:02    you    let me check with…   │ │
 │  │    ↳ filled: Priya pushed    │  │                                      │ │
 │  │      back on $49, annual ok  │  └─────────────────────────────────────┘ │
 │  │  • follow-ups                │   speakers are colors; you are white     │
 │  └──────────────────────────────┘                                          │
 │  Actions: ☐ send Priya the annual sheet  → Gmail  ☐ file pricing bug → Linear │
 │  (each action = connector call, tiered consent)                            │
 └────────────────────────────────────────────────────────────────────────────┘
```

Granola's skeleton pattern, local. Ask over a meeting = act key on this page.

## 9. Notes and memory

No chat window (spec Part 6). Memory is captured, searched, and answered *in place*.

```
   capture                       store                      use
   ─────────                     ─────                      ───
   "note: …"  (any time)    ──►  Timeline note         ──►  Timeline search
   ★ in a meeting           ──►  pinned moment         ──►  meeting page
   ambient transcript       ──►  Timeline, speaker-tagged   act key: "what did X say about Y"
   dictations               ──►  Timeline               ──►  answer types below cursor / in pill
                                                              end-of-day digest (Today page)
```

## 10. The menu

Left or right click. A status card, then high-frequency actions.

```
   ┌───────────────────────────────────┐
   │  (│) Listening · MacBook mic ◐    │   ← state, mic, quality. click = mute
   │  0 KB out today · 4,102 words     │
   ├───────────────────────────────────┤
   │  ⊘ Mute                     ⌥⇧M  │
   │  ● Start meeting recording        │   ← becomes "■ Stop · 12:04" while live
   │  ◎ Ambient listening          ✓   │
   │  ✎ Note…                          │   ← opens the pill in note mode
   ├───────────────────────────────────┤
   │  ↩ Undo last landing              │
   │  ⎘ Copy last dictation            │
   │  ⏸ Pause for 1 hour           ▸   │   ← 1 h · until tomorrow · until I resume
   ├───────────────────────────────────┤
   │  Open VoicePlus                   │
   │  Quit                             │
   └───────────────────────────────────┘
```

Nine actions, three groups. No Benchmark, no model line, no settings.

## 11. The window

```
 ┌──────────────┬────────────────────────────────────────────────────────────┐
 │ ┼ VoicePlus  │  Today                                                      │
 │              │                                                             │
 │ ● Today      │   4,102 words · 11 edited              ZERO-EDIT   99.7 %   │
 │   Timeline   │   ▁▂▃▅▃▂▁▂▃▅▇▅▃▂  words/hour                                │
 │   Meetings   │                                                             │
 │              │   0 KB out · 0 KB in   ◐ mic good   ▮ thermal nominal        │
 │   Dictionary │                                                             │
 │   Snippets   │   Recent                                                    │
 │   Apps       │   09:41  Mail   Priya, the deck is attached…          ✎ 1   │
 │              │   09:38  Slack  on it, give me ten                          │
 │   Voice      │   09:12  Xcode  let results = try await…          EN·हि    │
 │   Privacy    │                                                             │
 │   Settings   │   Learned this week                                         │
 │              │   Priya · Kothari · TeamViewer · Ultrathink        review › │
 │ ⓘ About      │                                                             │
 │              │   Digest · 3 notes · 1 meeting · 2 actions pending    open › │
 └──────────────┴────────────────────────────────────────────────────────────┘
```

| Section | Holds |
|---|---|
| Today | zero-edit, words/hour, egress, mic, thermal, recent, learned, digest |
| Timeline | dictations · notes · ambient segments · one list, filter chips: mine / others / notes |
| Meetings | list → meeting page (§8) |
| Dictionary | terms · auto-learned (approve/reject) · "heard as" · Contacts import |
| Snippets | trigger → expansion |
| Apps | per-app formatter · **persona = one plain-English sentence** · never-inject list |
| Voice | enrollment (re-record) · mic + self-test · **You** (personal WER day 1 vs 30, words learned, scripts) · **Benchmark** (the Lab) |
| Privacy | egress graph · request log · block-all · ambient retention · audio retention · screen context |
| Settings | keys · presence · **Models & connections** · sync (QR pairing) · updates |

Models & connections, plain:

```
   Hearing       Parakeet + EOU + Qwen3 ASR        bundled · on-device · 0 KB
   Writing       Local LLM (bundled)               on-device · 0 KB          ← new default
                 ○ ChatGPT (sign in)               your subscription pays
                 ○ Claude CLI  ○ Codex CLI         detected on this Mac
                 ○ API key (OpenRouter, any)
   Planning      same as Writing
   Every non-local call shows in Privacy. Auto = local first, always.
```

CLI / OAuth / key stay. They are upgrades to *Writing* and *Planning*, never to Hearing.

## 12. Onboarding — teach by doing

Each step: do one thing, see the result. Scripts are fixed so the demo is predictable.

```
  1 Welcome ─► 2 Permissions ─► 3 Voice ─► 4 Names ─► 5 Dictate ─► 6 Fix ─► 7 Latch
  ─► 8 Edit ─► 9 Act ─► 10 Ambient & mute ─► 11 Done                        ≈ 3 min
```

| # | Screen | You do | You see |
|---|---|---|---|
| 1 | Welcome | nothing | the caret mark, one line, one shader moment |
| 2 | Permissions | grant Mic, Accessibility | each row flips ✓ live; one line why each |
| 3 | Your voice | read 3 phrases | waveform; mic verdict ◐ inline |
| 4 | Names | Import from Contacts (optional) | "Priya, Sam, 214 more will land right" |
| 5 | Dictate | hold ⌥, read script A | fillers gone, self-correction resolved, name correct |
| 6 | Fix by voice | say "no, Priya" over the shown word | word snaps; "★ I'll remember" toast |
| 7 | Hands-free | ⌥⌥, read script B, pause, keep going | two sentences land separately; tap to stop |
| 8 | Edit | select the text, hold ⌥, say "make it one line" | inline morph; "↩ try again" ghost |
| 9 | Act | hold ⌘, say "open System Settings" | it opens (reversible); say "close it" |
| 10 | Ambient & mute | click the glyph → mute; click again | `⊘` badge appears and persists; then `◎` |
| 11 | Done | nothing | window opens on Today, 0 KB out |

Scripts:

```
   Enrollment (3, ~8 s total)
     "Hey VoicePlus, this is how I normally talk."
     "Send the deck to Priya on Thursday and copy the whole team."
     "Um, actually, make that Friday, and open the pull request in Safari."

   Script A (dictate)
     "Um, send the deck to Priya on Friday — no, Thursday — and cc the whole team."
       lands as:  Send the deck to Priya on Thursday and cc the whole team.

   Script B (hands-free)
     "The first sentence lands on its own."  (pause 2 s)  "So does the second one."

   Step 6 uses the real mis-hearing if one happened in step 5; otherwise shows "Prya" as a demo.
```

Removed: model choice, download bar, "Connect what you pay for" gate, separate enrollment window.

## 13. Consent surfaces

```
   semi-reversible                    irreversible
   ┌──────────────────────┐           ┌────────────────────────────────┐
   │ Sent to #design  ◔ ↩ │           │  Delete 3 files in ~/Desktop?  │
   └──────────────────────┘           │  say "confirm"  ·  [Confirm]   │
   bottom-right, 5 s ring             └────────────────────────────────┘
                                      slides from the right, never a sheet
```

## 14. Coverage vs. PRODUCT-SPEC

| Bet / phase | Where in this doc |
|---|---|
| B1 acoustic, mic warning | §4 mic quality before you speak |
| B2 biasing, Dictionary, Contacts | §11 Dictionary, §12 step 4 |
| B3 repair by voice | §5, §12 step 6 |
| B4 dual-path silent correction | §4 `corrected` state, ledger "show / put it back" |
| B5 two keys | §3 |
| B6 point and speak, ink | §5 |
| B7 tiered consent | §6, §13 |
| B8 gatekeeper, formatters | §5 |
| B9 confidence visible | §4 opacity + dotted |
| Ph2 transform, chained, answers, personas, snippets | §5, §11 Apps |
| Ph3 deixis, elicitation, regions | §4, §5 |
| Ph4 act, agent cursor, chips, connectors | §6 |
| Ph5 ambient, wake-verbs, speaker gate, mute, meetings | §7, §8 |
| Ph6 learned toast, You tab, code-switch badge, QR sync | §4, §11 Voice, §11 Settings |
| Lab | §11 Voice ▸ Benchmark |
| Zero-edit counter | §10, §11 |
| 4.6 model access | §11 Models & connections |

Not covered, on purpose: mobile keyboard (not a Mac surface), managed subscription (no GTM in scope).

## 15. Needs your call

1. Act key default: **Right ⌘** or **fn**? (Right ⌘ is free on most layouts; fn is what Kivi/Infina use.)
2. Ambient default stores transcript of *other* speakers too, or only yours until you mark a meeting?
3. "Note…" in the menu opens the pill in note mode — or should it open a tiny scratch card under the notch?
4. Local LLM for Writing: bundle it (adds ~1 GB) or download on first "Writing" use?
