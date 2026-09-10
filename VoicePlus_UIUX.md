# VoicePlus — UI / UX

Draft for approval. DESIGN.md (tokens, type, color, motion) follows only after sign-off.

---

## 1. What the category looks like

```
                 polished / opinionated UX
                          ▲
                          │        ● Wispr Flow (cloud, cream+serif, "4x faster")
                          │        ● Willow ("Apple-like, works instantly")
                          │
          ● Granola       │
          (meetings only) │
                          │
  ───────────────────────┼──────────────────────────────► on-device / private
                          │
                          │  ● Superwhisper (every knob exposed)
                          │  ● Muesli (sidebar window, honest, plain)
                          │  ● FluidVoice
                          │
                    ○ VoicePlus today
                    (private, but nine tabs + four stray windows)
```

Table stakes everyone ships: hold-key pill, live waveform, vocabulary, snippets, per-app style.
What nobody ships: **repair by voice**, **confidence you can see**, **proof nothing left the machine**.

The top-right quadrant is empty. That is the target.

## 2. The one thing to remember

> **It never leaves your Mac, and you never touch the keyboard to fix it.**

Every screen serves one of those two halves. Anything that serves neither gets cut.

Design posture: **an instrument, not a toy.** Honest readouts, one live color, no decoration
that isn't information. The category is warm-cream-and-serif; we are the opposite on purpose.

## 3. Surfaces

```
   ┌──────────────────────────────────────────────────────────────────────┐
   │  ▂▂▂▂▂ notch ▂▂▂▂▂      ┌──────────────┐        ◉ menu bar glyph      │
   │      [  PILL  ]         │              │        (3 states, click =   │
   │   the product lives     │   WINDOW     │         open window)         │
   │   here 95% of the time  │  sidebar +   │                              │
   │                         │  detail      │                              │
   │  ┌──────────────┐       │              │   ┌────────────────────┐    │
   │  │ inline repair│       └──────────────┘   │ ONBOARDING (once)  │    │
   │  │ under a word │                          └────────────────────┘    │
   │  └──────────────┘                                                     │
   └──────────────────────────────────────────────────────────────────────┘

   KILLED:  tabbed Settings · Data Panel window · Lab window · Enrollment window
            · menu-bar-opens-a-menu · dock icon (stays hidden)
```

Four surfaces. The pill is primary. The window is where you go on purpose, rarely.

## 4. The pill

Lives under the notch (or top-center on notchless Macs). Always present, one line tall when
idle. Expands only while something is happening; idles at 0% CPU.

```
 idle           ▂▂▂[ ● ]▂▂▂                          dot only. mic closed.

 hold ↓         ▂▂[ ● ▁▃▅▂▁ ]▂▂                      waveform. mic open (amber).

 speaking       ▂[ ● ▁▃▅▂  send the deck to Prya ]▂  volatile tail, gray text

 EOU / release  ▂[ ● ✓  send the deck to Priya. ]▂    text snaps to final, pulse once
                        └── Priya corrected by pass-2 + Dictionary

 landed         ▂▂▂[ ● ]▂▂▂                          retracts. text is in the app.

 latched        ▂▂[ ◉ ▁▃▅▂▁          ⏸ ]▂▂           ring around dot = hands-free
 ambient on     ▂▂[ ◎ ]▂▂                            hollow = listening, not injecting
 muted          ▂▂[ ⊘ ]▂▂                            hard mute. badge persists.
 bad mic        ▂[ ● ⚠ weak signal · check mic ]▂    BEFORE you speak, not after
 error          ▂[ ● ✕ couldn't land · ⌘Z ]▂
```

Rules
- Volatile text is **gray**; final text is **white**. The user learns in one use what is provisional.
- Low-confidence words get a **dotted underline** in the pill, never red.
- Amber is the only color, and it means exactly one thing: **mic is open**.
- Latch, ambient, and mute are distinct **glyph shapes**, not colors. Readable at a glance, readable colorblind.

## 5. Keys and modes

```
  TEXT KEY (Right ⌥)                          ACT KEY (separate, Bet 5)
  ┌────────────┐                              ┌────────────┐
  │   idle     │                              │   idle     │
  └─────┬──────┘                              └─────┬──────┘
   hold │        tap-tap                        hold│
        ▼            │                              ▼
  ┌────────────┐     ▼                        ┌────────────┐
  │ push-talk  │  ┌────────────┐              │  ask/act   │──► reversible: do it
  │ release =  │  │  latched   │              │            │──► semi: do + 5s undo
  │ endpoint   │  │ EOU =      │              │            │──► irreversible: confirm
  └─────┬──────┘  │ endpoint   │              └────────────┘
         │        └─────┬──────┘
         ▼          tap │
       land             ▼
                      stop

  Inside TEXT KEY the gatekeeper routes freely:
     selection exists?  ──► transform ("make this shorter")
     no selection       ──► dictate  → email / chat / code / prose / terminal formatter
  Text vs. Act is never inferred. Two keys. Heavy inference inside each.
```

Hold vs tap is decided by **duration**, so the hold path pays no double-tap wait.

## 6. Where text goes

```
   mic ──► VAD ──► Parakeet stream ──► EOU
                        │               │
                        ▼               ▼
                   ┌─────────┐    segment closed
                   │  PILL   │          │
                   │ volatile│          ▼
                   │  tail   │    gate? ──no──► commit Parakeet text
                   └─────────┘      │yes
                                    ▼
                          Qwen3 + bias list ──► commit final text
                          (Dictionary + AX screen                │
                           text + your history)                  ▼
                                                     ┌──────────────────────┐
                                                     │  TARGET FIELD        │
                                                     │  append-only, never  │
                                                     │  retracted           │
                                                     └──────────────────────┘
```

Perceived latency = the pill (~160 ms). Field latency = one sentence, last sentence only.
Earlier sentences refine while you keep talking. Nothing ever rewrites text the user has touched.

## 7. Inline repair (Bet 3)

Hold the text key over a word in the destination app:

```
      send the deck to Prya on friday
                       ─┬──
              ┌─────────┴──────────┐
              │ ① Priya  ② Preya   │   ◄── say "one", "Priya", or "not that one"
              │ ③ Freya  ✎ spell   │       "scratch that" drops the phrase
              └────────────────────┘
```

No panel, no popup window. Numbers are spoken. Alternates come from the confusion network,
then Dictionary, then phonetic neighbours.

## 8. The window

Opened from the menu-bar glyph or `⌥ + double-tap`. One window. Sidebar + detail. No tabs.

```
 ┌──────────────┬──────────────────────────────────────────────────────────┐
 │ ▌VoicePlus   │  Today                                                    │
 │              │                                                           │
 │ ● Today      │   4,102 words spoken · 11 edited          ZERO-EDIT 99.7% │
 │   Timeline   │   ─────────────────────────────────────────────────────── │
 │   Meetings   │   0 KB out · 0 KB in · mic: good · thermal: nominal      │
 │              │                                                           │
 │   Dictionary │   Recent                                                  │
 │   Snippets   │   ┌────────────────────────────────────────────────────┐ │
 │   Apps       │   │ 09:41  Mail    "Priya, the deck is attached…"  ✎1  │ │
 │              │   │ 09:38  Slack   "on it, give me ten"                │ │
 │   Voice      │   │ 09:12  Xcode   "let results = try await…"          │ │
 │   Privacy    │   └────────────────────────────────────────────────────┘ │
 │   Settings   │                                                           │
 │              │   Learned this week                                       │
 │              │   Priya · Kothari · TeamViewer · Ultrathink     [review] │
 │ ⚙ About      │                                                           │
 └──────────────┴──────────────────────────────────────────────────────────┘
```

| Section | What it holds | Where it came from |
|---|---|---|
| Today | zero-edit counter, egress, mic, recent dictations | menu dropdown + Data Panel header |
| Timeline | every dictation + ambient segment, searchable, speaker-tagged | new; Meetings folds in |
| Meetings | captured calls, diarized, local notes | existing coordinator |
| Dictionary | terms, auto-learned names (approve/reject), per-term "heard as" | existing |
| Snippets | existing | Snip… tab |
| Apps | per-app formatter, style, **never-inject list** (password managers on by default) | Pers… tab |
| Voice | enrollment (re-record), mic picker, self-test, **Benchmark** (= Lab) | Enrollment window + Lab window |
| Privacy | egress graph, request log, block-all toggle, ambient retention, "what VoicePlus saw" | Data Panel |
| Settings | keys, presence, connectors, sync, updates | Gene… / Servi… / Sync / Flags |

Lab is not deleted. It is renamed **Benchmark**, lives under Voice, and is the evidence panel
the spec promised: "the human tester doesn't take our accuracy claims on faith."

### Privacy is a section, not a debug window

```
 ┌───────────────────────────────────────────────────────────────┐
 │  Privacy                                    Block all egress ○ │
 │                                                                │
 │  0 KB out · 0 KB in · 0 requests            since install      │
 │  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  last 24h                            │
 │                                                                │
 │  Ambient capture        off ○    keep 7 days ▾   [delete all]  │
 │  Screen context         on  ●    read per utterance, never kept│
 │  Recordings             off ○                                  │
 │                                                                │
 │  Requests               (none)                                 │
 └───────────────────────────────────────────────────────────────┘
```

Bundled models mean the honest default reads **0 KB in**. Show it.

## 9. Onboarding

Under two minutes. Every step *does* something. No model choice, no download bar.

```
  ┌─────────┐   ┌──────────┐   ┌─────────┐   ┌──────────┐   ┌─────────┐   ┌──────┐
  │ Welcome │──►│ Permis-  │──►│ Your    │──►│ Your key │──►│ Ambient │──►│ Done │
  │ (hero)  │   │ sions ×2 │   │ voice   │   │ + try it │   │ opt-in  │   │      │
  └─────────┘   └──────────┘   └─────────┘   └──────────┘   └─────────┘   └──────┘
   ~5 s          mic, AX        3 phrases     dictate one      default OFF   window
                 one line why   = mic check   real sentence                  opens
                                              into a real box
```

Step 4 is the one that matters:

```
 ┌────────────────────────────────────────────────────────────────┐
 │                                                                 │
 │   Hold Right ⌥ and say anything.                                │
 │                                                                 │
 │   ┌──────────────────────────────────────────────────────────┐ │
 │   │ hello, this is me trying it out.                  ✓ 0.4s │ │
 │   └──────────────────────────────────────────────────────────┘ │
 │                                                                 │
 │   Now double-tap it. Talk. Pause. Keep talking.   ◉ latched     │
 │   ┌──────────────────────────────────────────────────────────┐ │
 │   │ first sentence lands. second one too. ▍                  │ │
 │   └──────────────────────────────────────────────────────────┘ │
 │                                                                 │
 │   Tap once to stop.                     [Change key]  [Next →] │
 └────────────────────────────────────────────────────────────────┘
```

Removed vs. today: `modelChoice` step, "Connect what you pay for" gate (moves to Settings ▸ Connectors),
separate enrollment window (becomes step 3).

## 10. Ambient and meetings

```
   speaker = you  + latched + field focused     ──►  dictation (field)
   speaker = you  + no field / focus lost       ──►  ambient note (Timeline); injection pauses
   not latched, ambient on                      ──►  Timeline, speaker-tagged
   speaker ≠ you                                ──►  Timeline as "other", diarized
   muted                                        ──►  nothing. hard latch. never auto-unmutes.
```

The mic never auto-stops. **Injection** is what has guards.

Meeting self-announce (existing pattern, kept), in the pill not a window:

```
   ▂[ ◎  Zoom started · Record ▾  │  Ignore ]▂
   ▂[ ◉ ▁▃▅  2 speakers · 12:04         ⏸ ]▂        during capture
   ▂[ ✓  Notes ready · Open ]▂                       after
```

## 11. Menu-bar glyph

Three states, matches the pill. Left-click opens the window. Right-click:

```
   ┌──────────────────────┐
   │ ◉ Listening          │
   │ ⊘ Mute               │
   │ ─────────────────────│
   │ Open VoicePlus    ⌥⌥ │
   │ Benchmark…           │
   │ Quit                 │
   └──────────────────────┘
```

Five rows. It is not a dashboard. The window is.

## 12. Design language (proposal — details land in DESIGN.md)

| | Proposal | Why |
|---|---|---|
| Aesthetic | **Instrument.** Utilitarian, refined, dark-first | The differentiator is truthfulness. Readouts, not decoration |
| Decoration | Minimal. One shader moment on the Welcome step, nowhere else | Animated backgrounds behind settings read as 2023 landing page |
| Color | Near-black warm neutrals + **one amber** = mic open | Amber is what macOS itself uses for the mic. Nobody in the category owns it |
| Type | SF Pro (UI) · **mono for every readout** (counts, KB, ms, timestamps, confidence) | Mono is the "instrument" tell; SF keeps it native |
| Confidence | opacity + dotted underline, never color | Color is reserved; low-confidence is a hint, not an alarm |
| Spacing | 4 pt grid, comfortable; rows 44 pt | Native Mac density |
| Motion | Springs only. Pill expand/retract, commit pulse, sidebar select. Zero idle animation | 0% CPU when idle is a feature |
| Copy | Keep the existing voice: "Hold to talk, release to land." Every toggle carries one line of why | Already the best-designed thing in the app |

SAFE: sidebar+detail window, SF Pro, native controls, 44 pt rows.
RISKS: amber as the only color · mono readouts everywhere · gray-vs-white as the provisional/final language.

From your links: adopt the **DESIGN.md pattern** (awesome-design-md / getdesign.md), borrow **motion.dev
principles** into SwiftUI springs, treat Vanta / aidesigner as a mood reference for the Welcome step only.
Skip Jitter and the web animation skill.

## 13. What changes vs. PRODUCT-SPEC

| Spec said | This doc says | Why |
|---|---|---|
| "Two surfaces only: menu bar + pill. No window." | Pill primary, **plus one window** | Timeline, Dictionary, Apps, Privacy, Benchmark can't live in a dropdown honestly |
| Onboarding has model choice | No model choice; stack is bundled | One stack is required for the UX; choice was fake |
| Menu dropdown is the dashboard | Window ▸ Today is the dashboard; menu is 5 rows | Dropdowns can't hold a graph or a list |
| Lab is a window | Benchmark, under Voice | Same feature, findable, named for what it does |

## 14. Needs your call

1. Window opened by **⌥ double-tap** as well as the glyph — or glyph only?
2. Ambient opt-in during onboarding (step 5) — or first-run prompt the first time you latch?
3. Amber as the single accent — or keep green for "active" (category convention)?
4. Timeline and Meetings as one list with a filter, or two sections?
