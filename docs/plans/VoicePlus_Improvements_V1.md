# VoicePlus — Improvements V1

Plan for the next major revision: bundled model stack, two-pass recognition, screen-aware
context biasing, always-on ambient capture, and a rebuilt app surface.

Companion docs: `VoicePlus_UIUX.md` / `VoicePlus_UIUX_V1.md` (surface design),
`VoicePlus_SignaturePill_V1.md` (pill), `DESIGN.md` (tokens — authored in parallel, not here).
Source of truth for scope remains `PRODUCT-SPEC.md` and `VoicePlus_Build.md`.

---

## 0. Decisions at a glance

| # | Decision | Replaces |
|---|---|---|
| 1 | Bundle all three models in the .app | Fast/Balanced/Best picker + onboarding download |
| 2 | Two-pass recognition (stream → refine at EOU) | Single-pass streaming only |
| 3 | Pill holds volatile text; field receives committed text | Direct injection of live text |
| 4 | Hold = transient, double-tap = latch | Hold-to-talk only |
| 5 | AX tree + Dictionary + history → bias list | Dictionary alone |
| 6 | Always-on splits into dictation vs ambient capture | Always-on treated as a hazard |
| 7 | One window (sidebar + detail) + one pill | Menu → panel → 9-tab settings |
| 8 | Onboarding: permissions, voice, key, ambient opt-in | Model choice + progress bar |

---

## 1. Model stack — bundled, not chosen

1.1 **Ship one configuration inside the .app**, `Contents/Resources/Models/`:
   - Parakeet TDT 0.6B v3 (CoreML) — streaming pass
   - Parakeet Realtime EOU 120M (CoreML) — turn detection
   - Qwen3 ASR 1.7B, 5-bit (MLX) — refinement pass
   - ~2.5 GB total. Precompile CoreML to `.mlmodelc` so first launch skips compilation.

1.2 **Why bundle.** All three are required for the target UX, so per-model selection was never
   a real choice — it was a way to postpone a download. Bundling also retires an entire bug
   class: 1.7.12–1.7.15 shipped fixes for parked-but-never-deleted model directories, a layout
   migration that blinded the integrity check, and install verification. Read-only files inside
   a signed bundle cannot drift.

1.3 **Why this stack.** Parakeet TDT 0.6B v3 is ~6.34% avg WER on the Open ASR Leaderboard —
   top of the open-source streaming tier; nothing local beats it, and Kyutai STT is lateral on
   WER with far worse language coverage. Qwen3 1.7B (~5.76%) is close to Cohere Transcribe
   (~5.42%) at less than half the size, is the only one of the two with context biasing, and
   has a proven MLX build. Cohere is rejected on 3.8 GB for ~0.3 WER points and no biasing.

1.4 **Consequences to accept now**
   - MLX is Apple Silicon only. Either drop Intel, or state plainly in Settings that the
     refinement pass is unavailable there. Do not fail silently.
   - Every DMG becomes ~2.5 GB. Version-stamp the Models folder so a later updater can skip an
     unchanged payload.
   - MLX Swift is a second inference runtime alongside CoreML, and a new SwiftPM dependency —
     record in `progress.md` per repo convention.
   - Data Panel reads "Zero KB out · Zero KB in" on a fresh install. That is a headline, not a
     footnote.

1.5 **What survives in Settings:** refinement mode (Auto / Always / Never) for battery, and the
   BYO-cloud option — moved out of onboarding.

---

## 2. Two-pass recognition

2.1 **Architecture**

```
mic ─► ring buffer ─► VAD gate ─┬─► Parakeet TDT 0.6B v3  (streaming, ~160 ms)
                                │            │
                                │            └─► volatile tail ─────► PILL
                                │
                                └─► EOU 120M ─► segment closed [t0,t1]
                                                       │
                                             ┌─────────┴──────────┐
                                             │ gate: worth pass 2?│
                                             └────┬──────────┬────┘
                                              yes │          │ no
                                                  ▼          │
                                    Qwen3 ASR 1.7B (MLX)     │
                                    + bias list (§4)         │
                                                  │          │
                                                  └────┬─────┘
                                                       ▼
                                              final TranscriptSpan
```

2.2 **Why two-pass rather than a better streaming model.** Swapping streaming models buys at
   most ~0.6 WER points. The published two-pass result — streaming RNN-T refined by an offline
   second pass — is a **17–22% relative WER reduction**, reaching parity with large offline
   models. It is also the on-device standard (Pixel dictation, multiple Google patents). The
   headroom is in the architecture, not the model list.

2.3 **Why the latency is affordable.** Only the *final* segment's refinement is on the critical
   path. Every earlier segment refines while the user is still speaking. Pipeline depth hides
   the second pass almost entirely — the asymmetry is the reason this works at all.

2.4 **Gate the second pass** (do not run 1.7B on every sentence — battery):
   - streaming confidence below threshold, or
   - a bias-list term scores a phonetic near-miss in the segment, or
   - non-English language selected, or
   - segment exceeds a duration threshold.
   Otherwise commit Parakeet's output immediately. Most clean English should never reach Qwen3.

2.5 **It also makes the old "Best · Most accurate" label true.** Today that tier ships the same
   transcription model as Balanced and buys only turn detection — a claim a user can falsify in
   a minute. Two-pass fixes the copy by fixing the product.

---

## 3. Two surfaces — volatile vs committed

3.1 **The constraint.** Injecting into another app's text field is append-only in practice.
   Retracting means backspaces or AX writes, which break in Electron, web fields, terminals and
   Google Docs, fight autocorrect and IME, and race the user's own cursor. Muesli's "it only
   appends words" is not a shortcut they took; it is the shape of the problem.

3.2 **The split**
   - **Volatile tail → the pill.** Word-by-word, ~160 ms behind the mouth, revised freely.
     You own those pixels.
   - **Committed text → the target field.** At EOU boundaries, append-only, never retracted.
     Qwen3 decides what lands.

```
time ─────────────────────────────────────────────────────────►
speech   "send this to Aditya"          "tomorrow at four"
pill     s..se..send..send this to Ad…   tom..tomorrow at four   (live, revisable)
field    ────────────────┤"Send this to Aditya." ├──────────────┤"Tomorrow at four."
                          EOU + pass 2                            EOU + pass 2
                          (committed — never retracted)
```

3.3 **Why commit at EOU rather than LocalAgreement-N.** LocalAgreement gets words into the field
   a few hundred ms sooner, but commits pass-1 text — which forecloses refinement entirely, since
   you cannot improve what is already injected. Committing at EOU is the only variant where the
   17–22% actually reaches the user. Perceived latency stays ~160 ms because the pill is live;
   only the field waits, and sentence-granular arrival reads as deliberate rather than laggy.

3.4 **Bonus:** voice commands ("scratch that", "new line") become necessary in latched mode and
   trivial to implement, because a committed sentence is one span with a record.

---

## 4. Context capture — the real accuracy lever

Qwen3 is the vehicle. The bias list is the payload. Shipping the second pass *without* this is
building the expensive half and skipping the valuable half.

4.1 **Sources, ranked**

| Rank | Source | What it yields |
|---|---|---|
| 1 | AX tree of focused window | on-screen names, recipients, identifiers, thread text |
| 2 | Dictionary | user-curated terms (exists) |
| 3 | Dictation history (GRDB) | every name they have ever said (exists) |
| 4 | App identity | formatting rules, not vocabulary |
| 5 | Field text before cursor | continuation: leading space, capitalization, mid-sentence |

```
AX tree of focused window ─┐
Dictionary                 ├─► dedupe + rank ─► bias list ─┬─► Qwen3 context prompt
Dictation history          │                               ├─► gate check (§2.4)
App identity ──────────────┘                               └─► formatting rules
```

4.2 **Why the screen.** If a word is visible on screen, the odds the user says it in the next ten
   seconds are enormous. This attacks the dominant error class — proper nouns and jargon —
   directly, and it is the one thing Parakeet structurally cannot do at any size.

4.3 **App-aware formatting** (from identity, not vocabulary): Terminal → no auto-capitalization,
   no trailing period. Editor → identifiers preserved. Slack → casual. Mail → paragraphs.
   **Secure text field → refuse to inject at all**; AX exposes the role.

4.4 **Mechanics.** Snapshot the AX tree on keydown / latch and on focus change; cache it; cap
   depth and node count. Never walk per-segment. Electron and Chrome expose partial trees; some
   apps expose nothing — degrade to app identity + Dictionary.

4.5 **Privacy rule.** Screen text is read into memory for the current utterance, biases the
   decode, and is discarded. Never logged, never in the Timeline, never in Sync. State this in
   the Privacy section — it is the kind of feature that reads as surveillance if undocumented.

4.6 **Open question.** Reading AX requires the Accessibility permission. If Injection already
   posts CGEvents into other apps you hold it and this is free. Current Settings copy says the
   key monitor needs "no extra permission" — a different mechanism. Confirm which applies before
   promising anything in onboarding.

---

## 5. Always-on — dictation plus ambient capture

5.1 **The mic does not auto-stop.** What is guarded is *injection*, not listening. The enrolled
   voice embedding ("Teach VoicePlus your voice") is the router, not a gate.

5.2 **Routing**

| Condition | Route |
|---|---|
| Latched · editable field focused · speaker = you | dictation → inject |
| Latched · no field, or focus changed | ambient note; injection pauses, mic continues |
| Not latched · ambient enabled | ambient Timeline |
| Speaker ≠ you | ambient, diarized |

5.3 **Why ambient is worth building.** It is the memory substrate for an assistant. Segments
   carry timestamp, speaker (you / other / unknown), transcript, frontmost app, and optionally
   audio under the existing "save recordings" toggle. Stored in GRDB, searchable, surfaced in
   Timeline — largely reuse of what Meetings already does. FluidAudio already ships diarization,
   so no new dependency.

5.4 **What replaces auto-stop as the safety story**
   - Hardware-truthful pill indicator (macOS shows the orange dot regardless — match it)
   - One-tap pause
   - Explicit never-inject app list
   - User-set retention policy
   - **Ambient is off by default and opted into during onboarding**, not buried in Settings.
     This is the single feature that can cost trust in one screenshot; consent must be unmissable.

5.5 **Power.** VAD in front of everything so Parakeet only runs on speech. Second pass only on
   dictation segments that trip the gate. Surface thermal state in the pill when throttled.

5.6 **Not now:** wake word. The enrollment phrase is already "Hey VoicePlus" — a natural later
   addition, out of scope for V1.

---

## 6. App surface

6.1 **Remove:** nine truncated Settings tabs, standalone Data Panel, standalone Lab window,
   standalone enrollment window, menu-bar-icon-opens-a-menu.

6.2 **The pill is the product.** States: idle dot → listening waveform → volatile text tail →
   commit pulse when a sentence lands → distinct tint while ambient is on. This is where the
   motion budget goes. Detail in `VoicePlus_SignaturePill_V1.md`.

6.3 **One window, sidebar + detail:**
   Home/Timeline · Dictations · Ambient · Dictionary · Voice (enrollment, mic, benchmark) ·
   Apps (per-app rules, never-inject list) · Privacy (Data Panel lives here — egress *is* a
   privacy feature, so name it that) · Settings · About.
   Menu-bar icon opens the window; right-click gives pause / latch / quit.

6.4 **Lab → Benchmark.** Its biasing-on/off configs are exactly the pass-1 vs pass-2 A/B needed
   in §9. Keep the harness, rename it, file it under Voice or behind a debug flag. It is a
   developer tool currently wearing a user-facing window.

---

## 7. Onboarding

7.1 Under two minutes; every step does something.

```
1. Welcome            the one hero moment
2. Permissions        Microphone, Accessibility — one line of why each. Nothing else.
3. Your voice         3–5 phrases; doubles as the mic check
4. Your key           pick it, then try it in a practice field:
                      hold → speak → watch it land; double-tap → see it latch
5. Ambient capture    explicit opt-in + privacy explanation; default OFF
6. Done               window opens on Home
```

7.2 **Removed:** model choice, download progress bar, "Connect what you pay for" gate.

7.3 **Why step 4 matters.** The hold/latch distinction is the core interaction and it is not
   self-evident from a settings row. Teaching it once, in a safe field, is worth more than any
   copy.

---

## 8. Input model

8.1 One key, disambiguated by **duration**, not by waiting:
   - **Hold** → transient push-to-talk. Key release *is* the endpoint; skip EOU entirely.
   - **Double-tap** → latch.
   - **Single tap while latched** → stop.

8.2 **Why duration.** Detecting a double-tap needs a ~250–300 ms window. If hold and tap shared
   that window, every push-to-talk would pay it. Duration separates them for free. Given the
   1.7.12 key-binding history ("your dictation key is no longer the act key"), do not regress
   here.

---

## 9. Measurement — prove it before shipping it

9.1 Build the replay harness in `Lab/` over `Fixtures/`: run fixture audio through pass 1 and
   pass 2, report WER delta segmented by **clean / accented / bias-heavy** audio. Reuse the
   existing biasing-on / biasing-off configuration shape.

9.2 **Why this gates the plan.** Every WER figure quoted here is measured on read speech,
   pre-segmented, close-mic — not on someone dictating into a laptop in a room. If the second
   pass does not earn its keep on your own fixtures, **the honest outcome is to ship §3's
   two-surface UX with Parakeet alone**: the streaming/commit split is most of the felt
   improvement and costs no extra model. Let the harness decide, and use the same numbers to
   tune §2.4's thresholds.

---

## 10. Design language

10.1 `DESIGN.md` is authored in parallel and is the source of truth for tokens, type, color,
   spacing, motion and copy voice. It matters more than usual here because several agents build
   this app simultaneously — without a shared spec, the result is nine more tabs.

10.2 **Direction:** native macOS, dark-first, one accent, SF Pro + SF Mono, sidebar + detail,
   generous spacing. Level-set against Wispr Flow, Superwhisper, Raycast, Linear. Keep the
   existing copy voice — "Hold to talk, release to land" is better than most of the UI around it.

10.3 **Reference verdicts**

| Reference | Verdict | Reasoning |
|---|---|---|
| [awesome-design-md](https://github.com/voltagent/awesome-design-md), [getdesign.md](https://getdesign.md/), [refero examples](https://styles.refero.design/ai-agents/design-md-examples) | **Adopt** | Structure for `DESIGN.md`; highest leverage item given parallel agents |
| [motion.dev](https://motion.dev/) | **Principles only** | Springs, staggered reveals, interruptible transitions map to SwiftUI `.spring()`, `PhaseAnimator`, `KeyframeAnimator`, `matchedGeometryEffect` — all macOS 14+ |
| [Vanta halo](https://www.vantajs.com/?effect=halo), [aidesigner backgrounds](https://www.aidesigner.ai/backgrounds) | **Mood reference, one screen** | WebGL/CSS — violates the no-web-views rule. Reproduce subtly as a Metal `.layerEffect` on the onboarding welcome step only; animated backgrounds behind settings read as a 2023 landing page |
| [Jitter](https://jitter.video/templates/all/), [ui-animation skill](https://explainx.ai/skills/mblode/agent-skills/ui-animation) | **Skip** | Web-oriented; low return for a native app |

---

## 11. Module mapping

| Module | Change |
|---|---|
| `Shared` | `TranscriptSpan` gains `stability` (`volatile` / `committed` / `final`). Minimal, additive; `confidence`, `audioRange`, `provenance` preserved — provenance identifies which pass produced the span |
| `Engine` | Three sessions (Parakeet streaming, EOU, Qwen3). Continuous ring buffer, VAD gate |
| `Pipeline` | Refine stage: replaces a span's text in place, preserving `audioRange`. Fits the existing `[TranscriptSpan] -> [TranscriptSpan]` contract |
| `Injection` | Commit queue, append-only writer, focus guard, never-inject list, secure-field refusal |
| `Providers` | AX tree reader → bias list; app identity → formatting rules |
| `App` | Pill (volatile tail, latch state); single window; onboarding |
| `Actions` | "scratch that", "new line", "period" |
| `Lab` | Replay harness + WER reporting |
| `Packaging` | `make_app.sh` copies bundled models; version-stamped Models folder |

Per repo convention: `Shared/` and `Package.swift` edits stay minimal and additive, and get
called out in the final report.

---

## 12. Build order

```
 0. DESIGN.md                                    (parallel — blocks UI work)
 1. Bundle models · delete download step · new onboarding
 2. Two surfaces + append-only commit at EOU     (Parakeet only — ships value, no new model)
 3. Latch mode · injection guards · speaker router
 4. Window restructure                           (fold in Data Panel, Lab, enrollment)
 5. AX context → bias list · app-aware formatting · field continuation
 6. Qwen3 second pass, gated                     (Benchmark measures delta before default-on)
 7. Ambient capture → Timeline
```

Rationale for the ordering: step 2 delivers most of the perceived improvement with zero new
inference. Step 5 lands before step 6 because the bias list is what makes step 6 worth its
compute. Step 6 is gated on step 9's measurement, not on the calendar.

---

## 13. Do not build

1. **Migration to Kyutai STT** — lateral on WER, much narrower language coverage.
2. **Cohere Transcribe** — 3.8 GB for ~0.3 WER points over Qwen3, no streaming, no biasing.
3. **Destructive re-editing of committed text** — backspaces or AX writes break in Electron, web
   fields and terminals, and race the user's cursor.
4. **Cloud streaming in the free tier** — genuinely the accuracy leader, but it belongs in
   "Connect what you pay for", not in a local-first default.
5. **Wake word** — out of scope for V1 (§5.6).

---

## 14. Open questions

1. Does Injection already hold Accessibility permission? (§4.6) — blocks the onboarding copy.
2. Intel support: drop, or ship with the refinement pass explicitly unavailable? (§1.4)
3. Update strategy for a ~2.5 GB DMG — does the current updater re-download the model payload?
4. Ambient retention default: how long, and does Sync ever carry ambient segments?
