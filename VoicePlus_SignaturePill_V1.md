# Signature mark + pill — 22 concepts

Working doc. The product name is tentative, so nothing here depends on it. Each concept is a
**mark** (app icon, menu-bar glyph) and a **pill behaviour** (the same mark, alive). Pick one,
then DESIGN.md specifies it.

## What a winner has to do

```
   1  say "listening" vs "not listening"      at a glance, from 2 m away
   2  say "this one is for ME"                ambient's hardest question
   3  make EOU visible                        our real technical edge
   4  make landing feel like landing          the copy already says "release to land"
   5  make mute feel physical and final       shape, never colour
   6  survive as a 16 px static icon          menu bar + Dock + DMG
   7  idle at 0 % CPU                         no perpetual animation
```

Legend: `▂[ … ]▂` = the pill under the notch. `──▼` = the land (content leaves the pill for the field).

---

## A. Typographic

### 1 · Comma
Voice is breath, a comma is a pause, a period means done.
```
   idle        listening          EOU               land          muted
   ▂[ , ]▂     ▂[ ,~~~~ ]▂        ▂[ ,~~~~. ]▂      ▂[ . ]▂ ──▼    ▂[ ; ]▂
   rests       stretches into     a period appears  the period     paused,
               the voice line     the instant it    drops into     not ended
                                  knows you're done the field
```
**Signature:** the period appearing = EOU made visible. **Risk:** quiet; reads as a font demo without great motion. **Names:** Comma, Period.

### 2 · Quote
Listening opens a quotation; landing closes it. Your words, quoted back exactly.
```
   idle        listening                  land              muted
   ▂[ " ]▂     ▂[ " send the deck to▍ ]▂  ▂[ " " ]▂ ──▼     ▂[ „ ]▂
   open quote  text fills the quote       close-quote       low quote:
   waits                                  appears, both     grounded, silent
                                          drop together
```
**Signature:** the close-quote as the commit. **Risk:** no life between utterances. **Names:** Quote.

### 3 · Underline
One line follows the words from mouth to page: waveform → underline → gone.
```
   listening              land                   in the app, 1 s later
   ▂[ ▁▃▅▂▁▃▂ ]▂          ▂[ ────── ]▂ ──▼        send the deck to Priya.
   the line is voice      flattens, drops        ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
                                                 same line, now under the
                                                 words, fading out
   low confidence: the underline stays, dotted, under that word only
```
**Signature:** confidence is a property of the line, not a colour. **Risk:** some fields can't host an overlay underline. **Names:** Line, Underscore.

### 4 · Beam
No mark in the pill. The brand is the **real caret in the user's app** waking up.
```
   in Mail, before      hold the key                    release
   Hi Priya, ▍          Hi Priya, ▍▁▃▅▂▁                Hi Priya, the deck is attached.▍
   plain caret          caret glows, voice line         glow collapses into
                        grows out of it, in place       the landed text
```
**Signature:** answers "where will this go?" at the exact pixel, before you speak. Nothing in the category renders at the cursor. **Risk:** needs AX caret geometry per app; pill fallback = two behaviours to maintain. **Names:** Beam, Cursor.

---

## B. Instrument

### 5 · Brackets
The pill *is* the mark. Brackets open as words arrive, snap shut on land.
```
   idle        listening                      land         muted
   [ ]         [  send the deck to Pri▍  ]    [ ] ──▼      []
   closed      widen with the text            snap shut,   welded shut
                                              contents drop
```
**Signature:** zero decoration; the container is the identity. **Risk:** cold; hard to be delightful with two glyphs. **Names:** Bracket.

### 6 · Needle
An analog VU needle. Endpointing = a needle coming to rest.
```
   idle        listening              EOU              muted
   ▂[ ╲ ]▂     ▂[ ╱ ]▂ ↔ ▂[ ╲ ]▂      ▂[ │ ]▂ ──▼       ▂[ ═ ]▂
   rests left  swings with level      stops dead        pinned flat
                                      upright: done
```
**Signature:** instrument-panel honesty; "this thing measures." **Risk:** retro; slow if physically damped, fake if not. **Names:** Meter, Needle, Gauge.

### 7 · Metronome
A pendulum on the rhythm of your speech; rests on EOU. Turn-taking as identity.
```
   ambient        you speak         pause (thinking)     done
   ▂[   │   ]▂    ▂[  ╲ ╱  ]▂       ▂[  ╲    ]▂          ▂[   │   ]▂ ──▼
   still          swings with       holds off-centre:    settles centre:
                  cadence           "I'll wait"          land
```
**Signature:** the thing we're technically best at becomes the identity. **Risk:** abstract; users may not decode it. **Names:** Tempo, Beat, Cadence.

### 8 · Keycap
The mark is the key you hold. The pop *is* the land.
```
   idle        holding                     release        latched
   ▂[ ▢ ]▂     ▂[ ▣ ▁▃▅▂ send the… ]▂      ▂[ ▢ ]▂ ──▼    ▂[ ▣ ]▂
   at rest     pressed in, text beside     pops up,       pinned, like
                                           text drops     caps lock
```
**Signature:** latch reads as caps-lock, which everyone already understands. **Risk:** it's about the input method, not the outcome; says little in ambient. **Names:** Hold, Key.

---

## C. Motion / natural

### 9 · Ripple
Sound arrives as rings coming *in*; landed text is one ring going *out* from your cursor.
```
   idle        listening            land                    ambient
   ▂[ · ]▂     ▂[ )))·  ]▂          ▂[ · ]▂  in the app:    ▂[ ) · ( ]▂
               rings converge       ( · ) one ring          slow, faint,
               on the dot           expands from the        breathing
                                    caret, once
   muted  ▂[ — ]▂  flat line, no rings
```
**Signature:** the out-ring happens *outside* our UI — in Mail, in Slack. **Risk:** sonar is familiar; all differentiation is execution. **Names:** Ripple, Echo.

### 10 · Tide
A waterline that rises while you speak and breaks with a crest when you're done.
```
   idle        listening       EOU / land          ambient        muted
   ▂[ ─── ]▂   ▂[ ▁▂▃▅ ]▂      ▂[ ▅▆〰 ]▂ ──▼       ▂[ ~~~ ]▂      ▂[ ═══ ]▂
   still       rises           crest breaks,       slow swell,    frozen
   water                       drains into field   never still
```
**Signature:** calming, motion-first, unlike anything in the category. **Risk:** abstract; hard to reduce to a static icon. **Names:** Tide, Swell.

### 11 · Halo
No pill mark. The mark is the notch itself — a hairline tracing the camera housing.
```
      ╭─────────────╮         ╭─────────────╮        ╭ ─ ─ ─ ─ ─ ─ ╮
      │   [notch]   │         │   [notch]   │        │   [notch]   │
      ╰─────────────╯         ╰──────╥──────╯        ╰ ─ ─ ─ ─ ─ ─ ╯
      idle: dark              listening: edge        muted: dashed
                              brightens with level;
                              land: one pulse runs down the seam ▼
```
**Signature:** the most Mac-native idea here; the hardware feels like yours (the old breathing sleep LED). Notchless Macs get a top-edge hairline. **Risk:** invisible on bright wallpapers; icon must be invented separately. **Names:** Halo, Rim.

---

## D. Material / craft

### 12 · Ink Drop
Speech fills a drop at the nib; release lets it fall; it blots into words.
```
   idle        listening              land           muted
   ▂[ ▽ ]▂     ▂[ ▼ ]▂                ▂[ ▽ ]▂ ──▼     ▂[ ⊽ ]▂
   empty       fills as you speak     drop falls,    capped
               (level = volume)       blots into text
```
**Signature:** "writing," not "transcribing." **Risk:** old-fashioned; fights a dark-instrument posture. **Names:** Nib, Blot.

### 13 · Stitch
Voice is thread. Words are sewn. Mute is a snip.
```
   listening              land                          muted
   ▂[ ~~~~~~~~~ ]▂        ▂[ ]▂ ──▼   in the app:       ▂[ ✂ ]▂
   thread pays out                    send the deck…     cut. nothing
   as you speak                       ‐ ‐ ‐ ‐ ‐ ‐ ‐      passes.
                                      running stitch,
                                      one beat
```
**Signature:** "stitched" implies care, not automation. **Risk:** craft aesthetic fights instrument posture — pick one. **Names:** Stitch, Thread, Seam.

### 14 · Fold
Text unfolds out of the pill like paper, folds flat on land.
```
   idle        listening                        land
   ▂[ ─ ]▂     ▂[ ─╱ send the deck to Pr… ]▂     ▂[ ─ ]▂ ──▼
   flat sheet  creases open, text on the        folds shut, contents
               revealed face                    drop into the field
```
**Signature:** satisfying physicality; a fold is a clean container. **Risk:** skeuomorphic, easy to overdo. **Names:** Fold, Crease.

### 15 · Fog
Speaking fogs the glass. Words appear written on it. Landing wipes it clear.
```
   idle          listening                    land            muted
   ▂[       ]▂   ▂[ ░░ send the deck ░░ ]▂     ▂[       ]▂ ──▼ ▂[ ▒▒▒▒▒ ]▂
   clear glass   breath fogs the glass,       one wipe,       frosted solid
                 text emerges through it      text drops
```
**Signature:** a *material* brand; breath is voice. **Risk:** blur costs GPU; legibility over light wallpapers. **Names:** Hush, Breath, Frost.

---

## E. Living

### 16 · Firefly
A point of light in the pill. **Its position is attention.**
```
   ambient (drifting)   colleague speaks       you say "type reply…"
   ▂[    ·         ]▂   ▂[  ·            ]▂    ▂[      ✦        ]▂
   wandering, dim       stays off-centre:      snaps to centre,
                        "not for me"           brightens: "for me"

   listening            land                    muted
   ▂[      ✦~~~~   ]▂   ▂[               ]▂     ▂[      ○        ]▂
   glows with voice        ✦ flies down         dark, hollow,
                        ───┼─── to the caret,   doesn't move
                                blinks, returns
```
**Signature:** answers "is it listening to *me*?" at a glance. A light sealed inside a pill is the privacy story with no words. **Risk:** if the fly centres late, it lies — needs sub-100 ms directed-speech feedback. **Names:** Firefly, Lumen, Mote.

### 17 · Wren
Firefly, grounded: a bird on a wire. The wire is the voice line.
```
   idle            listening          land               not you
   ▂[ ───•─── ]▂   ▂[ ~~~•~~~ ]▂      ▂[ ─────── ]▂      ▂[ ───────• ]▂
   perched         wire vibrates,        •  hops         hops to the far
                   bird stays put     ───┼─── down       end: "not mine"
   muted  ▂[ ─────── ]▂  flown. empty wire.
```
**Signature:** never floats in space; mute as an empty wire is disarming. **Risk:** same latency honesty problem as Firefly. **Names:** Wren, Perch, Wire.

### 18 · Creature
Two dots in the notch. It's a face. The camera housing already looks like a head.
```
   idle         listening      latched       not you       which one?    muted
   ▂[ • • ]▂    ▂[ ◉ ◉ ]▂      ▂[ ◉ ◉ ]▂     ▂[ •   • ]▂   ▂[ ◉  ◉ ]▂    ▂[ ‒ ‒ ]▂
   blinks /6 s  open, track    stays awake   looks away,   tilts         eyes shut
                level                        dims                        (persists)
```
**Signature:** highest recall here. People name it, screenshot it. Mute = it closes its eyes, the most legible mute possible. **Risk:** Clippy. Works only if it never talks, never has a mouth, never asks for anything. **Names:** —

### 19 · Ghost
A faceless wisp: a ghostwriter.
```
   ambient        addressed           listening              land
   ▂[  ~   ]▂     ▂[  ~~  ]▂          ▂[ ~~~ send the… ]▂    ▂[      ]▂ ──▼
   faint wisp     gathers, brightens  writes beside itself   dissolves; only
                                                             the words remain
   muted  ▂[  ·  ]▂  a dot. asleep.
```
**Signature:** "ghostwriter" is a concept people already hold; no face dodges Clippy. **Risk:** "ghost" + "always listening" is a headline we don't want. **Names:** Ghost, Wisp, Scribe.

---

## F. Concept

### 20 · Runway
The pill is a landing strip. Words taxi in and touch down.
```
   listening                                   land
   ▂[ ·  ·  ·  ·    send the deck to Pr▍ ]▂    ▂[ ·  ·  ·  · ]▂ ──▼
   runway lights, text rolls in                lights blink once,
                                               text touches down
   latched: lights stay on   ·   muted: runway closed  ▂[ ✕  ✕  ✕ ]▂
```
**Signature:** makes "release to land" literal, with humour. **Risk:** joke brands age; can read as an airline. **Names:** Land, Runway, Touchdown.

### 21 · Voiceprint
Enrollment generates a ridge pattern from *your* voice. That pattern is your mark. Every user's icon differs.
```
   enrollment                    your mark, forever      listening
   "this is how I talk…"         ▂[ ≋ ]▂                 ▂[ ≋≋≋ ]▂
   ──►  ridges form from         a thumbprint made       the ridges you
        your spectrum            of sound; yours only    made, alive

   not you:  ▂[ ≈ ]▂   a different, grey pattern flashes — "that wasn't you"
```
**Signature:** privacy and personalisation are the same picture. **Risk:** generated marks vary in beauty; a bad one is stuck in someone's menu bar. Needs a curated generator. **Names:** Print, Timbre, Grain.

### 22 · Tick — *a layer, not a mark*
The brand is a **sound**. Visual mark deliberately minimal (a dot).
```
   land   ♪ tick-tock (rising)    the sentence is yours
   mute   ♪ tock (falling)        it stopped hearing
   learn  ♪ a third note          "I'll remember Kothari" — once, ever
   error  ♪ nothing               silence is the alarm
   + a trackpad haptic on land
```
**Signature:** for a voice product, recall through the ear is honest; the Mac startup chime is the precedent. **Risk:** easy to hate; must be off in meetings and killable in one click. **Combines with any visual above.**

---

## Comparison

● = weak → ●●●● = strong

| # | Concept | Recall | Delight | "for me?" | "it landed" | Privacy | 16 px icon | Risk |
|---|---|---|---|---|---|---|---|---|
| 1 | Comma | ● | ●● | ● | ●● | ● | ●●●● | low |
| 2 | Quote | ● | ●● | ○ | ●●● | ● | ●●●● | low |
| 3 | Underline | ●● | ●● | ○ | ●●● | ● | ●● | low |
| 4 | Beam | ●●● | ●●● | ● | ●●●● | ●● | ●● | med |
| 5 | Brackets | ●● | ● | ○ | ●● | ●● | ●●● | low |
| 6 | Needle | ●● | ●● | ● | ●● | ● | ●●● | low |
| 7 | Metronome | ●● | ●● | ●● | ●● | ● | ●●● | med |
| 8 | Keycap | ●● | ●● | ○ | ●●● | ● | ●●●● | low |
| 9 | Ripple | ● | ●● | ● | ●●● | ● | ●●● | low |
| 10 | Tide | ●● | ●●● | ● | ●● | ● | ● | med |
| 11 | Halo | ●●● | ●●● | ●● | ●● | ●● | ○ | med |
| 12 | Ink Drop | ●● | ●● | ○ | ●●● | ● | ●●● | low |
| 13 | Stitch | ●● | ●●● | ○ | ●●● | ●● | ●● | med |
| 14 | Fold | ●● | ●● | ○ | ●●● | ● | ●● | low |
| 15 | Fog | ●●● | ●●● | ● | ●● | ●● | ● | med |
| 16 | Firefly | ●●● | ●●● | ●●●● | ●●● | ●●● | ●●● | med |
| 17 | Wren | ●●● | ●●●● | ●●●● | ●●● | ●●● | ●●● | med |
| 18 | Creature | ●●●● | ●●●● | ●●● | ● | ●● | ●●●● | high |
| 19 | Ghost | ●●● | ●●● | ●●● | ●● | ● | ●●● | high |
| 20 | Runway | ●●● | ●●● | ○ | ●●●● | ● | ●● | med |
| 21 | Voiceprint | ●●● | ●●● | ●●● | ● | ●●●● | ●●● | med |
| 22 | Tick | ●●● | ●●● | ● | ●●●● | ● | n/a | med |

## Shortlist

```
   Wren        grounded, warm, answers "for me?" best, mute = empty wire
   Beam        the only one that renders the brand IN the user's app, at the pixel
   Voiceprint  the only one where privacy and identity are the same image
   Creature    highest ceiling, highest chance of being embarrassing
```

## Pairings

Layers combine: a **container** (Halo), an **actor** (Wren / Firefly), a **land** (Underline / Ripple), a **sound** (Tick).

| Pairing | Reads as |
|---|---|
| Halo + Wren + Tick | the rim is the room, the bird is attention, the tick is the land |
| Beam + Tick | precise — "it goes exactly here" |
| Underline + Quote | typographic, calm, safest |
| Voiceprint + Halo | private, personal, hardware-native |
| Creature + Tick | a character with a voice of its own — swing hardest |

## Open

1. Container, actor, or typographic as the primary layer?
2. Is a character (18/19) on or off the table? It changes everything downstream.
3. Does the mark need to be one static shape (App Store, DMG, Dock), or can it be generative (21)?
4. Sound on by default, or opt-in?
