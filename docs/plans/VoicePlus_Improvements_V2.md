# VoicePlus — Improvements V2

Product and execution brief · 10 September 2026

**Outcome:** speak naturally, deliver the right text to the intended place, and recover or repair without losing work. Build the complete core experience while validating it continuously.

VoicePlus is a working name. Branding and the signature pill must work independently of “voice” or “plus.”

## 1. Authority and execution rules

- Read `PRODUCT-SPEC.md`, `VoicePlus_Build.md`, and `progress.md` before implementation. Inspect current code: a checked task or synthetic test is not evidence of working hardware behavior.
- This document replaces `VoicePlus_Improvements_V1.md` for this revision and overrides conflicting defaults in earlier proposals. `VoicePlus_UIUX_V1.md` and `VoicePlus_SignaturePill_V1.md` are design references, not settled behavior.
- Reuse and strengthen existing modules. Do not rebuild working infrastructure or add unrelated roadmap features.
- Implement the strongest candidate architecture directly. Instrument and compare it during development; do not make a large preliminary research project a prerequisite.
- Distinguish implemented, fixture-verified, and real-app/hardware-verified results. Never substitute mock speech, invented confidence, or simulated success in production.
- Preserve user preferences and data. Keep `Shared/` and `Package.swift` changes minimal; record dependency changes, measured decisions, and remaining gaps in the build/progress documents.

## 2. Prioritized scope

| Priority | Improvement | Impact / reason |
|---|---|---|
| P0 | Audio capture, microphone selection, echo/noise handling | Preserve real speech and prevent lost words or broken sessions. |
| P0 | Delivery, focus guards, recovery, explicit repair | Prevent misplaced or lost text; make errors recoverable. |
| P0, continuous | Real-audio benchmarks and actual-app tests | Select improvements using user outcomes; catch failures mocks miss. |
| P0, parallel track | `DESIGN.md` and signature-pill direction | Set consistent visual and interaction rules before production UI work. |
| P1 | Live preview and stable, ordered endpoint commits | Immediate feedback without automatic rewrites after insertion. |
| P1 | AX context, vocabulary ranking, formatting, continuation | Improve entities and fit text into the destination correctly. |
| P1 | Gated Qwen refinement | Improve difficult speech within latency and power budgets. |
| P1 | Bundled validated models and simpler onboarding | A working default without model selection or first-run downloads. |
| P1 | Dependable latch mode and speaker safeguards | Sustained dictation with explicit control over typing. |
| P1 | Unified window, consistent menu, clear pill | Make capabilities and recovery easy to find. |
| P1 | Inspectable, reversible learned corrections | Personalize without poisoning later dictations. |
| P2 | Opt-in ambient capture and searchable Timeline | Add useful memory with explicit capture and retention controls. |

Priority governs integration and release readiness, not a requirement to finish every earlier row before starting later work.

## 3. Core architecture and interaction contract

```text
Microphone -> owned capture + ring buffer -> acoustic processing -> VAD
                                                                  |
                         +----------------------------------------+
                         v
                 streaming recognition ------------> PILL: live preview
                         |
              release / endpoint closes segment
                         |
              optional Qwen refinement <------------ ranked context
                         |
              destination-aware formatting
                         |
              ordered queue + destination check
                         |
                 +-------+--------+
                 v                v
             insert once       hold for recovery
                 |
             verify result
                 |
          delivered / uncertain / failed
```

- **Hold text key:** capture immediately; release closes the final segment. Long holds may close earlier segments at natural boundaries without ending capture.
- **Double-tap text key:** latch; speech endpoints close segments while listening continues. Single tap stops and finalizes pending speech. Escape cancels pending work; already inserted text remains.
- **Hard mute:** immediately stop all app capture, cancel pending insertion, and discard uncommitted audio. Persist mute across relaunch; never automatically unmute. Already finalized recovery text follows its retention policy.
- The pill owns provisional text. Destination text is committed once, in spoken order. Automatic refinement never revises inserted text; explicit verified repair may do so.
- Use session and segment identities to reject stale results, preserve ordering, and prevent duplicate delivery. Bound buffers and refinement backlog; slower recognition must not accumulate unlimited pending work.
- A single session coordinator owns start, stop, cancel, and microphone arbitration across hotkey, menu, onboarding, and meetings. Reuse the existing lifecycle/ownership fixes.

## 4. Audio and recognition

### Capture

- Capture before model warm-up; buffer opening speech. Preload without opening the microphone. Failed starts and cancellation must release ownership completely.
- Respect explicit microphone choice. Automatic selection avoids narrowband Bluetooth when a better input exists and explains substitutions. Handle unplugging, reconnecting, and sleep/wake.
- Integrate echo cancellation and noise handling with a bypass for evaluation. Choose defaults by recognition quality; aggressive filtering is not inherently better.
- Preserve leading/trailing speech around VAD boundaries. Keep recording, signal quality, model readiness, and permission status distinct.

### Recognition candidate

- Start with Parakeet TDT 0.6B v3 for preview, Parakeet Realtime EOU 120M for endpointing, and Qwen3-ASR 1.7B through an MLX integration for refinement. Verify actual streaming support and chunk latency in the chosen runtime.
- Compare Parakeet alone, Qwen alone, and two-pass operation on identical real recordings. Include Qwen 0.6B if memory or latency warrants it. Retain the configuration that earns its complexity.
- Refine selectively using measured uncertainty, entity near-misses, language coverage, and segment characteristics. Do not assume the recognizer reliably knows when it is wrong.
- Bound refinement by a deadline. On timeout or failure, use the viable first-pass result; otherwise retain the utterance for recovery. A late second-pass result cannot overwrite delivered text.
- Preserve provenance and segment audio ranges. Re-align changed words where word timing is needed; do not attach old word confidence/timestamps to different words. Mark unavailable confidence explicitly and suppress misleading uncertainty UI.

### Model packaging

- Bundle the validated default stack inside the app; no Fast/Balanced/Best choice or download step during onboarding. Qwen ships in that stack only if it passes the quality/resource gate.
- Version and verify model assets, keep runtime caches outside the app, and ensure loaders do not silently download duplicate assets. Compiled Core ML assets may still require device specialization; measure cold start.
- Measure actual app/download size and upgrade behavior. A versioned model folder alone does not make updates incremental. Provide a reachable update source and test a real upgrade.
- Preserve existing model stores until the bundled replacement loads successfully; clean only app-owned obsolete assets after validation.
- Target Apple Silicon on macOS 14+. Preserve an existing working Intel path if feasible; do not advertise Intel support without a verified fallback. Document support before packaging.

## 5. Delivery, recovery, and repair

```text
Capture -> Recognize -> Finalize -> Check destination -> Insert -> Verify
                                      |                           |
                                      +----> Held                 +--> Delivered
                                                                  +--> Uncertain
                                                                  +--> Failed
```

- Snapshot app, window, focused element, selection/caret, and relevant surrounding text at activation; revalidate before each insertion. Same app does not mean same destination.
- Focus or target changes hold pending text. Returning focus alone does not insert it: offer **Insert here**, **Copy**, or **Discard** with the destination named.
- Reject secure fields and never-inject apps. If target safety cannot be established, hold text for copying. Keep the existing layered injection strategy and guarded clipboard restoration.
- Distinguish verified delivery, dispatched-but-unverified delivery, and failure. Do not automatically retry uncertain delivery: it may duplicate text. “Landed” requires verified success; expose recovery for uncertain results.
- Keep finalized undelivered text available in memory until handled or the app exits. Warn before quitting with pending text. Persist only when dictation history is enabled; never silently turn failed dictation into ambient capture.
- Errors stay readable and name an action: “Destination changed — Copy text,” “Microphone disconnected — Choose microphone,” or “No speech detected — Try again.” No raw internal errors.
- Support **scratch that**, **no, <replacement>**, and **put it back**. Restrict repair interpretation to an explicit/recent repair context; quoted commands must remain dictation.
- Repair requires a uniquely identified region still matching the last inserted/repaired text. Otherwise offer a suggestion. Never issue blind backspaces or generic Command-Z against an unknown document state.
- Automatic silent correction remains off. Voice repair does not depend on a live beam decoder: accept explicit replacement words and use meaningful vocabulary alternatives where available.

## 6. Context, formatting, and learning

```text
Explicit corrections + Dictionary  -- highest authority --+
Relevant focused-window AX text -------------------------+--> rank / dedupe / cap
Recent confirmed vocabulary ------- lowest authority ----+          |
                                                                   v
                                                        recognition context
App + field role + text around cursor -----------------> formatting / continuation
```

- Default vocabulary cap: 400 entries, tunable through measured entity recall and false insertions. Raw historical guesses never become authoritative corrections.
- Read bounded AX context at activation and relevant focus changes; cache per target/session. No screenshots. Treat screen text as data, never executable instructions.
- Discard screen context after the session; exclude it from history, diagnostics, and sync. Never send it to a provider without explicit cloud-context consent. Degrade gracefully when AX is partial or absent.
- Format by field role as well as app: a terminal inside an editor needs terminal behavior. Preserve code identifiers; handle spaces, capitalization, paragraphs, and insertion mid-sentence. Do not automatically submit terminal commands.
- Dictionary exposes learned spelling, “heard as,” origin, and remove/forget controls. Require explicit correction or repeated verified evidence before broad substitutions; reject document-sized or ambiguous edit pairs.
- “I'll remember…” means an entry was saved, not a guarantee it can never be misrecognized again. Removing it must stop its influence immediately.

## 7. Latch and ambient capture

| Mode / event | Behavior |
|---|---|
| Hold | Capture only while deliberately activated; release finalizes. |
| Latch | Continue across endpoints; show persistent listening state and visible Stop. |
| Focus changes while latched | Pause delivery, retain pending text, require explicit resumption into a named target. |
| Speaker mismatch / uncertain identity with filtering enabled | Suppress insertion; do not silently save another person's speech. |
| Ambient enabled | Capture transcript into Timeline only; never type or act from ambient speech in this revision. |
| Lock / sleep | Stop capture and cancel pending insertion; do not silently resume on unlock. |
| Hard mute | Stop every capture path; preserve the persistent muted state. |

- Speaker identity is not directed-speech intent. Explain that latch is an explicit dictation session; do not claim it safely distinguishes the user's conversation with a colleague.
- Enrollment is requested when enabling speaker filtering, not required for ordinary hold-to-talk. Treat unavailable/uncertain speaker models honestly; validate with real voices.
- Ambient is **off by default** with separate opt-in. Proposed defaults: transcript only, enrolled user only, seven-day retention, no sync. Unknown/other speakers are discarded unless the user explicitly enables broader capture or starts a meeting.
- Timeline supports search, source filters, delete, and delete-all; expiry/deletion also clears search indexes. Audio retention is a separate explicit choice. Capture indicators reflect actual microphone ownership.
- Wake words, wake verbs that trigger actions, and autonomous ambient actions are outside this revision. Existing experimental routes stay off by default.

## 8. Product surfaces and design

Create `DESIGN.md` before production UI work: typography, color, spacing, contrast, state vocabulary, focus behavior, reduced motion, display placement, and error sizing. Prototype **Wren** and **Fold** against the same states; these are candidates, not approved names. Keep one stable mark and one signature delivery transition. Do not block core engineering on branding.

```text
PILL              MENU                       ONE WINDOW
current state     status + microphone        Today / Timeline
live words        dictate / latch / mute     Meetings
one next action   copy / recover text         Dictionary / Apps
                  start meeting              Voice / Privacy
                  open app / settings / quit Settings
```

- Left or right click on the menu-bar glyph or idle notch presence opens the same menu. Provide explicit Stop/Mute controls during capture; preserve destination focus.
- Pill states: ready, listening, finalizing, delivered, latched, held, error, ambient, muted. Show mode and text first; warnings replace secondary detail. Put model names, exact latency, and thermal diagnostics in Voice/Benchmark.
- Keep notices bounded and readable; no constant idle animation. Support notchless/external displays, full-screen apps, light/dark backgrounds, increased contrast, and reduced motion. A muted mark remains visible.
- Fold Data Panel into Privacy, Lab into Voice > Benchmark, and enrollment into Voice. Today prioritizes readiness, pending recovery, and recent useful content; advanced/experimental features do not dominate navigation.
- Onboarding: **Welcome -> Microphone + real mic check -> Accessibility -> choose/try key + real landing -> Done.** No model picker, provider setup, mandatory enrollment, or ambient opt-in gate. Teach repair/latch after the first success; offer optional capabilities contextually.
- Privacy states separately what is captured, saved, and transmitted. Default speech processing is local. Optional provider traffic and update checks are logged honestly; do not promise literal zero network bytes merely because ASR is local.
- Retain per-stage provider options in Settings. Do not label a local writing/planning model available until one exists and works; Actions remain off until deliberately configured.

## 9. Verification and release acceptance

Build a small initial corpus from real successful and failed dictations; expand during implementation. Reuse the opt-in raw/processed recorder and landing-diff diagnostics. No production transcript/audio logging without consent.

| Check | Required evidence |
|---|---|
| Accuracy | Same recordings through baseline/candidates; WER, utterances needing edits, entity and number accuracy, false substitutions, first/last-word loss. Include normal room speech, names, pauses, noise, and actual microphones. |
| Refinement default | Useful improvement on difficult speech, no material clean-speech regression, and acceptable latency/resources. Record sample counts and regressions; do not import leaderboard gains as product claims. |
| Delivery | Notes, Mail, browser editor, Slack, VS Code, Terminal, and a spreadsheet: empty/existing text, selection, mid-text insertion, repair, focus changes, clipboard preservation. Use disposable documents/drafts. |
| Session durability | 50 consecutive dictations plus cancellation, quick release, cold start, device changes, sleep/wake, and repeated onboarding/hotkey use; no wedges, duplicate insertions, or lost finalized text. |
| Performance | Initial targets: live preview p50 <=300 ms after speech onset; final pending text p50 <=700 ms / p95 <=1200 ms after release or detected endpoint on a supported baseline Mac. Also measure speech-end-to-endpoint delay, cold start, backlog, peak memory, and sustained battery/thermal behavior. |
| UI | Visually exercise every state in the installed app on available display configurations; confirm focus behavior, readable errors, real onboarding delivery, and mute. |
| Packaging | Fresh bundled install works offline after permissions; existing settings/history survive upgrade; no duplicate model download; update payload and source verified. |

Define zero-edit rate as the fraction of **observable dictations** needing no correction within a stated observation window; report coverage separately. Unobservable fields are not successes. WER needs reference transcripts and must not be inferred from absence of edits.

If hardware access or a human voice is required, request a bounded recording/test session and continue independent implementation. Record unverified checks as unverified. A packaged app with unresolved release gates is a candidate build, not a completed reliability release.

## 10. Execution map

```text
Capture + session ownership ----> preview / endpoints ------------------+
Delivery + recovery ------------> explicit repair ----------------------+--> integrated candidate
Context + learning -------------> Qwen comparison / refinement ---------+          |
DESIGN.md ----------------------> pill / window / onboarding ------------+          v
Real audio + real-app checks ============================================> measured defaults
                                                                                 |
                                                       bundled stack + upgrade -> release
Ambient / Timeline follows the validated capture, mute, and storage contracts.
```

| Module | Primary work |
|---|---|
| `Engine` | Capture, VAD, recognition runtimes, endpointing, bounded buffers, speaker filtering. |
| `Shared` | Minimal session/segment identity, delivery outcomes, and uncertainty/provenance contracts. |
| `Pipeline` | Refinement, context-aware formatting, continuation, verified learning/repair routing. |
| `Injection` | Target validation, ordered delivery, readback, recovery, guarded replacement. |
| `Providers` / existing AX sources | Bounded context acquisition and explicit provider routing. |
| `App` | Unified state presentation, key/latch behavior, window/menu/onboarding, Timeline. |
| `Lab` / `Fixtures` | Real-audio replay, candidate comparison, observable zero-edit metrics. |
| `Packaging` | Validated bundled assets, migration, install/upgrade and distribution checks. |

Deliver a usable installed candidate throughout integration. Final handoff includes measured defaults, compatibility results, a packaged build through the existing release process, and an honest list of remaining limitations. Do not expand into a new action engine, mobile work, a general assistant, or a new sync system for this revision.
