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

### 1.6.5 — read-only files in the app bundle (packaging only)

`xattr -dr com.apple.quarantine /Applications/VoicePlus.app` — the documented post-install step — printed three `Permission denied` lines and exited 1 on 1.6.4. `make_app.sh` copies SwiftPM resource bundles with `cp -R`, which preserves the source mode, and three files are `0444` in the build directory (`GRDB_GRDB.bundle/PrivacyInfo.xcprivacy`, `FluidAudio_FluidAudio.bundle/luxtts_en_us_lexicon.tsv.zz`, `…/luxtts_en_us_g2p_aux.json`). The errors were cosmetic — there was no quarantine attribute to strip — but they read as a broken install, and any tool needing to write an xattr hits the same wall.

`make_app.sh` now normalises permissions across the assembled bundle before codesigning (dirs 755, executables 755, everything else 644) and **fails the build** if any file lacks `u+w`; `verify_install.sh` asserts the same against the shipped dmg, plus no quarantine attribute in a fresh install and a clean `xattr -dr` (exit 0, no stderr). The new verifier fails on 1.6.4, naming exactly those three files. **Read-only files in the bundle: 3 → 0.** No app behaviour change; signature unchanged, so 1.6.4 grants carry over.

Release:
- `Packaging/releases/VoicePlus_6_1.6.5.dmg` (15 MB, sha256 `6f4ded76ebe428b2bb56e73482d4b3d66b9f2a142db0a57509e6930f7b66dd03`), tag `release/phase-6/v1.6.5`, verify_install OK, notes `Packaging/notes/phase-6-1.6.5.md`.

### 1.6.6 — permissions are picked up live; the relaunch was our bug

> **⚠️ Partly retracted by 1.6.7 (see below).** The per-service verdicts in this section are
> **correct for Accessibility only**. For **Microphone** and **Input Monitoring** the claim
> "no relaunch needed" was **wrong**: macOS does not hand either service to a process that is
> already running. 1.6.7 measured it twice (Apple's own `PrivacyTCCServices.plist`, plus a
> natural experiment on this machine showing 25 s and 18 s of stale status inside the granting
> process) and reverses the guidance. The Input-Monitoring *arming* bug described below was
> real and is still fixed; what was wrong was concluding from it that no OS limit exists.

**The question this release answers: does granting a permission require quitting and relaunching?** Measured per service on macOS 26.6.2:

- **Microphone — no.** `AVCaptureDevice.authorizationStatus` re-queries tccd on every call, and capture re-checks authorization and re-opens the device on every dictation.
- **Accessibility — no, and proven.** `AXIsProcessTrusted()` is cached per process, but macOS drops that cache on the `com.apple.accessibility.api` distributed notification, which the app already subscribes to; the user's own toggle was observed making the *running* app issue a fresh tccd query **213 ms later**. macOS ships no "quit & reopen" alert for Accessibility at all, so that button is **removed** from that screen.
- **Input Monitoring — the relaunch was our bug, not an OS limit.** `hotkey.start()` had exactly one caller (completion of the permission walk), which never runs while onboarding is open and was held behind the *Accessibility* pre-prompt — a permission the hotkey does not need. Input Monitoring had been granted for 20+ minutes with no event tap ever created. The new `CapabilityWatcher` (`App/Services/CapabilityArming.swift`) owns the tap lifecycle, re-reads the permission matrix every second plus on the accessibility and app-activation notifications, and arms exactly once — `CapabilityArming.decision` is a pure function that returns `.hold` once armed, so the 1 s poll cannot stack duplicate taps. `CGEvent.tapCreate` is not a permission test (six creations, six non-NULL taps, no permission at all), so *working* is judged from event delivery against `CGEventSource`'s system-wide modifier idle: a deaf tap gets one silent re-arm, and only then is a restart offered.

**Honest caveat — untested (and, per 1.6.7, resolved against us):** it was **not** possible to prove that an event tap begins delivering events, in an already-running process, immediately after Input Monitoring is granted. That needs a human at the switch, and Apple's own Settings copy claims a restart is needed. **Quit & Reopen therefore stays on the Input Monitoring screen as a fallback** (and only there).

**The Accessibility root cause, now identified exactly.** The row the user had been toggling stored a code requirement of `cdhash H"459b5909…"` — the CDHash of **VoicePlus 1.0.0**, the very first Phase 1 build. It had been dead since 1.1.0. Toggling a row rewrites only its auth value, never the stored code requirement, which is why it could never work. That poisoned row has been cleared; a fresh grant records against `identifier "in.adityakatare.voiceplus"` (the stable designated requirement from 1.6.4) and survives all future builds.

Also in 1.6.6 (`6f2c409`, `89627b6`): the escalated recovery copy no longer asserts what the app cannot read — it claimed "that switch belongs to an older build" from `attempts >= 1 && !isTranslocated` alone, without establishing that an entry exists, that its switch is on, or that its requirement mismatches. It now leads with the cure (numbered steps at body size), keeps the cause conditional, and cites corroborating grants only when they exist. "Remove the old entry…" runs the scoped `tccutil reset <service> <bundle id>` for the user, gated on the escalated phase where nothing is granted. Every permission screen now states, per service, whether a quit is needed. The permissions step scrolls, so the numbered steps cannot be the first thing clipped in the 520×420 window.

Release:
- `Packaging/releases/VoicePlus_6_1.6.6.dmg` (15 MB, sha256 `736716ea540a74154573e6cc287ca8bf31411fd905987403ce5c6c13f31dd058`), tag `release/phase-6/v1.6.6`, verify_install OK, notes `Packaging/notes/phase-6-1.6.6.md`. **This is the build to install.**

**1074 automated tests green / 0 failed** at `release/phase-6/v1.6.6`, on two consecutive runs.

### 1.6.7 — the dictation key no longer kills the app

Five user-reported problems, all root-caused, four fixed outright and one (P6) reversing a claim we
made in 1.6.6. This is the largest patch on the Phase 6 line.

**P1 — pressing the dictation key crashed VoicePlus, 100% of the time, on every Mac.**
`App/Overlay/OverlayWindow.swift:13` called the five-argument
`super.init(contentRect:styleMask:backing:defer:screen:)`; AppKit re-dispatches that ObjC convenience
initializer through `self` into the Swift "unimplemented initializer" trap stub the compiler emits for
the four-argument designated init the subclass never overrode → `EXC_BREAKPOINT`. Every capture start
goes through `InkOverlayController.show()`, so it could never succeed even once, on any Mac.
Reproduced standalone and deterministic (4-arg init survives, 5-arg traps, independent of notch,
display count and nil screen). **Not a 1.6.6 regression** — that file has one commit and line 13 never
changed; 1.6.6 merely armed the tap for the first time, so a keypress could finally reach the code.
The menu-bar "Start dictation (no hotkey)" item never crashed because it does not touch the overlay —
that asymmetry was the confirming signature. Fixed by calling the four-argument initializer *and*
overriding the designated init so no trap stub exists for any future AppKit path (`8ec3ad0`).
Confirmed at the binary level on both shipped artifacts: 1.6.6's `@objc` thunk is
`bl __swift_stdlib_reportUnimplementedInitializer` + `brk #0x1` with no Swift body symbol at all;
1.6.7's tail-calls the real initializer and returns.
The latent second bug from the same investigation is closed too: the tap's `Unmanaged.passUnretained(self)`
refcon in a class with **no `deinit`** is now an integer token through a lock-protected registry, plus
a `deinit`, a teardown at the head of `start()` (exactly one live tap per service), and an installer
seam so arm → re-arm → stop is testable without CoreGraphics (`8e8559f`, `0201ac4`).

**P2 — the onboarding test showed a green "It landed. You're set." for a transcript that never existed.**
`runGuidedDictation` called `engine.start(prewarm:)` and `engine.stop()` in consecutive statements, so
the capture window was zero-length: the user spoke after the engine had stopped, the final pass got ~0
samples, and FluidAudio threw `ASRError.invalidAudioData` under its 300 ms floor. The catch then
**discarded the error and emitted the success event with an empty string**, which the view rendered as
a green check (`landedText != nil`); the button never called `UtteranceLander` at all, so "It landed"
could not have been true on any machine. The raw token came from `"\(error)"` instead of
`localizedDescription`. Now: a two-state button (Dictate now / Stop & transcribe) with a real capture
window, a 30 s self-stop, mic teardown, an `isFinalizing` latch so an impatient second press cannot
overwrite a good transcript, and a `GuidedDictationOutcome` of landed / heard / noSpeech / failed —
"It landed" requires an injection that reported success (`ab156d5`, `3f0a315`).

**P3/P4 — model readiness and names.** P3's premise was refuted (the full Parakeet TDT 0.6B v3, 461 MB,
was already on disk in the FluidAudio cache; nothing was downloading), but the design defects were real:
the step now names the recogniser it will use, shows real download progress with bytes/name/ETA, and
disables the button only when nothing on the Mac can transcribe — it no longer offers a test that cannot
work. Choosing a tier now downloads it (the old `download == .notStarted` guard meant a second choice
fetched nothing). Real model names and sizes are derived from `ModelCatalog`: Fast = Parakeet TDT-CTC
110M (110 MB), Balanced = Parakeet TDT 0.6B v3 (500 MB), Best = that plus Parakeet Realtime EOU 120M
(900 MB total). All three hardcoded sizes were wrong — "Best" advertised "~1.2 GB".

**P5 — the notch chin.** There was no always-visible VoicePlus affordance anywhere; the status item is
exactly what macOS culls on a crowded notched panel. A non-activating panel now hangs off the bottom of
the display's forbidden top band with states ready / listening / processing / muted / paused / blocked,
sharing **one geometry rule with the pill** (top edge == `frame.maxY - topBand`) so it can never draw
under the camera housing — verified live at y=1130 against a housing at `{{790,1131},{220,38}}` for
every state × hover × display fixture. Click-through except while the pointer is provably on it (a click
pops the status item's own menu), joins all Spaces, one level below the pill, switchable off in
Settings › General. Full screen suppresses **only the quiet states** — `listening`, `processing` and
`muted` always draw, because a hidden hot mic is the failure the spec forbids (`fdb1e49`, `c04a202`,
`9b5e9fa`).

**P6 — we were wrong about relaunching, for two of three services.** 1.6.6 said no relaunch is ever
needed. That holds **only for Accessibility**. Two independent lines of evidence: (a) Apple's own
`/System/Library/PreferencePanes/Security.prefPane/…/PrivacyTCCServices.plist` defines
`quitAllowTitleForAppName` for `kTCCServiceListenEvent` and `kTCCServiceMicrophone` and has **no entry
at all** for `kTCCServiceAccessibility`, and both strings are categorical ("will not have access… until
it is quit") where the Screen Recording one is hedged ("may not"); (b) a natural experiment on this
machine — Microphone granted 6 s into PID 76635's life, which then polled once a second for its
remaining **25 s** and never stopped reading `denied`; Input Monitoring granted 16 s into PID 76861's
life, `notDetermined` for its remaining **18 s**; each *following* process read the new value on its
first query — while **Accessibility did flip live inside a running process** (grant at 19:25:30.054 →
capability change at 19:25:31.021). A background `LSUIElement` control ticked a `.default` 1 Hz timer
49 times in 50 s, so App Nap is not an available explanation. **Measurement boundary kept explicit:**
what was measured is that the *status API* stays stale for the process lifetime; whether the underlying
*capability* is also dead was not measured and is claimed nowhere. The converse matters too — a status
API reading "granted" is not proof the capability works: `CGEvent.tapCreate` returns a non-NULL tap with
no Input Monitoring permission at all, which is why liveness is judged from event delivery, never from
tap creation. `Permission.grantReachesRunningApp` now records the verdict per service with its evidence;
`RelaunchAdvisor` fires only when the offer is honest (sent to Settings → came back → 3 s grace → still
off), closing a real gap — 1.6.6's only trigger, `onTapProvenDead`, presupposes an armed tap, and the tap
never arms while preflight reads false, so in the exact reported scenario it **structurally could not
fire**. The prompt quotes macOS' own sentence, keeps its headline conditional (the app cannot read
TCC.db), refuses to offer a relaunch from a translocated copy, and a first-time Microphone ask is told a
restart is **not** needed (that grant arrives through the app's own dialog, live in-process)
(`8e8559f`, `f7372de`, `4f86f3c`, `5c3bfa8`).

The 13 commits, oldest first: `a2ccc18` (1.6.5/1.6.6 notes + manifest), `8e8559f` (P1+P6 tap token,
per-service relaunch honesty), `fdb1e49` (P5 presence indicator), `c04a202` (P5 composite level),
`ab156d5` (P2/P3/P4 onboarding truth), `9b5e9fa` (P5 hosting view), `8ec3ad0` (**P1 crash fix**),
`f7372de` (P6 relaunch wiring), `4f86f3c` (P6 first-ask copy), `3f0a315` (P2 finalize latch),
`0201ac4` (P1 tap token fast path), `5c3bfa8` (P6 conditional headline), `f9ebac5` (release).

Release:
- `Packaging/releases/VoicePlus_6_1.6.7.dmg` (15 MB, sha256 `12e2583638c27028b936b591b3cde96c0c4c77543ed10f847dfdb4c829f349a7`), tag `release/phase-6/v1.6.7`, verify_install OK, notes `Packaging/notes/phase-6-1.6.7.md`. **This is the build to install.**

**1165 automated tests green / 0 failed** at `release/phase-6/v1.6.7` (`swift test --no-parallel`;
baseline at 1.6.6 was 1074).

Still open after 1.6.7:
- **The last link is unverified on hardware:** real finger on the dictation key → tap → startCapture →
  overlay. It could not be synthesised (posting to our own PID does not reach a session tap; posting
  session-wide would have driven every other dictation app on the machine). Both sides of the link are
  verified — the tap arms in production (one arm per service over 65 s, zero re-arms) and the initializer
  that trapped is a real function in the shipped binary. One human press settles it.
- `OnboardingDependencies.landUtterance` is still nil, so the last onboarding step reports *heard*, not
  *landed* — honest, but not an end-to-end landing test. `DictationCoordinator.guidedLanding` is
  implemented and tested on both branches; wiring it is a few lines in `AppDelegate`.
- **The P6 capability experiment is still open** — whether the capability (not just the status API)
  recovers mid-session after "Later" needs a grant toggled while a process runs. The shipped behaviour is
  correct either way; it only decides whether self-recovery could be added on top.
- **Eight `init()` trap stubs remain in the binary** (5 FluidAudio, 2 `StatusItemController`), all on
  plain `init()`, all audited as unreachable — none is an AppKit designated initializer. That is an
  argument, not a test. Ship rule worth adopting: **no release without one path that instantiates every
  window and view class.**
- **Two wall-clock tests flake under parallel load** — `GatekeeperLatencyTests.classifyStaysUnderBudget`
  and `ASRGoldenTranscriptTests.realEngineEndToEndOnFixture` (32.7 ms vs 15 ms, 1.169 s vs 0.4 s under
  load average 20–36; 0.029 s and 226 ms in isolation). `--no-parallel` is green.
- **Not verifiable headlessly:** the chin compositing over another app's full-screen window; whether a
  76×4 pt chin at 0.35 opacity reads right on a Retina panel (taste — one constant each); real-pointer
  hover and click-to-open-menu; a live 900 MB download (progress/ETA unit-tested against a mock); the
  real FluidAudio decoder path.
- `BundledModel.bootstrap` is still dead code, so there is no bundled tiny model; the false claim that
  there was one has been removed from the picker copy.
- **The 1.6.6 GitHub release title is now wrong** — "no more relaunching to pick up permissions" is the
  claim P6 retracts for two of three services.
- **The appcast enclosure URLs 404 anonymously**, for 1.6.7 and identically for 1.6.6: the GitHub repo is
  private, so Sparkle cannot fetch a release asset without credentials. The asset itself is intact
  (HTTP 200, 15,466,684 bytes, digest matching, via the authenticated API). Auto-update from a private
  repo cannot work as configured; `Packaging/appcast.xml` needs a reachable host or a public repo.

### 1.6.8 — VoicePlus no longer belongs in Input Monitoring

The user asked the question that unlocked this: *"Claude, Wispr Flow, Gemini, Raycast, Spokenly and Muesli
all run global hotkeys on this Mac and none of them need Input Monitoring. Why do we?"* They were right,
and the cause was one line.

**Root cause.** `HotkeyService` used `CGEvent.tapCreate(options: .listenOnly)` — **the single global-input
API on macOS gated on `kTCCServiceListenEvent`**. Nothing about hold-to-talk, and nothing about the
bare-modifier gesture, requires that API. Four rounds of TCC debugging, a stale-grant dead end, and the
mandatory quit-and-relaunch were all downstream of that one choice: the relaunch is a property of
`kTCCServiceListenEvent` (it alone carries `quitAllowTitleForAppName` in Apple's `PrivacyTCCServices.plist`),
not of VoicePlus.

**What ships.** `start()` selects a backend from the binding (`HotkeyBackendSelector`, pure and tested):

| Binding | Backend | Permission |
|---|---|---|
| Right ⌥ (default), Left ⌥, Right ⌘, Right ⌃, fn | `NSEvent` global + local `flagsChanged` monitors | none |
| ⌃⌥D, ⌃⌥A | Carbon `RegisterEventHotKey` + `InstallEventHandler` | none |
| any, with `hotkeyForceEventTap` | the 1.6.7 `.listenOnly` event tap | Input Monitoring |

**The default hotkey is unchanged** — Right ⌥, hold to talk, double-tap for hands-free.
`HotkeyStateMachine` was not touched (hold 250 ms, tap guard 180 ms, double-tap 350 ms).

**Deviation from the item as written, and it is the good kind.** The brief anticipated demoting the bare
modifier to an opt-in that still costs Input Monitoring, and defaulting to a chord. Measurement said that
was unnecessary — a bare-modifier global monitor delivers with **zero** TCC grants — so Right ⌥ stays the
default at no permission cost, and every shipped picker choice reads "no extra permission" instead of the
trade-off framing the plan assumed. Input Monitoring is now reachable **only** through the
`hotkeyForceEventTap` escape hatch, which nothing in the shipped UI turns on.

**Independent verification (this release's own bundle, macOS 26.6.2 arm64).** Method: take the shipped
`.app`, change only `CFBundleIdentifier` to a throwaway id that has never existed, re-sign ad-hoc, launch
through LaunchServices so TCC attributes it to that id rather than to the terminal. It then has no TCC
record at all — its own report reads `AXIsProcessTrusted()=false`, `CGPreflightListenEventAccess()=false`,
all three services `notDetermined`.

- **Arms:** `hotkey: armed (#1) via globalMonitor for Right ⌥ — needs no permission`, alongside
  `capabilities: capture=false hotkey=true inject=false hotkeyNeeds=nothing … [inputMonitoring=notDetermined]`.
- **Receives:** real HID `flagsChanged` generated permission-free with
  `IOHIDSetModifierLockState(kIOHIDCapsLockState)` (caps state read before and restored after) moved
  system-wide modifier idle **1205.27 s → 0.13 s**, and the app's own liveness watchdog stayed silent
  through its 20 s grace — that watchdog fires exactly when `eventsReceived == 0` while the system saw
  modifier keys, so its silence is the app asserting delivery.
- **A/B naming the culprit:** same binary, same zero-grant identity, `hotkeyForceEventTap` flipped on →
  `hotkey=false hotkeyNeeds=inputMonitoring` and **no `armed` line at all**.
- **Not opportunistic:** under the real bundle id, where this machine has `inputMonitoring=granted`, it
  still chooses `globalMonitor` and reports `hotkeyNeeds=nothing`. Selection is by binding style, never by
  what happens to be granted.
- **Onboarding:** the walk is microphone → accessibility only, confirmed headlessly via
  `--onboarding-selftest`.

**Trap recorded so it is not re-hit:** `RegisterEventHotKey` *accepts* a bare-modifier registration
(`kVK_RightOption`, empty mask), returns `noErr` with a valid ref, and then never fires. Testing only the
return code concludes it works. Hence the selector routes on `HotkeyBinding.Style`, never on "did
registration succeed". Also: `IOHIDPostEvent` is a dead end — `status=0` on both
`kIOHIDParamConnectType` and `kIOHIDEventSystemConnectType`, and it injects nothing.

**Bonus fix.** The Settings hotkey picker was decorative — it wrote its own defaults key and offered an
`f5` the binding type could not express, so choosing a key did nothing. It now writes `hotkeyBinding`, and
an armed service observes `UserDefaults.didChangeNotification`, so a Settings change reaches the running
app instead of waiting for the next launch. Migration: all five 1.6.7 raw values survive verbatim; an
unparseable stored value logs and falls back to the default.

**1207 tests green / 0 failed** (plain parallel `swift test`, first run; 1165 at 1.6.7). Signature
untouched — `designated => identifier "in.adityakatare.voiceplus"` — so 1.6.4+ grants carry over.
verify_install OK, and it left the user's running instance alone.

**Untested / honest limits:**
- **A real finger on Right ⌥ is still unverified.** `CGEventPost` needs Accessibility and
  `IOHIDSetModifierLockState` can only move caps lock, so delivery is proven with a *different* modifier
  than the bound one. The flag-word classifier is unit-tested and `NSEvent`/`CGEvent` field parity is
  pinned by `HotkeyBackendFlagWordTests`, but one human press closes this.
- **Carbon chords are lightly exercised** — they register (`status=0`; duplicate `-9878`) and drive the
  state machine in a probe, but nobody has lived on a chord binding. The default path is the monitor.
- **Accessibility read `notDetermined`** for the copy under `Packaging/build` (the installed
  `/Applications` copy has it), so `inject=false` in the quoted lines and the injection path was not
  exercised in those runs. Expected for a second copy at a different path; unchanged from earlier releases.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing since the first
  phase-6 release, deliberately not addressed here.

### 1.6.9 — the app can no longer invent words the user did not say

**The most serious defect found on this project.** With no ASR model on disk and no Apple Speech
fallback — **every fresh install, including the whole of onboarding** — `App/Services/EngineFactory.swift`
silently substituted `MockEngine` loaded from `Fixtures/transcripts/email_reply.json`. The mock replayed
those spans on a timer **with no microphone input at all**, the pill previewed them as the user's own
speech, and on hotkey release `UtteranceLander` typed them into the frontmost application:
*"Hi Priya, thanks for the update. Let's sync with TeamViewer tomorrow."* A name the user never wrote and
a meeting they never proposed, injected into a real document.

**It was live in release builds, not only in development.** `Packaging/make_app.sh` copied `Fixtures/`
into the shipped `.app`, so the bundle carried exactly the file the fallback needed. And the trigger is
the common case, not an edge case: a fresh install has no model until the onboarding download completes.

**Root cause, stated plainly:** "no recogniser available" was treated as a reason to substitute a fake
one, and the fake output was structurally indistinguishable from a real transcript — nothing in a
`TranscriptSpan` marked it, so nothing downstream could refuse it.

**What ships.**
- `EngineFactory` **no longer falls back to the mock**. `MockEngine` is reachable only by explicit
  developer opt-in via `VOICEPLUS_ENGINE=mock` / `VOICEPLUS_FIXTURE`.
- New `Shared/Engine/UnavailableEngine.swift` publishes `EngineState.unavailable(reason)` and nothing
  else: it never emits `.partial`, `.final` or `.previewing`, and `stop()` returns no spans. There is no
  path through it that produces a character of text.
- New `PillState.unavailable(reason:)` — **its own case, not a transcript string**, so the notice can
  never be mistaken for or substituted as speech. It reads "No speech model installed." The presence
  indicator reports `blocked(.modelMissing)` instead of "ready", which was the second lie: the app
  claimed to be listening when it could not hear.
- `DictationCoordinator.finalize()` returns early for an unavailable engine, so the lander/injector is
  never reached even in principle.
- `make_app.sh` no longer copies `Fixtures/` into the bundle at all. Nothing shipping read it —
  `transcripts/` was mock-only, `directed/` test-only, `tools/` a dev script. Verified: a built bundle
  contains none of the fixture sentences.

**New `Tests/AppTests/UnavailableEngineTests.swift` — 6/6 passing.** It pins the property, not the
implementation: no span of any kind escapes the engine, `stop()` returns empty, finalize does not reach
the injector. **`AppTests` 392/392 and `SharedTests` 37/37 green, 0 failed**; `swift build` clean for the
whole package. Full-package total recorded at the release build. 1 commit (`329af01`) on top of 1.6.8.

**Untested / honest limits:**
- **Nobody has watched the unavailable pill on a genuinely fresh machine.** The behaviour is covered by
  tests against the engine and the coordinator; the visual on a clean install is unverified.
- **The bundle check is a string search** over one build of the current `make_app.sh` — it proves the
  fixture text is absent from that artifact, not that a future change cannot reintroduce it. There is no
  packaging assertion guarding this the way `verify_install.sh` guards file modes.
- **`VOICEPLUS_ENGINE=mock` still injects fixture text**, by design. It now requires deliberately setting
  an environment variable, and nothing in the shipped UI turns it on.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### Test-harness safety fix (2026-09-06, post-1.6.6)

`Packaging/verify_install.sh` terminated processes by **name**: its cleanup trap ran `pkill -x VoicePlus`, so a verification run killed the **user's own running /Applications instance** mid-session (pid 76823 — it had to be relaunched by hand). A run during dictation would have lost the transcript. All three name-based kills are gone: the script records the pid of the instance it launched (matched by *executable path* against its own temp copy, normalised with `pwd -P` because `mktemp` returns `/var/…` while `ps` reports `/private/var/…`) and signals only that pid, guarded by `kill -0`; INT/TERM route through the same scoped cleanup so an interrupted run cannot orphan its own instance; pre-existing instances are listed before and after the run as a visible assertion they were left alone. `soak.sh`'s sampler kill was already pid-scoped (guarded against an unset `SAMPLER`); `reset_tcc.sh` kills nothing — it asks the user to quit the app, which stays the rule: **no script may stop a user's instance silently.** Verified against `VoicePlus_6_1.6.6.dmg` with two other instances running (/Applications and `Packaging/build/`): verify OK, its own instance stopped, both others still alive; same when the run was SIGTERM'd mid-flight (exit 143, no orphan, temp dir removed).

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
