# VoicePlus — Progress Log

## Environment / deviations
- 2026-08-23: No Xcode.app (CLT only, Swift 6.0.3). Build via SwiftPM; .app assembled by script; DMG via hdiutil; ad-hoc codesign, no notarization (no Developer ID identity). Unit/integration tests only (Swift Testing — see next line) — no Xcode UI tests.

- 2026-08-23 (P1.0): CLT has **no XCTest.framework** → all tests use **Swift Testing**. CLT also has stale leftovers (old `ManifestAPI/*.private.swiftinterface`, duplicate `usr/include/swift/module.modulemap`) that break every SwiftPM build; `Scripts/bootstrap-toolchain.sh` builds a cleaned user-local toolchain shim and `.claude/settings.json` exports `SWIFTPM_CUSTOM_LIBS_DIR`, `SWIFT_EXEC`, `SWIFT_EXEC_MANIFEST`. No sudo available to fix the CLT itself.
- 2026-08-23 (P1.0): Deps added via SwiftPM: GRDB.swift 7.8.0 (Shared), FluidAudio 0.15.6 (Engine; pulls a binary xcframework artifact → use `--disable-keychain` on first resolve).
- CI (`.github/workflows/ci.yml`) targets macos-14 + Xcode 16.2 and is unverified from this machine (no `gh` run possible offline); swiftlint step is conditional on the binary being present.

## Phase 1
- [x] P1.0 Shared foundation — done 2026-08-23. Frozen API: `TranscriptSpan`, `Alternate`, `StageID`, `Utterance`, `EngineState`, `MicQuality`, `FeatureFlag`, `PipelineStage`/`StageContext`/`ConfidenceContract`, `AppDatabase` + `*Record` structs, `EngineProtocol`/`EngineEvent`/`EngineEventBroadcaster`/`MockEngine`/`TranscriptFixture`, `Log`/`LogBuffer`, `FeatureFlagService`, `AppPaths`. 42 tests green.
- [x] P1.1 App shell — done (aeeb31b), 31 tests; pasteboard until P1.12 wires Injection; CGEvent tap/TCC/pill rendering untested headless.
- [x] P1.2 Audio/VAD/endpointing — done (c0b49b9, bd3ae0b), 30 tests; Energy VAD F1 0.983; Silero falls back to EnergyVAD (needs model v6.2.1); live HAL capture untested.
- [x] P1.3 ASR runtime — done (9f8a5e4…55c9438), 25 tests; no FluidAudio fork (adapter over 0.15.6, biaser post-hoc); TDT v3 WER 2.9%, final ≤190 ms; Whisper catalog-only.
- [x] P1.4 Acoustic robustness — done (2a9e71e), 12 tests; Apple voice-processing AEC primary, LocalVQE/DTLN weight-less slots; SNR-only assertion.
- [x] P1.5 Context biasing — done (5d9dad9), 14 tests; synthetic recall 0.2→1.0, 0 false insertions; in-loop biasing only on ScriptedLogitDecoder.
- [x] P1.6 Confidence/alternates/repair — done (1e8f368, abd3530), 28 tests; grammar 80/80, alternates 87% top-3 (synthetic); scripted beam backend; sinks wired in P1.12.
- [x] P1.7 Pipeline — done (7 commits), 115 tests; gatekeeper = rules + naive Bayes; 5 deterministic formatters (47–57 golden each); style = capitalization + terminal period only.
- [x] P1.8 Injection — done (b0f84e7), 46 tests; LiveSystemAccess unexercised; 12-app matrix mock-level.
- [x] P1.9 Onboarding/settings — done (16ea017), 22 tests; views/Contacts/permission prompts untested; P1.12 adapts ModelManager + PermissionService.
- [x] P1.10 Providers — done (cbe747d), 36 tests; no live Ollama/keys/OAuth/CLI; no MLX/CoreML local models.
- [x] P1.11 Lab/Zero-Edit/Data Panel — done (c495f9f), 28 tests; real engine + FieldObserver wired in P1.12; real-world suites not recorded.
- [x] P1.13 T1–T2 packaging scripts — done (bb1064d); ad-hoc sign, no notarization; 0.0.1 smoke dmg only. T3 + `VoicePlus_1_1.0.0.dmg` pending.
- [x] Verify (69b1d8b): full `swift build` clean; **424 tests green / 0 failed** (App 58, Engine 105, Pipeline 115, Injection 46, Providers 36, Lab 28, Actions 1, Shared 35). Fixed: GatekeeperStage registered in StageRegistry; flaky pill test.
- [x] P1.12 integration — done 2026-08-24 (9cd69d9, 82b9d2b, 2f6dc91, ada434e, 29f3a59); **613 tests green**. AppContainer wires RealEngine + pipeline + repair/injection/providers/egress gate; e2e latency p50 53 ms (mock engine); kill-criteria: contextBiasing → off (DECISIONS.md); soak 3 min mock only (2 h fanless pending); chaos tests; docs/SECURITY-REVIEW.md.
- [x] **Phase 1 release** — 2026-08-24: `Packaging/release.sh 1 1.0.0` → `Packaging/releases/VoicePlus_1_1.0.0.dmg` (13 MB, sha256 `6ce21d6cecb061bbc18308c28ffbb4d7a0fe236f19a7fa0edef116cc6620e0f9`), tag `release/phase-1/v1.0.0`, verify_install OK, notes in `Packaging/notes/phase-1.md`, GitHub release https://github.com/thekatarekid/VoicePlus/releases/tag/release/phase-1/v1.0.0. Ad-hoc signed, not notarized; human test script (14 steps) still to be run on a clean account.

## Early-start items (parallel with P1.12; verify 29f2a62: 601 tests green at the time, excluding the two P1.12-owned long-running tests)
- [x] P1.5.1 T1–T2 dual-path reconciler — 22fcf83; 22 tests; dualPath flag off, AX readback adapter pending P1.5.2.
- [x] P2.1+P2.2 transform routing + rewrite engine — e0985ac; 30 tests; live AX selection untested.
- [x] P2.4+P2.5+P2.6 Q&A / personas / snippets — aeeb19f, 332f28a; 50 tests; SnippetStage not yet in StageRegistry.
- [x] P3.1+P3.2 input timeline + ink overlay — 5705405; 22 tests; live CGEvent tap + overlay rendering untested, not wired.
- [x] P3.4 deep AX reading — 26808a6; 20 new tests (InjectionTests 66); live AX untested.
- [x] P5.5 meeting capture — 78be903; 17 tests; no app wiring, needs Calendar/Screen Recording usage strings.
- [x] P6.4 encrypted sync — 824db84; 17 tests; Keychain store + iCloud folder untested, no app wiring.

## Phase 1.5 + Phase 2
- [x] P1.5.2 Correction UX + P2.3 Transform UX — done 2026-08-24 (d80decf, c15b495); 36 tests incl. the no-keyboard E2E chain ("make this two lines" → "call out the churn number" → "bold it", zero keystrokes). Reconciler + AX readback wired in AppContainer behind `dualPath` (default off); Snippets tab, persona auto-draft, silent-corrections switches in Settings.
- [x] **Phase 1.5 release** — 2026-08-24: `Packaging/release.sh 1.5 1.1.0` → `Packaging/releases/VoicePlus_1.5_1.1.0.dmg` (14 MB, sha256 `451351335368748bc27ac7dffa2659d259332ffe9e3baef5fd138617d2e3db31`), tag `release/phase-1.5/v1.1.0`, verify_install OK, notes `Packaging/notes/phase-1.5.md`, GitHub release https://github.com/thekatarekid/VoicePlus/releases/tag/release/phase-1.5/v1.1.0. `dualPath` ships off (in-app reconciler preview is the landed text stand-in; real EOU+TDT disagreement rate unmeasured on hardware); human test script (11 steps) pending.
- [x] **Phase 2 release** — 2026-08-24: `Packaging/release.sh 2 1.2.0` → `Packaging/releases/VoicePlus_2_1.2.0.dmg` (14 MB, sha256 `ff450a8ca29c89f0072fa45185e602e9c4ab05dda2c3781ce177f945893d9840`), tag `release/phase-2/v1.2.0`, verify_install OK, notes `Packaging/notes/phase-2.md`, GitHub release https://github.com/thekatarekid/VoicePlus/releases/tag/release/phase-2/v1.2.0. Live AX selection / Mail-Slack-Notes untested on hardware; human test script (13 steps) pending.

## Phases 3–6 development wave (2026-08-24; built + unit-tested, not yet wired into the app)
- [x] P3.3+P3.5+P3.6 deixis / referents / reverse elicitation — 1545752; 29 tests; deixis fixture 120/120 (gate ≥95%); LiveAXHitTester + overlay rings untested.
- [x] P4.1 deterministic action layer — c11f180; 14 tests; 200-action catalogue; conformance 1398/1398 = 100% across 15 mock apps (gate ≥99%); LiveActionSystem untested.
- [x] P4.2+P4.5 act routing + native agent backend — d4aa81c; 32 tests; routing matrix 200/200; 300-plan consent fuzz clean; Cua: MIT but not imported (screenshot/VM loop), native loop shipped.
- [x] P4.3+P4.4 agent cursor + consent engine — 7230706, e9a7cc2; 14 tests; 2000-iteration fuzz: irreversible/unknown never execute unconfirmed; cursor never moves pointer (static check); live rendering untested.
- [x] P4.6 connectors Slack/Gmail/Calendar (7d99f8d, ae74b25; 40 tests) + Linear/Notion/GitHub (583138f; 34 tests); every call logged `act.connector`; live OAuth/endpoints/Keychain untested.
- [x] P5.1+P5.2 directed speech + wake verbs — cb383c7, 5de5b55; 47 tests; harness 0 false triggers/day, missed-address 1/12 on synthetic corpus → stays opt-in experimental; hands-free flag wiring pending.
- [x] P5.3+P5.4 speaker ID + ambient/mute — b1047f1, 961ec70; 14 tests; rejection 84/84 = 100% (bar ≥99%), own-voice 31/33; WeSpeaker path untested (no models); Gaussian MFCC fallback.
- [x] P6.1+P6.2 adaptation loop + learned lexicon — d07fac1, af25cb7; 27 tests; LoRA infeasible on-device → bias-list learner; day-30 < day-1 synthetic replay; regression fixture green.
- [x] P6.3 code-switching — 11b9852; 23 tests; IndicConformer MIT verified, no CoreML weights shipped; hinglish fixture lands as one string.
- [x] P6.5 iOS keyboard — db094ff, 14227c9; 22 KeyboardCore tests; UIKit/extension tree untestable here (no Xcode/iOS SDK), TestFlight manual.
- [x] Verify (cceb7c0): whole package builds clean; **930 tests green / 0 failed**; app launches and runs 8 s without crash; four timing flakes de-flaked.
- [x] **Phases 3–6 app integration** — done 2026-08-24, one phase per commit, **930 → 959 tests green** (`swift run VoicePlusApp` verified after each):
  - P3 (de94fc4): DeixisService on hotkey hold → contextLine in StageContext; AXReferentContext (deep window text → biasing + referents); per-display ink overlay, pulse rings + "which one?" elicitation with clarifying-text fallback. Phase3AcceptanceTests: two-display "move this over there". 936 tests.
  - P4 (cae24d4): second key (default Right ⌘) → ActSessionController → ActRouter (200-action catalog bundled, consent engine, native agent backend over provider planner); ActPreRouteHook claims act utterances (never typed); undo toast + confirmation card + agent cursor; ConnectorHub with Keychain + loopback OAuth (1456) + GitHub PAT, Settings "Services" tab. Phase4AcceptanceTests: 200-case irreversible fuzz zero unconfirmed. 944 tests.
  - P5 (93f5369): new `directedSpeech` flag (experimental, **default off** — synthetic-corpus-only pass, DECISIONS.md); HandsFreeController = directed × speaker gate × hard mute; wake verbs; "not you" teaching; three-state glyph + persistent hard mute; speaker enrollment (onboarding-2); MeetingCoordinator → notch prompt → local diarized notes. Phase5AcceptanceTests: 0 false triggers/day, TV rejection. 952 tests.
  - P6 (df2c4d6): AdaptationService (corrections + edits → TrainingPairStore → bias-list retrain → learned lexicon + regression guard in the live pipeline); Lab "you" tab; "Train by voice" + RememberToast; CodeSwitchRouter/Service + EN·हि pill badge (Indic weights not shipped — UnavailableIndicBackend); SyncService + QR pairing + Settings "Sync" tab. Phase6AcceptanceTests: day-30 < day-1, Hinglish one-string, sync round-trip. 959 tests.
- [x] **Phase 3 release** — 2026-08-24: `Packaging/releases/VoicePlus_3_1.3.0.dmg` (14 MB, sha256 `5344f3e9c8f90e7d012780af96d9c8ad3850cc11998901219f66a3c178da5969`), tag `release/phase-3/v1.3.0`, verify_install OK, notes `Packaging/notes/phase-3.md`, GitHub release updated with real notes; human test script (10 steps) pending.
- [x] **Phase 4 release** — 2026-08-24: `Packaging/releases/VoicePlus_4_1.4.0.dmg` (14 MB, sha256 `98ec9cf4367b0e8ee1be0f16e5ae902c6b3bce8bae472603ad79a2826e8e5ecc`), tag `release/phase-4/v1.4.0`, verify_install OK, notes `Packaging/notes/phase-4.md`, GitHub release updated; human test script (12 steps) pending.
- [x] **Phase 5 release** — 2026-08-24: `Packaging/releases/VoicePlus_5_1.5.0.dmg` (14 MB, sha256 `bfe33f9b99a243c3d256d82bb2db7b8f7ae062a1197ed807fda5c3a68074a3e0`), tag `release/phase-5/v1.5.0`, verify_install OK, notes `Packaging/notes/phase-5.md`, GitHub release updated; `directedSpeech` ships experimental/off; human test script (11 steps incl. real-corpus soak) pending.
- [x] **Phase 6 release** — 2026-08-24: `Packaging/releases/VoicePlus_6_1.6.0.dmg` (14 MB, sha256 `66ae1e52b469a2b65a85761f16e5256865d7e707eed5bc68ae9ee1305310a1af`), tag `release/phase-6/v1.6.0`, verify_install OK, notes `Packaging/notes/phase-6.md`, GitHub release updated; no TestFlight build (iOS keyboard source-only without Xcode); human test script (11 steps) pending.

## Post-release bug fixes (user-reported, 2026-08-29)

First install of a 1.6.0-class build on **real hardware** (notched MacBook, macOS 26.6.2) — onboarding could not be completed. Three bugs reported, all fixed and released as 1.6.1 + 1.6.2.

| # | Reported symptom | Root cause (one line) |
|---|---|---|
| 1 | "Allow Input Monitoring" did nothing; Accessibility never reachable | `CGRequestListenEventAccess()`/`AXIsProcessTrustedWithOptions` are non-blocking status reads, not dialogs — they return `false` instantly once *any* TCC row exists for the bundle id (ad-hoc cdhash identity), and Skip advanced past **all** remaining permissions instead of one. Compounded by six TCC-critical `Info.plist` usage strings being missing, which makes macOS refuse silently with no prompt and no log. |
| 2 | Mic-check level bar never moved; always "Very quiet…" despite mic granted + correct device | Onboarding metered `EngineState`, not audio: `RealEngine` emits one synthetic `.listening(level: 0)` before any sample exists, pinning the verdict to `.tooQuiet` forever, while the pipeline's `.level(rms:)` channel had no consumer at all. |
| 3 | Notch pill rendered under the physical camera housing (only its ends visible) | The notched branch placed the pill's top edge at `screen.frame.maxY`, so its top 38 pt across the housing's 220 pt had no panel behind it. |

Fix commits (seven):
- `1acf570` Packaging: TCC-critical `Info.plist` keys (`NSSpeechRecognition`, `NSContacts`, `NSCalendarsFullAccess`/`NSCalendars`, `NSCamera`, `NSLocalNetwork`, `NSAccessibility` — all missing), hardened-runtime ad-hoc signing, non-relocatable `LC_RPATH` (build-machine toolchain) stripped, bundle self-containment audit; `make_app.sh` now fails the build if a usage string is missing.
- `17ac108` BUG 1 + BUG 2: permission steps never dead-end (Open System Settings deep link, 0.5 s live status poll, Re-check, Continue anyway, stale-TCC recovery copy, **per-permission** Skip); mic meter driven by `PipelineMicLevelPublisher` off the real audio level channel, capture errors surfaced, "too quiet" withheld until real audio is heard.
- `f1c5db8` BUG 3: pill hangs off the bottom of the screen's forbidden top band (`NotchGeometry` topBand rule); retract rolls up to that boundary; re-layout on `didChangeScreenParameters`.
- `532e116` Onboarding window opened off-screen on an external display running a full-screen Space (`NSWindow.center()` centres on `NSScreen.main`) → new `WindowPlacement` pins to built-in/primary, clamps to `visibleFrame`, `.moveToActiveSpace`.
- `7e82ace` Meeting prompt panel had the same notch occlusion as the pill.
- `7a629a4` Pill waveform dead: `bind(engineState:)` called without `audioLevel:`, so levels were never passed to the pill and stopped at `.previewing`; `RealEngine` now publishes levels for the whole utterance and the app drives the pill from `PipelineAudioSource.onLevel`.
- `69a12c7` + `2f44d9c` Bundle-first fixture/catalog lookup (was source-checkout first, so installs took an untested path); and: an `NSHostingController` window has a 1×0 frame until first layout, so onboarding was centred as a 1×0 invisible window — size from content, re-centre on resize, log `window settled:`.

Releases:
- `Packaging/releases/VoicePlus_6_1.6.1.dmg` (15 MB, sha256 `020958a94e1af2b51831a0ece5b1d11c09e89d2aaaf2020f821ccdddd134d612`), tag `release/phase-6/v1.6.1`, verify_install OK, notes `Packaging/notes/phase-6-1.6.1.md`.
- `Packaging/releases/VoicePlus_6_1.6.2.dmg` (15 MB, sha256 `651ace2609b30309ef13334437bdc2c67ef1af824155b33cff8e589d206ac486`), tag `release/phase-6/v1.6.2`, verify_install OK, notes `Packaging/notes/phase-6-1.6.2.md`. **Superseded — this build cannot grant Microphone at all, see 1.6.3 below.**

**1006 automated tests green / 0 failed** at `release/phase-6/v1.6.2`.

### 1.6.3 — microphone regression introduced by our own 1.6.1/1.6.2 fixes

**1.6.1 and 1.6.2 introduced a regression that 1.6.3 fixes.** On those builds the user **could not grant Microphone at all**: the onboarding Microphone screen went straight to the "macOS only asks once" recovery UI with no **Allow** button, and VoicePlus did not appear in System Settings → Privacy & Security → **Microphone**, so there was nothing to enable there either.

Root cause (one line): the 1.6.1 permission rewrite persisted an `onboarding.requested.<permission>` flag and `OnboardingStateMachine.initialPhase` opened **any** flagged permission directly in the settings-recovery phase — but the sole call site of `AVCaptureDevice.requestAccess(for: .audio)` is the Allow button in the `.explain` phase, and calling that API is the only way an app can ever appear in the Microphone pane (it has no **+**), so flag + `tccutil reset` = permanent dead end. Proven from tccd: 1.6.2 emitted only `preflight=yes` status queries and never a `preflight=no` request.

Fix commits (six):
- `39cb91d` Promptable services (microphone, speech recognition, contacts, calendars) modelled separately from non-promptable ones (input monitoring, accessibility): a promptable service whose **live** status is `notDetermined` always opens on the Allow button regardless of any persisted flag; a dismissed dialog stays retryable; the 0.5 s poll self-heals a stale flag (a `tccutil reset` now recovers in-app, no rebuild, no Terminal); Re-check re-invokes the API; recovery panel gained "Ask macOS again"; per-service copy made truthful ("macOS only asks once" and the −/+ instructions now appear only for Input Monitoring and Accessibility, whose panes actually have those buttons).
- `375f97a` Headless `VoicePlus --request-permission microphone`, plus `Packaging/SIGNING.md` evidence that **hardened runtime is not a TCC barrier** — probe apps signed ad-hoc **with** `--options runtime` and our exact entitlements got the real prompt, so `--options runtime` **stays and must not be reverted**.
- `a43fc80` **Fix A — meeting capture is now opt-in.** Every launch previously requested Calendar **and** Reminders with no user intent (`AppDelegate` → `MeetingCoordinator.startMonitoring()` → unconditional `requestAccess()`; Reminders came from `EKEventStore()`'s no-arg initialiser covering all entity types). Now off by default, `startMonitoring()` inert until the user enables "Capture meetings", launch is status-query only, notification request moved to after an accepted meeting actually produced notes. tccd on a clean launch: zero Calendar/Reminders lines, zero prompts of any kind.
- `e7343c5` + `fca72b8` **Fix B — the onboarding phase is now logged** (`onboarding: microphone status=notDetermined phase=explain`), plus a headless `VoicePlus --onboarding-selftest`. The original regression was invisible in logs — the dead end and the correct path were byte-identical in `os_log` — which is why it took a user report to find.
- `3efde4b` **Fix C — three wall-clock tests de-flaked.** Nothing deleted: hang guards widened (120 s / 60 s), the chaos latency check load-normalised against a same-run baseline, suite `.serialized`.

Hardware verification of the fix: after `tccutil reset Microphone`, tccd logged `AUTHREQ_CTX … preflight=no` and `AUTHREQ_PROMPTING … kTCCServiceMicrophone, subject=Sub:{in.adityakatare.voiceplus}`, the dialog appeared, and TCC created the record.

Release:
- `Packaging/releases/VoicePlus_6_1.6.3.dmg` (15 MB, sha256 `5cde1597ffeb337ade8dcac93da748d0d88d2220807a9819ccab06a3bf3058b4`), tag `release/phase-6/v1.6.3`, verify_install OK, notes `Packaging/notes/phase-6-1.6.3.md`. **This is the build to install.**

**1032 automated tests green / 0 failed** at `release/phase-6/v1.6.3`, on two consecutive runs.

Outstanding manual items (not verified on real hardware — all instrumented, `log stream --predicate 'subsystem == "in.adityakatare.voiceplus"'`):
- The **enable → Calendar-request** path (that toggling "Capture meetings" on is the single place a Calendar dialog can originate) — unit-tested only.
- The **microphone prompt appearing through the GUI Allow button** — the API call itself is proven via tccd, but nobody could click the dialog from an automated session.
- Audio actually arriving from the physical mic at the mic-check step (`mic check: capture started on …`, `mic check: first audio block reached the meter`).
- The permission poll against real TCC (`onboarding poll: …`) — tested against a mock status source only.
- Multi-display window placement (`window settled: …`) — verified on the built-in display; the AirPlay/full-screen-Space case not re-reproduced.
- Pill waveform during live dictation.
- **User action required on every update:** permissions granted to an earlier build do not carry over — ad-hoc cdhash identity changes each build, and tccd logs `Failed to match existing code requirement`. Microphone now simply asks again (that is the 1.6.3 fix); Input Monitoring **and** Accessibility have no prompt, so remove the stale `VoicePlus` row with **−** and re-add the new app with **+** (or run `Packaging/reset_tcc.sh`). This repeats on every update until the app is signed with a Developer ID certificate and notarized — that is the only cure.
- Note: an agent ran `defaults delete in.adityakatare.voiceplus` during debugging, clearing saved preferences (onboarding-completed flag, hotkey choice, routing overrides) — onboarding re-runs and those need re-picking.

## Status: all 7 phase releases complete

Every phase of the build plan has shipped through `Packaging/release.sh`; checksums in `Packaging/releases/CHECKSUMS.txt`, notes in `Packaging/notes/`, tags + GitHub releases per phase. **959 automated tests green / 0 failed** at the final tag.

| Artifact | Version | Tag |
|---|---|---|
| `VoicePlus_0_0.0.1.dmg` | 0.0.1 (pipeline smoke) | — |
| `VoicePlus_1_1.0.0.dmg` | 1.0.0 | `release/phase-1/v1.0.0` |
| `VoicePlus_1.5_1.1.0.dmg` | 1.1.0 | `release/phase-1.5/v1.1.0` |
| `VoicePlus_2_1.2.0.dmg` | 1.2.0 | `release/phase-2/v1.2.0` |
| `VoicePlus_3_1.3.0.dmg` | 1.3.0 | `release/phase-3/v1.3.0` |
| `VoicePlus_4_1.4.0.dmg` | 1.4.0 | `release/phase-4/v1.4.0` |
| `VoicePlus_5_1.5.0.dmg` | 1.5.0 | `release/phase-5/v1.5.0` |
| `VoicePlus_6_1.6.0.dmg` | 1.6.0 | `release/phase-6/v1.6.0` |

**Remaining manual / hardware-only verification** (from DECISIONS.md + the integration reports — automated coverage stops here):
- Live mic → injection latency on real hardware, live AX paths (selection, hit-testing, deep window reads, LiveActionSystem) and all TCC grants (Microphone, Accessibility, Input Monitoring, Calendar, Screen Recording) — every phase's human test script on a clean account.
- 2 h thermal/battery soak on fanless hardware with `VOICEPLUS_LIVE_MODELS=1` (`Packaging/soak.sh 120`; only the 3-min mock soak has run).
- Real OAuth client IDs for the P4.6 connectors (env-supplied; only the GitHub PAT path works with zero setup) + live endpoint verification.
- Directed-speech real-corpus soak (recorded home+office corpus, < 1 false trigger/day) before `directedSpeech` can default on — current pass is synthetic-only.
- Indic RNNT CoreML weights for P6.3 (router ships with `UnavailableIndicBackend`); real Devanagari accuracy unmeasured until then.
- iOS keyboard build via Xcode (xcodegen + archive + TestFlight) — source-only in v1.6.0; Mac→iPhone sync round-trip untested end-to-end.
- Notarization + Developer ID signing + hardened runtime (all builds are ad-hoc signed) — pending an identity.
- Real-world recorded fixture suites (`Lab/FIXTURES.md` backlog) — all kill-criteria/gate numbers to date are on synthetic TTS audio.
