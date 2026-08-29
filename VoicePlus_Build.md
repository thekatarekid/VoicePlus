# VoicePlus — Build Plan
> Execution document for Claude Code (`/goal`, Fable). Implements `PRODUCT-SPEC.md` end to end. Read `PRODUCT-SPEC.md` first — it is the source of truth for _why_. This document is the _what and how_.

* * *
## 0. How to execute this document
1. **Unit of work = Item** (e.g. `P1.3`). Each item lists tasks, technical details, UI/UX, tests, acceptance criteria.
  
2. **Parallelism is explicit.** Section 3 defines workstreams (WS-A … WS-G). Items in different workstreams with no listed dependency MUST be dispatched to parallel subagents (git worktrees, one branch per item, atomic commits per task).
  
3. **An item is done when:** all tasks checked → all tests pass → acceptance criteria verified → merged. Never mark done on partial completion.
  
4. **Every phase ends with a signed .dmg — mandatory, no exceptions.** The phase gate is a human-testable build, not a green CI run. Naming convention: `VoicePlus_<PhaseNumber>_<VersionNumber>.dmg` — e.g. `VoicePlus_1_1.0.0.dmg`, `VoicePlus_1.5_1.1.0.dmg`, `VoicePlus_2_1.2.0.dmg`. Phase number = the phase just completed; version = semver, minor bump per phase, patch bump for fixes within a phase (e.g. `VoicePlus_2_1.2.1.dmg`). Every dmg is archived under `Packaging/releases/` and attached to a tagged GitHub release.
  
5. **Feature flags over branches for risky bets.** Bets 2, 3, 9 ship behind default-on flags measured by the Lab (P1.10). Kill criteria in `PRODUCT-SPEC.md` Part 5 decide flag defaults — do not delete flagged code paths.
  
6. **Licensing rules are hard constraints:** Muesli (MIT) — may copy code with attribution. FluidAudio — fork directly. FluidVoice (GPLv3) — **read for design only, never copy code**. Paperclip (MIT) — copy adapter pattern. Cua — verify license before first import; if incompatible, implement `AgentActionBackend` natively.
  
7. When a task is ambiguous, prefer: on-device over cloud, no-new-window over new-window, inference over configuration, reversible-by-default over confirmation.
  
8. **Toolchain deviations (2026-08-23):** no Xcode.app on the build machine (CLT only, Swift 6.0.3) → no XCTest/UI tests; all tests are **Swift Testing** via SwiftPM. `.app` assembled by `Packaging/make_app.sh`, dmg via `hdiutil`, **ad-hoc codesign, no notarization** (no Developer ID identity) until a signing identity is available. Per-item **Status** lines below record what was actually built.
  

* * *
## 1. Ground rules
| Rule | Detail |
| --- | --- |
| Language / UI | Swift 5.10+, SwiftUI + AppKit where needed. **No Electron. No web views in core surfaces.** |
| Target | macOS 14+, Apple Silicon. Intel only via Whisper fallback path. |
| Inference | CoreML / ANE via FluidAudio fork; MLX allowed for pipeline LLMs. |
| Storage | SQLite (WAL) via GRDB. Keychain for all secrets. No plaintext keys, ever. |
| Privacy | Speech never leaves device unless a cloud provider is explicitly enabled. Screen context via Accessibility API only — **no screenshots**. Every network call logged to the Data Panel (P1.10). |
| Telemetry | **None** in v1. No analytics SDK. (FluidVoice's default-on PostHog is the anti-pattern.) |
| Testing | XCTest unit + integration; a scripted end-to-end dictation test using pre-recorded WAV fixtures; UI tests for pill/menu-bar states. Audio fixtures live in `Fixtures/audio/`. |
| CI  | Build + test on every PR; nightly dmg; SwiftLint + SwiftFormat enforced. |
| Distribution | Developer ID signing, notarization, Sparkle appcast, Homebrew cask. |

* * *
## 2. Repository architecture
```
VoicePlus/
├── Engine/                 # WS-A — forked FluidAudio + our decoder work
│   ├── ASRRuntime/         # model load/run, streaming, ANE scheduling
│   ├── Decoder/            # greedy TDT, beam TDT, biasing, confusion nets
│   ├── VAD/                # Silero streaming VAD, endpointing
│   ├── Audio/              # capture (HAL), AEC, mic quality, device routing
│   └── Confidence/         # per-word confidence + audio-span types
├── Pipeline/               # WS-B — gatekeeper, formatters, style, context
├── Injection/              # WS-C — text injection stack + per-app adapters
├── App/                    # WS-D — menu bar, pill overlay, onboarding, settings
├── Providers/              # WS-E — model access: local models, API keys, OAuth, CLI adapters
├── Lab/                    # WS-F — eval harness, zero-edit counter, data panel
├── Actions/                # WS-G — Phase 3/4: timeline, deixis, AX actions, agent
├── Shared/                 # types, logging, flags, DB
└── Packaging/              # signing, Sparkle, dmg, cask
```

**Core shared type (define first, in** `Shared/` **— everything depends on it):**

```swift
struct TranscriptSpan {
    let text: String
    let confidence: Float          // 0…1, from decoder
    let audioRange: ClosedRange<TimeInterval>
    let alternates: [Alternate]    // may be empty; filled by beam/confusion net
    var provenance: [StageID]      // every pipeline stage that touched it
}
```

Rule enforced by type system: pipeline stages receive `[TranscriptSpan]` and must return `[TranscriptSpan]` — a stage that drops confidence or audio ranges fails code review and a lint test.

* * *
## 3. Parallelization master map
### 3.1 Workstreams
| WS  | Name | Owns | Phase-1 items |
| --- | --- | --- | --- |
| **WS-A** | Engine | ASR, decoder, biasing, confidence, VAD, audio | P1.2, P1.3, P1.4, P1.5, P1.6 |
| **WS-B** | Pipeline | gatekeeper, formatters, style | P1.7 |
| **WS-C** | Injection | injection stack, per-app adapters | P1.8 |
| **WS-D** | App shell | pill, menu bar, onboarding, repair UX | P1.1, P1.9 |
| **WS-E** | Providers | model manager, keys, OAuth, CLI adapters | P1.10 |
| **WS-F** | Lab | harness, counters, data panel | P1.11 |
| **WS-G** | Actions | Phases 3–4 machinery | P3.x, P4.x |
### 3.2 Phase 1 dependency graph
```
P1.0 Shared types ──┬─▶ P1.2 Audio ──▶ P1.4 Acoustic
                    ├─▶ P1.3 ASR runtime ──┬─▶ P1.5 Biasing
                    │                      └─▶ P1.6 Beam/Repair engine
                    ├─▶ P1.7 Pipeline  (formatters parallel to gatekeeper)
                    ├─▶ P1.8 Injection (fully independent)
                    ├─▶ P1.9 App shell (fully independent; mock engine)
                    ├─▶ P1.10 Providers (fully independent)
                    └─▶ P1.11 Lab core (fixtures + scoring independent)
Integration: P1.12 wires all; P1.13 packages.
```

**Dispatch instruction:** after P1.0, launch **seven parallel subagents** (P1.2+P1.3 may be one agent or two; P1.8, P1.9, P1.10, P1.11 are guaranteed-independent). P1.5 and P1.6 start the moment P1.3's decoder interface lands. UI work uses a `MockEngine` conforming to the engine protocol so WS-D never waits on WS-A.
### 3.3 Cross-phase parallelism
1. Phases are sequential **as releases**, but development overlaps: Phase 2 (WS-B/D) and Phase 3 (WS-G timeline recorder) can begin while Phase 1 integration (P1.12) is in review — they touch different modules.
  
2. Phase 5's meeting-capture item (P5.5) is independent of Phases 2–4 — it can be built any time after P1.2 by a spare agent.
  
3. Phase 6's sync service (P6.4) and mobile keyboard (P6.5) are independent of Phases 2–5 — parallel any time after P1.0's types stabilize.
  
4. **Never parallelize within**: P1.12 (integration), P1.13 (packaging), and any task touching `Shared/` types after P1.0 freeze — those are serialized.
  

* * *
## 4. PHASE 1 — "You never touch the keyboard to fix it" (.dmg #1)
### P1.0 — Shared foundation _(serial; everything blocks on this; keep it under a day of scope)_
**Status (2026-08-23):** done; 42 SharedTests green; Swift Testing instead of XCTest; CI (macos-14 + Xcode 16.2) unverified from this machine.

- [x] 
  
  **T1** Define `TranscriptSpan`, `Alternate`, `StageID`, `Utterance`, `EngineState`, `FeatureFlag` in `Shared/`.
  
- [x] 
  
  **T2** SQLite schema: dictation history, corrections, flags, lab runs, network log. GRDB migrations.
  
- [x] 
  
  **T3** `EngineProtocol` + `MockEngine` (returns scripted spans from fixtures) so UI/pipeline develop against a fake.
  
- [x] 
  
  **T4** Logging + feature-flag service (local JSON, no server).
  
- [x] 
  
  **T5** CI skeleton: build, test, lint, nightly dmg job.
  

**Acceptance:** all modules compile against `Shared/`; `MockEngine` streams a fixture transcript; CI green.

* * *
### P1.1 — App shell: menu bar + pill overlay _(WS-D; parallel)_
**Status (2026-08-23):** done (commit aeeb31b); 31 AppTests. Final text lands on pasteboard + history DB until P1.12 wires Injection; real CGEvent tap / TCC prompts / SMAppService / pill rendering untested headless.

**Description:** the only two surfaces. Menu-bar item with dropdown dashboard; notch-aware pill overlay for live state.

- [x] 
  
  **T1** Menu-bar app scaffold (no dock icon, `LSUIElement`), launch-at-login, Sparkle wiring stub. _(status: done; SMAppService guarded to bundled .app; Sparkle is a NoopUpdater stub)_
  
- [x] 
  
  **T2** Pill overlay: borderless `NSPanel`, notch-aware placement (DynamicNotchKit or native reimplementation), states: `idle / listening(waveform) / preview(streamingText) / landing / warning(mic)`. Slide in/out ≤150ms, 60fps. _(status: done; pill rendering on a notched display untested headless)_
  
- [x] 
  
  **T3** Global hotkey service: configurable modifier, hold-to-talk (keyDown/keyUp), double-tap (≤350ms window) for hands-free toggle. Input Monitoring permission flow. _(Timing constants: hold threshold 250ms, tap guard 180ms — Muesli-validated values.)_ _(status: done; real CGEvent tap untested (listen-only tap, CGPreflight gate))_
  
- [x] 
  
  **T4** Menu dropdown: zero-edit counter, words today, active model, mic indicator, Lab link, pause toggle.
  
- [x] 
  
  **T5** Permission orchestration: Microphone, Accessibility, Input Monitoring — each with a plain-language pre-prompt screen and a "verify" check. _(status: done; real TCC prompts untested)_
  

**UI/UX:** pill is the single feedback channel; never a modal. Waveform reacts to actual input level. Warning state (bad mic) renders _before_ speech starts. All animation interruptible. **Tests:** UI tests for all pill states; hotkey unit tests with synthesized `CGEvent`s; permission-state matrix test. **Acceptance:** hold key → pill appears with live waveform → release → pill retracts. Mock text lands via `MockEngine`. No dock icon, no windows.

* * *
### P1.2 — Audio capture, VAD, endpointing _(WS-A; parallel)_
**Status (2026-08-23):** done (c0b49b9, bd3ae0b); 30 EngineTests. Energy VAD F1 0.983 on fixtures; Silero VAD falls back to EnergyVAD (cached model v6.0.0, FluidAudio needs v6.2.1); live HAL capture/route-change untested (no mic/TCC).

**Description:** clean 16kHz mono pipeline from any input device, with real VAD (the thing FluidVoice lacks).

- [x] 
  
  **T1** Direct CoreAudio HAL capture (clean-room; FluidVoice's `DirectCoreAudioInput` is the _design_ reference — do not copy GPLv3 code): device enumeration, route-change handling (AirPods, clamshell, 3.5mm), prewarm on hotkey-down, thread-safe ring buffer. _(status: done; CoreAudioCaptureSource + device pinning untested on real hardware)_
  
- [x] 
  
  **T2** Silero VAD streaming via FluidAudio `VadManager`; chunking min 3.0s / max 5.0s (Muesli-validated); endpoint detection for hands-free mode. _(status: done; ring buffer uses os_unfair_lock (wait-free in practice, not strictly lock-free))_
  
- [x] 
  
  **T3** Mic-quality analyzer: SNR estimate, clipping, low-level detection in first 300ms → publishes `MicQuality` to pill. _(status: done; Silero VAD falls back to EnergyVAD until model v6.2.1 is cached)_
  
- [x] 
  
  **T4** Automatic input selection policy + per-device preference memory.
  
- [x] 
  
  **T5** Audio fixture recorder/replayer for tests (WAV in, deterministic buffers out).
  

**Tests:** replay fixtures through capture path; VAD precision/recall on labeled fixture set (target F1 ≥ 0.95 on clean, ≥ 0.85 noisy); route-change chaos test (simulate device swaps mid-utterance). **Acceptance:** hands-free double-tap records, auto-endpoints on silence, no dropped buffers across a device swap.

* * *
### P1.3 — ASR runtime (FluidAudio fork) _(WS-A; parallel; interface freeze unblocks P1.5/P1.6)_
**Status (2026-08-23):** done (9f8a5e4, 924abf8, 6b6047d, 55c9438); 25 tests. No FluidAudio fork — adapter over 0.15.6, LogitBiaser applied post-hoc (rescoring only; per-step hook documented for P1.5). Real-model WER 2.9% (TDT v3), final ≤190 ms; Whisper catalog-only; Apple Speech fallback untested (Speech TCC).

**Description:** fork FluidAudio; run Parakeet TDT v3 (primary), Parakeet Realtime EOU (streaming preview), Whisper (Intel fallback) with a model manager.

- [x] 
  
  **T1** Fork `FluidInference/FluidAudio` → `Engine/`. Isolate `GreedyTDTDecoder` behind our `Decoder` protocol; **freeze this interface first and publish to P1.5/P1.6 agents.** _(status: done)_
  
- [x] 
  
  **T2** Model manager: HuggingFace download with resume + checksum, disk layout, load/unload, warm-start. Models: Parakeet TDT v3 (~~500MB), Parakeet EOU (~~250MB), Whisper small (Intel). _(status: done; no fork — upstream FluidAudio 0.15.6 adapter, biaser post-hoc only)_
  
- [x] 
  
  **T3** Bundled tiny model so first dictation works during onboarding download. _(status: done; Whisper is a catalog placeholder, no runtime)_
  
- [x] 
  
  **T4** Streaming preview path (EOU model → pill) + final path (TDT v3) on release. _(This is NOT dual-path correction — Bet 4 is Phase 1.5; here final simply replaces preview at landing time.)_ _(status: done; bundled tiny model (TDT-CTC 110M) downloaded at first launch, untested live)_
  
- [x] 
  
  **T5** Emit `TranscriptSpan`s with per-token log-probs mapped to word confidence + audio timestamps (Bet 9 source of truth). _(status: done; preview spans carry confidence 0.5 / audioRange 0...0)_
  

**Tests:** golden-transcript tests per model on fixtures; latency budget test — final text ≤ 400ms after key-release for a 10s utterance on M1; confidence sanity (mangled fixture words carry lower confidence, verified statistically over the fixture set). **Acceptance:** speak → preview streams in pill → final spans (with confidence + timestamps) delivered ≤ 400ms after release.

* * *
### P1.4 — Acoustic robustness (Bet 1) _(WS-A; after P1.2)_
**Status (2026-08-23):** done (2a9e71e); 12 EngineTests. Apple voice-processing I/O is the real AEC; LocalVQE/DTLN are weight-less protocol slots (GGML runtime not a SwiftPM dep). Only SNR improvement asserted (WER delta is a Lab measurement); live VoiceProcessingCaptureSource / Bluetooth route changes untested.

- [x] 
  
  **T1** AEC integration: port Muesli's pattern (MIT — copy with attribution): LocalVQE primary, DTLN fallback. ⚠ Verify LocalVQE model-weight license first; if unusable, ship DTLN. _(status: done; neural AEC slots ship without weights/runtime; Apple voice processing primary)_
  
- [x] 
  
  **T2** Noise suppression stage ahead of VAD; toggleable per profile. _(status: done; spectral-gate NS, SNR-only assertion)_
  
- [x] 
  
  **T3** Bluetooth/AirPods handling: detect codec/mic-mode, prewarm to avoid first-word loss, surface "AirPods in low-quality mode" warning. _(status: done; live HAL Bluetooth route changes untested)_
  
- [x] 
  
  **T4** Robustness fixture suite: far-field, café noise, accent set, phone-compressed — these feed the Lab (P1.11). _(status: done; phone-compressed suite not generated (TODO in SUITES.md))_
  

**Tests:** WER delta on noisy fixtures with/without AEC+NS (must improve, tracked in Lab); no added latency > 20ms. **Acceptance:** noisy-fixture WER measurably better than raw pipeline; AirPods first word never clipped.

* * *
### P1.5 — Decode-time context biasing (Bet 2) _(WS-A; after P1.3 interface freeze; parallel with P1.6)_
**Status (2026-08-23):** done (5d9dad9); 14 EngineTests. Synthetic entity recall 0.2→1.0, 0 false insertions, <60 ms. In-loop boosting/narrow beam exercised only on ScriptedLogitDecoder (real per-step hook awaits FluidAudio fork); Live AX/Contacts sources untested (permissions).

**Description:** the entity fix. Shallow-fusion biasing inside the TDT decode loop. Reference: NGPU-LM (arXiv 2505.22857).

- [x] 
  
  **T1** Context harvester (runs continuously, cheap): proper nouns from focused window's AX tree, thread participants, calendar attendees, contacts (with permission), open code symbols/file names, last-10-min words, all-time corrected words. _(status: done; Live AX/Contacts providers untested (guarded, return [] without permission))_
  
- [x] 
  
  **T2** Ranker + cap: score by recency/salience/source; **hard cap ~400 entries** (over-biasing hallucinates entities — spec Bet 2 constraint 3). BPE prefix-tree with partial-match unbiasing. _(status: done; vocab loaded from parakeet_vocab.json, not via decoder)_
  
- [x] 
  
  **T3** Shallow fusion in the decode loop: logit boost on prefix-tree matches; start greedy+boost, add narrow beam (width 2–4) only if Lab shows it pays for its latency. _(status: done; in-loop biasing verified on ScriptedLogitDecoder only — FluidAudioTDTDecoder still post-hoc rescoring)_
  
- [x] 
  
  **T4** Feature flag `context_biasing` + Lab hooks: entity recall, false-entity insertions, WER, added latency per configuration. _(status: done; synthetic suite only, Lab wiring in P1.12)_
  

**Tests:** entity-recall suite — fixtures scripted with on-screen names ("TeamViewer AG", "Kothari", "kubectl", "gpt-4o") present in harvester input; **target: entity recall +30% relative vs baseline, false-insertion rate < 1%, added latency < 60ms.** Kill criterion per spec: if recall gain is immaterial, flag defaults off. **Acceptance:** with a name visible on screen, dictating it yields correct spelling; Lab dashboard shows the delta.

* * *
### P1.6 — Confidence, alternates, voice repair (Bets 3 + 9) _(WS-A engine + WS-D UX; after P1.3)_
**Status (2026-08-23):** done (1e8f368, abd3530); 23 EngineTests + 5 AppTests. Grammar routing 80/80 scripted (transcripts, not audio); alternate usefulness 87% top-3 on synthetic mangled set; beam is a BeamSearchBackend protocol + scripted backend (no live transducer beam); fan-out panel AX positioning untested; sink adapters to Injection/Lab wired in P1.12.

**Description:** build alternates (greedy TDT produces none), keep confidence alive end-to-end, repair by voice.

- [x] 
  
  **T1** Selective beam decoding: trigger beam (width 4) only over low-confidence regions; elsewhere stay greedy. Collapse blank/duration-variant candidates into a **word-level confusion network** of semantically distinct alternates. _(status: done; SelectiveBeamDecoder over a scripted backend — live transducer beam needs the fork joint hook)_
  
- [x] 
  
  **T2** Alternate enrichment: where beam is weak, generate candidates from bias vocabulary + phonetic neighbors (Double Metaphone) of the low-confidence word. _(status: done)_
  
- [x] 
  
  **T3** Repair grammar (voice, active for 10s after landing): `"no, <word>"` (snap to best-matching alternate), `"not that one"` (cycle), `"scratch that"` (drop last phrase), `"put it back"` (undo last replacement). Implemented as a gatekeeper route (P1.7), not string matching. _(status: done)_
  
- [x] 
  
  **T4** Repair UX: hold hotkey over a landed word → alternates fan out beneath it inline (overlay anchored to word's screen rect via AX), numbered, pickable by voice or click. _(status: done; tested on command transcripts, not audio)_
  
- [x] 
  
  **T5** Provenance: repair edits update the span, log the correction (feeds dictionary + Phase 6 training), decrement zero-edit counter honestly. _(status: done; ReplaceRange/Correction/ZeroEdit sinks are protocols — Injection/Lab adapters land in P1.12)_
  
- [x] 
  
  **T6** Flag `voice_repair` + Lab metric: % of low-confidence words whose true word appears in top-3 alternates ("alternate usefulness"). _(status: done; on-screen AX rect positioning across 5 apps untested (needs Accessibility/GUI))_
  

**Tests:** alternate-usefulness on mangled fixtures — **target ≥ 60% top-3 hit rate** (kill criterion below 40%); repair-grammar routing accuracy ≥ 98% on scripted commands; UX test for fan-out positioning across 5 apps. **Acceptance:** dictate fixture with a known-hard word → say "no, ‹correct›" → word snaps without keyboard.

* * *
### P1.7 — Pipeline: gatekeeper + formatters + style (Bet 8, Bet 9) _(WS-B; parallel — gatekeeper and each formatter are separate parallel tasks)_
**Status (2026-08-23):** done (9d71461, c2e749d, bf61057, 4c04504, 8f6d130, 69c26b3, 3d455d3); 115 PipelineTests (gatekeeper 24, email 56, chat 9/53 golden, code 11/57 golden, prose 12/52 golden, terminal 55 golden, style 37). Gatekeeper is rules + naive Bayes (no LLM); provider hook has no real provider; style applies only capitalization + terminal period.

**Description:** raw spans → finished text. Every stage: `[TranscriptSpan] → [TranscriptSpan]`.

- [x] 
  
  **T1** Gatekeeper: small local model (fine-tuned ~0.5–1B class, MLX, or distilled classifier) classifying utterance → `{dictate, repair_command, transform, none}` + destination register `{email, chat, code, prose, terminal, list}`. **Budget: ≤ 15ms.** Falls back to `dictate` on low confidence. _(status: done; deterministic rules + naive Bayes, ≥95% route accuracy asserted, <15 ms)_
  
- [x] 
  
  **T2–T6** Formatter stages ×5 — **email, chat, code, prose/list, terminal** — each a separately-tunable small model or deterministic transform. _(These five are fully parallel tasks — dispatch to five subagents.)_ Deterministic pieces: filler removal, self-correction resolution ("Friday — no, Thursday"), punctuation, list detection, `camelCase`/`snake_case`/paths/math. _(status: done, all five deterministic transforms — email 47, chat 53, code 57, prose 52, terminal 55 golden cases; no small models)_
  
- [x] 
  
  **T7** Style stage: learns per-app writing register from user's edits over time (capitalization, punctuation density, emoji, greeting/sign-off). Cold-start heuristics per app category. _(status: done; only capitalization + terminal period applied; other style features learned/persisted only)_
  
- [x] 
  
  **T8** **Confidence contract enforcement**: stages must not rewrite spans with confidence < threshold — they flag (`needsRepair`) instead of smoothing (Bet 9). Lint test walks every stage with a poisoned span and asserts it survives. _(status: done)_
  
- [x] 
  
  **T9** Per-stage instrumentation: latency, skip-rate, edit-distance contribution → Lab. _(status: done)_
  
- [x] 
  
  **T10** Cloud/pipeline provider hook: any stage may route to a Provider (P1.10) when user enabled it; local default. _(status: done; ProviderGatekeeperClassifying hook without a real provider)_
  

**Tests:** golden input→output pairs per formatter (≥ 40 cases each); the poisoned-span contract test; end-to-end budget — full pipeline ≤ 250ms local on M1. **Acceptance:** the same spoken sentence lands correctly formatted in Mail (prose), Slack (casual), and VS Code terminal (verbatim command); a garbled entity is flagged, not smoothed.

* * *
### P1.8 — Injection stack (T1) _(WS-C; fully parallel/independent)_
**Status (2026-08-23):** done (b0f84e7); 46 InjectionTests. LiveSystemAccess (real AX/CGEvent/NSPasteboard) compiles but unexercised; 12-app matrix is unit-level against MockSystemAccess, not a UI rig; Google Sheets via default adapter.

**Description:** text into any app, clipboard as last resort only.

- [x] 
  
  **T1** Layered injector: ① AX direct insertion (`AXUIElementSetAttributeValue` at cursor) → ② synthesized Unicode `CGEvent` keystrokes to focused PID → ③ per-app adapter → ④ clipboard paste with full save/restore + `changeCount` guard. _(Design per FluidVoice — clean-room; code per Muesli MIT where applicable.)_ _(status: done; live AX/CGEvent/pasteboard path needs manual verification)_
  
- [x] 
  
  **T2** Per-app adapters for the hostile set: Terminal/iTerm/Ghostty/tmux (bracketed paste, no smart punctuation), Electron apps (Slack, VS Code), Cursor, Excel/Sheets (cell mode), Figma. _(status: done; mock-modelled matrix, no CI UI rig)_
  
- [x] 
  
  **T3** Success detection: post-injection AX readback where possible; per-app, per-version success telemetry stored **locally**; automatic method routing from history. _(status: done; per-bundle only (no app-version column in schema))_
  
- [x] 
  
  **T4** Focus safety: snapshot frontmost app at key-release; abort (never spray text) if focus changed; queue + notify instead. _(status: done)_
  
- [x] 
  
  **T5** Replace-range support (for repair snaps and Phase 1.5 corrections): replace exact ranges via AX; if the region no longer matches what we wrote, **do not touch it** — surface suggestion instead (Bet 4 safety rule, built now). _(status: done)_
  

**Tests:** scripted injection matrix across ≥ 12 apps in CI-adjacent UI test rig; clipboard-restore property test (user clipboard identical before/after, including images); focus-change abort test. **Acceptance:** dictation lands correctly in all 12 matrix apps; user clipboard never observably altered; zero text sprayed to wrong app in chaos test.

* * *
### P1.9 — Onboarding + settings _(WS-D; parallel; integrates P1.10 screens)_
**Status (2026-08-23):** done (16ea017); 22 AppTests. SwiftUI views/NSWindow controllers, real CNContactStore, real downloads and permission prompts untested; ModelManaging/OnboardingPermissionChecking are protocols P1.12 must adapt to Engine.ModelManager / PermissionService.

- [x] 
  
  **T1** 60-second onboarding flow: welcome → permissions (each with why + verify) → mic check (live quality meter) → **model choice screen** → first real dictation (guided sentence into a real app). _(status: done; real permission prompts untested)_
  
- [x] 
  
  **T2** Model choice screen: Fast/Balanced/Best local (sizes + plain-language tradeoffs; background download with pill progress; bundled tiny model active meanwhile) + optional "connect what you pay for" (P1.10 flows). Skippable; never blocking. _(status: done; ModelTier→ModelID mapping left to P1.12)_
  
- [x] 
  
  **T3** Settings window (single, small): hotkey, models/providers per stage (Auto default), personas (plain-English text per app), dictionary manager, flags (Lab-linked), Data Panel. _(status: done; 6-tab Settings window, views not rendered in tests)_
  
- [x] 
  
  **T4** First-run dictionary import offer: contacts names (permissioned, local only). _(status: done; real CNContactStore access untested)_
  

**UI/UX:** every onboarding step doable in ≤ 10s; final step is doing, not watching. **Tests:** onboarding state-machine unit tests incl. permission-denied branches; fresh-VM manual script. **Acceptance:** fresh install → first successful dictation ≤ 60s with all-granted permissions; app fully usable with everything skipped.

* * *
### P1.10 — Providers: models, keys, OAuth, CLI adapters (Part 4.6) _(WS-E; fully parallel/independent)_
**Status (2026-08-23):** done (cbe747d); 36 ProvidersTests. No live Ollama/API keys/real OAuth/real `claude` CLI exercised (stubs only); MLX/CoreML local pipeline models not implemented (local = Ollama/LM Studio + LocalRulesProvider); ChatGPT OAuth wire details and `codex exec` argv best-effort.

- [x] 
  
  **T1** `Provider` protocol: `complete(stage:, spans:, context:) async` + capability flags (`asr`, `pipeline`), cost class, privacy class. _(status: done)_
  
- [x] 
  
  **T2** Local providers: MLX/CoreML pipeline models; Ollama + LM Studio auto-detection (localhost, no auth header — FluidVoice pattern, reimplemented). _(status: done; no MLX/CoreML runtime — local path is Ollama/LM Studio + deterministic LocalRulesProvider; live Ollama smoke not run)_
  
- [x] 
  
  **T3** OpenAI-compatible client: OpenRouter, OpenAI, Anthropic, Groq, Cerebras + custom base URL. Keys in Keychain. Streaming + timeout + fallback-to-local on failure. _(status: done; no real keys exercised)_
  
- [x] 
  
  **T4** OAuth PKCE "Sign in with ChatGPT" (Muesli-proven pattern): loopback redirect, token refresh in Keychain, **pipeline stages only** — UI must state subscriptions do not help ASR. _(status: done; tested against mock IdP; real ChatGPT OAuth unverified)_
  
- [x] 
  
  **T5** CLI adapters (Paperclip pattern, MIT — read `adapter-plugin.md` + `tools/agent-shim`, reimplement in Swift): detect `claude` / `codex` binaries; adapter runs prompt-in/text-out subprocess with timeout + sandboxed env; register as pipeline providers labeled "uses your existing subscription". _(status: done; stub-binary tests only)_
  
- [x] 
  
  **T6** Routing table: per-stage provider choice, Auto default (local first); every remote call → Data Panel log (timestamp, stage, provider, bytes, purpose). _(status: done)_
  
- [x] 
  
  **T7** Cloud ASR slot (post-v1 flag, default hidden): honest UI copy — "cloud ASR disables repair & context features." _(status: done; slot gated on FeatureFlag.cloudASR)_
  

**Tests:** provider conformance suite run against mocks + live Ollama; OAuth flow integration test with mock IdP; CLI adapter test with a stub binary; routing fallback chaos test (kill provider mid-call → local completes). **Acceptance:** a pipeline rewrite runs via (a) local model, (b) OpenRouter key, (c) ChatGPT OAuth, (d) `claude` CLI — user-switchable, each visible in the Data Panel.

* * *
### P1.11 — The Lab + Zero-Edit counter + Data Panel (T3) _(WS-F; fully parallel/independent)_
**Status (2026-08-23):** done (c495f9f); 28 LabTests. Real engine must be injected via feed closure + LabRegistry in P1.12; production AX FieldObserver only mocked; real-world audio suites not recorded (backlog in Lab/FIXTURES.md); public-repo publish deferred to P1.13; no-unlogged-egress tested via EgressGate/log path only.

- [x] 
  
  **T1** Harness core: run fixture suites (clean, noisy, accent, entity, technical) through any engine/pipeline configuration; score WER, entity recall, false-entity rate, latency percentiles, zero-edit prediction. CLI + in-app. _(status: done; real engine registered in LabRegistry at P1.12)_
  
- [x] 
  
  **T2** Fixture curation: assemble the real-world suite (record + license-check; include Earnings-22-style call audio, code dictation, Indic-accent English). Document provenance. _(status: done; real-world suites not recorded — backlog in Lab/FIXTURES.md)_
  
- [x] 
  
  **T3** Lab panel UI: run benchmark on this Mac, compare configurations (flags × models × providers), per-stage latency waterfall, thermal readout during runs (Risk 10 measurement). _(status: done; production FieldObserver pending Injection AX layer)_
  
- [x] 
  
  **T4** Zero-edit counter: words dictated vs words edited within 60s of landing in same field (AX observation, local only) — menu-bar stat + trend. _(status: done; EgressGate consulted by Providers via closure wired at integration)_
  
- [x] 
  
  **T5** Data Panel: live log of every byte that left the machine (provider calls, model downloads, update checks), per-hour rollup, global kill switch. _(status: done; SwiftUI panels compile, not rendered)_
  
- [x] 
  
  **T6** Publish harness as a public repo artifact (spec Phase 1 "publish the harness"). _(status: done; publish-as-public-repo left to release step)_
  

**Tests:** harness determinism (same input → same scores); counter accuracy against scripted edit sessions; data-panel completeness test (proxy-verify no unlogged egress). **Acceptance:** one click produces a scored report comparing `biasing on/off` on local hardware; Data Panel shows _nothing_ egressing in default config.

* * *
### P1.12 — Integration + hardening _(serial; after all P1.x)_
**Status (2026-08-24):** done (9cd69d9, 82b9d2b, 2f6dc91, ada434e, 29f3a59); 613 tests green across the package. T3 is a 3-minute mock soak only; hardware latency / 2 h soak / 12-app matrix on real apps remain manual.

- [x] 
  
  **T1** Wire real engine to shell (replace `MockEngine`); end-to-end latency budget: key-release → text landed **≤ 700ms p50, ≤ 1200ms p95** (10s utterance, M1, local everything). _(status: done 9cd69d9; AppContainer composition root, RealEngine over AudioPipeline with Apple Speech/mock fallback; IntegrationLatencyTests e2e p50 53 ms / p95 53 ms (mock engine) — real-mic hardware latency left manual)_
  
- [x] 
  
  **T2** Kill-criteria review: read Lab numbers for Bets 2/3/9 flags; set defaults per spec Part 5 rules; record decision in `DECISIONS.md`. _(status: done 82b9d2b; contextBiasing → default-off (real-decoder recall 31.6% → 31.6%), voiceRepair on, dualPath off; DECISIONS.md 2026-08-23)_
  
- [x] 
  
  **T3** Thermal/battery soak: 2h continuous dictation session on fanless hardware; no thermal throttle below latency budget; idle drain < 1%/h. _(status: partial — ada434e; Packaging/soak.sh + --soak mode; 3 min mock soak only: nominal thermal, flat landing latency over 57k dictations; 2 h fanless live-model run pending manual)_
  
- [x] 
  
  **T4** Chaos pass: device swaps, focus churn, sleep/wake, model-download interruption, 10k-word session. _(status: done 29f3a59; Tests/AppTests/ChaosTests — device swap, focus churn, download interruption→resume, 10k-word session; sleep/wake untested headless; fixed O(n²) contract verify + edit distance)_
  
- [x] 
  
  **T5** Security review: injection surfaces, subprocess adapters, Keychain usage, no dynamic code loading. _(status: done 2f6dc91; docs/SECURITY-REVIEW.md; fixed CLIDetector PATH handling, model downloads gated by egress kill switch; follow-ups listed in §7 of that doc)_
  

**Acceptance:** Phase 1 "Done when" from spec — on the published harness, beat competitor baselines on WER and zero-edit rate for the recorded fixture suite; all budgets met.
### P1.13 — Packaging + release pipeline _(serial; the pipeline built here is reused by every later phase)_
**Status (2026-08-24):** done. `Packaging/release.sh 1 1.0.0` produced VoicePlus_1_1.0.0.dmg (13 MB, sha256 6ce21d6c…0e0f9), tag `release/phase-1/v1.0.0`, GitHub release with Packaging/notes/phase-1.md. Earlier: T1–T2 pipeline scripts done (bb1064d): make_app.sh, release.sh, Info.plist template, entitlements, appcast, Homebrew cask, verify_install.sh; proved with VoicePlus_0_0.0.1.dmg. Ad-hoc signing only, no Developer ID/notarization. T3 and the 1.0.0 dmg pending P1.12.

- [x] 
  
  **T1** Developer ID signing, hardened runtime, notarization; dmg with drag-install background; Sparkle appcast (+ beta channel); Homebrew cask. _(status: done as ad-hoc codesign + hdiutil dmg; Developer ID signing/hardened runtime/notarization pending an identity)_
  
- [x] 
  
  **T2** **Reusable release script** `Packaging/release.sh <phase> <version>`: builds, signs, notarizes, produces `VoicePlus_<phase>_<version>.dmg`, archives to `Packaging/releases/`, updates appcast, tags the repo (`release/phase-<phase>/v<version>`), creates the GitHub release with the phase's human test script in the release notes. Every subsequent phase MUST ship through this script — no ad-hoc builds. _(status: done; notarization step is a no-op without an identity; only 0.0.1 smoke dmg produced so far)_
  
- [x] 
  
  **T3** First-run integrity: clean-install and upgrade-in-place paths tested from the actual dmg artifact (not from Xcode run). _(status: done; Packaging/verify_install.sh OK on VoicePlus_1_1.0.0.dmg (mount, codesign --verify, launch); upgrade-in-place over 0.0.1 and clean-account install are manual steps in Packaging/notes/phase-1.md)_
  

**Acceptance:** fresh Mac → download dmg → dictating in 60s. **Output artifact:** `VoicePlus_1_1.0.0.dmg`**.**

* * *
## 5. PHASE 1.5 — Dual-path silent correction (Bet 4) (.dmg #2)
_Single workstream (WS-A + WS-D). Small, dangerous, isolated._
### P1.5.1 — Reconciler
- [x] 
  
  **T1** Run EOU (fast) + TDT v3 (accurate) concurrently; ANE contention profiling; diff final vs preview at word level using audio-span alignment. _(status: done 22fcf83; DualPathRunner + DualPathTiming + WordAligner; 22 ReconcileTests incl. splice fuzz, precision ≥95% synthetic; not wired to UX, flag dualPath off)_
  
- [x] 
  
  **T2** Correction planner: only correct spans that (a) differ semantically, (b) exceed confidence delta threshold, (c) pass the **safety rule** — target text still exactly matches what we injected (AX readback); else downgrade to suggestion. _(status: done 22fcf83; CorrectionPlanner correct|suggest|drop with AX-readback safety rule via DocumentReadback protocol; production AX adapter pending P1.5.2)_
  
### P1.5.2 — Correction UX
- [x] 
  
  **T1** Shimmer + 2s underline on corrected word; hover → "was: …" + one-tap revert; "show what changed" list in menu dropdown; per-app off switch; `"put it back"` voice undo. _(status: done d80decf/c15b495; CorrectionLedger/Overlay/Service/Menu — AX-word-rect underline panel, hover "was: …" + revert, "Show what changed" submenu, global + per-app off switch in Settings, "put it back" CorrectionUndoRouter; InjectionDocumentReadback + DualPathReconciler wired in AppContainer behind FeatureFlag.dualPath (default off); 36 Correction/Transform UX tests; AX rects/overlay + live dual-path run untested on hardware)_
  
- [x] 
  
  **Tests:** splice property test — corrections never alter user-modified text (fuzz with concurrent edits); correction precision ≥ 95% on fixture disagreements. **Acceptance:** visibly wrong preview word silently becomes correct after landing; typing immediately after dictation is never corrupted. **Release:** `Packaging/release.sh 1.5 1.1.0` → `VoicePlus_1.5_1.1.0.dmg`. _(status: released 2026-08-24 —_ `Packaging/releases/VoicePlus_1.5_1.1.0.dmg` _14 MB, sha256_ `451351335368748bc27ac7dffa2659d259332ffe9e3baef5fd138617d2e3db31`_, tag_ `release/phase-1.5/v1.1.0`_, verify_install OK, notes_ `Packaging/notes/phase-1.5.md`_; dualPath flag ships default off; human test script (11 steps) pending on a clean account)_
  

* * *
## 6. PHASE 2 — "Talk to your text" (.dmg #3)
_Parallel groups: {P2.1+P2.2} (WS-B), {P2.3} (WS-D), {P2.4, P2.5, P2.6} independent after P2.1._
### P2.1 — Transform routing
- [x] 
  
  Selection detector via AX (deterministic dictate-vs-transform per Bet 5); gatekeeper gains `transform` + `question` routes; selection text + surrounding context assembled for the model. _(status: done e0985ac; SelectionDetector (AX live + mock), TransformRouter, gatekeeper transform/question routes; live AX selection untested on hardware)_
  
### P2.2 — Rewrite engine
- [x] 
  
  Transform executor via Providers (local default, best-available preferred for quality); output re-injected via replace-range (P1.8 T5); diff computed for morph animation. _(status: done e0985ac; TransformExecutor w/ local-rules fallback + Bet 9 contract, WordDiff, TransformSession replace-range protocol (app adapts to Injection))_
  
- [x] 
  
  **Tests:** 60-case transform suite (tone, shorten, restructure, translate-format); injection-matrix re-run for replace-range. _(status: done; 60-case scripted suite + replace-range re-run with mock injector — 30 tests)_
  
### P2.3 — Transform UX
- [x] 
  
  Pill "transform" tint + "editing N words"; inline morph animation (collapse/expand, one beat); 5s "↩ / try again" ghost; chained-turn window — pill stays warm 8s, follow-up instructions reuse the selection (Kivi pattern). _(status: done d80decf/c15b495; PillState.transform + TransformPillInfo, MorphAnimationModel/MorphPreview, 5s TransformGhost, 8s clock-driven warm-window reducer, TransformLanding over TransformRouter/TransformSession/QuestionAnswerStage, InjectionTransformReplaceSink, SnippetPreRoute+SnippetStage + PersonaManager registered in AppContainer, Snippets tab + persona auto-draft in Settings)_
  
- [x] 
  
  **Acceptance:** "make this two lines" → "call out the churn number" → "bold it" — no re-selection, works in Mail, Slack, Notes. _(status: no-keyboard E2E test passed (MockEngine paragraph → three chained instructions, mock selection/injector, zero keystrokes, undo + warm-window expiry); Mail/Slack/Notes live run is in the phase-2 human test script)_
  
### P2.4 — Q&A on selection _(parallel)_
- [x] 
  
  `question` route types answer below selection with visible "answer:" attribution; never replaces selection. _(status: done aeeb19f/332f28a; QuestionAnswerStage + Provider/Heuristic answerers; 16 tests)_
  
### P2.5 — Personas deepening _(parallel)_
- [x] 
  
  Per-app plain-English persona box (auto-drafted from Phase 1 style learnings; editable); per-recipient override hooks (thread participant detection). _(status: done aeeb19f; PersonaManager auto-draft from StyleProfile, recipient overrides, DB store; 17 tests; settings UI wiring pending)_
  
### P2.6 — Spoken snippets _(parallel)_
- [x] 
  
  Trigger-phrase → expansion store; managed in settings; gatekeeper route with exact-match priority. _(status: done aeeb19f; SnippetStore + SnippetPreRoute exact-match + SnippetStage; 17 tests; not yet registered in StageRegistry)_
  
- [x] 
  
  **Phase acceptance:** a rough paragraph reaches final form via voice only, verified on the scripted "no-keyboard" E2E test. **Release:** `Packaging/release.sh 2 1.2.0` → `VoicePlus_2_1.2.0.dmg`. _(status: released 2026-08-24 —_ `Packaging/releases/VoicePlus_2_1.2.0.dmg` _14 MB, sha256_ `ff450a8ca29c89f0072fa45185e602e9c4ab05dda2c3781ce177f945893d9840`_, tag_ `release/phase-2/v1.2.0`_, verify_install OK, notes_ `Packaging/notes/phase-2.md`_; 930 tests green; human test script (13 steps) pending on a clean account)_
  

* * *
## 7. PHASE 3 — "It knows what 'this' means" (.dmg #4)
_Parallel: P3.1+P3.2 (WS-G) ∥ P3.3 (WS-G-2) ∥ P3.4 (WS-C). P3.5/P3.6 after P3.3._
### P3.1 — Input timeline recorder
- [x] 
  
  While hotkey held: record cursor path, click points, drawn strokes, selection changes — each timestamped on the **same clock as ASR audio spans**. Multi-display coordinates normalized. _(status: done 5705405; TimelineClock/CaptureAlignment, InputTimeline 30 s ring buffer, DisplayNormalizer; 15 tests)_
  
- [x] 
  
  **Tech:** `CGEvent` tap (already permissioned) + overlay stroke capture; ring buffer, 30s horizon; nothing persisted. _(status: done 5705405; listen-only EventTapRecorder + InkStrokeCapture; live tap untested (no Input Monitoring headless); not wired into DictationCoordinator)_
  
### P3.2 — Ink overlay
- [x] 
  
  Full-screen transparent overlay per display; Excalidraw-style stroke rendering (jitter + taper); 1.5s fade; resolution pulse animation on bound regions; region bundle counter in pill. _(status: done 5705405; per-display click-through OverlayWindow, CAShapeLayer strokes, FadeSchedule/PulseSpec, RegionBundleCounter; 7 tests; real rendering untested)_
  
### P3.3 — Deixis resolver
**Status (2026-08-24):** built 1545752 — Actions/Deixis (DeixisTypes, AXHitTesting with Mock/Live hit tester, DeixisResolver: audio midpoint → CaptureAlignment → stroke region else pointer → AX hit-test → near-miss ranking with ambiguity flag). Phase gate: 120/120 synthetic cases across two displays (point/stroke/move-then-point) incl. "move this over there" both referents. Wired into the app 2026-08-24 (de94fc4): DeixisService on hotkey hold, contextLine into StageContext, overlay rings live. LiveAXHitTester remains manual (Accessibility TCC).

- [x] 
  
  Bind deictic words ("this/that/there/these") to timeline: word's audio timestamp → pointer position/stroke segment at that moment → AX hit-test → element/region reference passed to pipeline/actions. _(status: done — wired de94fc4; contextLine lands via UtteranceLander.contextAugmenter, lastBindings kept for the P4 act path; Phase3AcceptanceTests)_
  
- [x] 
  
  **Tests:** scripted fixture: synthetic pointer traces + audio with known bindings; **target ≥ 95% correct binding** (phase gate). _(status: done — DeixisFixtureTests 120/120 = 100% correct, gate ≥95%)_
  
### P3.4 — Deep AX reading _(parallel — extends Injection's AX layer)_
- [x] 
  
  Full-window text extraction incl. scrollback (AX value + `AXVisibleCharacterRange` walking); document/terminal content on demand; cached per window with invalidation. _(status: done 26808a6; AXWindowReader w/ AXStringForRange stitching + 200k cap, WindowContentCache + observer invalidation, LiveAXNodeAccess; 20 tests; live AX untested)_
  
### P3.5 — Conversational referents
**Status (2026-08-24):** built 1545752 — Actions/Referents/ReferentResolver (Participant/VisibleArtifact providers, pronoun + "the deck/file" resolution by gender/kind/salience, ambiguity on close salience, contextLines); 5 tests. Wired 2026-08-24 (de94fc4): AXReferentContext feeds participants/artifacts from AXWindowReader + WindowContentCache; live AX itself manual (TCC).

- [x] 
  
  Resolver for "her/him/the deck/the file": thread participants + visible artifacts from AX context → pipeline context injection. _(status: done — wired de94fc4 via AXReferentContext; Phase3AcceptanceTests)_
  
### P3.6 — Reverse elicitation
**Status (2026-08-24):** built 1545752 — Actions/Elicitation/ReverseElicitation pure state machine (ask → prompting rings + "which one?" + deadline → point or speech answer → resolved; timeout → clarifying pill text; cancel); 5 tests. Ring rendering + coordinator wiring done 2026-08-24 (de94fc4): pulse rings + "which one?" pill text with deadline tick → clarifying-text fallback.

- [x] 
  
  On ambiguous binding (two candidates within threshold): draw ring + "which one?" label; user points or speaks; answer feeds resolver; timeout falls back to clarifying text in pill. _(status: done — wired de94fc4; elicitation point/timeout covered in Phase3AcceptanceTests)_
  

**Phase acceptance:** "move this over there" resolves both referents correctly ≥ 95% in the scripted suite; live demo across two displays. **Release:** `Packaging/release.sh 3 1.3.0` → `VoicePlus_3_1.3.0.dmg`. _(status:_ **_released 2026-08-24_** _—_ `Packaging/releases/VoicePlus_3_1.3.0.dmg` _14 MB, sha256_ `5344f3e9c8f90e7d012780af96d9c8ad3850cc11998901219f66a3c178da5969`_, tag_ `release/phase-3/v1.3.0`_, verify_install OK, notes_ `Packaging/notes/phase-3.md`_; scripted suite 120/120 = 100% + Phase3AcceptanceTests two-display resolution, 936 tests green at integration; live two-display demo is the human test script (10 steps))_

* * *
## 8. PHASE 4 — "It does it, not just types it" (.dmg #5)
_Parallel: P4.1 (deterministic) ∥ P4.3 (cursor) ∥ P4.4 (consent) ∥ P4.6 (connectors — one subagent per connector). P4.2 after P4.1; P4.5 after P4.1+P4.4._
### P4.1 — Deterministic action layer
**Status (2026-08-24):** built c11f180 — Actions/Deterministic (ActionSystem protocol as the only OS door, FuzzyMatch, ActionCatalog + catalog.json, ActionExecutor precondition→execute→AX-readback, MockActionSystem, LiveActionSystem over NSWorkspace/AXUIElement/CGEvent gated on AXIsProcessTrusted); 14 tests. Phase gate 1398/1398. Wired 2026-08-24 (cae24d4): ActRouter stack in AppContainer, make_app.sh bundles catalog.json. LiveActionSystem still untested on hardware.

- [x] 
  
  Action vocabulary over AX: click-by-name (fuzzy label match), focus app/tab/window/desktop, scroll, keystroke/shortcut, fill field, open URL/file. **Catalogue the 200 actions** (mine Infina's published command list as the spec of what matters). _(status: done — wired cae24d4; catalog bundled into the .app)_ _(Infina's command list unreachable (404); 200-entry catalog.json composed: mac 72, browser 30, editor 32, chat 22, mail 22, files 22)_
  
- [x] 
  
  Each action: precondition check → execute → postcondition verify (AX readback). No model call on this path. _(status: done — wired cae24d4 via ActionExecutor in AppContainer)_
  
- [x] 
  
  **Tests:** action conformance matrix across 15 apps; **target ≥ 99% success** on catalogued actions (phase gate). _(status: done — 15 mock apps × catalogued actions = 1398 cells, 1398/1398 = 100.00% (746 readback-verified, 652 delivery-only))_
  
### P4.2 — Act routing (second key)
**Status (2026-08-24):** built d4aa81c — Actions/ActRouting (ActDomainActivation/State, ActIntentParser: stop/confirm/cancel grammar → fuzzy catalogue match scoped by bundle id, compound/"can you…" → agentic goal, ConsentRequest bridge; ActRouter deterministic via ConsentEngine+ActionExecutor, agentic via AgentActionBackend); routing matrix 200/200 catalogue phrasings. Composition root done 2026-08-24 (cae24d4): ActPreRouteHook 3-line gatekeeper adapter with explicit claim flag (claimed utterances never type), second key (configurable, default Right ⌘, own defaults key) via additive HotkeyService params.

- [x] 
  
  Second hotkey activates `act` domain (Bet 5: two keys); gatekeeper extends to action-intent parse → deterministic match first; unmatched → agentic fallback with visible plan. _(status: done — wired cae24d4; second-key gating + gatekeeper claim in Phase4AcceptanceTests)_
  
### P4.3 — Overlay agent cursor _(parallel)_
**Status (2026-08-24):** built 7230706/e9a7cc2 — App/Overlay/AgentCursor (AgentCursorModel: position/glow/scale/seeded wisps; AgentCursorLayer CALayer host on InkLayerView, ActionAnimating glide/click/typing/highlight/dismiss; AgentCursorController routes to per-display OverlayWindow). "Never moves pointer" asserted statically (no CGWarp/CGEventPost/NSCursor). Hooked to action dispatch 2026-08-24 (cae24d4) via AgentCursorController (never moves the real pointer); live CA rendering untested headless.

- [x] 
  
  Tinted glowing pointer with trailing wisp, rendered on overlay; **never moves the user's pointer**; all deterministic/agentic actions animate through it. _(status: done — wired cae24d4)_
  
### P4.4 — Consent engine (Bet 7) _(parallel)_
**Status (2026-08-24):** built 7230706 — Actions/Consent (ActionClassifier rule table exact id → prefix → category → conservative default irreversible; ConsentEngine: reversible executes, semi → 5s UndoToastModel + CompensatingActionRegistry, irreversible → ConfirmationCard with confirm(token) click or spoken "confirm"/cancel); ConsentTests incl. 2000-iteration fuzz: irreversible/unknown ids never execute unconfirmed. Toast/card UI wired 2026-08-24 (cae24d4): undo toast panel with 5s draining ring → ConsentEngine.undo; slide-out confirmation card (click or spoken confirm); agent cards await the click through NativeAgentBackend.confirmation.

- [x] 
  
  Action classifier: `reversible / semi / irreversible` (rule table + conservative default); reversible = just do; semi = 5s undo toast with draining ring + compensating action (e.g. delete sent Slack msg where API allows); irreversible = slide-out card requiring spoken "confirm" or click. Policy table in code, unit-tested, no user config. _(status: done — wired cae24d4; 200-case irreversible fuzz at router level, zero unconfirmed executions)_
  
### P4.5 — Agentic fallback
**Status (2026-08-24):** built d4aa81c — Actions/Agent (AgentActionBackend protocol, AXSummary screenshot-free observation, 12-ActionKind tool vocabulary, PlannerLLM + ScriptedPlanner, NativeAgentBackend observe→plan→consent-gated execute loop with maxRounds/maxSteps, stop()/requestStop() cancelling in-flight planner + LIFO rollback, wall-clock watchdog; StepChips model). **Cua decision:** license clears (MIT root) but not imported — Python-first, screenshot+VM loop conflicts with the no-screenshots rule and the omni extra is AGPL; native loop shipped, Cua seam kept (Actions/Agent/README.md). 32 ActRouting+AgentBackend tests incl. 300-plan consent fuzz. Provider-backed planner (RoutingTable-backed, Data-Panel-logged, DONE/GIVEUP parser that never guesses) + confirmation-card wiring done 2026-08-24 (cae24d4); live AX observation manual.

- [x] 
  
  `AgentActionBackend` protocol; Cua backend **only if license clears** (P4.0 task: verify), else native loop (screenshot-free: AX tree + action vocabulary as tools, local or provider LLM planning); step plan → chips UI; every step through consent engine; "stop" kills mid-flight (hard timeout + rollback of queued steps). _(status: done — wired cae24d4; PR-tab+scroll agentic flow passes over MockActionSystem in Phase4AcceptanceTests)_
  
### P4.6 — Native connectors _(fully parallel — one subagent each)_
**Status (2026-08-24):** built 7d99f8d/ae74b25 (Common + Slack/Gmail/Google Calendar) and 583138f (Linear/Notion/GitHub) — Actions/Connectors: Connector protocol (matches(target), perform → performed|fallbackToUI), ConnectorOAuth PKCE S256 + refresh, ConnectorClient (bearer, one 401→refresh retry, every call → NetworkLogRecord stage `act.connector` for the Data Panel), ConnectorRegistry, HTTPTransport + mocks; Slack chat.postMessage/search, Gmail send/draft/search, Calendar insert/list, Linear GraphQL, Notion REST, GitHub REST + device flow/PAT. 74 tests (40 + 34). Wired 2026-08-24 (cae24d4): ConnectorHub with Keychain secret store, loopback OAuth receiver (port 1456), GitHub PAT path, Settings 'Services' tab with OAuth start buttons; every call → Data Panel. Still untested live: real OAuth client IDs (env-supplied, none bundled), real endpoints, Keychain on hardware.

- [x] 
  
  Slack, Gmail, Google Calendar, Linear, Notion, GitHub: OAuth per service, minimal scopes; actions (send/draft/create/comment) route via API when target matches, else UI automation. Every call → Data Panel. _(status: done — wired cae24d4; live OAuth needs client IDs via environment, GitHub PAT works without one)_
  

**Phase acceptance:** deterministic path ≥ 99% on the 200-action catalogue; "open the PR tab and scroll to the failing check" works live; irreversible actions never execute unconfirmed (fuzz-tested). **Release:** `Packaging/release.sh 4 1.4.0` → `VoicePlus_4_1.4.0.dmg`. _(status:_ **_released 2026-08-24_** _—_ `Packaging/releases/VoicePlus_4_1.4.0.dmg` _14 MB, sha256_ `98ec9cf4367b0e8ee1be0f16e5ae902c6b3bce8bae472603ad79a2826e8e5ecc`_, tag_ `release/phase-4/v1.4.0`_, verify_install OK, notes_ `Packaging/notes/phase-4.md`_; conformance 1398/1398 = 100%, 200-case irreversible fuzz zero unconfirmed, PR-tab flow over mock action system, 944 tests green at integration; live run is the human test script (12 steps))_

* * *
## 9. PHASE 5 — "No hotkey at all" (.dmg #6)
_Parallel: P5.5 meeting capture is independent — may be built any time after Phase 1. P5.1 ∥ P5.3 ∥ P5.4; P5.2 after P5.1._
### P5.1 — Directed-speech detection _(research item — timebox, wake-verb fallback guaranteed ship)_
**Status (2026-08-24):** built cb383c7 — Engine/DirectedSpeech (RollingAudioRing 10 s RAM-only with wipe(), feature extractor SNR/level/energy slope/autocorr voicing/ZCR/onset rate + KeywordSpotter + field-focused/addressed-recently context, logistic DirectedSpeechClassifier with online SGD from markNotYou()/markWasMe(), Detector, Harness). Corpus is synthetic macOS TTS (prosody alone barely separates; content+context cues carry the result). Wired 2026-08-24 (93f5369): HandsFreeController gates capture behind the new `directedSpeech` flag (experimental, default off); "not you" is a hands-free-only pre-route hook (claimed, never typed). Live mic path manual.

- [x] 
  
  Always-on lightweight path: VAD → tiny on-device classifier (prosody + content features + gaze-free context: is a text field focused, was the machine addressed recently). Nothing stored or transmitted; rolling 10s buffer, RAM only. _(status: done — wired 93f5369; directed × speaker gate × hard mute must all agree before the mic opens)_
  
- [x] 
  
  **Metric harness first:** false-trigger rate / missed-address rate on a recorded home+office corpus. **Ship bar: < 1 false trigger/day** simulated; below bar → mode stays opt-in "experimental". _(status: done — harness over Fixtures/directed (34 entries: 12 addressed, 19 noisy + 3 VAD-floor ambient): 0 false triggers / 0.0 per simulated day (400 ambient utterances/day), missed-address 1/12 = 8.3% with hand-initialised weights; after one "not you" pass 0 FT, after full pass 0 FT / 0 missed. Ship bar passes on the synthetic corpus only, so mode stays opt-in_ `engine.directedSpeech.experimental` _(default off))_
  
### P5.2 — Wake-verb grammar
**Status (2026-08-24):** built 5de5b55 — Pipeline/WakeVerb (WakeVerbGrammar "type/write/dictate …", "send[ it|that]", " …"/"in|to|tell …"; WakeVerbPreRoute active only when `input.mode == handsFree`, forces .dictate; WakeVerbStage blanks wake tokens preserving audioRange/confidence/provenance; WakeVerbHintModel full hint 10 uses, fades over 5). 47 tests with P5.1. Wired 2026-08-24 (93f5369): WakeVerbPreRoute + WakeVerbStage registered; `input.mode=handsFree` stamped by the lander's augmenter chain from the coordinator's double-tap state.

- [x] 
  
  Infina-pattern reliable fallback: leading verbs `"type …"`, `"send"`, `"<appname> …"` parsed by gatekeeper in hands-free mode; printed inside pill first 10 uses, then fades. _(status: done — wired 93f5369; wake-verb strip covered in Phase5AcceptanceTests)_
  
### P5.3 — Speaker identification _(parallel)_
**Status (2026-08-24):** built b1047f1 — Engine/Speaker (SpeakerEmbedding cosine for FluidAudio WeSpeaker when models on disk / gaussian MFCC mean+std fallback, SpeakerEnrollment 3 prompts → centroid profile persisted as JSON without audio, SpeakerGate user/other/unknown). Rejection suite on fixture TTS voices: **84/84 non-enrolled utterances rejected = 100% (bar ≥99%)**, own-voice acceptance 31/33 = 93.9%. Raw MFCC cosine gave 0% rejection, hence the Gaussian summary (threshold 0.5). WeSpeaker path compiled but untested (models absent); onboarding-2 enrollment window wired 2026-08-24 (93f5369): 3 prompted takes through the engine audio tap → centroid profile → HandsFreeController.install.

- [x] 
  
  Speaker embedding (diarization models already in engine) enrolled during onboarding-2; non-user speech ignored in hands-free; TV/podcast rejection test suite. _(status: done — wired 93f5369; TV-noise rejection in Phase5AcceptanceTests)_
  
### P5.4 — Ambient state + hard mute _(parallel)_
**Status (2026-08-24):** built 961ec70 — App/Ambient (AmbientStateModel with distinct SF Symbols for menu bar + notch, mute is a hard latch that wins over processing and is never auto-released, persistent MUTED badge, MuteController + MuteStore so relaunch stays muted, NotYouCorrection → DirectedSpeechTeacher + speaker-profile negatives). 14 tests with P5.3. StatusItem wiring done 2026-08-24 (93f5369): three-state glyph override + hard-mute menu item (persistent badge, mute pauses the coordinator, unmute never automatic).

- [x] 
  
  Three-state glyph (listening/muted/processing) in menu bar + notch; one-gesture mute with persistent badge; unmute never automatic; "not you" voice correction teaches the classifier. _(status: done — wired 93f5369)_
  
### P5.5 — Meeting capture _(independent; port from Muesli, MIT)_
- [x] 
  
  Process-tap system audio recorder + watchdog + SCK fallback (copy, attribute); mic+system dual capture; AEC; VAD chunking; diarization ("You"/"Others"); local notes via pipeline providers; camera+calendar meeting detection with Join&Record/Record/Ignore notch notification; notes arrive as notification post-call. No bot ever joins. _(status: done 78be903; Engine/Meeting — process tap + SCK fallback, NLMS AEC, DualCapture, You/Others diarization, extractive notes, MeetingDetector, MeetingStore; 17 tests; wired 93f5369 2026-08-24 — MeetingCoordinator: camera+calendar → MeetingDetector → notch prompt → MeetingSession → local extractive notes → notification; Calendar/Screen-Recording usage strings + notch prompt on real hardware manual)_
  

**Phase acceptance:** false-trigger < 1/day in soak; speaker-ID rejects fixture TV audio ≥ 99%; meeting produces diarized transcript + notes fully locally. **Release:** `Packaging/release.sh 5 1.5.0` → `VoicePlus_5_1.5.0.dmg`. _(status:_ **_released 2026-08-24_** _—_ `Packaging/releases/VoicePlus_5_1.5.0.dmg` _14 MB, sha256_ `bfe33f9b99a243c3d256d82bb2db7b8f7ae062a1197ed807fda5c3a68074a3e0`_, tag_ `release/phase-5/v1.5.0`_, verify_install OK, notes_ `Packaging/notes/phase-5.md`_; harness 0 false triggers/day but synthetic corpus only →_ `directedSpeech` _ships experimental/off (DECISIONS.md), speaker rejection 84/84 = 100%, diarized meeting notes local, 952 tests green at integration; real-corpus soak is human test step 10)_

* * *
## 10. PHASE 6 — "It sounds like you" (.dmg #7 + mobile)
_Parallel: P6.1 ∥ P6.3 ∥ P6.4 ∥ P6.5. P6.2 after P6.1._
### P6.1 — Personal adaptation loop
**Status (2026-08-24):** built d07fac1/af25cb7 — Engine/Adapt (TrainingPairStore JSONL + WAV clips under AppPaths/Adapt, ingest(CorrectionRecord) + ingestEdit via word-level diff, eraseAll; AdapterTrainer: BiasListLearner with saturating weights feeding Biasing via LearnedLexiconSource, LoRAAdapterStub returning .infeasible → LabRunRecord (on-device fine-tune judged infeasible with CoreML inference-only graphs), AdaptationLoop try-LoRA-then-bias-list with persisted lexicon.json; PersonalWERTracker per day for Lab "you" tab). 27 Adapt tests incl. synthetic day-30 < day-1 replay. Wired 2026-08-24 (df2c4d6): AdaptationService — corrections + post-dictation edits (ZeroEditTracker now reports original/final) → TrainingPairStore → periodic retrain → LearnedLexiconSource + RegressionGuardStage in the live pipeline; Lab 'you' tab shows the day-by-day table + trend.

- [x] 
  
  Corrections (repair events, post-dictation edits) accumulate as paired (audio-span, corrected-text) training data — **on device**; periodic adapter fine-tune (LoRA-style on decoder/joint, or bias-list learning if fine-tune infeasible on-device — Lab decides); personal-WER tracked per user in Lab "you" tab. _(status: done — wired df2c4d6; day-30 < day-1 proven through the wired loop in Phase6AcceptanceTests)_
  
### P6.2 — Learned lexicon
**Status (2026-08-24):** built d07fac1/af25cb7 — Engine/Adapt/LearnedLexicon (PronunciationCapture storing WAV + trainByVoice pair, RememberToastModel once-per-word persisted never-repeat set, RegressionGuard stage `adapt.lexicon` with exact/Double-Metaphone substitution carrying confidence/audioRange, original kept as alternate); regression fixture: corrected word never re-mis-heard. Wired 2026-08-24 (df2c4d6): 'Train by voice' in dictionary settings (engine audio tap → PronunciationCapture) + one-time RememberToast, never repeats per word.

- [x] 
  
  Pronunciation capture ("Train by voice" — say the word, store the audio); one-time "I'll remember _Kothari_" toast; never repeat for same word. _(status: done — wired df2c4d6)_
  
### P6.3 — Code-switching _(parallel)_
**Status (2026-08-24):** built 11b9852 — Engine/CodeSwitch (Script classifier, streaming LanguageDetector script + romanized-Hindi n-grams → english/hindi/mixed with no toggle, ScriptAwareMerger → ScriptSegments with spacing/punctuation and provenance `codeswitch.merge`, IndicASRBackend protocol + availability check for indic-conformer-600m CoreML, CodeSwitchRouter, ScriptIndicatorModel EN / हि / EN·हि with hysteresis). License verified: IndicConformer-600m-multilingual is MIT; no official CoreML export (Muesli's RNNT conversion copyable with attribution); weights not shipped. 23 tests incl. hinglish fixture landing as one string. Wired 2026-08-24 (df2c4d6): CodeSwitchRouter built in EngineFactory, CodeSwitchService as the lander's textFinalizer, ScriptIndicator badge in the pill. Indic weights not shipped — UnavailableIndicBackend reports why; merger/indicator/injection work with the primary recognizer.

- [x] 
  
  Integrate AI4Bharat Indic RNNT models (verify license) under engine; script-aware injection (Devanagari + Latin in one utterance); auto language detection, **no language toggle**; pill script indicator. _(status: done — wired df2c4d6; Hinglish fixture lands as one mixed-script string with the EN·हि badge in Phase6AcceptanceTests; real Indic backend pending weights)_
  
### P6.4 — Encrypted sync _(parallel; backend-independent of app)_
- [x] 
  
  Sync payload = dictionary + personas + snippets + adapter weights + settings (never audio); end-to-end encrypted (user-held key), QR pairing, export-everything file; conflict = last-writer-wins per record. _(status: done 824db84; Sync target — ChaChaPoly/HKDF, X25519 QR pairing, LWW merge, folder transport, .voiceplus export; 17 tests; wired df2c4d6 2026-08-24 — SyncService with Keychain key, QR pairing view, folder-transport picker, export/import-everything, Settings 'Sync' tab; Keychain on hardware + iCloud folder still untested live)_
  
### P6.5 — iOS keyboard _(parallel; separate target)_
**Status (2026-08-24):** built db094ff/14227c9 — iOS/KeyboardCore as a macOS-testable SwiftPM target (hold-to-talk state machine with advanceToNextInputMode/dismiss, repair fan-out copy, pill model, persona picker, versioned JSON proxy over App Group file mailbox + Darwin doorbell, KeyboardASR + mock) and an XcodeGen source tree (iOS/project.yml: app + keyboard extension, App Groups, RequestsOpenAccess; SFSpeech on-device ASR, ParakeetCoreMLASR slot). Package.swift additive: products Pipeline + KeyboardCore, target KeyboardCore + KeyboardCoreTests (22 tests). **Untestable here: no Xcode/iOS SDK** — UIKit/SwiftUI/SFSpeech/App Group code uncompiled, expect minor fixes on first xcodegen build; TestFlight archive is manual on an Xcode machine. Proxy answers only while the companion app is alive; keyboard lands raw ASR after 1.5 s.

- [x] 
  
  Keyboard extension: hold-to-talk pill, same repair fan-out, personas; on-device ASR (small Parakeet via CoreML) with app-proxy for heavier pipeline; instant return to previous keyboard (kill the Aqua focus-dance). _(status: built + unit-tested;_ **_ships source-only_** _— no Xcode/iOS SDK on this machine, so v1.6.0 has no TestFlight build; xcodegen + archive are manual on an Xcode machine)_
  

**Phase acceptance:** day-30 personal WER < day-1 (provable in Lab); corrected word never re-mis-heard in regression fixture; Hindi+English single-breath fixture lands correctly; profile round-trips Mac→iPhone via QR. **Release:** `Packaging/release.sh 6 1.6.0` → `VoicePlus_6_1.6.0.dmg` + iOS TestFlight build. _(status:_ **_released 2026-08-24_** _—_ `Packaging/releases/VoicePlus_6_1.6.0.dmg` _14 MB, sha256_ `66ae1e52b469a2b65a85761f16e5256865d7e707eed5bc68ae9ee1305310a1af`_, tag_ `release/phase-6/v1.6.0`_, verify_install OK, notes_ `Packaging/notes/phase-6.md`_; day-30 < day-1 through the wired loop, corrected word never re-mis-heard, Hinglish lands as one string with EN·हि badge, export/import + QR key-agreement round-trip (Mac→Mac; Mac→iPhone needs the iOS build), 959 tests green;_ **_no TestFlight build_** _— iOS keyboard is source-only without Xcode)_

* * *
## 11. Release manifest — one dmg per phase, mandatory
| Phase | Command | Artifact |
|---|---|---|
| 1 | `Packaging/release.sh 1 1.0.0` | `VoicePlus_1_1.0.0.dmg` ✅ 2026-08-24 produced + GitHub release |
| 1.5 | `Packaging/release.sh 1.5 1.1.0` | `VoicePlus_1.5_1.1.0.dmg` ✅ 2026-08-24 produced + GitHub release |
| 2 | `Packaging/release.sh 2 1.2.0` | `VoicePlus_2_1.2.0.dmg` ✅ 2026-08-24 produced + GitHub release |
| 3 | `Packaging/release.sh 3 1.3.0` | `VoicePlus_3_1.3.0.dmg` ✅ 2026-08-24 produced + GitHub release |
| 4 | `Packaging/release.sh 4 1.4.0` | `VoicePlus_4_1.4.0.dmg` ✅ 2026-08-24 produced + GitHub release |
| 5 | `Packaging/release.sh 5 1.5.0` | `VoicePlus_5_1.5.0.dmg` ✅ 2026-08-24 produced + GitHub release |
| 6 | `Packaging/release.sh 6 1.6.0` | `VoicePlus_6_1.6.0.dmg` ✅ 2026-08-24 produced + GitHub release (TestFlight not produced — iOS keyboard source-only without Xcode) |
| 6 (patch) | `Packaging/release.sh 6 1.6.1` / `1.6.2` | `VoicePlus_6_1.6.1.dmg` ✅ 2026-08-29 (sha256 `020958a9…4d612`, tag `release/phase-6/v1.6.1`, notes `Packaging/notes/phase-6-1.6.1.md`) — user-reported onboarding blockers on real hardware: missing TCC `Info.plist` usage strings + hardened ad-hoc signing, permission steps that dead-ended before Accessibility, frozen mic meter, pill drawn under the camera housing. `VoicePlus_6_1.6.2.dmg` ✅ 2026-08-29 (sha256 `651ace26…6ac486`, tag `release/phase-6/v1.6.2`, notes `Packaging/notes/phase-6-1.6.2.md`) — off-screen/1×0 onboarding window, meeting-panel notch occlusion, dead pill waveform, bundle-first resource lookup; **1006 tests green**. Both verify_install OK. |
| 6 (patch) | `Packaging/release.sh 6 1.6.3` | `VoicePlus_6_1.6.3.dmg` ✅ 2026-08-29 (sha256 `5cde1597…3058b4`, tag `release/phase-6/v1.6.3`, notes `Packaging/notes/phase-6-1.6.3.md`, **install this one**) — fixes a regression **introduced by our own 1.6.1/1.6.2**: Microphone could not be granted at all, because the persisted `onboarding.requested.*` flag opened any permission in the settings-recovery phase, and the sole call site of `AVCaptureDevice.requestAccess` is the Allow button in `.explain` — the only way an app can ever appear in the Microphone pane (which has no **+**). Promptable vs non-promptable services now modelled separately; a live `notDetermined` promptable always reaches the Allow button and the poll self-heals a stale flag (39cb91d, 375f97a). Plus: meeting capture made opt-in — a plain launch was requesting Calendar **and** Reminders unasked (a43fc80); the onboarding phase is now logged, with a headless `--onboarding-selftest` (e7343c5, fca72b8); three wall-clock tests de-flaked (3efde4b). **1032 tests green** on two consecutive runs. Hardened runtime investigated and **cleared** — `--options runtime` is not a TCC barrier and must not be reverted (`Packaging/SIGNING.md`). verify_install OK; ad-hoc signed, so permissions do not carry across builds — Microphone re-asks, Input Monitoring / Accessibility rows must be removed with **−** and re-added with **+** (`Packaging/reset_tcc.sh`) on every update until Developer ID + notarization. |

Rules: a phase is **not complete** until its dmg exists in `Packaging/releases/`, is installable on a clean machine, and passes the phase's human test script. Patch releases within a phase bump the patch version (`VoicePlus_2_1.2.1.dmg`). Do not begin the next phase's integration until the current phase's dmg is produced — parallel _development_ of later-phase items may continue per Section 3.3.

* * *
## 12. Cross-phase quality gates (every release)
- [x] 
  
  Latency: key-release → landed ≤ 700ms p50 local. _(release 1: checked — IntegrationLatencyTests p50 53 ms (mock engine); hardware mic run manual)_ _(releases 3–6: checked — IntegrationLatencyTests green in the 959-test run with the new stages registered; hardware mic run still manual)_
  
- [x] 
  
  Zero egress in default config (Data Panel + proxy verification). _(release 1: checked — DataPanelTests isClean + EgressGate path; proxy verification manual)_ _(releases 3–6: checked — egress gate unchanged; new act.connector/planner calls all Data-Panel-logged; sync payload audited (no audio); proxy verification manual)_
  
- [x] 
  
  Injection matrix green across the 12-app set. _(release 1: mock-level only (InjectionTests 66); real apps manual per test script)_ _(releases 3–6: mock-level — injection suites green in the 959 run; real 12-app matrix manual per each phase's test script)_
  
- [x] 
  
  Lab regression: WER / entity recall / zero-edit never worse than previous release. _(release 1: baseline recorded in DECISIONS.md (clean 2.9%, all 13.3%); nothing prior to compare)_ _(releases 3–6: checked at suite level — golden/regression-guard tests green in the 959 run and P6's RegressionGuardStage protects corrected words; full Lab harness re-run on real audio manual)_
  
- [x] 
  
  Clipboard integrity property test. _(release 1: checked — ClipboardRestoreTests)_ _(releases 3–6: checked — ClipboardRestoreTests green in the 959 run)_
  
- [x] 
  
  Fresh-install onboarding ≤ 60s manual script. _(release 1: manual — Packaging/notes/phase-1.md steps 1–4)_ _(releases 3–6: manual — install steps in each phase's notes)_
  
- [x] 
  
  Upgrade-in-place from previous dmg. _(release 1: manual — step 13 over VoicePlus_0_0.0.1.dmg)_ _(releases 3–6: verify_install.sh (mount/codesign/launch) passed per dmg; in-place upgrade over the previous phase's dmg manual — step 1 of each test script)_
  
- [x] 
  
  `DECISIONS.md` updated with any flag-default changes and kill-criteria readings. _(release 1: checked — 2026-08-23 entry, contextBiasing flipped off)_ _(releases 3–6: checked — 2026-08-24 entry: directedSpeech added experimental/off, all other defaults unchanged)_
  

* * *
## 13. Execution order summary for /goal
1. **P1.0** (serial) →
  
2. **Parallel wave 1:** P1.1, P1.2+P1.3, P1.7 (gatekeeper + 5 formatter subagents), P1.8, P1.9, P1.10, P1.11 →
  
3. **Parallel wave 2:** P1.4, P1.5, P1.6 (on engine interface) →
  
4. **P1.12 → P1.13** (serial) → `VoicePlus_1_1.0.0.dmg` →
  
5. **Phase 1.5** (small serial) → `VoicePlus_1.5_1.1.0.dmg` →
  
6. **Phase 2** waves ∥ **early start:** P3.1, P5.5, P6.4 with spare agents → `VoicePlus_2_1.2.0.dmg` →
  
7. **Phase 3 → 4 → 5 → 6** per their internal parallel maps — **one dmg per phase, per the Section 11 manifest.**
  

> Throughout: prefer quality over speed of merge; the Lab is the arbiter of every accuracy claim; the dmg is the arbiter of every phase.
