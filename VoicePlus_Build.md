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
- [ ] 
  
  **T1** Define `TranscriptSpan`, `Alternate`, `StageID`, `Utterance`, `EngineState`, `FeatureFlag` in `Shared/`.
  
- [ ] 
  
  **T2** SQLite schema: dictation history, corrections, flags, lab runs, network log. GRDB migrations.
  
- [ ] 
  
  **T3** `EngineProtocol` + `MockEngine` (returns scripted spans from fixtures) so UI/pipeline develop against a fake.
  
- [ ] 
  
  **T4** Logging + feature-flag service (local JSON, no server).
  
- [ ] 
  
  **T5** CI skeleton: build, test, lint, nightly dmg job.
  

**Acceptance:** all modules compile against `Shared/`; `MockEngine` streams a fixture transcript; CI green.

* * *
### P1.1 — App shell: menu bar + pill overlay _(WS-D; parallel)_
**Description:** the only two surfaces. Menu-bar item with dropdown dashboard; notch-aware pill overlay for live state.

- [ ] 
  
  **T1** Menu-bar app scaffold (no dock icon, `LSUIElement`), launch-at-login, Sparkle wiring stub.
  
- [ ] 
  
  **T2** Pill overlay: borderless `NSPanel`, notch-aware placement (DynamicNotchKit or native reimplementation), states: `idle / listening(waveform) / preview(streamingText) / landing / warning(mic)`. Slide in/out ≤150ms, 60fps.
  
- [ ] 
  
  **T3** Global hotkey service: configurable modifier, hold-to-talk (keyDown/keyUp), double-tap (≤350ms window) for hands-free toggle. Input Monitoring permission flow. _(Timing constants: hold threshold 250ms, tap guard 180ms — Muesli-validated values.)_
  
- [ ] 
  
  **T4** Menu dropdown: zero-edit counter, words today, active model, mic indicator, Lab link, pause toggle.
  
- [ ] 
  
  **T5** Permission orchestration: Microphone, Accessibility, Input Monitoring — each with a plain-language pre-prompt screen and a "verify" check.
  

**UI/UX:** pill is the single feedback channel; never a modal. Waveform reacts to actual input level. Warning state (bad mic) renders _before_ speech starts. All animation interruptible. **Tests:** UI tests for all pill states; hotkey unit tests with synthesized `CGEvent`s; permission-state matrix test. **Acceptance:** hold key → pill appears with live waveform → release → pill retracts. Mock text lands via `MockEngine`. No dock icon, no windows.

* * *
### P1.2 — Audio capture, VAD, endpointing _(WS-A; parallel)_
**Description:** clean 16kHz mono pipeline from any input device, with real VAD (the thing FluidVoice lacks).

- [ ] 
  
  **T1** Direct CoreAudio HAL capture (clean-room; FluidVoice's `DirectCoreAudioInput` is the _design_ reference — do not copy GPLv3 code): device enumeration, route-change handling (AirPods, clamshell, 3.5mm), prewarm on hotkey-down, thread-safe ring buffer.
  
- [ ] 
  
  **T2** Silero VAD streaming via FluidAudio `VadManager`; chunking min 3.0s / max 5.0s (Muesli-validated); endpoint detection for hands-free mode.
  
- [ ] 
  
  **T3** Mic-quality analyzer: SNR estimate, clipping, low-level detection in first 300ms → publishes `MicQuality` to pill.
  
- [ ] 
  
  **T4** Automatic input selection policy + per-device preference memory.
  
- [ ] 
  
  **T5** Audio fixture recorder/replayer for tests (WAV in, deterministic buffers out).
  

**Tests:** replay fixtures through capture path; VAD precision/recall on labeled fixture set (target F1 ≥ 0.95 on clean, ≥ 0.85 noisy); route-change chaos test (simulate device swaps mid-utterance). **Acceptance:** hands-free double-tap records, auto-endpoints on silence, no dropped buffers across a device swap.

* * *
### P1.3 — ASR runtime (FluidAudio fork) _(WS-A; parallel; interface freeze unblocks P1.5/P1.6)_
**Description:** fork FluidAudio; run Parakeet TDT v3 (primary), Parakeet Realtime EOU (streaming preview), Whisper (Intel fallback) with a model manager.

- [ ] 
  
  **T1** Fork `FluidInference/FluidAudio` → `Engine/`. Isolate `GreedyTDTDecoder` behind our `Decoder` protocol; **freeze this interface first and publish to P1.5/P1.6 agents.**
  
- [ ] 
  
  **T2** Model manager: HuggingFace download with resume + checksum, disk layout, load/unload, warm-start. Models: Parakeet TDT v3 (~~500MB), Parakeet EOU (~~250MB), Whisper small (Intel).
  
- [ ] 
  
  **T3** Bundled tiny model so first dictation works during onboarding download.
  
- [ ] 
  
  **T4** Streaming preview path (EOU model → pill) + final path (TDT v3) on release. _(This is NOT dual-path correction — Bet 4 is Phase 1.5; here final simply replaces preview at landing time.)_
  
- [ ] 
  
  **T5** Emit `TranscriptSpan`s with per-token log-probs mapped to word confidence + audio timestamps (Bet 9 source of truth).
  

**Tests:** golden-transcript tests per model on fixtures; latency budget test — final text ≤ 400ms after key-release for a 10s utterance on M1; confidence sanity (mangled fixture words carry lower confidence, verified statistically over the fixture set). **Acceptance:** speak → preview streams in pill → final spans (with confidence + timestamps) delivered ≤ 400ms after release.

* * *
### P1.4 — Acoustic robustness (Bet 1) _(WS-A; after P1.2)_
- [ ] 
  
  **T1** AEC integration: port Muesli's pattern (MIT — copy with attribution): LocalVQE primary, DTLN fallback. ⚠ Verify LocalVQE model-weight license first; if unusable, ship DTLN.
  
- [ ] 
  
  **T2** Noise suppression stage ahead of VAD; toggleable per profile.
  
- [ ] 
  
  **T3** Bluetooth/AirPods handling: detect codec/mic-mode, prewarm to avoid first-word loss, surface "AirPods in low-quality mode" warning.
  
- [ ] 
  
  **T4** Robustness fixture suite: far-field, café noise, accent set, phone-compressed — these feed the Lab (P1.11).
  

**Tests:** WER delta on noisy fixtures with/without AEC+NS (must improve, tracked in Lab); no added latency > 20ms. **Acceptance:** noisy-fixture WER measurably better than raw pipeline; AirPods first word never clipped.

* * *
### P1.5 — Decode-time context biasing (Bet 2) _(WS-A; after P1.3 interface freeze; parallel with P1.6)_
**Description:** the entity fix. Shallow-fusion biasing inside the TDT decode loop. Reference: NGPU-LM (arXiv 2505.22857).

- [ ] 
  
  **T1** Context harvester (runs continuously, cheap): proper nouns from focused window's AX tree, thread participants, calendar attendees, contacts (with permission), open code symbols/file names, last-10-min words, all-time corrected words.
  
- [ ] 
  
  **T2** Ranker + cap: score by recency/salience/source; **hard cap ~400 entries** (over-biasing hallucinates entities — spec Bet 2 constraint 3). BPE prefix-tree with partial-match unbiasing.
  
- [ ] 
  
  **T3** Shallow fusion in the decode loop: logit boost on prefix-tree matches; start greedy+boost, add narrow beam (width 2–4) only if Lab shows it pays for its latency.
  
- [ ] 
  
  **T4** Feature flag `context_biasing` + Lab hooks: entity recall, false-entity insertions, WER, added latency per configuration.
  

**Tests:** entity-recall suite — fixtures scripted with on-screen names ("TeamViewer AG", "Kothari", "kubectl", "gpt-4o") present in harvester input; **target: entity recall +30% relative vs baseline, false-insertion rate < 1%, added latency < 60ms.** Kill criterion per spec: if recall gain is immaterial, flag defaults off. **Acceptance:** with a name visible on screen, dictating it yields correct spelling; Lab dashboard shows the delta.

* * *
### P1.6 — Confidence, alternates, voice repair (Bets 3 + 9) _(WS-A engine + WS-D UX; after P1.3)_
**Description:** build alternates (greedy TDT produces none), keep confidence alive end-to-end, repair by voice.

- [ ] 
  
  **T1** Selective beam decoding: trigger beam (width 4) only over low-confidence regions; elsewhere stay greedy. Collapse blank/duration-variant candidates into a **word-level confusion network** of semantically distinct alternates.
  
- [ ] 
  
  **T2** Alternate enrichment: where beam is weak, generate candidates from bias vocabulary + phonetic neighbors (Double Metaphone) of the low-confidence word.
  
- [ ] 
  
  **T3** Repair grammar (voice, active for 10s after landing): `"no, <word>"` (snap to best-matching alternate), `"not that one"` (cycle), `"scratch that"` (drop last phrase), `"put it back"` (undo last replacement). Implemented as a gatekeeper route (P1.7), not string matching.
  
- [ ] 
  
  **T4** Repair UX: hold hotkey over a landed word → alternates fan out beneath it inline (overlay anchored to word's screen rect via AX), numbered, pickable by voice or click.
  
- [ ] 
  
  **T5** Provenance: repair edits update the span, log the correction (feeds dictionary + Phase 6 training), decrement zero-edit counter honestly.
  
- [ ] 
  
  **T6** Flag `voice_repair` + Lab metric: % of low-confidence words whose true word appears in top-3 alternates ("alternate usefulness").
  

**Tests:** alternate-usefulness on mangled fixtures — **target ≥ 60% top-3 hit rate** (kill criterion below 40%); repair-grammar routing accuracy ≥ 98% on scripted commands; UX test for fan-out positioning across 5 apps. **Acceptance:** dictate fixture with a known-hard word → say "no, ‹correct›" → word snaps without keyboard.

* * *
### P1.7 — Pipeline: gatekeeper + formatters + style (Bet 8, Bet 9) _(WS-B; parallel — gatekeeper and each formatter are separate parallel tasks)_
**Description:** raw spans → finished text. Every stage: `[TranscriptSpan] → [TranscriptSpan]`.

- [ ] 
  
  **T1** Gatekeeper: small local model (fine-tuned ~0.5–1B class, MLX, or distilled classifier) classifying utterance → `{dictate, repair_command, transform, none}` + destination register `{email, chat, code, prose, terminal, list}`. **Budget: ≤ 15ms.** Falls back to `dictate` on low confidence.
  
- [ ] 
  
  **T2–T6** Formatter stages ×5 — **email, chat, code, prose/list, terminal** — each a separately-tunable small model or deterministic transform. _(These five are fully parallel tasks — dispatch to five subagents.)_ Deterministic pieces: filler removal, self-correction resolution ("Friday — no, Thursday"), punctuation, list detection, `camelCase`/`snake_case`/paths/math.
  
- [ ] 
  
  **T7** Style stage: learns per-app writing register from user's edits over time (capitalization, punctuation density, emoji, greeting/sign-off). Cold-start heuristics per app category.
  
- [ ] 
  
  **T8** **Confidence contract enforcement**: stages must not rewrite spans with confidence < threshold — they flag (`needsRepair`) instead of smoothing (Bet 9). Lint test walks every stage with a poisoned span and asserts it survives.
  
- [ ] 
  
  **T9** Per-stage instrumentation: latency, skip-rate, edit-distance contribution → Lab.
  
- [ ] 
  
  **T10** Cloud/pipeline provider hook: any stage may route to a Provider (P1.10) when user enabled it; local default.
  

**Tests:** golden input→output pairs per formatter (≥ 40 cases each); the poisoned-span contract test; end-to-end budget — full pipeline ≤ 250ms local on M1. **Acceptance:** the same spoken sentence lands correctly formatted in Mail (prose), Slack (casual), and VS Code terminal (verbatim command); a garbled entity is flagged, not smoothed.

* * *
### P1.8 — Injection stack (T1) _(WS-C; fully parallel/independent)_
**Description:** text into any app, clipboard as last resort only.

- [ ] 
  
  **T1** Layered injector: ① AX direct insertion (`AXUIElementSetAttributeValue` at cursor) → ② synthesized Unicode `CGEvent` keystrokes to focused PID → ③ per-app adapter → ④ clipboard paste with full save/restore + `changeCount` guard. _(Design per FluidVoice — clean-room; code per Muesli MIT where applicable.)_
  
- [ ] 
  
  **T2** Per-app adapters for the hostile set: Terminal/iTerm/Ghostty/tmux (bracketed paste, no smart punctuation), Electron apps (Slack, VS Code), Cursor, Excel/Sheets (cell mode), Figma.
  
- [ ] 
  
  **T3** Success detection: post-injection AX readback where possible; per-app, per-version success telemetry stored **locally**; automatic method routing from history.
  
- [ ] 
  
  **T4** Focus safety: snapshot frontmost app at key-release; abort (never spray text) if focus changed; queue + notify instead.
  
- [ ] 
  
  **T5** Replace-range support (for repair snaps and Phase 1.5 corrections): replace exact ranges via AX; if the region no longer matches what we wrote, **do not touch it** — surface suggestion instead (Bet 4 safety rule, built now).
  

**Tests:** scripted injection matrix across ≥ 12 apps in CI-adjacent UI test rig; clipboard-restore property test (user clipboard identical before/after, including images); focus-change abort test. **Acceptance:** dictation lands correctly in all 12 matrix apps; user clipboard never observably altered; zero text sprayed to wrong app in chaos test.

* * *
### P1.9 — Onboarding + settings _(WS-D; parallel; integrates P1.10 screens)_
- [ ] 
  
  **T1** 60-second onboarding flow: welcome → permissions (each with why + verify) → mic check (live quality meter) → **model choice screen** → first real dictation (guided sentence into a real app).
  
- [ ] 
  
  **T2** Model choice screen: Fast/Balanced/Best local (sizes + plain-language tradeoffs; background download with pill progress; bundled tiny model active meanwhile) + optional "connect what you pay for" (P1.10 flows). Skippable; never blocking.
  
- [ ] 
  
  **T3** Settings window (single, small): hotkey, models/providers per stage (Auto default), personas (plain-English text per app), dictionary manager, flags (Lab-linked), Data Panel.
  
- [ ] 
  
  **T4** First-run dictionary import offer: contacts names (permissioned, local only).
  

**UI/UX:** every onboarding step doable in ≤ 10s; final step is doing, not watching. **Tests:** onboarding state-machine unit tests incl. permission-denied branches; fresh-VM manual script. **Acceptance:** fresh install → first successful dictation ≤ 60s with all-granted permissions; app fully usable with everything skipped.

* * *
### P1.10 — Providers: models, keys, OAuth, CLI adapters (Part 4.6) _(WS-E; fully parallel/independent)_
- [ ] 
  
  **T1** `Provider` protocol: `complete(stage:, spans:, context:) async` + capability flags (`asr`, `pipeline`), cost class, privacy class.
  
- [ ] 
  
  **T2** Local providers: MLX/CoreML pipeline models; Ollama + LM Studio auto-detection (localhost, no auth header — FluidVoice pattern, reimplemented).
  
- [ ] 
  
  **T3** OpenAI-compatible client: OpenRouter, OpenAI, Anthropic, Groq, Cerebras + custom base URL. Keys in Keychain. Streaming + timeout + fallback-to-local on failure.
  
- [ ] 
  
  **T4** OAuth PKCE "Sign in with ChatGPT" (Muesli-proven pattern): loopback redirect, token refresh in Keychain, **pipeline stages only** — UI must state subscriptions do not help ASR.
  
- [ ] 
  
  **T5** CLI adapters (Paperclip pattern, MIT — read `adapter-plugin.md` + `tools/agent-shim`, reimplement in Swift): detect `claude` / `codex` binaries; adapter runs prompt-in/text-out subprocess with timeout + sandboxed env; register as pipeline providers labeled "uses your existing subscription".
  
- [ ] 
  
  **T6** Routing table: per-stage provider choice, Auto default (local first); every remote call → Data Panel log (timestamp, stage, provider, bytes, purpose).
  
- [ ] 
  
  **T7** Cloud ASR slot (post-v1 flag, default hidden): honest UI copy — "cloud ASR disables repair & context features."
  

**Tests:** provider conformance suite run against mocks + live Ollama; OAuth flow integration test with mock IdP; CLI adapter test with a stub binary; routing fallback chaos test (kill provider mid-call → local completes). **Acceptance:** a pipeline rewrite runs via (a) local model, (b) OpenRouter key, (c) ChatGPT OAuth, (d) `claude` CLI — user-switchable, each visible in the Data Panel.

* * *
### P1.11 — The Lab + Zero-Edit counter + Data Panel (T3) _(WS-F; fully parallel/independent)_
- [ ] 
  
  **T1** Harness core: run fixture suites (clean, noisy, accent, entity, technical) through any engine/pipeline configuration; score WER, entity recall, false-entity rate, latency percentiles, zero-edit prediction. CLI + in-app.
  
- [ ] 
  
  **T2** Fixture curation: assemble the real-world suite (record + license-check; include Earnings-22-style call audio, code dictation, Indic-accent English). Document provenance.
  
- [ ] 
  
  **T3** Lab panel UI: run benchmark on this Mac, compare configurations (flags × models × providers), per-stage latency waterfall, thermal readout during runs (Risk 10 measurement).
  
- [ ] 
  
  **T4** Zero-edit counter: words dictated vs words edited within 60s of landing in same field (AX observation, local only) — menu-bar stat + trend.
  
- [ ] 
  
  **T5** Data Panel: live log of every byte that left the machine (provider calls, model downloads, update checks), per-hour rollup, global kill switch.
  
- [ ] 
  
  **T6** Publish harness as a public repo artifact (spec Phase 1 "publish the harness").
  

**Tests:** harness determinism (same input → same scores); counter accuracy against scripted edit sessions; data-panel completeness test (proxy-verify no unlogged egress). **Acceptance:** one click produces a scored report comparing `biasing on/off` on local hardware; Data Panel shows _nothing_ egressing in default config.

* * *
### P1.12 — Integration + hardening _(serial; after all P1.x)_
- [ ] 
  
  **T1** Wire real engine to shell (replace `MockEngine`); end-to-end latency budget: key-release → text landed **≤ 700ms p50, ≤ 1200ms p95** (10s utterance, M1, local everything).
  
- [ ] 
  
  **T2** Kill-criteria review: read Lab numbers for Bets 2/3/9 flags; set defaults per spec Part 5 rules; record decision in `DECISIONS.md`.
  
- [ ] 
  
  **T3** Thermal/battery soak: 2h continuous dictation session on fanless hardware; no thermal throttle below latency budget; idle drain < 1%/h.
  
- [ ] 
  
  **T4** Chaos pass: device swaps, focus churn, sleep/wake, model-download interruption, 10k-word session.
  
- [ ] 
  
  **T5** Security review: injection surfaces, subprocess adapters, Keychain usage, no dynamic code loading.
  

**Acceptance:** Phase 1 "Done when" from spec — on the published harness, beat competitor baselines on WER and zero-edit rate for the recorded fixture suite; all budgets met.
### P1.13 — Packaging + release pipeline _(serial; the pipeline built here is reused by every later phase)_
- [ ] 
  
  **T1** Developer ID signing, hardened runtime, notarization; dmg with drag-install background; Sparkle appcast (+ beta channel); Homebrew cask.
  
- [ ] 
  
  **T2** **Reusable release script** `Packaging/release.sh <phase> <version>`: builds, signs, notarizes, produces `VoicePlus_<phase>_<version>.dmg`, archives to `Packaging/releases/`, updates appcast, tags the repo (`release/phase-<phase>/v<version>`), creates the GitHub release with the phase's human test script in the release notes. Every subsequent phase MUST ship through this script — no ad-hoc builds.
  
- [ ] 
  
  **T3** First-run integrity: clean-install and upgrade-in-place paths tested from the actual dmg artifact (not from Xcode run).
  

**Acceptance:** fresh Mac → download dmg → dictating in 60s. **Output artifact:** `VoicePlus_1_1.0.0.dmg`**.**

* * *
## 5. PHASE 1.5 — Dual-path silent correction (Bet 4) (.dmg #2)
_Single workstream (WS-A + WS-D). Small, dangerous, isolated._
### P1.5.1 — Reconciler
- [ ] 
  
  **T1** Run EOU (fast) + TDT v3 (accurate) concurrently; ANE contention profiling; diff final vs preview at word level using audio-span alignment.
  
- [ ] 
  
  **T2** Correction planner: only correct spans that (a) differ semantically, (b) exceed confidence delta threshold, (c) pass the **safety rule** — target text still exactly matches what we injected (AX readback); else downgrade to suggestion.
  
### P1.5.2 — Correction UX
- [ ] 
  
  **T1** Shimmer + 2s underline on corrected word; hover → "was: …" + one-tap revert; "show what changed" list in menu dropdown; per-app off switch; `"put it back"` voice undo.
  

**Tests:** splice property test — corrections never alter user-modified text (fuzz with concurrent edits); correction precision ≥ 95% on fixture disagreements. **Acceptance:** visibly wrong preview word silently becomes correct after landing; typing immediately after dictation is never corrupted. **Release:** `Packaging/release.sh 1.5 1.1.0` → `VoicePlus_1.5_1.1.0.dmg`.

* * *
## 6. PHASE 2 — "Talk to your text" (.dmg #3)
_Parallel groups: {P2.1+P2.2} (WS-B), {P2.3} (WS-D), {P2.4, P2.5, P2.6} independent after P2.1._
### P2.1 — Transform routing
- [ ] 
  
  Selection detector via AX (deterministic dictate-vs-transform per Bet 5); gatekeeper gains `transform` + `question` routes; selection text + surrounding context assembled for the model.
  
### P2.2 — Rewrite engine
- [ ] 
  
  Transform executor via Providers (local default, best-available preferred for quality); output re-injected via replace-range (P1.8 T5); diff computed for morph animation.
  
- [ ] 
  
  **Tests:** 60-case transform suite (tone, shorten, restructure, translate-format); injection-matrix re-run for replace-range.
  
### P2.3 — Transform UX
- [ ] 
  
  Pill "transform" tint + "editing N words"; inline morph animation (collapse/expand, one beat); 5s "↩ / try again" ghost; chained-turn window — pill stays warm 8s, follow-up instructions reuse the selection (Kivi pattern).
  
- [ ] 
  
  **Acceptance:** "make this two lines" → "call out the churn number" → "bold it" — no re-selection, works in Mail, Slack, Notes.
  
### P2.4 — Q&A on selection _(parallel)_
- [ ] 
  
  `question` route types answer below selection with visible "answer:" attribution; never replaces selection.
  
### P2.5 — Personas deepening _(parallel)_
- [ ] 
  
  Per-app plain-English persona box (auto-drafted from Phase 1 style learnings; editable); per-recipient override hooks (thread participant detection).
  
### P2.6 — Spoken snippets _(parallel)_
- [ ] 
  
  Trigger-phrase → expansion store; managed in settings; gatekeeper route with exact-match priority.
  

**Phase acceptance:** a rough paragraph reaches final form via voice only, verified on the scripted "no-keyboard" E2E test. **Release:** `Packaging/release.sh 2 1.2.0` → `VoicePlus_2_1.2.0.dmg`.

* * *
## 7. PHASE 3 — "It knows what 'this' means" (.dmg #4)
_Parallel: P3.1+P3.2 (WS-G) ∥ P3.3 (WS-G-2) ∥ P3.4 (WS-C). P3.5/P3.6 after P3.3._
### P3.1 — Input timeline recorder
- [ ] 
  
  While hotkey held: record cursor path, click points, drawn strokes, selection changes — each timestamped on the **same clock as ASR audio spans**. Multi-display coordinates normalized.
  
- [ ] 
  
  **Tech:** `CGEvent` tap (already permissioned) + overlay stroke capture; ring buffer, 30s horizon; nothing persisted.
  
### P3.2 — Ink overlay
- [ ] 
  
  Full-screen transparent overlay per display; Excalidraw-style stroke rendering (jitter + taper); 1.5s fade; resolution pulse animation on bound regions; region bundle counter in pill.
  
### P3.3 — Deixis resolver
- [ ] 
  
  Bind deictic words ("this/that/there/these") to timeline: word's audio timestamp → pointer position/stroke segment at that moment → AX hit-test → element/region reference passed to pipeline/actions.
  
- [ ] 
  
  **Tests:** scripted fixture: synthetic pointer traces + audio with known bindings; **target ≥ 95% correct binding** (phase gate).
  
### P3.4 — Deep AX reading _(parallel — extends Injection's AX layer)_
- [ ] 
  
  Full-window text extraction incl. scrollback (AX value + `AXVisibleCharacterRange` walking); document/terminal content on demand; cached per window with invalidation.
  
### P3.5 — Conversational referents
- [ ] 
  
  Resolver for "her/him/the deck/the file": thread participants + visible artifacts from AX context → pipeline context injection.
  
### P3.6 — Reverse elicitation
- [ ] 
  
  On ambiguous binding (two candidates within threshold): draw ring + "which one?" label; user points or speaks; answer feeds resolver; timeout falls back to clarifying text in pill.
  

**Phase acceptance:** "move this over there" resolves both referents correctly ≥ 95% in the scripted suite; live demo across two displays. **Release:** `Packaging/release.sh 3 1.3.0` → `VoicePlus_3_1.3.0.dmg`.

* * *
## 8. PHASE 4 — "It does it, not just types it" (.dmg #5)
_Parallel: P4.1 (deterministic) ∥ P4.3 (cursor) ∥ P4.4 (consent) ∥ P4.6 (connectors — one subagent per connector). P4.2 after P4.1; P4.5 after P4.1+P4.4._
### P4.1 — Deterministic action layer
- [ ] 
  
  Action vocabulary over AX: click-by-name (fuzzy label match), focus app/tab/window/desktop, scroll, keystroke/shortcut, fill field, open URL/file. **Catalogue the 200 actions** (mine Infina's published command list as the spec of what matters).
  
- [ ] 
  
  Each action: precondition check → execute → postcondition verify (AX readback). No model call on this path.
  
- [ ] 
  
  **Tests:** action conformance matrix across 15 apps; **target ≥ 99% success** on catalogued actions (phase gate).
  
### P4.2 — Act routing (second key)
- [ ] 
  
  Second hotkey activates `act` domain (Bet 5: two keys); gatekeeper extends to action-intent parse → deterministic match first; unmatched → agentic fallback with visible plan.
  
### P4.3 — Overlay agent cursor _(parallel)_
- [ ] 
  
  Tinted glowing pointer with trailing wisp, rendered on overlay; **never moves the user's pointer**; all deterministic/agentic actions animate through it.
  
### P4.4 — Consent engine (Bet 7) _(parallel)_
- [ ] 
  
  Action classifier: `reversible / semi / irreversible` (rule table + conservative default); reversible = just do; semi = 5s undo toast with draining ring + compensating action (e.g. delete sent Slack msg where API allows); irreversible = slide-out card requiring spoken "confirm" or click. Policy table in code, unit-tested, no user config.
  
### P4.5 — Agentic fallback
- [ ] 
  
  `AgentActionBackend` protocol; Cua backend **only if license clears** (P4.0 task: verify), else native loop (screenshot-free: AX tree + action vocabulary as tools, local or provider LLM planning); step plan → chips UI; every step through consent engine; "stop" kills mid-flight (hard timeout + rollback of queued steps).
  
### P4.6 — Native connectors _(fully parallel — one subagent each)_
- [ ] 
  
  Slack, Gmail, Google Calendar, Linear, Notion, GitHub: OAuth per service, minimal scopes; actions (send/draft/create/comment) route via API when target matches, else UI automation. Every call → Data Panel.
  

**Phase acceptance:** deterministic path ≥ 99% on the 200-action catalogue; "open the PR tab and scroll to the failing check" works live; irreversible actions never execute unconfirmed (fuzz-tested). **Release:** `Packaging/release.sh 4 1.4.0` → `VoicePlus_4_1.4.0.dmg`.

* * *
## 9. PHASE 5 — "No hotkey at all" (.dmg #6)
_Parallel: P5.5 meeting capture is independent — may be built any time after Phase 1. P5.1 ∥ P5.3 ∥ P5.4; P5.2 after P5.1._
### P5.1 — Directed-speech detection _(research item — timebox, wake-verb fallback guaranteed ship)_
- [ ] 
  
  Always-on lightweight path: VAD → tiny on-device classifier (prosody + content features + gaze-free context: is a text field focused, was the machine addressed recently). Nothing stored or transmitted; rolling 10s buffer, RAM only.
  
- [ ] 
  
  **Metric harness first:** false-trigger rate / missed-address rate on a recorded home+office corpus. **Ship bar: < 1 false trigger/day** simulated; below bar → mode stays opt-in "experimental".
  
### P5.2 — Wake-verb grammar
- [ ] 
  
  Infina-pattern reliable fallback: leading verbs `"type …"`, `"send"`, `"<appname> …"` parsed by gatekeeper in hands-free mode; printed inside pill first 10 uses, then fades.
  
### P5.3 — Speaker identification _(parallel)_
- [ ] 
  
  Speaker embedding (diarization models already in engine) enrolled during onboarding-2; non-user speech ignored in hands-free; TV/podcast rejection test suite.
  
### P5.4 — Ambient state + hard mute _(parallel)_
- [ ] 
  
  Three-state glyph (listening/muted/processing) in menu bar + notch; one-gesture mute with persistent badge; unmute never automatic; "not you" voice correction teaches the classifier.
  
### P5.5 — Meeting capture _(independent; port from Muesli, MIT)_
- [ ] 
  
  Process-tap system audio recorder + watchdog + SCK fallback (copy, attribute); mic+system dual capture; AEC; VAD chunking; diarization ("You"/"Others"); local notes via pipeline providers; camera+calendar meeting detection with Join&Record/Record/Ignore notch notification; notes arrive as notification post-call. No bot ever joins.
  

**Phase acceptance:** false-trigger < 1/day in soak; speaker-ID rejects fixture TV audio ≥ 99%; meeting produces diarized transcript + notes fully locally. **Release:** `Packaging/release.sh 5 1.5.0` → `VoicePlus_5_1.5.0.dmg`.

* * *
## 10. PHASE 6 — "It sounds like you" (.dmg #7 + mobile)
_Parallel: P6.1 ∥ P6.3 ∥ P6.4 ∥ P6.5. P6.2 after P6.1._
### P6.1 — Personal adaptation loop
- [ ] 
  
  Corrections (repair events, post-dictation edits) accumulate as paired (audio-span, corrected-text) training data — **on device**; periodic adapter fine-tune (LoRA-style on decoder/joint, or bias-list learning if fine-tune infeasible on-device — Lab decides); personal-WER tracked per user in Lab "you" tab.
  
### P6.2 — Learned lexicon
- [ ] 
  
  Pronunciation capture ("Train by voice" — say the word, store the audio); one-time "I'll remember _Kothari_" toast; never repeat for same word.
  
### P6.3 — Code-switching _(parallel)_
- [ ] 
  
  Integrate AI4Bharat Indic RNNT models (verify license) under engine; script-aware injection (Devanagari + Latin in one utterance); auto language detection, **no language toggle**; pill script indicator.
  
### P6.4 — Encrypted sync _(parallel; backend-independent of app)_
- [ ] 
  
  Sync payload = dictionary + personas + snippets + adapter weights + settings (never audio); end-to-end encrypted (user-held key), QR pairing, export-everything file; conflict = last-writer-wins per record.
  
### P6.5 — iOS keyboard _(parallel; separate target)_
- [ ] 
  
  Keyboard extension: hold-to-talk pill, same repair fan-out, personas; on-device ASR (small Parakeet via CoreML) with app-proxy for heavier pipeline; instant return to previous keyboard (kill the Aqua focus-dance).
  

**Phase acceptance:** day-30 personal WER < day-1 (provable in Lab); corrected word never re-mis-heard in regression fixture; Hindi+English single-breath fixture lands correctly; profile round-trips Mac→iPhone via QR. **Release:** `Packaging/release.sh 6 1.6.0` → `VoicePlus_6_1.6.0.dmg` + iOS TestFlight build.

* * *
## 11. Release manifest — one dmg per phase, mandatory
| Phase | Command | Artifact |
|---|---|---|
| 1 | `Packaging/release.sh 1 1.0.0` | `VoicePlus_1_1.0.0.dmg` |
| 1.5 | `Packaging/release.sh 1.5 1.1.0` | `VoicePlus_1.5_1.1.0.dmg` |
| 2 | `Packaging/release.sh 2 1.2.0` | `VoicePlus_2_1.2.0.dmg` |
| 3 | `Packaging/release.sh 3 1.3.0` | `VoicePlus_3_1.3.0.dmg` |
| 4 | `Packaging/release.sh 4 1.4.0` | `VoicePlus_4_1.4.0.dmg` |
| 5 | `Packaging/release.sh 5 1.5.0` | `VoicePlus_5_1.5.0.dmg` |
| 6 | `Packaging/release.sh 6 1.6.0` | `VoicePlus_6_1.6.0.dmg` (+ TestFlight) |

Rules: a phase is **not complete** until its dmg exists in `Packaging/releases/`, is installable on a clean machine, and passes the phase's human test script. Patch releases within a phase bump the patch version (`VoicePlus_2_1.2.1.dmg`). Do not begin the next phase's integration until the current phase's dmg is produced — parallel _development_ of later-phase items may continue per Section 3.3.

* * *
## 12. Cross-phase quality gates (every release)
- [ ] 
  
  Latency: key-release → landed ≤ 700ms p50 local.
  
- [ ] 
  
  Zero egress in default config (Data Panel + proxy verification).
  
- [ ] 
  
  Injection matrix green across the 12-app set.
  
- [ ] 
  
  Lab regression: WER / entity recall / zero-edit never worse than previous release.
  
- [ ] 
  
  Clipboard integrity property test.
  
- [ ] 
  
  Fresh-install onboarding ≤ 60s manual script.
  
- [ ] 
  
  Upgrade-in-place from previous dmg.
  
- [ ] 
  
  `DECISIONS.md` updated with any flag-default changes and kill-criteria readings.
  

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
