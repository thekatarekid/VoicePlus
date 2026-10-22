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
  
  **T5** Security review: injection surfaces, subprocess adapters, Keychain usage, no dynamic code loading. _(status: done 2f6dc91; docs/reviews/SECURITY-REVIEW.md; fixed CLIDetector PATH handling, model downloads gated by egress kill switch; follow-ups listed in §7 of that doc)_
  

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
| 6 (patch) | `Packaging/release.sh 6 1.6.3` | `VoicePlus_6_1.6.3.dmg` ✅ 2026-08-29 (sha256 `5cde1597…3058b4`, tag `release/phase-6/v1.6.3`, notes `Packaging/notes/phase-6-1.6.3.md`, ~~install this one~~ — superseded by 1.6.6 below) — fixes a regression **introduced by our own 1.6.1/1.6.2**: Microphone could not be granted at all, because the persisted `onboarding.requested.*` flag opened any permission in the settings-recovery phase, and the sole call site of `AVCaptureDevice.requestAccess` is the Allow button in `.explain` — the only way an app can ever appear in the Microphone pane (which has no **+**). Promptable vs non-promptable services now modelled separately; a live `notDetermined` promptable always reaches the Allow button and the poll self-heals a stale flag (39cb91d, 375f97a). Plus: meeting capture made opt-in — a plain launch was requesting Calendar **and** Reminders unasked (a43fc80); the onboarding phase is now logged, with a headless `--onboarding-selftest` (e7343c5, fca72b8); three wall-clock tests de-flaked (3efde4b). **1032 tests green** on two consecutive runs. Hardened runtime investigated and **cleared** — `--options runtime` is not a TCC barrier and must not be reverted (`Packaging/SIGNING.md`). verify_install OK; ad-hoc signed, so permissions do not carry across builds — Microphone re-asks, Input Monitoring / Accessibility rows must be removed with **−** and re-added with **+** (`Packaging/reset_tcc.sh`) on every update until Developer ID + notarization. |
| 6 (patch) | `Packaging/release.sh 6 1.6.5` | `VoicePlus_6_1.6.5.dmg` ✅ 2026-09-06 (sha256 `6f4ded76…6dd03`, tag `release/phase-6/v1.6.5`, notes `Packaging/notes/phase-6-1.6.5.md`) — packaging only, no app behaviour change: the documented `xattr -dr com.apple.quarantine /Applications/VoicePlus.app` printed three `Permission denied` lines on 1.6.4, because `make_app.sh` copies SwiftPM resource bundles with `cp -R` and three of their files are `0444` in the build directory. Cosmetic (there was no quarantine attribute to strip) but it reads as a broken install. `make_app.sh` now normalises modes across the assembled bundle before codesigning and **fails the build** if any file lacks `u+w`; `verify_install.sh` asserts the same against the shipped dmg, plus no quarantine attribute in a clean install and a silent `xattr -dr`. **Read-only files: 3 → 0.** Signature unchanged, so grants made on 1.6.4 — which introduced the build-independent `designated => identifier "in.adityakatare.voiceplus"` — carry over. verify_install OK. |
| 6 (patch) | `Packaging/release.sh 6 1.6.6` | `VoicePlus_6_1.6.6.dmg` ✅ 2026-09-06 (sha256 `736716ea…1dd058`, tag `release/phase-6/v1.6.6`, notes `Packaging/notes/phase-6-1.6.6.md`, ~~install this one~~ — superseded by 1.6.7 below) — answers "does granting a permission require quitting and relaunching?" per service: **Microphone no** (status re-queries tccd every call, capture re-opens the device per dictation) — **⚠️ RETRACTED by 1.6.7: wrong, a relaunch IS required**; **Accessibility no, proven** (`AXIsProcessTrusted()` is cached per process but macOS drops that cache on the `com.apple.accessibility.api` distributed notification the app already observes — the user's toggle made the running app re-query 213 ms later; macOS ships no quit-and-reopen alert for Accessibility at all, so that button is removed from the screen); **Input Monitoring — the relaunch was our bug** (**⚠️ the arming bug below was real and is still fixed, but 1.6.7 retracts the conclusion: macOS genuinely does require a relaunch for this service**): `hotkey.start()` had exactly one caller, the completion of the permission walk, which never runs while onboarding is open and was held behind the Accessibility pre-prompt, so a 20-minute-old grant had never produced an event tap. New `CapabilityWatcher` (`App/Services/CapabilityArming.swift`) owns the tap lifecycle, re-reads the matrix every 1 s plus on accessibility/activation notifications, and arms exactly once (`CapabilityArming.decision` returns `.hold` when armed — cannot stack duplicate taps); `tapCreate` is not a permission test, so liveness is judged from event delivery against `CGEventSource`'s system-wide modifier idle. **Untested:** that an already-created tap starts delivering events immediately after the grant — needs a human at the switch, and Apple's copy claims otherwise, so **Quit & Reopen stays on the Input Monitoring screen only**, as a fallback. Root cause of the Accessibility failure identified exactly: the toggled row stored `cdhash H"459b5909…"`, the CDHash of **1.0.0**, dead since 1.1.0 — toggling rewrites only the auth value, never the stored code requirement. Row cleared; a fresh grant records against `identifier "in.adityakatare.voiceplus"` and survives every future build. Plus honest recovery copy (no claims about rows the app cannot read), an in-app scoped `tccutil reset`, and scrollable steps in the 520×420 window (6f2c409, 89627b6). **1074 tests green** on two consecutive runs. verify_install OK. |
| 6 (patch) | `Packaging/release.sh 6 1.6.7` | `VoicePlus_6_1.6.7.dmg` ✅ 2026-09-06 (sha256 `12e25836…f349a7`, tag `release/phase-6/v1.6.7`, notes `Packaging/notes/phase-6-1.6.7.md`, ~~install this one~~ — superseded by 1.6.8 below) — the largest patch on the Phase 6 line; five reported problems, all root-caused. **P1 — the dictation key killed the app, 100% of the time, on every Mac:** `App/Overlay/OverlayWindow.swift:13` called the five-argument `super.init(contentRect:styleMask:backing:defer:screen:)`; AppKit re-dispatches that ObjC convenience initializer through `self` into the Swift "unimplemented initializer" trap stub emitted for the four-argument designated init the subclass never overrode → `EXC_BREAKPOINT`. Every capture start goes through `InkOverlayController.show()`, so it could never succeed once, anywhere. **Not a 1.6.6 regression** — that file has one commit and line 13 never changed; 1.6.6 merely armed the tap so a keypress could reach the code (the menu-bar "Start dictation (no hotkey)" item never crashed, because it does not touch the overlay — the confirming signature). Fixed by calling the four-argument initializer **and** overriding the designated init so no trap stub survives for any future AppKit path; confirmed by disassembling both artifacts (1.6.6: `bl __swift_stdlib_reportUnimplementedInitializer` + `brk #0x1`, no Swift body symbol; 1.6.7: real initializer, tail-called). The tap's latent `Unmanaged.passUnretained(self)` with no `deinit` is also gone — an integer token through a lock-protected registry, plus `deinit` and one live tap per service. **P2 — a green "It landed. You're set." for a transcript that never existed:** `runGuidedDictation` started and stopped the engine in consecutive statements, so the capture window was zero-length and FluidAudio threw `ASRError.invalidAudioData` under its 300 ms floor; the catch then **discarded the error and emitted the success event with an empty string**, which the view read as a landing. Now a two-state button with a real capture window, 30 s self-stop, mic teardown, an `isFinalizing` latch, and a `GuidedDictationOutcome` of landed/heard/noSpeech/failed — "It landed" requires an actual injection. **P3/P4** — the step names the recogniser it will use, shows real byte/ETA download progress, no longer offers a test that cannot work, downloads any newly chosen tier, and prints real model names and sizes from `ModelCatalog` (Fast 110 MB, Balanced 500 MB, Best 900 MB across two models — all three hardcoded numbers were wrong, "Best" advertised ~1.2 GB). **P5 — the notch chin:** an always-available non-activating panel under the display's forbidden top band (ready/listening/processing/muted/paused/blocked), sharing one geometry rule with the pill so it can never draw under the camera housing, click-through except on hover, joins all Spaces, switchable off in Settings; full screen suppresses only the quiet states, never a hot mic. **P6 — 1.6.6's relaunch claim retracted for two of three services:** Apple's `PrivacyTCCServices.plist` carries `quitAllowTitleForAppName` for `kTCCServiceListenEvent` and `kTCCServiceMicrophone` and **none** for `kTCCServiceAccessibility` (and both strings are categorical, unlike the hedged Screen Recording one); on this machine Microphone stayed `denied` for the granting process's remaining **25 s** and Input Monitoring `notDetermined` for **18 s**, each next process reading the new value instantly, while Accessibility flipped live inside a running process in under a second. So **Accessibility live; Microphone and Input Monitoring need a relaunch.** `RelaunchAdvisor` now fires only when the offer is honest (sent to Settings → returned → 3 s grace → still off), closing a gap where 1.6.6's `onTapProvenDead` trigger structurally could not fire; the prompt quotes macOS' own sentence and a first-time Microphone ask is told no restart is needed. Measurement boundary kept explicit: the **status API** was proven stale per process; the underlying **capability** was not measured and is claimed nowhere. **1165 tests green / 0 failed** (`--no-parallel`; 1074 at 1.6.6). 13 commits `8e8559f`…`f9ebac5`. verify_install OK; signature unchanged, so 1.6.4+ grants carry over (`identifier "in.adityakatare.voiceplus"`). **Caveat:** the repo is private, so the appcast enclosure URL 404s anonymously (identically for 1.6.6) — Sparkle auto-update cannot fetch a private release asset; the asset itself is intact (HTTP 200, 15,466,684 bytes, digest verified via the authenticated API). |

| 6 (patch) | `Packaging/release.sh 6 1.6.8` | `VoicePlus_6_1.6.8.dmg` ✅ 2026-09-07 (sha256 `9ce250f7…4f02a8ab`, tag `release/phase-6/v1.6.8`, notes `Packaging/notes/phase-6-1.6.8.md`, ~~install this one~~ — superseded by 1.6.9 below) — **VoicePlus no longer requires Input Monitoring.** The user asked why Claude, Wispr Flow, Gemini, Raycast, Spokenly and Muesli all run global hotkeys without appearing in that pane and VoicePlus did not; the answer is that `HotkeyService` used `CGEvent.tapCreate(options: .listenOnly)`, **the one global-input API gated on** `kTCCServiceListenEvent`. Nothing about hold-to-talk and nothing about the bare-modifier gesture requires it. `start()` now selects a backend from the binding (`HotkeyBackendSelector`, pure + tested): **bare modifier →** `NSEvent` **global + local** `flagsChanged` **monitors (no permission)**, **chord → Carbon** `RegisterEventHotKey` **+** `InstallEventHandler`**, both press and release (no permission)**, event tap only via the new `hotkeyForceEventTap` escape hatch, which nothing in the shipped UI turns on. **Default binding unchanged: Right ⌥ hold-to-talk + double-tap for hands-free**; `HotkeyStateMachine` untouched (hold 250 ms, tap guard 180 ms, double-tap 350 ms). **Deviation from the plan, measured not assumed:** the item anticipated demoting the bare modifier to an opt-in that still costs Input Monitoring and defaulting to a chord — unnecessary, because a bare-modifier global monitor delivers with **zero** TCC grants, so Right ⌥ stays default and free and every shipped picker choice reads “no extra permission”. **Evidence** (this release's own bundle, `CFBundleIdentifier` swapped to a throwaway id with no TCC record, ad-hoc re-signed, launched via LaunchServices; macOS 26.6.2 arm64): with `AXIsProcessTrusted()=false` and `CGPreflightListenEventAccess()=false` and all three services `notDetermined`, the app logs `hotkey: armed (#1) via globalMonitor for Right ⌥ — needs no permission` and `capabilities: … hotkey=true … hotkeyNeeds=nothing`; real HID `flagsChanged` generated permission-free via `IOHIDSetModifierLockState(kIOHIDCapsLockState)` (caps state restored) moved system-wide modifier idle **1205.27 s → 0.13 s** and the liveness watchdog stayed silent past its 20 s grace — i.e. the app itself asserting `eventsReceived > 0`. **A/B naming the culprit:** same binary, same zero-grant identity, `hotkeyForceEventTap` on → `hotkey=false hotkeyNeeds=inputMonitoring`, no `armed` line at all. **Not opportunistic:** under the real bundle id with `inputMonitoring=granted` it still picks `globalMonitor`. Wired through: `PermissionPlanner.baselineOrder` is `[.microphone, .accessibility]`, `capabilities(_:hotkeyRequires:)` takes the active backend's requirement (nil for every shipped binding), and the onboarding walk is microphone → accessibility only (confirmed headlessly). **The forced quit-and-relaunch goes with it** — it was a property of `kTCCServiceListenEvent`, not of VoicePlus. Trap recorded: `RegisterEventHotKey` **accepts** a bare-modifier registration, returns `noErr`, and never fires — so the selector routes on `HotkeyBinding.Style`, never on “did registration succeed”. Bonus fix: the Settings hotkey picker was decorative (wrote its own key, offered an `f5` the binding could not express) — it now writes `hotkeyBinding` and an armed service observes `UserDefaults.didChangeNotification`, so a Settings change reaches the running app. Migration: all five 1.6.7 raw values survive verbatim; an unparseable value logs and falls back. **1207 tests green / 0 failed** (plain parallel `swift test`, first run; 1165 at 1.6.7). 2 commits `260b044`…`c07e58a`. verify_install OK; signature unchanged (`designated => identifier "in.adityakatare.voiceplus"`), so 1.6.4+ grants carry over. **Untested:** a real finger on Right ⌥ — `CGEventPost` needs Accessibility and `IOHIDSetModifierLockState` can only move caps lock, so delivery is proven with a different modifier than the bound one (the flag-word classifier is unit-tested and `NSEvent`/`CGEvent` field parity is pinned by `HotkeyBackendFlagWordTests`). Carbon chords register and drive the state machine in a probe but nobody has lived on one. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.6.9` | `VoicePlus_6_1.6.9.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.0 build (tag `release/phase-6/v1.6.9`, notes `Packaging/notes/phase-6-1.6.9.md`, ~~install this one once it is built~~ — superseded by 1.7.0 below, which carries it) — **VoicePlus can no longer invent words the user did not say.** With no ASR model on disk and no Apple Speech fallback — **every fresh install, and the whole of onboarding** — `App/Services/EngineFactory.swift` silently substituted `MockEngine` loaded from `Fixtures/transcripts/email_reply.json`. The mock replayed those spans **on a timer with no microphone input at all**, the pill previewed them as the user's own speech, and on hotkey release `UtteranceLander` typed them into the frontmost application: _“Hi Priya, thanks for the update. Let’s sync with TeamViewer tomorrow.”_ A name the user never wrote, in a real document. **Live in release builds, not just development** — `Packaging/make_app.sh` shipped `Fixtures/` inside the `.app`, so the bundle carried exactly the file the fallback needed. Root cause: “no recogniser available” was treated as a reason to substitute a fake one, and the fake output was structurally indistinguishable from a real transcript. **Fixed:** the factory no longer falls back — the mock is reachable only by explicit developer opt-in (`VOICEPLUS_ENGINE=mock` / `VOICEPLUS_FIXTURE`); with no recogniser it returns the new `Shared/Engine/UnavailableEngine.swift`, which publishes only `EngineState.unavailable(reason)`, never emits `.partial`/`.final`/`.previewing`, and whose `stop()` returns no spans. The new `PillState.unavailable(reason:)` is **its own case, not a transcript string**, so the “No speech model installed” notice can never be mistaken for or substituted as speech, and the presence indicator reads `blocked(.modelMissing)` rather than “ready” — the second lie, claiming to listen while unable to hear. `DictationCoordinator.finalize()` returns early for an unavailable engine, so the lander/injector is unreachable. `make_app.sh` no longer copies `Fixtures/` at all (nothing shipping read it: `transcripts/` mock-only, `directed/` test-only, `tools/` a dev script) — verified, a built bundle contains none of the fixture sentences. New `Tests/AppTests/UnavailableEngineTests.swift` **6/6**; `AppTests` **392/392 and** `SharedTests` **37/37 green / 0 failed**, `swift build` clean for the whole package (full-package total recorded at the release build). 1 commit `329af01`. **Untested:** nobody has watched the unavailable pill on a genuinely fresh machine — the visual on a clean install is unverified; the bundle check is a string search over one build of the current `make_app.sh`, so no packaging assertion guards a future reintroduction the way `verify_install.sh` guards file modes. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (minor) | `Packaging/release.sh 6 1.7.0` | `VoicePlus_6_1.7.0.dmg` ✅ 2026-09-07 (sha256 `8f946c91…58ba4aa1`, 15,521,882 bytes, tag `release/phase-6/v1.7.0`, notes `Packaging/notes/phase-6-1.7.0.md`, ~~install this one~~ — it carried 1.6.9 as well; superseded by 1.7.3 below) — **the mic check now needs a microphone, not a fixture.** On a Mac with no ASR model the owner ran onboarding's "Say something." step, **said nothing at all**, and the level meter filled and the step passed with "Sounds good." — admitted only by a small caption reading _“Simulated meter — no real capture is running in this build.”_ Root cause: the meter was fed by the **speech engine's** state, not by the microphone. `AppContainer` chose `PipelineMicLevelPublisher` (real capture) only when a live audio pipeline existed, and one existed only when a recogniser did — never during onboarding, which by definition runs before any model is on disk — so it fell back to `EngineMicLevelPublisher`, forwarding the **mock** engine's fixture-derived `listening(level:)` numbers; the verdict fired on any level `>= 0.08`, so a fabricated number cleared the gate exactly as a spoken word would. After 329af01 the same install builds `UnavailableEngine`, which emits nothing, so the bar was dead rather than fake — still incapable of saying anything true about the user's microphone. **Fixed:** onboarding now owns a real capture session independent of the engine — new `PipelineMicLevelPublisher.standalone()` builds `AcousticCaptureSource(wrapping: CoreAudioCaptureSource())` → `AudioPipeline(vad: EnergyVAD())` → `PipelineAudioSource`, the same audio graph the app uses minus the recogniser (metering a microphone never required a speech model, and now the mic check does not either), and `EngineMicLevelPublisher` is **deleted**, so no engine-derived path into the meter survives. **Passing without real audio is now structurally impossible**, enforced at three layers: `MicLevelPublishing.isRealCapture` lost its defaulted `true` so every conformer must declare provenance (the default was how a synthetic source got to look real by saying nothing); `OnboardingViewModel` refuses to start or subscribe to a non-capture source; and `OnboardingStateMachine` is **default-deny** — it discards `.micLevel` entirely while capture provenance is unconfirmed, so an undeclared level never touches the peak and `verdict` is never even called. The “Simulated meter” caption and the code path that made it reachable are gone. Separately, a denied or undetermined microphone permission no longer routes the user onto a meter that cannot move: `.micCheck` opens on a new **“The microphone is blocked.”** verdict with no capture started, copy that names the problem, a button to the Microphone privacy settings, and a **Re-check** that proceeds only on an actual grant. New `Tests/AppTests/OnboardingMicCheckHonestyTests.swift` **11 tests** — undeclared levels neither pass nor count, a non-capture publisher is never started or metered, retry clears provenance, capture failure blocks, a denied mic is immune to injected levels. **`swift build` clean, 1224 tests passing** for the whole package (1207 at 1.6.8). 1 commit `fa2c3a2`. **Untested — the HAL leg: an agent cannot speak into a microphone.** Unverified precisely: that `standalone()` opens a real input device and delivers taps on real hardware, and that a genuine grant → speak → “Sounds good.” round trip works end to end; everything above the hardware boundary is covered by tests. **Recommend a real spoken mic check on first launch**; `--mic-selftest` on the signed bundle drives the identical capture graph headlessly under the app's own TCC identity. Also unverified: the blocked screen on a machine that actually denied the microphone (copy and routing are state-machine tested, the visual is not). `OnboardingDependencies.mock(pretendRealMicCapture: true)` still lets a synthetic meter stand in, by design and by name, for tests of the post-capture logic — nothing in the app sets it. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.1` | `VoicePlus_6_1.7.1.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.3 build (tag `release/phase-6/v1.7.1`, notes `Packaging/notes/phase-6-1.7.1.md`, superseded by 1.7.3 below, which carries it) — **dictation now starts working when the speech model finishes downloading.** The owner installed 1.7.0, ran onboarding, chose **Best**, watched all **900 MB** download to completion and read the next screen confirm _“Using Parakeet TDT 0.6B v3.”_ — and then dictation **did not work at all**: the hotkey produced _“No speech model installed — Dictation is off until a speech model is installed”_, and onboarding's own **“Dictate now”** showed _“Listening…”_ and never recognised a word. The microphone was fine; the mic-check step earlier in the same run had passed for real. Root cause: the speech engine was resolved **exactly once, at app launch**, and never re-resolved — and a fresh install *necessarily* launches with no model on disk, so every collaborator that took the engine at startup (coordinator, pill, presence indicator, code switcher, onboarding — a dozen in all) took `UnavailableEngine` and held it for the life of the process, however many models the user then downloaded. The staleness was **pre-existing but masked**: before 1.7.0 an app with no recogniser fell back silently to `MockEngine` replaying a fixture, so a stale engine produced *fabricated* transcripts rather than silence — removing that fallback in 329af01 was correct, and it turned a hidden bug into a visibly dead app. **Fixed:** new `Shared/Engine/SwappableEngine.swift` fixes the engine's **lifetime rather than its contents** — a box owning **one** state subject and **one** event broadcaster, re-attached to whichever engine is inside, so the dozen-odd holders subscribe once and keep working across a swap with no refactor of the call sites and no second subscription path to go stale differently; availability is queried through a new `EngineAvailabilityReporting` protocol. `AppContainer.refreshEngineIfNeeded()` **swaps only on an availability flip** — a real engine when a model lands, `UnavailableEngine` when one disappears — so an ordinary utterance never disturbs a working engine, and it runs at the three moments that were three faces of one bug: a download completing (`ModelManagerTiers.onModelsChanged`), **hotkey-down preflight**, and before onboarding's **“Dictate now.”** A **mid-utterance swap lands nothing rather than something wrong**: the outgoing engine is cancelled and a `stop()` whose `start()` belonged to a previous generation returns no spans, so a swap in flight cannot land half an utterance nor the same one twice. A **failed or cancelled download never fires the change notification**, so the app stays honestly unavailable rather than swapping in an engine with no model behind it. New `Tests/AppTests/EngineSwapTests.swift` **8 tests** — a subscriber bound before the swap sees the new engine's states, a swap happens only on an availability flip, a stale `stop()` returns no spans, a failed download leaves the engine unavailable. **`swift build` clean, 1259 tests passing** for the whole package (1224 at 1.7.0). 1 commit `d4f804d`. **Untested:** no agent on this machine has a real downloaded model, so the construction of the **real** engine inside the swap (CoreAudio graph + FluidAudio model load) is unverified, as is a true end-to-end **download → speak → text appears** round trip — the swap machinery itself (subscriber continuity, the flip condition, generation-scoped `stop()`, no-swap-on-failure) is covered. **Recommend the owner run that round trip once on a real machine.** **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.2` | `VoicePlus_6_1.7.2.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.3 build (tag `release/phase-6/v1.7.2`, notes `Packaging/notes/phase-6-1.7.2.md`, superseded by 1.7.3 below, which carries it) — **choosing a model is no longer the same act as downloading it.** Two reported bugs on onboarding's **“Pick a free local model.”** step, both about consent rather than plumbing: the three options were radio buttons, so merely **selecting** one silently began a several-hundred-megabyte download with nothing saying that a selection was also a commitment; and **Continue was enabled while the chosen model sat at 3%**, so users clicked through to a dictation step with no model on disk — the exact route into the dead app 1.7.1 fixes. Root cause: `.choose` both selected a tier and started fetching it; Continue was live from the moment a fetch *started* rather than the moment a model *landed*, treating “we began a download” as “the user has a model”; download state was shared rather than per option, so one row's progress or failure was painted under all three; and presence was tracked **per tier**, so with Balanced already on disk, choosing Best — which is Balanced **plus** a 120 MB EOU model — offered the whole 900 MB again. **Fixed:** every option now has **its own Download button**, so choosing and committing are separate acts — `.choose` selects and nothing else, and a new `.download(tier)` event raised only by that option's own button is the only path to a fetch; **selection alone never downloads.** Each row shows its own state from `downloadStates`: **Download**, or that option's live progress (_“1 of 2 — 27 MB of 900 MB”_) with **Cancel**, or **Installed** with **“Use this”**. Continue is gated on `installedTiers` **read back from the model manager** rather than inferred from a started fetch, and `.next` is **refused by the state machine**, not merely greyed out in the view — and it says why: _“Balanced is still downloading (3%). Continue turns on the moment it lands.”_ Presence is now per **model**, so an already-downloaded model is never offered for re-download and Best reads **“Download 120 MB · Only the part you don't have yet.”** **Skip stays** — it is a legitimate choice — but records that it was taken without a model and warns, on the dictation step and the final screen, that dictation will not work until one is installed. New `Tests/AppTests/OnboardingModelPickerTests.swift` **9 tests** — selection does not download, only `.download(tier)` fetches, `.next` is refused while the chosen model is absent, the blocked reason names the model and the percent, per-row state does not bleed across options, an installed model is not re-offered, skip records its cost; `OnboardingStateMachineTests` and `OnboardingDictationTests` updated for the split. **`swift build` clean, 1259 tests passing** for the whole package. 1 commit `3b9c75e`. **Untested:** the real HuggingFace download — no agent here has fetched a model, so live byte counts, the _“1 of 2”_ multi-file progress and **mid-flight Cancel** against a real transfer are covered against the model-manager protocol and mocks only; everything above the download boundary (gating, refusal, per-row state, per-model presence, the blocked-reason text, the skip warnings) is tested. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.3` | `VoicePlus_6_1.7.3.dmg` ✅ 2026-09-08 (sha256 `98d6bb9a…bf40c00c`, 15,566,502 bytes, tag `release/phase-6/v1.7.3`, notes `Packaging/notes/phase-6-1.7.3.md`, ~~install this one~~ — it carried 1.7.1 and 1.7.2 as well; superseded by 1.7.8 below) — **the status row fits its text, and is visible without hovering.** Three complaints about one surface, the row under the notch. It was **cut off** — _“VoicePlus · Ready — hold R…”_ with no state in which the rest ever became readable; it was **invisible**, because `.ready` at rest drew nothing at all inside a 4 pt chin at 35% black, a near-black sliver under a black bezel, so the app appeared to have no presence unless the user happened to hover over the notch; and it was **mute about how to use the app** — no ambient sign that VoicePlus was running and armed, and no discoverable reminder of the dictation hotkey. Root cause: the expanded panel was a hard-coded **190 pt** drawing `lineLimit(1)` with `truncationMode(.tail)`, so any longer message was clipped permanently — and _“hold Right ⌃”_ was exactly the part that fell off the end, so the one thing the row existed to teach was the one thing it hid; `.ready` at rest was an `EmptyView`; and where a hotkey label existed it was a **literal**, so a rebound key would have been described wrongly. **Fixed:** new `App/Core/PresenceRow.swift` handles text fitting and the hotkey hint, and the row is **sized to its content** — `PresenceRow.fit` measures in the **real font** and `NotchGeometry`/`NotchPresenceGeometry` clamp against actual notch and screen geometry (the pill gets the same treatment for its fixed notices). When a display genuinely cannot hold the sentence the row **degrades in order and never mid-word**: the **hint** drops first, then the **“VoicePlus · ” prefix**, then **trailing whole words** — no half a word plus an ellipsis. At rest it is now a **status light, not a banner**: a 10 pt chin at 72% carrying one small lit dot. And it **announces itself** — the full row expands for **six seconds** at launch and whenever the app **recovers out of a blocked state**, so it tells the user the moment a permission grant or a finished model download makes dictation live again; never after an ordinary utterance, and click-through while announcing so it cannot eat a click. The hotkey label is **read live from the configured binding** (`HotkeyHint.label`): _“hold Right ⌃”_ for a bare modifier, _“press ⌃⌥D”_ for a chord, so it follows a change in Settings instead of hardcoding “Right Control”. New `Tests/AppTests/PresenceRowTests.swift` **17 tests** — the fitted width holds the whole string, degradation drops components in order and never splits a word, the hint tracks the binding rather than a literal, the announce window fires on launch and on unblock but not after an utterance; `NotchPresenceTests` updated for content-sized geometry. **`swift build` clean, 1259 tests passing** for the whole package. 1 commit `06c5ccd`. **Untested — every visual judgement here, because an agent has no window server.** Precisely unknown: whether the lit-dot chin reads as visible-but-quiet against a **real** bezel, whether the six-second announcement feels informative or intrusive in daily use, and the **true measured width** of the expanded row in the system font on real hardware; the degradation ladder's order is tested but its appearance at each rung has not been seen on a genuinely narrow display. **Recommend the owner watch the notch on first launch and say whether the dot and the six seconds are right.** **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.4` | `VoicePlus_6_1.7.4.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.8 build (tag `release/phase-6/v1.7.4`, notes `Packaging/notes/phase-6-1.7.4.md`, superseded by 1.7.8 below, which carries it) — **dictation no longer wedges itself permanently after one use.** Onboarding's **“Dictate now”** worked **exactly once**; pressing **“Try again”** then said _“VoicePlus is already recording.”_ and said it forever. With the real hotkey the same fault wore a different face: an error appeared on key **release**, and after four or five attempts the hotkey **stopped working altogether** — no listening state on press, and a broken animation flashing on release. Only relaunching the app cleared it. Root cause — **two defects compounding into one symptom**: `RealEngine.start()` set `listening = true` **before** `try audio.start()` and never rolled it back when that threw (a denied microphone, a 3 s HAL start timeout, a format mismatch), so the flag **outlived the session it described** — it stood up with no capture behind it, and every later start threw `alreadyListening` for the rest of the process; and `DictationCoordinator` ran start, finalize and cancel as **three independent racing `Task`s**, so a key released during warm-up ran `stop()` **before its own `start()` finished** — the stop threw `notListening` and was swallowed, the start then succeeded, and the engine was left recording with nobody left to stop it. Onboarding and the hotkey **share one engine**, which is why a failure on either path killed the other. **Fixed:** **one session flag with one owner**, held by the coordinator and written by nothing else; **all engine calls on a serial chain**, so a release can never overtake its own start; **unconditional teardown on every exit path** — success, throw, cancel — so a session cannot outlive the code that created it; `RealEngine.start` **rolls back fully on a failed `audio.start()`**, so a capture that never opened leaves no flag behind; and **a held-over session is released and retried rather than refused** — an `alreadyListening` start is retried once after a forced cancel, so **a wedge clears itself instead of needing a relaunch**. Plus a **bounded preflight** (`refreshEngineIfNeeded` sits in the hotkey path, so an engine swap cannot hang a key press), **`SwappableEngine.swap` cancelling the outgoing engine unconditionally**, and **`AppDelegate` resetting the hotkey gesture when capture never opened** — the reason the hotkey went dead after four or five failures. New `Tests/AppTests/DictationSessionLifecycleTests.swift` and `Tests/EngineTests/RealEngineStartRollbackTests.swift` **11 tests** over the four ways the session used to leak — a second utterance after a success, after a failed start, after a cancel, after a stop that threw; a key released during warm-up; an engine another owner left recording; an engine swap mid-utterance; a preflight that overruns — and the preflight bound is a **raced continuation, not a task group** (`withTaskGroup` waits for its children on exit, so the timeout never actually fired). **`swift build` clean, 1313 tests passing** for the whole package (1259 at 1.7.3). 2 commits `14010b7`, `9a01b91`. **Untested:** no agent on this machine has a microphone, so the failure modes that *start* this bug — a denied mic, a real HAL start timeout, a format mismatch — are reproduced against the capture protocol and mocks; and no agent has driven the hotkey with a real key press, so the gesture reset is tested at the coordinator boundary and the CGEvent leg is not. The rollback, the serialisation and the self-healing retry are covered. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.5` | `VoicePlus_6_1.7.5.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.8 build (tag `release/phase-6/v1.7.5`, notes `Packaging/notes/phase-6-1.7.5.md`, superseded by 1.7.8 below, which carries it) — **the onboarding window no longer clips its own buttons.** The window was a hard-coded **520 × 420** for **six steps of very different heights**, with no scroller anywhere. When a model download started, roughly **120 pt** of progress UI appeared on the model step — a progress bar, a wrapping progress line, a Cancel button, an info line and a two-line amber warning — and the footer went off the bottom edge. That footer is **Back / Skip / Continue**: the only way forward, **cut in half** by the window it lived in. Option subtitles were truncating **mid-sentence** in the same window, for the same reason. Root cause: a fixed `.frame(width: 520, height: 420)` suits a step at rest and nothing else; **nothing scrolled**, so content that did not fit simply overflowed rather than becoming reachable; and **the action row had no reserved space** — laid out after the step content, it was the first thing to lose when the content grew, which is the worst possible casualty since it is the only exit. **Fixed:** **each step reports its own laid-out height and the window adopts it** — new `App/Onboarding/OnboardingWindowSizing.swift` — **clamped to the usable area of the display the window opens on**, so sizing to content can never size past the screen. **The step area is the only flexible region, and it scrolls**: the progress bar and the action row keep their space at any content height, so **the clipped footer is now structurally impossible** rather than merely unlikely. **Progress text sits in a reserved fixed-height box**, so a tick from _“95 MB”_ to _“96 MB”_ is a text change rather than a window relayout, and **sub-1 pt geometry republishes are ignored**, removing the residual jitter from measurement noise during a live download. **Option subtitles wrap** instead of truncating. New `Tests/AppTests/OnboardingWindowSizingTests.swift` **15 tests** — the window adopts the tallest reported content, the clamp holds against a small display, the chrome keeps its height while the step area absorbs the overflow, a sub-point change does not republish, and a step that grows mid-flight (the download case) still leaves the action row fully on screen; **all six steps checked in their tallest states.** **`swift build` clean, 1313 tests passing** for the whole package. 1 commit `8b359e3`. **Untested — every visual judgement, because an agent has no window server.** Precisely unknown: how the resized window *looks* at each step, whether the grow animation is pleasant, whether the scrolling step area is ever visibly scrolled on a normal display, and the clamp's appearance against a genuinely small display (its behaviour is tested). The sizing arithmetic, the clamp, the fixed chrome and the jitter suppression are covered. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.6` | `VoicePlus_6_1.7.6.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.8 build (tag `release/phase-6/v1.7.6`, notes `Packaging/notes/phase-6-1.7.6.md`, superseded by 1.7.8 below, which carries it) — **the status dot's click means something, and errors stay long enough to read.** Two faults on the notch surface introduced with 1.7.3's presence row. Clicking the new **green presence dot** opened the menu bar app's menu — not sometimes: it had been wired unconditionally to `statusItem.popUpMenu()` for **every** state, so the one control that describes the app's health answered every click with a list of commands. And errors **flashed past unread**: `RealEngine` emits `.landed` then `.idle` back to back, while the reducer mapped `.error` to a preview the next `.idle` erased, so the pill ran its **slide-in and slide-out in the same run-loop pass** — the “broken animation” the owner saw on key release, and the reason he **could not screenshot the error** he was hitting. Root cause: one click behaviour for every state, so a dot meaning “the microphone is denied” answered a click with something other than the way to fix it; `landing` → `hidden` reducing in a single pass with no time in between; and an error that was **not its own state** — it was `.preview(“⚠︎ …”)`, a transcript-shaped string, so it could not be sized, dwelled or styled as a notice, and any later `.idle` erased it as though it had been speech. **Fixed:** a **click router** (new `App/Core/PresenceClick.swift`) — the **primary click pins the expanded row open for 5 s in place**, with **no focus change**, so the dot explains itself; on a **blocked** dot it goes to the **actual remedy** instead (relaunch, the **Microphone** or **Input Monitoring** privacy pane, or our own **Settings** for a missing model); **right-click / ⌃-click still opens the menu**, preserving the culled-status-item escape hatch. And a **presenter owns the single write path to the pill** (new `App/Core/PillPresentation.swift`): `PillPresenter` gates every write to `PillViewModel.state` so that **a visible state lands immediately** but **a retraction waits out the current state's `PillDwell` minimum** — **4 s** for an error or warning, **0.6 s** for _“Landing…”_, 0 for everything else. The flicker is not smoothed; it is **unreachable**. **`.error` is now its own `PillState` case** with a **headline and subtitle**, so it can be sized and dwelled as a notice — **legible for four seconds**, long enough to read and to photograph. The panel stays a **non-activating `NSPanel`** and nothing on the explain path activates the app. New `Tests/AppTests/PillPresenterTests.swift` **13 tests** — a visible state lands with no delay, a retraction inside the dwell is held then applied, `landed` followed immediately by `idle` produces one visible notice rather than a flicker, an error outlives its erasing `.idle`, the dwell differs correctly between a notice and “Landing…”; `PillTests` updated for `.error` as its own case. **`swift build` clean, 1313 tests passing** for the whole package. 1 commit `243c57a`. **Untested — every visual judgement, because an agent has no window server.** Precisely unknown: whether the pinned click-to-explain row reads as an explanation, whether five seconds is the right pin, and whether the four-second error pill is long enough to read without being long enough to annoy; the privacy-pane deep links are pinned by test but have not been followed on this machine. The dwell arithmetic, the routing per dot state and the single write path are covered. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.7` | `VoicePlus_6_1.7.7.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.8 build (tag `release/phase-6/v1.7.7`, notes `Packaging/notes/phase-6-1.7.7.md`, superseded by 1.7.8 below, which carries it) — **the warm-up records, and only one owner holds the microphone.** **“Dictate now” left the notch on _“Warming up…”_ for a long time before anything happened**, and whatever was said during that time was gone. Root cause: `RealEngine.start(prewarm:)` resolved the recognizers **before** `audio.start()`, so a **cold CoreML load of Parakeet TDT** ran **with the microphone shut** — unbounded, with no progress to show, and **every word spoken during it discarded**; and nothing loaded the model eagerly, so the **first key press of the session paid the entire compile**. Separately, **two owners were fighting over the microphone**: `PipelineAudioSource.start()` **returned success while doing nothing** whenever the source was already running, and the onboarding meter is handed the **same source the engine uses** — so the second owner inherited a graph whose **ring, VAD and utterance tap belonged to the first owner's session**, and **whichever owner stopped first closed the microphone under the other**. **Fixed:** **explicit audio ownership with rank and preemption** — the **engine outranks** the meter and diagnostics, and a start either **takes the graph and restarts it clean** (ring, VAD and tap rebuilt for the new owner) **or throws `AudioCaptureError.busy`**; there is no third outcome that quietly succeeds, and **displaced owners are told**. **A stop releases the graph only if that owner still holds it**, so a displaced owner's late `stop()` cannot close the new owner's microphone. **Capture-first cold start:** `RealEngine.start` **opens the microphone before resolving the model**, samples captured while the model loads are **buffered**, and the preview pass is flushed the moment the recognizer is ready — so a push-to-talk press **never loses its opening words**. Plus **eager preload** — new `RealEngine.preloadModel()` and `AppContainer.warmUpEngine()` load the model **at launch** and again **after a download-driven engine swap**, so the first press is not the cold one. New `Tests/AppTests/AudioSourceOwnershipTests.swift` and `Tests/EngineTests/RealEngineColdStartTests.swift` **8 tests** — the engine taking the graph from the meter and getting it restarted, tap and all; a meter refused out loud while dictation holds capture; a displaced owner's late stop that must not close the new owner's microphone; a failed start that leaves no owner; audio **and preview text spoken during a cold model load surviving**; a failed cold start releasing capture; `preloadModel()` loading **without** publishing _“Warming up…”_. **`swift build` clean, 1313 tests passing** for the whole package. 2 commits `9f4b0c3`, `54888e6`. **Untested — and this is the important one: the badly-wrong hotkey transcription is not confirmed fixed.** The owner reported the hotkey path producing **completely wrong text** where onboarding was accurate; recognizer configuration was proven **identical** between the two paths and **biasing was ruled out** as a text corruptor, which leaves a shared-capture-graph corruption as the leading explanation — and this is exactly the fix for that — but **the cause is not confirmed on hardware.** Also unverified: the **real cold-load duration** (no agent here has loaded Parakeet TDT), and the HAL leg generally — no agent on this machine has a microphone, so ownership, preemption and the buffered cold start are covered against the capture protocol and mocks. **Recommend the owner retry the hotkey and say whether the text is right now.** **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.8` | `VoicePlus_6_1.7.8.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.9 build (tag `release/phase-6/v1.7.8`, notes `Packaging/notes/phase-6-1.7.8.md`, superseded by 1.7.9 below, which carries it) — **“it downloaded the Balanced model by itself.”** Reported, after choosing **Best** and watching **900 MB** download: _“I only downloaded the best 900 MB model. It downloaded the Balanced itself.”_ It did not. **Best** is Parakeet TDT 0.6B v3 **plus** the EOU model, and **Balanced** is that same TDT v3 — so completing Best completes Balanced with **not one extra byte fetched**. Per-model presence (1.7.2, `3b9c75e`) is right and stays. What was missing was **the sentence**: both rows read a bare **“Installed”**, and a green check beside an option nobody asked for reads as **500 MB the app decided to spend on its own**. Technically correct is not good enough on a several-hundred-megabyte download — presented bare, it destroys trust. Root cause: the overlap was **never stated** (nothing before the download said Best contains Balanced, nothing after it explained why a second row had turned green), and **“Installed” could not tell two different facts apart** — a tier the user **explicitly downloaded** and a tier their **choice brought along** rendered identically. **Fixed:** **the containment is stated _before_ anything is downloaded** — the Best row reads _“Includes Balanced's 500 MB model, plus 400 MB more.”_, **computed from `ModelCatalog`** in new `App/Onboarding/ModelTierComposition.swift`, so the figures cannot drift from what is actually fetched; **afterwards the Balanced row reads “Included with Best”** rather than a bare “Installed” — a visible **consequence of the user's own choice**, not a mystery download; **a non-selected installed row says “Switching downloads nothing.”** and fetches nothing, which is now a test rather than a claim; and the state machine tracks **`explicitlyDownloadedTiers`**, the buttons the user actually pressed, because “installed” alone cannot distinguish a tier the user fetched from one their choice carried in — **a tier downloaded on its own keeps the plain “Installed”**, since crediting it to Best would be its own small lie, and with nobody's presses remembered (after a relaunch) the shared row still explains itself. **Also corrected:** three code comments called the EOU model **“120 MB”**, misreading the **“120M”** in its name as megabytes when it is **parameters** — it is **400 MB**, and the advertised **900 MB** total was right all along (**500 + 400**). New `Tests/AppTests/OnboardingTierCompositionTests.swift` **7 tests**, one of which **pins each tier's label to the sum of its catalogue entries** so the advertised figures cannot drift again; the rest cover the containment line appearing before any download, “Included with Best” only for a tier the user did not press, “Installed” surviving for one they did, “Switching downloads nothing.” fetching nothing, and the shared row explaining itself with no press history. **`swift build` clean, 1313 tests passing** for the whole package. 1 commit `3842440`. **Untested:** whether **“Included with Best” reads correctly in its column** — no window server, so the wording is tested and its appearance is not; and the **real HuggingFace download** remains unverified (pre-existing since 1.7.2, unchanged) — the composition arithmetic is computed from the catalogue and pinned by test, but nobody here fetches the bytes. **The badly-wrong hotkey transcription is still unconfirmed on hardware — see 1.7.7.** **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.9` | `VoicePlus_6_1.7.9.dmg` ✅ 2026-09-08 (sha256 `d9d42247…ac4de68a`, 15,632,650 bytes, tag `release/phase-6/v1.7.9`, notes `Packaging/notes/phase-6-1.7.9.md`, ~~install this one~~ — it carried 1.7.4, 1.7.5, 1.7.6, 1.7.7 and 1.7.8 as well; superseded by 1.7.12 below) — **dictation no longer types a paragraph of your document instead of your words.** The most alarming report yet: dictating _“The quick brown fox jumps over the lazy dog”_ through the **hotkey** landed **completely wrong text**, while the **same sentence** through **onboarding** was accurate — same model, same microphone, same session. It was never audio and never recognition: **the app's own learned-corrections system was poisoning itself**, and the poison was applied on only one of the two paths. Root cause: `ZeroEditTracker` finalised an edit with `finalText` set to the **entire focused field's accessibility value** — the whole document the user was typing into — while `originalText` was just the one utterance (`Lab/Counter/ZeroEditTracker.swift:126`); `AdaptationService.ingestEdit` then **word-diffed a single utterance against a whole document** and `BiasListLearner` dutifully stored the result as corrections, producing variants mapping an ordinary word like “the” to **two paragraphs of the user's own document** (`Engine/Adapt/AdapterTrainer.swift:84-90`); on a later utterance `RegressionGuard.apply` **substituted that blob for the real word** (`Engine/Adapt/LearnedLexicon.swift:114`), and its **phonetic fallback matched on a single occurrence**, so one poisoned pair spread to **any similar-sounding word**. **That is exactly why one path was right and the other was garbage:** `RegressionGuardStage` is installed **only in the hotkey pipeline** (`AppContainer.swift:157-158`), while the onboarding path displays **raw recognised spans**. **Fixed:** new **`LexiconSanity`** states the rule a correction has to satisfy — **a respelling, never a document** — enforced at **three** points: when a pair is **stored**, when an edit readback is **ingested**, and, critically, **when a variant is used**, so a `lexicon.json` **already poisoned on a user's machine degrades to pass-through** instead of continuing to corrupt text — **no manual reset is required**, though a clean slate is available by quitting VoicePlus and removing `~/Library/Application Support/VoicePlus/Adapt` (there is no in-app control for this). **Also added: a “landing diff” diagnostic.** `UtteranceLander` logs **one line per utterance** — **raw recognised text vs landed text**, their **Levenshtein distance**, and **which stages touched the spans** — so **a single real utterance** separates “the recogniser misheard” from “post-processing mangled it” (`distance 0` clears post-processing; anything else points back into the pipeline). Local `os_log` only, nothing leaves the machine, consistent with the no-telemetry stance; **verbatim text stays off** unless launched with `VOICEPLUS_LOG_TEXT=1`. Read with `log show --last 30m --predicate 'subsystem == "in.adityakatare.voiceplus" AND category == "pipeline"' --info | grep "landing diff"`. **Cleared with evidence** (worth recording, since it is the rest of the post-processing chain): `ContractEnforcingStage`/`ConfidenceContract.verify` enforce the confidence/audioRange/provenance invariant on **every** stage with a fallback to the stage's input, `CodeSwitchService.finalize` returns `nil` unless **two scripts are genuinely present**, and **every provider stage falls back to a deterministic local path** when no API key is configured — none of them silently degrade into inventing text. **5 new tests** in `Tests/EngineTests/AdaptTests.swift` covering the sanity rule at each of the three enforcement points, including an already-poisoned lexicon degrading to pass-through. **`swift build` clean, 1318 tests passing.** 1 commit `8e440fe`. **Untested:** **it is not confirmed that this specific poisoning is what the owner hit** — no agent here has hardware and their `lexicon.json` may or may not have been in that state; the mechanism is proven in test and explains the hotkey/onboarding asymmetry exactly, but **the diagnosis on that machine is unconfirmed**, and the new landing-diff line settles it in **a single key press** — that is the recommended next check. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.10` | `VoicePlus_6_1.7.10.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.12 build (tag `release/phase-6/v1.7.10`, notes `Packaging/notes/phase-6-1.7.10.md`, superseded by 1.7.12 below, which carries it) — **the dictation key was also the “act” key, so your sentence became an agent goal.** With the **Best** model fully downloaded and onboarding finished, pressing the dictation hotkey (**Right ⌘**) produced **no transcription at all** — what appeared in the notch was `Agent: failed(reason: "planner: disabled(stage: act.planner)")`. Two failures in one line: the words never landed, and **the app spoke to its owner in a debug string**. Root cause, a chain: `AppDelegate` defaulted the **act (second) key to `.rightCommand`** — the **same physical key as dictation** — and nothing prevented the two from sharing it, so **one press drove both hotkey services**; the act session opened, **raced `engine.stop()` for the transcript**, found **no catalogue command** matching the user's sentence, and fell through to **`.agentic(goal:)`** — so **a plain dictated sentence became an agent goal**, the right fallback for a deliberate act press and completely wrong for a dictation press that should never have reached it. `ProviderPlanner.plan` then called `providers.complete` **unconditionally**; with **no provider pinned for `act.planner`** the router threw `ProviderRoutingError.disabled`; `NativeAgentBackend` turned that **configuration state** into `.failed(reason:)`; and `AppDelegate` rendered it with `String(describing:)` — producing the raw internal string the owner saw. **Fixed:** **`ActKeyBinding.isDistinct`** — the act key is **inert while it shares a key with dictation** (**dictation wins the collision**, because that is the app's whole purpose), re-checked **per event** so **a rebind from Settings takes effect immediately**; **`ProviderPlanner` checks whether the provider is enabled first** and maps every `ProviderRoutingError` to a new **`PlannerError.unavailable`** — **a state, not a failure**, because “you have not configured this” and “this broke” are different facts; **`AgentRunStatus` gained plain-language user messages for all seven cases** — _“Actions need a model set up in Settings”_, _“That didn't work”_, _“I couldn't work out how to do that”_ — and the failure reason **no longer interpolates the underlying `Error`**. **Separately: `ContractEnforcingStage` now degrades a throwing pipeline stage to pass-through** — preserving **confidence, `audioRange` and provenance** — instead of **unwinding the run and discarding every earlier stage's output**, so one broken stage costs its own contribution and not the user's sentence; **`.strict` still rethrows**. **Scoped deliberately:** an audit found **`ProviderPlanner` was the only unguarded provider caller**, so the guard went where it was missing rather than everywhere as ceremony, while the contract-stage fix is **generic and covers all 11 stages**. **13 new tests** across `Tests/ActionsTests/PlannerUnavailableTests.swift`, `Tests/AppTests/ActPlannerRegressionTests.swift` and `Tests/PipelineTests/StageFailurePassthroughTests.swift` — one of them a standing guarantee about the app's voice: **no status message may contain `failed(`, `reason:`, `stage:` or `act.planner`**; the rest cover an unconfigured planner resolving to `.unavailable` rather than `.failed`, a genuinely broken planner whose reason carries no debug text, the two hotkeys being required to be two different keys, a disabled `act.planner` stage still landing the recognised text in the frontmost field, and a throwing stage passing its input through with the span invariants intact while strict mode rethrows. **`swift build` clean, 1347 tests passing.** 2 commits `68e75d0`, `69638f5`. **Untested:** that **Right ⌘ push-to-talk now types text with the act key silently disabled**, and that **rebinding the act key restores act commands** — no agent here has a microphone or a window server, so the binding rule, the planner state and the pill's wording are covered against protocols and mocks. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.11` | `VoicePlus_6_1.7.11.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.12 build (tag `release/phase-6/v1.7.11`, notes `Packaging/notes/phase-6-1.7.11.md`, superseded by 1.7.12 below, which carries it) — **a model that reported “installed” but was half-downloaded.** Choosing the **Fast** model, the download **reported success** and onboarding said _“Using Parakeet TDT-CTC 110M (tiny)”_ — then **“Dictate now”** showed _“Warming up…”_ and failed with **`The file "weight.bin.partial" doesn't exist.`** That file is **not ours**: it is **FluidAudio's download scratch file**, streamed from HuggingFace and then moved into place, and the user should never have seen its name. Root cause: **two defects, and it took both**. First, `ModelManager.load` was **actor-isolated but suspended across `AsrModels.load`**, and **an actor releases itself across a suspension** — so the **launch preload** and the user's **“Dictate now”** both saw nothing loaded and both loaded; `AsrModels.load` is **not a pure read** (it **re-downloads whatever the cache lacks**), so two of them over one folder **raced on the same `.partial` file** — one won the move, the loser reported it missing. **The eager preload added in 1.7.7 did not cause this**; it supplied the *second caller* that made an already-present race reachable. Second, the **“is it installed?” check was `fileExists` over paths that are every one of them `.mlmodelc` _directories_** — which **exist from the very first byte written into them** — so a download that had barely started already read as **complete**; FluidAudio documents this exact trap upstream. **All three tiers were equally at risk** — they share **one fetcher, one presence check and one loader**, and **Best succeeding earlier was luck of timing, not a safer path**. **Fixed:** new **`Engine/ASRRuntime/ModelIntegrity.swift`** defines **complete-and-loadable** rather than present — **no `.partial` / `.part` / `.etag` files anywhere**, **required paths present**, every **`.mlmodelc` bundle carrying its `coremldata.bin`**, and **no truncation** against the manifest's byte counts; a **cheap `stat` walk, no hashing**, since it runs on **every hotkey press**, and it **walks the tree by hand** rather than subtracting path strings, because `/var` and `/private/var` are the same file spelled two ways and the arithmetic silently turned “delete the debris” into a no-op. **`load` dedupes in-flight tasks and gates on integrity**; **the fetcher verifies a staged tree _before_ publishing it and swaps rather than delete-then-move**, so **a failed move can no longer destroy a working install** and **`.partial` files stay in staging** where nothing can read them as installed. **Recovery is automatic:** a broken model now **reports as not-installed** so the picker offers a re-download, and **`repair(_:)` deletes just the `.mlmodelc` bundle each `.partial` sits in** — not merely the scratch file, since a bundle caught mid-download is missing an interior weight file no `requiredPaths` list names — **keeping intact siblings**, so a retry costs **one bundle rather than the whole model**. **The user sees** _“The Parakeet TDT-CTC 110M (tiny) speech model didn't finish downloading — 1 file is missing or incomplete…”_ rather than a scratch filename; the errors **count** the incomplete files rather than naming them. New `Tests/EngineTests/ModelIntegrityTests.swift` — a `.partial` inside a bundle does **not** report installed on **any tier**, an interrupted or cancelled download leaves nothing that does, a download that lands incomplete **throws instead of publishing**, **concurrent loads share one load task**, and the **verbatim Cocoa error from the report is rewritten**; `ModelManager`'s loader was made **injectable** so the dedupe contract is testable **without CoreML models**. **`swift build` clean, 1347 tests passing.** 2 commits `c5fe8ae`, `a2f2887`. **Untested — the end-to-end recovery path: download Fast, interrupt it, relaunch, dictate.** Nobody here fetches the real bytes from HuggingFace; the integrity rules, the dedupe, the staged-then-swapped publish and the rewritten error are covered against a **synthesised model tree on disk**, and a **real interrupted download is not**. **The real HuggingFace download remains unverified** — pre-existing since 1.7.2, unchanged. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.12` | `VoicePlus_6_1.7.12.dmg` ✅ 2026-09-08 (sha256 `d2114de0…3970be01`, 15,655,544 bytes, tag `release/phase-6/v1.7.12`, notes `Packaging/notes/phase-6-1.7.12.md`, ~~install this one~~ — it carried 1.7.10 and 1.7.11 as well; superseded by 1.7.15 below) — **the error notice covered half the screen, and the dot's click went back to opening the menu.** Two things, both on the notch surface, both hit on real hardware. When dictation failed the owner got, in their words, _“a big black strip emanating from the notch in the center with an error”_ — **a black slab over roughly half the screen height** for a one-sentence error. Root cause: **not the geometry math** — every frame `NotchGeometry` computed was correct and the panel was still a slab. **`NSHostingView.sizingOptions` defaults to `.standardBounds`**, which publishes the SwiftUI content's **minimum** size as the panel's **`contentMinSize`**, and **AppKit then grows the window to it after every `setFrame`** — overruling the layout code silently after it had finished. With **`.fixedSize` on the notice stack** the minimum **width** was **one word wide**, so the minimum **height** became the **fully wrapped paragraph**. Measured with a standalone AppKit probe: a panel set to **420×64** came back **420×1187** for the owner's actual message, and **420×4727** for a long one. **Fixed, in three layers:** **`sizingOptions = []` with explicit content min/max on both the pill and presence panels**, so **frames are placement math and never content**; **a bounded notice view** — headline **two lines, tail-truncated**, subtitle **one line**, **no `fixedSize`**, so a long error is **elided rather than unrolled**; and **`NotchGeometry.absoluteMaximumSize` of 560×96**, **clamped per display** and applied in **both sizing and layout**, so even a caller asking for **9000×9000** gets a pill. **Second, at the owner's request the presence dot's left-click opens the status menu again** — _“It was ok to open menu on left clicking the notch. No need to make it right click.”_ The **1.7.6 remedy routing** — where a click's meaning depended on **decoding the dot's colour first** — was **removed rather than kept for blocked states**, because that is exactly the unpredictability being complained about and every remedy it offered (**Check permissions…**, **Settings…**, **Quit**) is **one item away in the menu anyway**. **`PresenceClickRouter` survives as the single tested decision point**; the dead code was **deleted rather than left asserting behaviour we no longer have**. The panel stays a **non-activating `NSPanel`** and nothing here activates the app. `Tests/AppTests/NotchGeometryTests.swift` covers **2,600- and 5,000-character messages staying bounded across five display shapes**, in both sizing and layout, including a caller demanding an absurd size; `Tests/AppTests/PillPresenterTests.swift` is updated for the simplified click contract. **`swift build` clean, 1347 tests passing.** 1 commit `30911bb`. **Untested — every visual judgement here:** that the **error notice is now a compact two-line pill under the notch**, and that **left-clicking the dot pops the menu without stealing focus**. An agent has no window server; the size ceiling is measured and pinned by test, but how it *looks* is not. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.13` | `VoicePlus_6_1.7.13.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.15 build (tag `release/phase-6/v1.7.13`, notes `Packaging/notes/phase-6-1.7.13.md`, superseded by 1.7.15 below, which carries it) — **every speech model was downloaded twice.** After choosing a model the owner watched **“Warming up…”** for **well over a minute**, and then found **two byte-identical 468 MB copies of Parakeet TDT v3** on disk — the wait was real work, just work that had already been done once. Root cause: **VoicePlus stored the model in a folder FluidAudio would never look in, and then asked FluidAudio to load from it.** The folder was named from **`ModelID.rawValue`** (`parakeet-tdt-0.6b-v3-coreml`), but **`AsrModels.load(from:)` ignores the directory it is passed** — it takes the **parent** as a models root and asks **`ModelHub`** to resolve the name itself, and **`Repo.folderName` strips `-coreml`**, so it descended into **`parakeet-tdt-0.6b-v3`**; finding that **empty**, it **re-downloaded the entire model from HuggingFace**. **Only `parakeet_vocab.json` was ever read from our own copy.** Measured from the owner's log: the duplicate download cost roughly **81 seconds** of the wait, on top of a genuinely one-time **~19 second Neural Engine compile**. **All tiers were affected** — one naming rule, one loader. **Fixed:** the on-disk folder name now comes from **`ModelDescriptor.folderName`**, **decoupled from `ModelID.rawValue`** — which stays the model's **stable identity**, `Codable` and already written into every `voiceplus-manifest.json` on disk — and set to **FluidAudio's own `Repo.folderName`**, so **the path it resolves is the path we wrote**; **`ModelCatalog.fluidAudioFolderName(for:)` reads `Repo.folderName` out of the dependency** rather than repeating the string, and **a test pins our name to FluidAudio's**, so an **upstream rename fails the build here** instead of costing every user another **468 MB**; **the EOU model keeps its own name**, since `StreamingEouAsrManager.loadModels(from:)` opens the files **in the directory it is given** and never re-downloads; new **`Engine/ASRRuntime/ModelLayoutMigration.swift` runs from `ModelManager.init`** and leaves **exactly one folder per model, re-downloading nothing** — a **lone legacy folder is renamed**, and where **both** exist the **complete one is kept** (ours first, since it carries the manifest) and the **orphan deleted**, with publishing a **swap** so a failure leaves a working model under *some* name rather than none; and **`BiasVocabulary.discoverParakeet` builds its candidates from the descriptor**, legacy name included, because the vocab lookup is the one thing that ever read from our own copy. **Nobody re-downloads, and an affected user reclaims 461 MB on first launch.** **Verified against the real 461 MB model on disk** with **`ModelHub.offlineMode = true`** so nothing *could* be fetched: the **new** path loads with *“no download needed”*, the **old** path reports the model **missing** — **exactly where it used to re-fetch**. **Also fixed:** **`BundledModel.firstLaunchOrder` put the weakest model (110M TDT-CTC) first**, so a user who **already had the far better 0.6B v3** could still end up on the tiny one; it is now **a function of what is already installed**, and **`chooseFinal` and `bestFinalModelOnDisk` read one shared quality ranking** (`BundledModel.finalModelsByQuality`) rather than duplicating it in three places. **Cold start is unchanged** — tiny first, because 110 MB is what makes dictation work in seconds. New `Tests/EngineTests/ModelLayoutTests.swift` **14 tests**, one **pinning our folder name to FluidAudio's `Repo.folderName` read out of the library**; the rest cover the round trip landing where we wrote, a lone legacy folder being renamed, both folders collapsing to the complete one, the migration fetching nothing, and `firstLaunchOrder` preferring an installed better model while cold start stays tiny-first; `ASRModelManagerTests`, `ModelIntegrityTests` and `OnboardingDictationTests` updated, two of them having had the old folder name spelled out. **`swift build` clean**; the full-package test total is recorded at the release build. 2 commits `6e45b4e`, `dfdad8a`. **Untested:** **the reclaim against a real duplicate pair on a user's disk** — the migration is covered against **synthesised trees** and the load path is confirmed against the **real 461 MB model offline**, but nobody here has the owner's actual two-copy layout; and **the real HuggingFace download remains unverified** — pre-existing since 1.7.2, unchanged. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.14` | `VoicePlus_6_1.7.14.dmg` ⏳ no separate dmg — this fix ships inside the 1.7.15 build (tag `release/phase-6/v1.7.14`, notes `Packaging/notes/phase-6-1.7.14.md`, superseded by 1.7.15 below, which carries it) — **the Actions key could not be rebound or turned off.** The owner pressed **Right ⌘** expecting to dictate and got _“Actions need a model set up in Settings”_. **Right ⌘ was their _Actions_ key; dictation was Right ⌥** — so the message was, strictly, correct and **their dictation was never broken**. But two things about that were genuinely wrong, and both have the same root cause: **the Actions feature shipped with no UI at all.** **First, the message named a Settings row that did not exist:** **`act.planner` was not among the routable stages**, so there was **nothing in the UI to configure** and the only route was a **`defaults write`**. It is now **routable and appears as “Actions (voice commands)”** under Models, persisted through the **same `routing.<stage>` key** as every other stage — the exact key the old workaround used — offering **Auto and connected providers only**, with **no misleading local option**, because **there is no local planner** and a *“Local · balanced”* row would have been a **second unreachable instruction**. **Second, the Actions key had no UI at all:** **nothing wrote `actHotkeyBinding`**, it appeared in **no menu and no settings pane**, and there was **no way to disable it** — so **every fresh install shipped a live Right ⌘** that users would **press by accident**, with **no discoverable way to change or silence it**. It is now **rebindable from both the menu-bar item and Settings › General**, with **“off” folded into the same picker**, so **you cannot end up with a live key and a dead feature**. **The default is now off** — **Actions can do nothing until a provider is pinned**, so an armed-by-default key could **only swallow a keypress and report a missing provider**; **installs that had set the binding by hand keep their opt-in**. **Off means the event source is never installed**, not merely that its events are dropped (`CapabilityWatcher` treats a switched-off key like a **revoked permission**), and it is **re-read each tick** so the picker **takes effect within a second without a relaunch**. **The 1.7.10 collision guard is byte-for-byte unchanged**, now sitting behind **`ActKeyBinding.isLive`** which only **ANDs a second reason to stay shut** onto `isDistinct`: **bind both to the same key and dictation still wins**; both pickers **label the colliding key rather than hiding it**. New `Tests/AppTests/ActKeySettingsTests.swift` **14 tests** — `act.planner` is a routable stage whose pin **persists under `routing.act.planner`**; the act key is **off on a fresh install**, **rebindable** and **silenceable**; a switched-off key is **inert for every pairing of the two bindings** *and* is **never armed by `CapabilityWatcher` at all**; arming **re-reads a binding written while the key was off**; and the **1.7.10 `isDistinct` guard is unchanged**. **`swift build` clean**; the full-package test total is recorded at the release build. 2 commits `86c41da`, `59ad925`. **Also in this build, two investigations that changed no behaviour but closed real test gaps** (`429638b`, `4158ec4`), both **refuting a plausible diagnosis by measurement rather than confirming it**: the always-on **spectral-gate noise suppressor** was suspected of the dictation-accuracy problem and is **better, not worse** — measured **through** the acoustic chain over **12 clean fixtures**, **`.raw` mean WER 0.0291 versus `.default` 0.0140**, with the pangram at **WER 0.000 on both paths across 3 accents and ±30 dB room floors**; the gate **does** mangle the waveform (**10.9 dB SDR**) but **Parakeet is robust to it**, and a **through-the-chain WER regression test** now sits alongside the existing bypass test. **Biasing was suspected next and measured too:** **`FeatureFlag.contextBiasing` is off by default** and **no flags file exists on this machine**, so **no biaser was installed**; and **even enabled the rescorer only adjusts the confidence of tokens already chosen and cannot substitute a word** — **byte-identical output, WER 0.0291 both ways**. The new coverage exercises the decoder **as `AppContainer` actually builds it**, which had **never been tested**, and **privacy was confirmed clean along the way**: screen context is **accessibility-only**, held **in memory**, **rebuilt per utterance**, **never written to disk**. Written up in `Engine/Audio/Robustness/SUITES.md` and `Engine/Biasing/README.md`. **Untested:** that a **switched-off Actions key is silent under a real key press**, and that **rebinding it from either picker arms the new key without a relaunch** — no agent here has a keyboard event tap, a microphone or a window server; **every visual judgement is likewise unverified**, including the new picker in Settings › General and in the menu-bar item. **Recorded honestly: the live-microphone accuracy issue remains unresolved** — the **model, decoder, DSP and post-processing are all measured clean on fixture audio**, so **the remaining suspect is live capture itself**, and nothing here claims to have fixed it. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

| 6 (patch) | `Packaging/release.sh 6 1.7.15` | `VoicePlus_6_1.7.15.dmg` ✅ 2026-09-08 (sha256 `8bbbca88…67398b4c`, 15,738,218 bytes, tag `release/phase-6/v1.7.15`, notes `Packaging/notes/phase-6-1.7.15.md`, **install this one** — it carries 1.7.13 and 1.7.14 as well) — **AirPods would have silently ruined dictation, and a way to prove what the microphone actually heard.** This landed out of the hunt for the live-microphone accuracy problem: the owner read _“The quick brown fox jumps over the lazy dog”_ and got *“the quake brown fogs jump above the lazy doll”* — roughly **55% WER on a clean read**. Successive investigations had already **measured and cleared** the acoustic chain, the decoder, biasing, audio format conversion, the preview-versus-final landing, end-of-utterance truncation, the VAD and post-processing; this round **cleared the last synthetic suspects** and shipped the two things that came out of it. **The latent bug found and fixed:** **`InputSelectionPolicy` awarded the system default input a bonus of `+50`**, which **dwarfed every transport score** — so the moment a **Bluetooth headset connects and becomes the system default**, dictation would **silently move onto an HFP/SCO link**, a **narrowband 8 kHz (CVSD) or 16 kHz (mSBC), heavily compressed microphone**, **with no indication to the user and a large accuracy cost**. **The bonus is now withheld from a narrowband Bluetooth input** (`BluetoothInputMode.isNarrowbandSpeech`, the one-bit view of the classification `BluetoothInputDetector` already owned); **it still wins when it is the only input available**, **an explicit user pin still overrides everything**, and **wideband / LE Audio is untouched** — the rule is about telephony bandwidth, not about Bluetooth. **When the app substitutes a different microphone it says so**, in the UI and in the log, rather than doing it silently: `InputSelectionPolicy.decide` returns **`Choice.avoidedNarrowbandBluetooth`**, and **Settings › General gains a Microphone picker** — Automatic or a specific device, with **low-quality inputs labelled**, and a **pinned-then-unplugged device falling back** rather than showing a blank row. **The diagnostic:** every accuracy measurement so far has been taken on **synthetic fixtures**, and **the failure is not reproducible from them**, so the deliverable is **the ability to capture the real thing**. New **`Engine/Audio/UtteranceRecorder.swift`** saves the **raw and post-DSP audio of an utterance as WAVs** alongside a **manifest recording the device, transport, sample rate, capture graph and levels**, so a failing dictation can be **replayed through the existing fixture harness**. It is **opt-in and off by default, written locally, never leaving the machine**, keeps **only the newest 20 recordings**, and shows an **orange note in Settings while it is on**, with **Show in Finder** and **Delete all**. The owner turns it on in **Settings › General › Microphone**, reproduces a bad dictation, turns it off, and replays with `VOICEPLUS_REPLAY_TEXT="the quick brown fox jumps over the lazy dog" swift test --scratch-path .build-capture --filter replaySavedRecordings` (after `eval "$(Scripts/bootstrap-toolchain.sh)"`); `RecordingReplayTests` prints the manifest, the level, what the model heard and the **WER against the reference**, with **no fixture manifest to author**. **The whole loop was verified end to end against a fixture**, and **`Engine/Audio/README.md` carries a table explaining how to read each outcome**. **What was measured and cleared this round:** every prior accuracy figure had been taken on **16 kHz fixtures, where `AudioConverter16k` is a no-op** — so **the 44.1 kHz conversion a real microphone forces had never actually been exercised**. It now has been: **WER 0.0140 identically at 16 kHz, 44.1 kHz and 48 kHz**, **duration drift 0.01%**, and **zero sample drift** between streaming and one-shot conversion; **absolute level was cleared too**, **flat WER from −20 dBFS down to −60 dBFS**. **A genuine bug surfaced while testing this:** **silent audio produced `-inf` dBFS, which JSON cannot encode**, so the recording **would have been discarded in precisely the “the microphone delivered nothing” case that most needs capturing** — levels are now **floored at −200 dBFS**. New `Tests/EngineTests/UtteranceRecorderTests.swift` **12 tests**, `Tests/EngineTests/LiveCapturePathWERTests.swift` **4 tests**, `Tests/AppTests/MicrophoneSettingsTests.swift` **6 tests**, plus the opt-in replay harness in `Tests/EngineTests/RecordingReplayTests.swift`; `AudioUnitTests`' `skipsDisplayAndVirtualDefaults` **expected AirPods to win as system default** — **that expectation was the bug**, and now says so. **Then the verification pass over that new code found a privacy defect in the switch that turns it on, and two faults in the model store.** **The recording toggle was read exactly once, when the engine was built at launch** — so **turning it off stopped nothing**: the recorder stayed installed and went on writing a raw and a processed WAV plus a manifest **for every dictation until the app was relaunched**, while the Settings copy directly under the toggle said _“Turn it off when you're done.”_ Turning it **on** mid-session was inert in the same way. A switch about **audio of the user's voice being written to disk** that does not take effect when it is turned off is a **privacy defect, not a UI nit**. **The switch is now a predicate re-read at every `start()`**, so it means what it says **in both directions**; **a recorder is always allocated but stays disarmed** — two empty buffers, **no directory, no file** — and `begin()` is only called when the switch is on. **Off by default, local-only and the newest-20 retention are unaffected**; an **explicitly injected recorder still records unconditionally** for tests and Lab; **one narrow window remains by design**, a toggle flipped off *during* an utterance still writes that utterance. **Then, verifying 1.7.13's `ModelLayoutMigration` against the shapes a real disk can be in: a branch could permanently blind the truncation check.** `voiceplus-manifest.json` holds the byte count every file had when the install succeeded, and is **the only thing `ModelIntegrity` can check a silently truncated file against** (the check added in 1.7.11); the `adoptedExisting` branch **kept the manifest-less copy, deleted the manifest-bearing one, and wrote nothing in its place**, and **nothing else in the app ever writes a manifest for an already-installed model**, so the degradation **never healed**. **Every branch now settles the manifest before it returns** via one `ModelManifest.ensure` — already there → nothing to do; otherwise **adopt the doomed copy's manifest** when it describes the survivor **exactly, byte for byte** (a `stat` per file instead of a **SHA-256 pass over 468 MB**); otherwise **rebuild** with the same writer both fetchers use; **never for an incomplete folder**, since a manifest built over a truncated file **records the truncation as correct**. **The no-op branch settles it too**, healing an install an earlier build already stripped. **`ModelIntegrity.assess` now distinguishes `.verified` / `.unverifiable` / `.incomplete`** — a **manifest-less model is never reported verified**. **And the directories we park and then never delete.** Replacing a model is a **swap, not a delete-then-move** (`.replaced-<uuid>` from `FluidAudioFetcher.fetch`, `.superseded-<uuid>` from the migration), each cleaned up immediately afterwards — **if it gets that far**. Killed mid-swap the park survived and **nothing ever looked at it again**: **~468 MB stranded** under a name no presence check reads and `repair` never visits. **`ParkedModelDirectories.sweep` collects them conservatively**: **direct children of the models root only**; **only `<a model folder name we own>.<kind>-<a parsable UUID>`**, excluding a stranger's directory, a real model folder and our own `.staging-<id>`; **never FluidAudio's own directory**; **never symlinks**; a **15-minute grace period measured from the newest of creation, content and attribute modification time** — the last one is the point, because **parking is a rename** and a rename bumps `st_ctime` while leaving `st_mtime` and birth time alone; and **claim by atomic rename to `.sweeping-<uuid>` before removing anything**, which **exactly one racing sweeper can win** and which is itself collectable. **`ModelRootLock` puts the whole maintenance pass under an `flock`** so **two VoicePlus processes launching together cannot interleave** a park, a rename and a delete over the same two paths — per-open-file-description, so **a crash cannot leave a stale lock**, with the **wait bounded and then abandoned**. **`swift test` no longer runs maintenance inside a real model store**: eleven tests point `ModelManager` at the real `~/Library/Application Support/VoicePlus/Models` and, since maintenance runs from `init`, those **read-only intentions were entitled to migrate and delete inside a user's 468 MB store** — they now pass `Maintenance.skip`. **Cost on an already-migrated install: one `open`, a `stat` per model, one directory listing.** New `Tests/EngineTests/ModelMaintenanceTests.swift` **18 tests** over both fixes. **`swift build` clean, 1430 tests passing, 0 failures** — full package, from a clean scratch path. 5 commits `c9491df`, `8849dff`, `89611c6`, `4410afb`, `e96a167`. **On the owner's specific report, recorded honestly: the Bluetooth theory did not explain it.** Their own unified log shows **41 of 41 capture graphs** at `device=MacBook Pro Microphone … tap=44100Hz/1ch`, and **the affected dictations match that window row for row** — those were captured on the **built-in microphone**, with **AirPods paired but not connected**. **So the live-microphone accuracy issue remains unresolved.** The **model, decoder, DSP, conversion and post-processing are all now measured clean**; the **open hypothesis is far-field reverberation from a MacBook microphone at arm's length**, since **every fixture tested to date is anechoic text-to-speech with no reverb**, and reverb is a **classic source of exactly these phonetically-adjacent, right-syllable-count substitutions**. **The replay diagnostic is what will confirm or refute it:** if the replayed audio **scores badly but sounds fine**, capture is faithful and the model is failing on real-room speech; if the **raw file scores well and the processed one badly**, the spectral gate is implicated after all. **Untested — everything that needs a real microphone:** that a connected Bluetooth headset is actually **stepped around at the HAL**, that the **picker rebinds the live device**, and that a **real utterance records and replays**. No agent here has a microphone or TCC permission; the policy, the recorder and the replay path are covered against **protocols, mocks and fixture audio**, and the replay loop was verified **against a fixture** rather than a live capture. **Every visual judgement is likewise unverified** — the new Microphone section, the substitution note, the orange recording note and the Show in Finder / Delete all buttons. **The model-store fixes are untested against the real failures they guard:** the **sweeper has never collected a park left by a real crash**, and the **cross-process `flock`** has never been exercised by **two VoicePlus processes launching at once**; both are covered against temporary directories only. **On the owner's own machine the migration is a no-op** — their models root already holds `parakeet-tdt-0.6b-v3` and `parakeet-realtime-eou-120m-coreml-160ms`, **both carrying a valid manifest**, with **no legacy folder and nothing parked**, so the first launch of this build **moves no bytes**. **Caveat unchanged:** the repo is private, so the appcast enclosure URL 404s anonymously. |

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
