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
whole package — **1224 tests green / 0 failed** for the full package at the release build. 1 commit
(`329af01`) on top of 1.6.8.

**Untested / honest limits:**
- **Nobody has watched the unavailable pill on a genuinely fresh machine.** The behaviour is covered by
  tests against the engine and the coordinator; the visual on a clean install is unverified.
- **The bundle check is a string search** over one build of the current `make_app.sh` — it proves the
  fixture text is absent from that artifact, not that a future change cannot reintroduce it. There is no
  packaging assertion guarding this the way `verify_install.sh` guards file modes.
- **`VOICEPLUS_ENGINE=mock` still injects fixture text**, by design. It now requires deliberately setting
  an environment variable, and nothing in the shipped UI turns it on.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.0 — the mic check now needs a microphone, not a fixture

**The onboarding step that asks you to talk passed without anyone talking.** On a machine with no ASR
model — again, every fresh install — the user ran "Say something.", **said nothing at all**, and the
level meter filled and the step reported "Sounds good." The only admission was a small caption:
*"Simulated meter — no real capture is running in this build."* The step passed regardless.

**Root cause:** the mic-check meter was fed by the **speech engine's** state rather than by the
microphone. `AppContainer` chose `PipelineMicLevelPublisher` (real capture) only when a live audio
pipeline existed, and that existed only when a recogniser did — never during onboarding, which by
definition runs before any model is on disk. It fell back to `EngineMicLevelPublisher`, forwarding the
**mock** engine's fixture-derived `listening(level:)` numbers; the verdict fired on any level `>= 0.08`,
so a fabricated number cleared the gate exactly as a spoken word would. After 329af01 the same install
builds `UnavailableEngine`, which emits nothing, so the bar was dead rather than fake — still incapable
of telling the user anything true. Separately, a user who **denied or skipped** the microphone
permission was routed to the mic check anyway, onto a meter that could never move for a reason the
screen never named.

**What ships.**
- **Onboarding owns a real capture session, independent of the speech engine.** New
  `PipelineMicLevelPublisher.standalone()` builds `AcousticCaptureSource(wrapping: CoreAudioCaptureSource())`
  → `AudioPipeline(vad: EnergyVAD())` → `PipelineAudioSource` — the same audio graph the app uses, minus
  the recogniser. Metering a microphone never required a speech model; now the mic check does not either.
  `EngineMicLevelPublisher` is **deleted**: no engine-derived path into the meter survives.
- **Passing without real audio is structurally impossible**, enforced at three layers:
  `MicLevelPublishing.isRealCapture` lost its defaulted `true`, so every conformer must declare its
  provenance (the default was how a synthetic source got to look real by saying nothing);
  `OnboardingViewModel` refuses to start or subscribe to a non-capture source; and
  `OnboardingStateMachine` is **default-deny** — it discards `.micLevel` entirely while capture
  provenance is unconfirmed, so an undeclared level never touches the peak and `verdict` is never even
  called.
- **The "Simulated meter" caption is gone**, along with the code path that made it reachable.
- **A blocked microphone gets its own screen.** A denied or undetermined permission opens `.micCheck` on
  a new **"The microphone is blocked."** verdict with no capture started, copy that names the problem, a
  button to the Microphone privacy settings, and a **Re-check** that asks about the permission and
  proceeds only on an actual grant — instead of a dead meter or a silent skip.

**New `Tests/AppTests/OnboardingMicCheckHonestyTests.swift` — 11 tests.** They pin the property, not the
implementation: undeclared levels can neither pass nor be counted, a non-capture publisher is never
started or metered, retry clears provenance, a capture failure blocks the step, and a denied microphone
is immune to injected levels. **Full package: `swift build` clean, 1224 tests passing.** 1 commit
(`fa2c3a2`) on top of 1.6.9. Ships in the same dmg as 1.6.9.

**Untested / honest limits:**
- **The HAL leg is untested — an agent cannot speak into a microphone.** Unverified precisely: that
  `standalone()` opens a real input device and delivers taps on real hardware, and that a genuine grant →
  speak → "Sounds good." round trip works end to end. Everything above the hardware boundary is covered
  by tests. **Recommend the user run a real spoken mic check on first launch**; the standalone check for
  the same leg is `--mic-selftest` on the signed bundle, which drives the identical capture graph
  headlessly under the app's own TCC identity.
- **Nobody has seen the blocked screen on a machine that actually denied the microphone.** Its copy and
  routing are covered by state-machine tests; the visual is unverified.
- **`OnboardingDependencies.mock(pretendRealMicCapture: true)` still lets a synthetic meter stand in**, by
  design and by name, for tests of the post-capture logic. Nothing in the app sets it — `AppContainer`
  builds a real capture graph unconditionally.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.1 — dictation now starts working when the model finishes downloading

**The app downloaded 900 MB, said it had the model, and stayed dead.** The owner installed 1.7.0, ran
onboarding, chose **Best**, watched the whole download complete, and read the next screen confirm
*"Using Parakeet TDT 0.6B v3."* Pressing the hotkey then produced **"No speech model installed —
Dictation is off until a speech model is installed"**, and onboarding's own **"Dictate now"** showed
**"Listening…"** and never recognised a word. The microphone was fine — the mic-check step earlier in
the same run had passed for real.

**Root cause:** the speech engine was resolved **exactly once, at app launch**, and never re-resolved. A
fresh install necessarily launches with no model on disk, so every collaborator that took the engine at
startup — coordinator, pill, presence indicator, code switcher, onboarding, a dozen in all — took
`UnavailableEngine` and held it for the life of the process, however many models the user then
downloaded. The staleness was **pre-existing but masked**: before 1.7.0 an app with no recogniser fell
back silently to `MockEngine` replaying a fixture, so a stale engine produced *fabricated* transcripts
rather than silence. Removing that fallback in 329af01 was correct, and it turned a hidden bug into a
visibly dead app.

**What ships.**
- **The engine has a stable lifetime, not stable contents.** New `Shared/Engine/SwappableEngine.swift`
  is a box owning **one** state subject and **one** event broadcaster, re-attached to whichever engine
  is inside — so the dozen-odd collaborators holding it subscribe once and keep working across a swap,
  with no refactor of the call sites and no second subscription path to go stale differently.
  Availability is queried through a new `EngineAvailabilityReporting` protocol.
- **`AppContainer.refreshEngineIfNeeded()` swaps only on an availability flip** — a real engine when a
  model lands, `UnavailableEngine` when one disappears — so an ordinary utterance never disturbs a
  working engine. It runs at three moments that were three faces of one bug, not three bugs: a download
  completing (`ModelManagerTiers.onModelsChanged`), **hotkey-down preflight**, and before onboarding's
  **"Dictate now."**
- **A mid-utterance swap lands nothing rather than something wrong.** The outgoing engine is cancelled,
  and a `stop()` whose `start()` belonged to a previous generation returns no spans — so a swap in
  flight cannot land half an utterance, and cannot land the same one twice.
- **A failed or cancelled download changes nothing.** The change notification never fires, so the app
  stays honestly unavailable instead of swapping in an engine with no model behind it.

**New `Tests/AppTests/EngineSwapTests.swift` — 8 tests.** They pin the property, not the
implementation: a subscriber bound before the swap sees the new engine's states, a swap happens only on
an availability flip, a stale `stop()` returns no spans, and a failed download leaves the engine
unavailable. **Full package: `swift build` clean, 1259 tests passing** (1224 at 1.7.0). 1 commit
(`d4f804d`) on top of 1.7.0. Ships in the 1.7.3 dmg.

**Untested / honest limits:**
- **No agent on this machine has a real downloaded model**, so the construction of the *real* engine
  inside the swap — the CoreAudio graph plus the FluidAudio model load — is unverified. What is covered
  is the swap machinery: subscriber continuity, the availability-flip condition, generation-scoped
  `stop()`, and the no-swap-on-failure path.
- **A true end-to-end round trip — download → speak → text appears — has not been run by anyone.**
  Recommend the owner do it once on a real machine.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.2 — choosing a model is no longer the same act as downloading it

**Two reported bugs on onboarding's "Pick a free local model." step, both about consent rather than
plumbing.** The three options were radio buttons, so merely *selecting* one silently began a
several-hundred-megabyte download; nothing said a selection was also a commitment. And **Continue was
enabled while the chosen model sat at 3%**, so the user clicked through to a dictation step with no
model on disk — the exact route into the dead app 1.7.1 fixes.

**Root cause:** `.choose` both selected a tier and started fetching it; Continue was live from the
moment a fetch *started* rather than the moment a model *landed*, treating "we began a download" as "the
user has a model." Download state was shared rather than per option, so one row's progress or failure
was painted under all three. And presence was tracked **per tier** — "Best" is "Balanced" plus an extra
120 MB model, so with Balanced already on disk, choosing Best offered the whole 900 MB again.

**What ships.**
- **Every option has its own Download button**, so choosing and committing are separate acts: `.choose`
  selects and nothing else, and a new `.download(tier)` event — raised only by that option's own button
  — is the only path to a fetch. **Selection alone never downloads.**
- **Each row shows its own state** from `downloadStates`: **Download**, or that option's live progress
  (*"1 of 2 — 27 MB of 900 MB"*) with **Cancel**, or **Installed** with **"Use this"**.
- **Continue waits for the model to genuinely be on disk** — gated on `installedTiers` read back from
  the model manager rather than inferred from a started fetch, and `.next` is **refused by the state
  machine**, not merely greyed out in the view. It says why: *"Balanced is still downloading (3%).
  Continue turns on the moment it lands."*
- **Presence is per model, not per tier**, so an already-downloaded model is never offered for
  re-download: Best reads **"Download 120 MB · Only the part you don't have yet."**
- **Skip stays — and states its cost.** It records that it was taken without a model and warns, on the
  dictation step and the final screen, that dictation will not work until one is installed.

**New `Tests/AppTests/OnboardingModelPickerTests.swift` — 9 tests**: selection does not download, only
`.download(tier)` fetches, `.next` is refused while the chosen model is absent, the blocked reason names
the model and percent, per-row state does not bleed across options, an installed model is not
re-offered, and skip records its cost. `OnboardingStateMachineTests` and `OnboardingDictationTests`
updated for the split. **Full package: `swift build` clean, 1259 tests passing.** 1 commit (`3b9c75e`)
on top of 1.7.1. Ships in the 1.7.3 dmg.

**Untested / honest limits:**
- **The real HuggingFace download is unverified.** No agent here has fetched a model, so live byte
  counts, the *"1 of 2"* multi-file progress, and **mid-flight Cancel** against a real transfer are
  covered against the model-manager protocol and mocks only.
- Everything above the download boundary is tested: gating, refusal, per-row state, per-model presence,
  the blocked-reason text, and the skip warnings.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.3 — the status row fits its text, and you can see it without hovering

**Three complaints about one surface, the little row under the notch.** It was **cut off** —
*"VoicePlus · Ready — hold R…"*, with no state in which the rest ever became readable. It was
**invisible**: at rest the indicator drew nothing at all inside a 4 pt chin at 35% black, a near-black
sliver under a black bezel, so the app appeared to have no presence unless you happened to hover over
the notch. And it was **mute about how to use the app**: no ambient sign that VoicePlus was running and
armed, and no discoverable reminder of the dictation hotkey.

**Root cause:** the hover panel was a hard-coded **190 pt** drawing `lineLimit(1)` with
`truncationMode(.tail)`, so any longer message was clipped permanently — and "hold Right ⌃" was exactly
the part that fell off, so the one thing the row existed to teach was the one thing it hid. `.ready` at
rest was an `EmptyView`, and where a hotkey label existed it was a literal, so a rebound key would have
been described wrongly.

**What ships.**
- **The row is sized to its content.** New `App/Core/PresenceRow.swift` handles text fitting and the
  hotkey hint; `PresenceRow.fit` measures in the **real font** and `NotchGeometry`/
  `NotchPresenceGeometry` clamp against actual notch and screen geometry. The pill gets the same
  treatment for its fixed notices.
- **A narrow display degrades in order, never mid-word** — the **hint** drops first, then the
  **"VoicePlus · " prefix**, then **trailing whole words**. No half a word plus an ellipsis.
- **At rest it is a status light, not a banner**: a 10 pt chin at 72% carrying one small lit dot.
- **It announces itself when there is something to announce** — the full row expands for **six seconds**
  at launch and whenever the app **recovers out of a blocked state**, so it tells the user the moment a
  model download makes dictation live again. Never after an ordinary utterance, and click-through while
  announcing so it cannot eat a click.
- **The hotkey label is read live from the configured binding** (`HotkeyHint.label`): *"hold Right ⌃"*
  for a bare modifier, *"press ⌃⌥D"* for a chord — so it follows a change in Settings instead of
  hardcoding "Right Control".

**New `Tests/AppTests/PresenceRowTests.swift` — 17 tests.** They pin the property, not the pixels: the
fitted width holds the whole string, degradation drops components in order and never splits a word, the
hint tracks the binding rather than a literal, and the announce window fires on launch and on unblock
but not after an utterance. `NotchPresenceTests` updated for content-sized geometry. **Full package:
`swift build` clean, 1259 tests passing.** 1 commit (`06c5ccd`) on top of 1.7.2. Carries 1.7.1 and 1.7.2
in its dmg.

**Untested / honest limits:**
- **Every visual judgement here is unverified — an agent has no window server.** Precisely unknown:
  whether the lit-dot chin reads as visible-but-quiet against a **real** bezel, whether six seconds
  feels informative or intrusive in daily use, and the **true measured width** of the expanded row in
  the system font on real hardware. Fitting, degradation order, hint derivation and announce triggers
  are covered by tests; how any of it *looks* is not.
- **The degradation ladder has not been seen on a genuinely narrow display** — its order is tested, its
  appearance at each rung is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.4 — dictation no longer wedges itself permanently after one use

**Onboarding's "Dictate now" worked exactly once.** Pressing **"Try again"** then said *"VoicePlus is
already recording."* — and said it forever. With the real hotkey the same fault wore a different face:
an error appeared on key **release**, and after four or five attempts the hotkey **stopped working
altogether** — no listening state on press, and a broken animation flashing on release. Only relaunching
the app cleared it.

**Root cause — two defects compounding into one symptom.** `RealEngine.start()` set `listening = true`
**before** `try audio.start()` and never rolled it back when that threw (a denied microphone, a 3 s HAL
start timeout, a format mismatch), so the flag outlived the session it described: it stood up with no
capture behind it, and every later start threw `alreadyListening` for the rest of the process. And
`DictationCoordinator` ran start, finalize and cancel as **three independent racing `Task`s**, so a key
released during warm-up ran `stop()` **before its own `start()` finished** — the stop threw
`notListening` and was swallowed, the start then succeeded, and the engine was left recording with
nobody left to stop it. Onboarding and the hotkey **share one engine**, which is why a failure on either
path killed the other.

**What ships.**
- **One session flag with one owner**, held by the coordinator and written by nothing else.
- **All engine calls on a serial chain**, so a release can never overtake its own start.
- **Unconditional teardown on every exit path** — success, throw, cancel — so a session cannot outlive
  the code that created it.
- **`RealEngine.start` rolls back fully on a failed `audio.start()`**, so a capture that never opened
  leaves no flag behind.
- **A held-over session is released and retried rather than refused**: an `alreadyListening` start is
  retried once after a forced cancel, so **a wedge clears itself instead of needing a relaunch**.
- **Bounded preflight** (`refreshEngineIfNeeded` sits in the hotkey path), **`SwappableEngine.swap`
  cancels the outgoing engine unconditionally**, and **`AppDelegate` resets the hotkey gesture when
  capture never opened** — the reason the hotkey went dead after four or five failures.

**New `Tests/AppTests/DictationSessionLifecycleTests.swift` and
`Tests/EngineTests/RealEngineStartRollbackTests.swift` — 11 tests** over the four ways the session used
to leak: a second utterance after a success, after a failed start, after a cancel, after a stop that
threw; a key released during warm-up; an engine another owner left recording; an engine swap
mid-utterance; and a preflight that overruns. The preflight bound is a **raced continuation, not a task
group** — `withTaskGroup` waits for its children on exit, so the timeout never actually fired. **Full
package: `swift build` clean, 1313 tests passing** (1259 at 1.7.3). 2 commits (`14010b7`, `9a01b91`) on
top of 1.7.3. Ships in the 1.7.8 dmg.

**Untested / honest limits:**
- **No agent on this machine has a microphone**, so the failure modes that *start* this bug — a denied
  mic, a real HAL start timeout, a format mismatch — are reproduced against the capture protocol and
  mocks. The rollback, the serialisation and the self-healing retry are covered by tests.
- **No agent has driven the hotkey with a real key press.** The gesture reset is tested at the
  coordinator boundary; the CGEvent leg is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.5 — the onboarding window no longer clips its own buttons

**The window was a hard-coded 520 × 420 for six steps of very different heights, with no scroller.**
When a model download started, roughly **120 pt** of progress UI appeared on the model step — a progress
bar, a wrapping progress line, a Cancel button, an info line and a two-line amber warning — and the
footer went off the bottom edge. That footer is **Back / Skip / Continue**: the only way forward, cut in
half by the window it lived in. Option subtitles were truncating mid-sentence in the same window.

**Root cause:** a fixed `.frame(width: 520, height: 420)` suits a step at rest and nothing else; nothing
scrolled, so content that did not fit simply overflowed; and the action row had **no reserved space** —
laid out after the step content, it was the first thing to lose when the content grew, which is the
worst possible casualty since it is the only exit.

**What ships.**
- **Each step reports its own laid-out height and the window adopts it** — new
  `App/Onboarding/OnboardingWindowSizing.swift` — **clamped to the usable area of the display the window
  opens on**, so sizing to content can never size past the screen.
- **The step area is the only flexible region, and it scrolls.** The progress bar and the action row
  keep their space at any content height, so **the clipped footer is structurally impossible** rather
  than merely unlikely.
- **Progress text sits in a reserved fixed-height box**, so a tick from *"95 MB"* to *"96 MB"* is a text
  change rather than a window relayout, and **sub-1 pt geometry republishes are ignored**, which removes
  the residual jitter from measurement noise during a live download.
- **Option subtitles wrap** instead of truncating mid-sentence.

**New `Tests/AppTests/OnboardingWindowSizingTests.swift` — 15 tests**: the window adopts the tallest
reported content, the clamp holds against a small display, the chrome keeps its height while the step
area absorbs the overflow, a sub-point change does not republish, and a step that grows mid-flight (the
download case) still leaves the action row fully on screen. **All six steps checked in their tallest
states.** **Full package: `swift build` clean, 1313 tests passing.** 1 commit (`8b359e3`) on top of
1.7.4. Ships in the 1.7.8 dmg.

**Untested / honest limits:**
- **Every visual judgement is unverified — an agent has no window server.** Precisely unknown: how the
  resized window *looks* at each step, whether the grow animation is pleasant, and whether the scrolling
  step area is ever visibly scrolled on a normal display. The sizing arithmetic, the clamp, the fixed
  chrome and the jitter suppression are covered by tests.
- **The clamp has not been seen against a genuinely small display** — its behaviour is tested, its
  appearance is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.6 — the dot's click means something, and errors stay long enough to read

**Two faults on the notch surface introduced with 1.7.3's presence row.** Clicking the new **green
presence dot** opened the menu bar app's menu — not sometimes: the dot was wired unconditionally to
`statusItem.popUpMenu()` for **every** state, so the one control that describes the app's health
answered every click with a list of commands. And errors **flashed past unread**: `RealEngine` emits
`.landed` then `.idle` back to back while the reducer mapped `.error` to a preview the next `.idle`
erased, so the pill ran its slide-in and slide-out in the **same run-loop pass** — the "broken
animation" the owner saw on key release, and the reason he could not screenshot the error he was
hitting.

**Root cause:** one click behaviour for every state, so a dot meaning "the microphone is denied"
answered a click with something other than the way to fix it; `landing` → `hidden` reduced in one pass
with no time in between; and an error was **not its own state** — it was `.preview("⚠︎ …")`, a
transcript-shaped string, so it could not be sized, dwelled or styled as a notice, and any later `.idle`
erased it as though it had been speech.

**What ships.**
- **A click router** (new `App/Core/PresenceClick.swift`). The **primary click** pins the expanded row
  open for **5 s in place**, with no focus change, so the dot explains itself — or, on a **blocked** dot,
  goes to the actual remedy: relaunch, the **Microphone** or **Input Monitoring** privacy pane, or our
  own **Settings** for a missing model. **Right-click / ⌃-click still opens the menu**, preserving the
  escape hatch for a culled status item.
- **A presenter owns the single write path to the pill** (new `App/Core/PillPresentation.swift`).
  `PillPresenter` gates every write to `PillViewModel.state`: a **visible state lands immediately**, but
  a **retraction waits out the current state's `PillDwell` minimum** — **4 s** for an error or warning,
  **0.6 s** for *"Landing…"*, 0 for everything else. The flicker is not smoothed; it is unreachable.
- **`.error` is its own `PillState` case** with a **headline and subtitle**, so it can be sized and
  dwelled as a notice — **legible for four seconds**, long enough to read and to photograph.
- The panel stays a **non-activating `NSPanel`** and nothing on the explain path activates the app.

**New `Tests/AppTests/PillPresenterTests.swift` — 13 tests**: a visible state lands with no delay, a
retraction inside the dwell is held and then applied, `landed` followed immediately by `idle` produces
one visible notice rather than a flicker, an error outlives its erasing `.idle`, and the dwell differs
correctly between a notice and "Landing…". `PillTests` updated for `.error` as its own case. **Full
package: `swift build` clean, 1313 tests passing.** 1 commit (`243c57a`) on top of 1.7.5. Ships in the
1.7.8 dmg.

**Untested / honest limits:**
- **Every visual judgement here is unverified — an agent has no window server.** Precisely unknown:
  whether the pinned click-to-explain row reads as an explanation, whether five seconds is the right
  pin, and whether the four-second error pill is long enough to read without being long enough to annoy.
  The dwell arithmetic, the routing per dot state and the single write path are covered by tests.
- **The privacy-pane deep links have not been followed on this machine** — the URLs are pinned by test;
  whether each lands on the right pane on the owner's macOS version is not verified here.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.7 — the warm-up records, and only one owner holds the microphone

**"Dictate now" left the notch on "Warming up…" for a long time before anything happened**, and whatever
was said during that time was gone. Separately, **two owners were fighting over the microphone**:
onboarding's level meter and the speech engine each believed they had configured capture while only the
first of them actually had.

**Root cause:** `RealEngine.start(prewarm:)` resolved the recognizers **before** `audio.start()`, so a
**cold CoreML load of Parakeet TDT** ran with the microphone shut — unbounded, with no progress to show,
and **every word spoken during it discarded**. Nothing loaded the model eagerly, so the **first** key
press of the session paid the entire compile. And `PipelineAudioSource.start()` **returned success while
doing nothing** whenever the source was already running — the onboarding meter is handed the **same
source the engine uses**, so the second owner inherited a graph whose **ring, VAD and utterance tap
belonged to the first owner's session**, and whichever owner stopped first **closed the microphone under
the other**.

**What ships.**
- **Explicit audio ownership with rank and preemption** — the **engine outranks** the meter and
  diagnostics. A start either **takes the graph and restarts it clean** (ring, VAD and tap rebuilt for
  the new owner) **or throws `AudioCaptureError.busy`**. There is no third outcome that quietly
  succeeds, and **displaced owners are told**.
- **A stop releases the graph only if that owner still holds it**, so a displaced owner's late `stop()`
  cannot close the new owner's microphone.
- **Capture-first cold start:** `RealEngine.start` **opens the microphone before resolving the model**;
  samples captured while the model loads are **buffered** and the preview pass is flushed the moment the
  recognizer is ready, so a push-to-talk press **never loses its opening words**.
- **Eager preload** — new `RealEngine.preloadModel()` and `AppContainer.warmUpEngine()` load the model
  **at launch** and again **after a download-driven engine swap**, so the first press is not the cold
  one.

**New `Tests/AppTests/AudioSourceOwnershipTests.swift` and
`Tests/EngineTests/RealEngineColdStartTests.swift` — 8 tests**: the engine taking the graph from the
meter and getting it restarted, tap and all; a meter refused out loud while dictation holds capture; a
displaced owner's late stop that must not close the new owner's microphone; a failed start that leaves
no owner; audio **and preview text spoken during a cold model load surviving**; a failed cold start
releasing capture; and `preloadModel()` loading **without** publishing *"Warming up…"*. **Full package:
`swift build` clean, 1313 tests passing.** 2 commits (`9f4b0c3`, `54888e6`) on top of 1.7.6. Ships in
the 1.7.8 dmg.

**Untested / honest limits:**
- **The badly-wrong hotkey transcription is not confirmed fixed.** The owner reported the hotkey path
  producing **completely wrong text** where onboarding was accurate. Recognizer configuration was proven
  **identical** between the two paths and biasing was **ruled out** as a text corruptor, which leaves a
  shared-capture-graph corruption as the leading explanation — and this is exactly the fix for that —
  but **the cause is not confirmed on hardware.** Recommend the owner retry the hotkey and report.
- **The real cold-load duration is unmeasured.** No agent here has loaded Parakeet TDT, so how long the
  eager preload actually takes at launch is unknown.
- **No agent on this machine has a microphone**, so ownership, preemption and the buffered cold start
  are covered against the capture protocol and mocks, not a real HAL device.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.8 — "it downloaded the Balanced model by itself"

**Reported, after choosing Best and watching 900 MB download:** *"I only downloaded the best 900 MB
model. It downloaded the Balanced itself."* It did not. **Best** is Parakeet TDT 0.6B v3 **plus** the
EOU model, and **Balanced** is that same TDT v3 — so completing Best completes Balanced with **not one
extra byte fetched**. Per-model presence (1.7.2, `3b9c75e`) is right and stays. What was missing was
**the sentence**: both rows read a bare **"Installed"**, and a green check beside an option nobody asked
for reads as **500 MB the app decided to spend on its own**. Technically correct is not good enough on a
several-hundred-megabyte download; presented bare, it destroys trust.

**Root cause:** the overlap was **never stated** — nothing before the download said Best contains
Balanced, and nothing after it explained why a second row had turned green — and **"Installed" could not
tell two different facts apart**: a tier the user **explicitly downloaded** and a tier their choice
**brought along** rendered identically. Separately, **three code comments called the EOU model
"120 MB"**, misreading the **"120M"** in its name as **parameters**, not megabytes. It is **400 MB**;
the advertised **900 MB** total was right all along — **500 + 400**.

**What ships.**
- **The containment is stated *before* anything is downloaded** — the Best row reads *"Includes
  Balanced's 500 MB model, plus 400 MB more."*, computed from `ModelCatalog` in new
  `App/Onboarding/ModelTierComposition.swift`, so the figures cannot drift from what is actually
  fetched.
- **Afterwards the Balanced row reads "Included with Best"**, not a bare "Installed" — a visible
  consequence of the user's own choice rather than a mystery download.
- **A non-selected installed row says "Switching downloads nothing."** and fetches nothing, which is now
  a test rather than a claim.
- **The state machine tracks `explicitlyDownloadedTiers`** — the buttons the user actually pressed —
  because "installed" alone cannot distinguish a tier the user fetched from one their choice carried in.
  **A tier downloaded on its own keeps the plain "Installed"**; crediting it to Best would be its own
  small lie. With nobody's presses remembered (after a relaunch) the shared row still explains itself.
- **The "120 MB" comments are corrected to 400 MB.**

**New `Tests/AppTests/OnboardingTierCompositionTests.swift` — 7 tests.** One **pins each tier's label to
the sum of its catalogue entries**, so the advertised figures cannot drift again; the rest cover the
containment line appearing before any download, "Included with Best" only for a tier the user did not
press, "Installed" surviving for one they did, "Switching downloads nothing." fetching nothing, and the
shared row explaining itself with no press history. **Full package: `swift build` clean, 1313 tests
passing.** 1 commit (`3842440`) on top of 1.7.7. **Ships in the 1.7.9 dmg.**

**Untested / honest limits:**
- **Whether "Included with Best" reads correctly in its column is unverified** — no window server, so
  the wording is tested and its appearance is not.
- **The real HuggingFace download remains unverified** — pre-existing since 1.7.2, unchanged here. The
  composition arithmetic is computed from the catalogue and pinned by test; the bytes are not fetched by
  anyone here.
- **The badly-wrong hotkey transcription is still unconfirmed on hardware** — see 1.7.7.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.9 — dictation no longer types a paragraph of your document instead of your words

**The most alarming thing the owner reported.** Dictating *"The quick brown fox jumps over the lazy dog"*
through the **hotkey** landed **completely wrong text**, while the **same sentence** through
**onboarding** was accurate — same model, same microphone, same session.

**Root cause: it was never audio and never recognition — the app's own learned-corrections system was
poisoning itself.** `ZeroEditTracker` finalised an edit with `finalText` set to the **entire focused
field's accessibility value** — the whole document the user was typing into — while `originalText` was
just the one utterance (`Lab/Counter/ZeroEditTracker.swift:126`). `AdaptationService.ingestEdit` then
**word-diffed a single utterance against a whole document**, and `BiasListLearner` dutifully stored the
result as corrections — variants mapping an ordinary word like **"the"** to **two paragraphs of the
user's own document** (`Engine/Adapt/AdapterTrainer.swift:84-90`). On a later utterance
`RegressionGuard.apply` **substituted that blob for the real word**
(`Engine/Adapt/LearnedLexicon.swift:114`), and its **phonetic fallback matched on a single occurrence**,
so one poisoned pair spread to **any similar-sounding word**. **That asymmetry is the whole explanation
of the two paths:** `RegressionGuardStage` is installed **only in the hotkey pipeline**
(`AppContainer.swift:157-158`); the onboarding path displays **raw recognised spans**.

**What ships.**
- **New `LexiconSanity` states the rule a correction has to satisfy — a respelling, never a document.**
  It is enforced at **three** points: when a pair is **stored**, when an edit readback is **ingested**,
  and, critically, **when a variant is used** — so a `lexicon.json` **already poisoned on a user's
  machine degrades to pass-through** rather than continuing to corrupt text. **No manual reset is
  required**, though a user who wants a clean slate can quit VoicePlus and remove
  `~/Library/Application Support/VoicePlus/Adapt` (there is no in-app control for this).
- **A "landing diff" diagnostic.** `UtteranceLander` logs **one line per utterance** — **raw recognised
  text vs landed text**, their **Levenshtein distance**, and **which stages touched the spans** — so **a
  single real utterance** definitively separates *"the recogniser misheard"* from *"post-processing
  mangled it"*. Local `os_log` only, nothing leaves the machine, consistent with the no-telemetry
  stance; **verbatim text stays off** unless the app is launched with `VOICEPLUS_LOG_TEXT=1`. Read with
  `log show --last 30m --predicate 'subsystem == "in.adityakatare.voiceplus" AND category == "pipeline"'
  --info | grep "landing diff"` — **`distance 0`** means post-processing is innocent and the recogniser
  is at fault; anything else points back into the pipeline.

**Cleared with evidence**, worth recording because it is the rest of the post-processing chain:
`ContractEnforcingStage`/`ConfidenceContract.verify` enforce the confidence/audioRange/provenance
invariant on **every** stage (a violation falls back to the stage's input), `CodeSwitchService.finalize`
returns `nil` unless **two scripts are genuinely present**, and **every provider stage falls back to a
deterministic local path** when no API key is configured — none of them silently degrade into inventing
text.

**5 new tests in `Tests/EngineTests/AdaptTests.swift`**, covering the sanity rule at each of the three
enforcement points including an already-poisoned lexicon degrading to pass-through. **`swift build`
clean, 1318 tests passing.** 1 commit
(`8e440fe`) on top of 1.7.8. **This is the dmg — it carries 1.7.4 through 1.7.8 as well.**

**Untested / honest limits:**
- **It is not confirmed that this specific poisoning is what the owner hit.** No agent here has
  hardware, and their `lexicon.json` may or may not have been in that state. The mechanism is proven in
  test and it explains the hotkey/onboarding asymmetry exactly, but **the diagnosis on that machine is
  unconfirmed.** The new landing-diff line settles it in **a single key press** — that is the
  recommended next check.
- **No agent on this machine has a microphone or a window server**, so everything here is covered
  against protocols and mocks rather than a real capture device.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.10 — the dictation key was also the "act" key, so your sentence became an agent goal

**With the Best model fully downloaded and onboarding finished, pressing the dictation hotkey (Right ⌘)
produced no transcription at all.** What appeared in the notch instead was
`Agent: failed(reason: "planner: disabled(stage: act.planner)")` — two failures in one line: **the words
never landed**, and **the app spoke to its owner in a debug string**.

**Root cause: a chain, each link individually reasonable.** `AppDelegate` defaulted the **act (second)
key to `.rightCommand`** — the **same physical key as dictation** — and nothing anywhere prevented the
two from sharing it, so **one press drove both hotkey services**. The act session opened, **raced
`engine.stop()` for the transcript**, found **no catalogue command** matching the user's sentence, and
fell through to **`.agentic(goal:)`** — so **a plain dictated sentence became an agent goal**. That is
the right fallback for a deliberate act press and completely wrong for a dictation press that should
never have reached it. `ProviderPlanner.plan` then called `providers.complete` **unconditionally**; with
**no provider pinned for `act.planner`** the router threw `ProviderRoutingError.disabled`;
`NativeAgentBackend` turned that **configuration state** into `.failed(reason:)`; and `AppDelegate`
rendered it with `String(describing:)` — producing the raw internal string the owner read.

**What ships.**
- **`ActKeyBinding.isDistinct` — the act key is inert while it shares a key with dictation.**
  **Dictation wins the collision**, because that is the app's whole purpose, and the check is
  re-evaluated **per event**, so **a rebind from Settings takes effect immediately** with no relaunch.
- **`ProviderPlanner` checks whether the provider is enabled before calling it**, and maps every
  `ProviderRoutingError` to a new **`PlannerError.unavailable`** — **a state, not a failure**. "You have
  not configured this" and "this broke" are different facts and now have different types.
- **`AgentRunStatus` speaks plain language.** It gains `.unavailable` and a `userMessage` for **all
  seven** cases — *"Actions need a model set up in Settings"*, *"That didn't work"*, *"I couldn't work
  out how to do that"* — and the failure reason **no longer interpolates the underlying `Error`**.
- **`ContractEnforcingStage` degrades a throwing stage to pass-through**, preserving **confidence,
  `audioRange` and provenance**, instead of **unwinding the run and discarding every earlier stage's
  output**. One broken stage now costs its own contribution, not the user's sentence. **`.strict` still
  rethrows.**

**Scoped deliberately.** An audit of every provider caller found **`ProviderPlanner` was the only
unguarded one**, so the guard went where it was missing rather than everywhere as ceremony; the
contract-stage change is **generic and covers all 11 stages**, so the next stage that throws for its own
reasons cannot take a dictation turn down with it.

**13 new tests** across `Tests/ActionsTests/PlannerUnavailableTests.swift`,
`Tests/AppTests/ActPlannerRegressionTests.swift` and
`Tests/PipelineTests/StageFailurePassthroughTests.swift`. One is a standing guarantee about the app's
voice: **no status message may contain `failed(`, `reason:`, `stage:` or `act.planner`.** The rest cover
an unconfigured planner resolving to `.unavailable` rather than `.failed`, a genuinely broken planner
whose reason carries no debug text, the two hotkeys being required to be two different keys, a disabled
`act.planner` stage still landing the recognised text in the frontmost field, and a throwing stage
passing its input through with the span invariants intact while strict mode rethrows. **`swift build`
clean, 1347 tests passing.** 2 commits (`68e75d0`, `69638f5`)
on top of 1.7.9. Ships in the 1.7.12 dmg.

**Untested / honest limits:**
- **That Right ⌘ push-to-talk now types text with the act key silently disabled is unverified on
  hardware**, as is **that rebinding the act key restores act commands** — no agent here has a
  microphone or a window server; the binding rule, the planner state and the pill's wording are covered
  against protocols and mocks.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.11 — a model that reported "installed" but was half-downloaded

**Choosing the Fast model, the download reported success** and onboarding said *"Using Parakeet TDT-CTC
110M (tiny)"* — then **"Dictate now"** showed *"Warming up…"* and failed with **`The file
"weight.bin.partial" doesn't exist.`** That file is **not ours**: it is **FluidAudio's download scratch
file**, streamed from HuggingFace and then moved into place, and the user should never have seen its
name at all.

**Root cause: two defects, and it took both.** First, `ModelManager.load` was **actor-isolated but
suspended across `AsrModels.load`**, and **an actor releases itself across a suspension** — so the
**launch preload** and the user's **"Dictate now"** both saw nothing loaded and both loaded.
`AsrModels.load` is **not a pure read**: it **re-downloads whatever the cache lacks**, so two of them
over one folder **raced on the same `.partial` file** — one won the move, the loser reported it missing.
(**The eager preload added in 1.7.7 did not cause this**; it supplied the *second caller* that made an
already-present race reachable.) Second, the **"is it installed?" check was `fileExists` over paths that
are every one of them `.mlmodelc` *directories*** — which **exist from the very first byte written into
them** — so a download that had barely started already read as **complete**. FluidAudio documents this
exact trap upstream.

**All three tiers were equally at risk** — they share **one fetcher, one presence check and one
loader**. **Best succeeding earlier was luck of timing, not a safer path**, which is worth stating
plainly because *"it only happens on Fast"* was the comfortable and wrong conclusion.

**What ships.**
- **New `Engine/ASRRuntime/ModelIntegrity.swift` defines complete-and-loadable** rather than present:
  **no `.partial` / `.part` / `.etag` files anywhere**, **required paths present**, **every `.mlmodelc`
  bundle carrying its `coremldata.bin`**, and **no truncation** against the manifest's byte counts. A
  **cheap `stat` walk, no hashing** — it runs on **every hotkey press**. It walks the tree **by hand**
  rather than subtracting path strings, because `/var` and `/private/var` are the same file spelled two
  ways and the arithmetic silently turned "delete the debris" into a no-op.
- **`load` dedupes in-flight tasks and gates on integrity** — concurrent callers share **one load task**,
  and a model that is not complete-and-loadable is neither loaded nor reported installed.
- **The fetcher verifies a staged tree _before_ publishing it, and swaps rather than delete-then-move**,
  so **a failed move can no longer destroy a working install** and **`.partial` files stay in staging**
  where nothing can read them as installed.
- **Recovery is automatic.** A broken model reports **not-installed**, so the picker simply **offers a
  re-download**; and `repair(_:)` deletes **the `.mlmodelc` bundle each `.partial` sits in** — not just
  the scratch file, since a bundle caught mid-download is missing an interior weight file no
  `requiredPaths` list names, and clearing only the `.partial` leaves something that **passes every
  check and still cannot load**. **Intact siblings stay**: a retry costs **one bundle, not the model**.
- **The user reads a sentence, not a scratch filename** — *"The Parakeet TDT-CTC 110M (tiny) speech model
  didn't finish downloading — 1 file is missing or incomplete…"*. The errors **count** the incomplete
  files rather than naming them.

**New `Tests/EngineTests/ModelIntegrityTests.swift`.** A `.partial` inside a bundle does not report
installed on **any tier**; an interrupted or cancelled download leaves nothing that does; a download that
lands incomplete **throws instead of publishing**; **concurrent loads share one load task**; and the
**verbatim Cocoa error from the report is rewritten**. `ModelManager`'s loader was made **injectable** so
the dedupe contract is testable **without CoreML models**. **`swift build` clean, 1347 tests passing** for the whole
package. 2 commits (`c5fe8ae`, `a2f2887`) on top of 1.7.10. Ships in the
1.7.12 dmg.

**Untested / honest limits:**
- **The end-to-end recovery path is untested — download Fast, interrupt it, relaunch, dictate.** No agent
  here fetches the real bytes from HuggingFace. The integrity rules, the dedupe, the staged-then-swapped
  publish and the rewritten error are covered against a synthesised model tree on disk; a **real
  interrupted download is not**.
- **The real HuggingFace download remains unverified** — pre-existing since 1.7.2, unchanged here.
- **No agent on this machine has a microphone or a window server**, so the warm-up path itself is covered
  against protocols and mocks.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.12 — the error notice covered half the screen, and the dot's click went back to opening the menu

**Two things, both on the notch surface, both hit on real hardware.** When dictation failed the owner
got, in their words, *"a big black strip emanating from the notch in the center with an error"* — **a
black slab over roughly half the screen height** for a one-sentence error. And, separately: *"It was ok
to open menu on left clicking the notch. No need to make it right click."*

**Root cause: not the geometry math.** Every frame `NotchGeometry` computed was correct and the panel was
still a slab. **`NSHostingView.sizingOptions` defaults to `.standardBounds`**, which publishes the
SwiftUI content's **minimum** size as the panel's **`contentMinSize`** — and **AppKit then grows the
window to it after every `setFrame`**, overruling the layout code silently after it had finished. With
**`.fixedSize` on the notice stack** the minimum **width** was **one word**, so the minimum **height**
became the **fully wrapped paragraph**. Measured with a standalone AppKit probe: a panel set to
**420×64** came back **420×1187** for the owner's actual message, and **420×4727** for a long one.

**What ships.**
- **`sizingOptions = []` with explicit content min/max on both the pill and presence panels** — the
  hosting view opts out of window sizing entirely, so **frames are placement math and never content**.
- **A bounded notice view** — headline **two lines, tail-truncated**; subtitle **one line**; **no
  `fixedSize`**. A long error is **elided**, not unrolled.
- **`NotchGeometry.absoluteMaximumSize` — 560×96** — **clamped per display** and applied in **both
  sizing and layout**, so even a caller asking for **9000×9000** gets a pill.
- **The presence dot's left-click opens the status menu again.** The **1.7.6 remedy routing is removed
  rather than kept for blocked states**: a click whose meaning depends on **decoding the dot's colour
  first** is exactly the unpredictability being complained about, and every remedy it offered — **Check
  permissions…**, **Settings…**, **Quit** — is **one item away in the menu anyway**.
  **`PresenceClickRouter` survives as the single tested decision point**; the dead code was **deleted
  rather than left asserting behaviour we no longer have**.

`Tests/AppTests/NotchGeometryTests.swift` covers **2,600- and 5,000-character messages staying bounded
across five display shapes**, in both sizing and layout, including a caller demanding an absurd size;
`Tests/AppTests/PillPresenterTests.swift` is updated for the simplified click contract. **`swift build`
clean, 1347 tests passing.** 1 commit (`30911bb`) on top of
1.7.11. **This is the dmg — it carries 1.7.10 and 1.7.11 as well.**

**Untested / honest limits:**
- **Every visual judgement here is unverified** — an agent has no window server. Specifically
  unconfirmed: **that the error notice is now a compact two-line pill under the notch**, and **that
  left-clicking the dot pops the menu without stealing focus**. The size ceiling is measured and pinned
  by test; how it *looks* is not.
- **No agent on this machine has a microphone, a window server, a real model download or hardware**, so
  everything across 1.7.10–1.7.12 is covered against protocols, mocks and synthesised trees on disk.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.13 — every speech model was downloaded twice

**After choosing a model the owner watched "Warming up…" for well over a minute**, and then found
**two byte-identical 468 MB copies of Parakeet TDT v3** on disk. The wait was real work — it was just
work that had already been done once.

**Root cause: VoicePlus stored the model in a folder FluidAudio would never look in, and then asked
FluidAudio to load from it.** The folder was named from **`ModelID.rawValue`**
(`parakeet-tdt-0.6b-v3-coreml`), but **`AsrModels.load(from:)` ignores the directory it is passed** —
it takes the **parent** as a models root and asks **`ModelHub`** to resolve the name itself, and
**`Repo.folderName` strips `-coreml`**, so it descended into **`parakeet-tdt-0.6b-v3`**. Finding that
**empty**, it **re-downloaded the entire model from HuggingFace**. **Only `parakeet_vocab.json` was
ever read from our own copy.** Measured from the owner's log: the duplicate download cost roughly
**81 seconds** of the wait, on top of a genuinely one-time **~19 second Neural Engine compile**. **All
tiers were affected** — one naming rule, one loader.

**What ships.**
- **The on-disk folder name now comes from `ModelDescriptor.folderName`**, decoupled from
  **`ModelID.rawValue`** — which stays the model's **stable identity**, since it is `Codable` and is
  already written into every `voiceplus-manifest.json` on disk — and set to **FluidAudio's own
  `Repo.folderName`**, so **the path it resolves is the path we wrote**.
- **`ModelCatalog.fluidAudioFolderName(for:)` reads `Repo.folderName` out of the dependency** rather
  than repeating the string, and **a test pins our name to FluidAudio's**: an **upstream rename fails
  the build here** instead of costing every user another **468 MB**.
- **The EOU model keeps its own name** — `StreamingEouAsrManager.loadModels(from:)` opens the files
  **in the directory it is given** and never re-downloads, so it was never affected.
- **New `Engine/ASRRuntime/ModelLayoutMigration.swift` runs from `ModelManager.init`** and leaves
  **exactly one folder per model, re-downloading nothing**: a **lone legacy folder is renamed**; where
  **both** exist the **complete one is kept** (ours first, since it carries the manifest) and the
  **orphan deleted**. Publishing is a **swap**, so a failure leaves a working model under *some* name
  rather than none. **Nobody re-downloads, and an affected user reclaims 461 MB on first launch.**
- **`BiasVocabulary.discoverParakeet` builds its candidates from the descriptor**, legacy name
  included — it is the one thing that ever read from our own copy, so a hard-coded name there would
  have **stopped finding it the moment the migration ran**.

**Verified against the real 461 MB model on disk** with **`ModelHub.offlineMode = true`**, so nothing
*could* be fetched: the **new** path loads with *"no download needed"*; the **old** path reports the
model **missing** — **exactly where it used to re-fetch**.

**Also fixed: the weakest model went first.** `BundledModel.firstLaunchOrder` was a constant headed by
the **110M TDT-CTC** tiny model, so a user who **already had the far better 0.6B v3** could still end
up on the tiny one. It is now **a function of what is already installed**, and **`chooseFinal` and
`bestFinalModelOnDisk` read one shared ranking** (`BundledModel.finalModelsByQuality`) rather than
duplicating the same quality order in three places. **Cold start is unchanged** — tiny first, because
110 MB is what makes dictation work in seconds.

**New `Tests/EngineTests/ModelLayoutTests.swift` — 14 tests**, one of them **pinning our folder name to
FluidAudio's `Repo.folderName` read out of the library**; the rest cover the round trip landing where
we wrote, a lone legacy folder being renamed, both folders collapsing to the complete one, the
migration fetching nothing, and `firstLaunchOrder` preferring an installed better model while cold
start stays tiny-first. `ASRModelManagerTests`, `ModelIntegrityTests` and `OnboardingDictationTests`
updated — two of them had the old folder name spelled out. **`swift build` clean**; the full-package
test total is recorded at the release build. 2 commits (`6e45b4e`, `dfdad8a`) on top of 1.7.12. Ships
in the 1.7.15 dmg.

**Untested / honest limits:**
- **The reclaim is unverified against a real duplicate pair on a user's disk** — the migration is
  covered against **synthesised trees**, and the load path is confirmed against the **real 461 MB
  model offline**, but nobody here has the owner's actual two-copy layout.
- **The real HuggingFace download remains unverified** — pre-existing since 1.7.2, unchanged here.
- **No agent on this machine has a microphone or hardware**, so the warm-up timing is read from the
  owner's log rather than reproduced.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.14 — the Actions key could not be rebound or turned off

**The owner pressed Right ⌘ expecting to dictate and got *"Actions need a model set up in Settings"*.**
**Right ⌘ was their _Actions_ key; dictation was Right ⌥** — so the message was, strictly, correct, and
**their dictation was never broken.** But two things about that were genuinely wrong, and both have the
same root cause: **the Actions feature shipped with no UI at all.**

**Root cause, first half: the message named a Settings row that did not exist.** **`act.planner` was
not among the routable stages**, so there was **nothing in the UI to configure** and the only route was
a **`defaults write`**. It is now routable and appears as **"Actions (voice commands)"** under Models,
persisted through the **same `routing.<stage>` key** as every other stage — the exact key the old
workaround used — and offers **Auto and connected providers only**, with **no misleading local option**,
because **there is no local planner** and a *"Local · balanced"* row would have been a **second
unreachable instruction**.

**Root cause, second half: the Actions key had no UI at all.** **Nothing wrote `actHotkeyBinding`**, it
appeared in **no menu and no settings pane**, and there was **no way to disable it** — so **every fresh
install shipped a live Right ⌘** that users would **press by accident**, with **no discoverable way to
change or silence it**.

**What ships.**
- **The Actions key is rebindable from both the menu-bar item and Settings › General**, with **"off"
  folded into the same picker**, so **you cannot end up with a live key and a dead feature** — which is
  exactly the state the owner was in.
- **The default is now off.** **Actions can do nothing until a provider is pinned**, so an
  armed-by-default key could only **swallow a keypress and report a missing provider**. **Installs that
  had set the binding by hand keep their opt-in.**
- **Off means the event source is never installed**, not that its events are dropped — `CapabilityWatcher`
  treats a switched-off key like a **revoked permission** — and the switch is **re-read each tick**, so
  the picker **takes effect within a second without a relaunch**.
- **The 1.7.10 collision guard is byte-for-byte unchanged.** It now sits behind **`ActKeyBinding.isLive`**,
  which only **ANDs a second reason to stay shut** onto `isDistinct`: **bind both to the same key and
  dictation still wins**. Both pickers **label the colliding key rather than hiding it**.

**New `Tests/AppTests/ActKeySettingsTests.swift` — 14 tests**: `act.planner` is a routable stage whose
pin **persists under `routing.act.planner`**; the act key is **off on a fresh install**, **rebindable**
and **silenceable**; a switched-off key is **inert for every pairing of the two bindings** *and* is
**never armed by `CapabilityWatcher` at all**; arming **re-reads a binding written while the key was
off**; and the **1.7.10 `isDistinct` guard is unchanged**. **`swift build` clean**; the full-package
test total is recorded at the release build. 2 commits (`86c41da`, `59ad925`) on top of 1.7.12,
interleaved in history with 1.7.13's. **Ships in the 1.7.15 dmg**, which carries 1.7.13 and this.

**Untested / honest limits:**
- **That a switched-off Actions key is silent under a real key press is unverified**, as is **that
  rebinding it from either picker arms the new key without a relaunch** — no agent here has a keyboard
  event tap, a microphone or a window server; the switch, the arming rule and the collision guard are
  covered against protocols and mocks.
- **Every visual judgement is unverified** — the new picker in **Settings › General** and in the
  **menu-bar item**, and how the colliding key is labelled. The wording is tested; its appearance is not.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### 1.7.15 — AirPods would have silently ruined dictation, and a way to prove what the microphone actually heard

**This landed out of the hunt for the live-microphone accuracy problem.** The owner read *"The quick
brown fox jumps over the lazy dog"* and got *"the quake brown fogs jump above the lazy doll"* —
**roughly 55% WER on a clean read**. Successive investigations had already **measured and cleared**
the acoustic chain, the decoder, biasing, audio format conversion, the preview-versus-final landing,
end-of-utterance truncation, the VAD and post-processing. This round **cleared the last synthetic
suspects** and shipped the two things that came out of it.

**The latent bug found and fixed.** **`InputSelectionPolicy` awarded the system default input a
bonus of `+50`**, which **dwarfed every transport score**. The consequence: the moment a **Bluetooth
headset connects and becomes the system default**, dictation would **silently move onto an HFP/SCO
link** — a **narrowband 8 kHz (CVSD) or 16 kHz (mSBC), heavily compressed microphone**, telephony
bandwidth — **with no indication to the user and a large accuracy cost**.

- **The bonus is now withheld from a narrowband Bluetooth input.** `BluetoothInputDetector` already
  owned the transport classification; it now exposes it as one bit,
  **`BluetoothInputMode.isNarrowbandSpeech`**, which the policy reads.
- **It still wins when it is the only input available**, **an explicit user pin
  (`audio.input.preferredUID`) still overrides everything**, and **wideband / LE Audio Bluetooth is
  untouched** — the rule is about **telephony bandwidth**, not about Bluetooth.
- **When the app substitutes a different microphone it says so**, in the UI and in the log, rather
  than doing it silently: **`InputSelectionPolicy.decide` returns `Choice.avoidedNarrowbandBluetooth`**.
- **Settings › General gains a Microphone picker** — **Automatic** or a specific device, with
  **low-quality inputs labelled as such**, and a **pinned-then-unplugged device falling back**
  instead of showing a blank row.

**The diagnostic.** **Every accuracy measurement so far has been taken on synthetic fixtures, and
the failure is not reproducible from them** — so the deliverable is **the ability to capture the
real thing**. New **`Engine/Audio/UtteranceRecorder.swift`** saves the **raw and post-DSP audio of
an utterance as WAVs** alongside a **manifest recording the device, transport, sample rate, capture
graph and levels**, so a failing dictation can be **replayed through the existing fixture harness**.
It is **opt-in and off by default, written locally, never leaving the machine**, keeps **only the
newest 20 recordings**, and shows an **orange note in Settings while it is on**, with **Show in
Finder** and **Delete all**. The owner turns it on in **Settings › General › Microphone**,
reproduces a bad dictation, turns it off, and replays with:

```sh
eval "$(Scripts/bootstrap-toolchain.sh)"
VOICEPLUS_REPLAY_TEXT="the quick brown fox jumps over the lazy dog" \
  swift test --scratch-path .build-capture --filter replaySavedRecordings
```

`RecordingReplayTests` reads the recordings back **through the real recognizer** and prints, per
recording, the manifest, the level, what the model heard and the **WER against the reference** —
**no fixture manifest to author**. **The whole loop was verified end to end against a fixture.**
**`Engine/Audio/README.md` carries a table explaining how to read each outcome.**

**What was measured and cleared this round.** **Every prior accuracy figure had been taken on 16 kHz
fixtures, where `AudioConverter16k` is a no-op** — so **the 44.1 kHz conversion that a real
microphone forces had never actually been exercised**. It now has been: **WER 0.0140 identically at
16 kHz, 44.1 kHz and 48 kHz**, **duration drift 0.01%**, and **zero sample drift** between streaming
and one-shot conversion. **Absolute level was cleared too** — **flat WER from −20 dBFS down to
−60 dBFS**. **A genuine bug surfaced while testing this:** **silent audio produced `-inf` dBFS,
which JSON cannot encode**, so the recording **would have been discarded in precisely the "the
microphone delivered nothing" case that most needs capturing**. Levels are now **floored at
−200 dBFS**, which no real signal reaches.

**New `Tests/EngineTests/UtteranceRecorderTests.swift` — 12 tests**: nothing is written unasked; raw,
processed and a manifest that explains the recording; **a silent processed track still encodes a
manifest**; the newest-20 cap; capture through `AcousticCaptureSource` **without changing what the
sink receives**; and the device rules — **AirPods as system default do not win over the built-in
mic**, narrowband Bluetooth **is still used when it is the only input**, an **explicit user choice of
AirPods is honoured**, **high-quality Bluetooth keeps its system-default standing**, and a **wired mic
still beats the built-in**. **New `Tests/EngineTests/LiveCapturePathWERTests.swift` — 4 tests**: the
duration and streaming-versus-one-shot checks, and the **WER sweeps across sample rate and across
absolute level**. **New `Tests/AppTests/MicrophoneSettingsTests.swift` — 6 tests**: Automatic is the
default and a choice writes the key the capture source reads; the recording toggle is **off by
default**; an unplugged pinned device **falls back**; the note **explains the substitution rather
than making it silently**; a low-quality Bluetooth mic is **labelled** in the picker; and the summary
**counts utterances, not the three files each one writes**. **New
`Tests/EngineTests/RecordingReplayTests.swift`** is the replay harness itself, opt-in and driven by
`VOICEPLUS_REPLAY_TEXT`. `AudioUnitTests`' `skipsDisplayAndVirtualDefaults` **expected AirPods to win
as system default** — **that expectation was the bug**, and now says so.

**Then the verification pass over that new code found a privacy defect in the switch that turns it
on.** **The recording toggle was read exactly once, when the engine was built at launch** — so
**turning it off stopped nothing**: the recorder stayed installed and went on writing a raw and a
processed WAV, plus a manifest, **for every dictation until the app was relaunched**, while the
Settings copy directly under the toggle said *"Turn it off when you're done."* Turning it **on**
mid-session was inert in the same way, with the copy asserting the opposite. A switch about **audio
of the user's voice being written to disk** that does not take effect when it is turned off is a
**privacy defect, not a UI nit**. **The switch is now a predicate re-read at every `start()`**, so it
means what it says **in both directions**; **a recorder is always allocated but stays disarmed** — two
empty buffers, **no directory, no file** — and `begin()` is only called when the switch is on, so
`finish()` returns nil and **nothing touches the disk**. **Off by default, local-only and the
newest-20 retention are unaffected.** An **explicitly injected recorder still records
unconditionally**, which is what the tests and Lab ask for by passing one. **One narrow window
remains by design:** a toggle flipped off *during* an utterance **still writes that utterance**, which
began while opted in. 1 commit (`89611c6`).

**Two more faults, in the model store, from verifying 1.7.13's migration against the shapes a real
disk can be in.** Both matter to anyone upgrading, because **the migration runs on the next launch of
this build**. **First, a branch could permanently blind the truncation check.**
`voiceplus-manifest.json` records the byte count every file had when the install succeeded, and it is
**the only thing `ModelIntegrity` can check a silently truncated file against** — the check added in
1.7.11 because a half-downloaded model reported itself installed. `ModelLayoutMigration`'s
`adoptedExisting` branch **kept the manifest-less copy of a model, deleted the manifest-bearing one,
and wrote nothing in its place**, and **nothing else in the app ever writes a manifest for an
already-installed model**, so the degradation **never healed**. **Every branch now settles the
manifest before it returns** through one `ModelManifest.ensure`: already there → nothing to do (one
file read, the common case); otherwise **adopt the manifest from the copy about to be deleted**, but
only when it describes the survivor **exactly, file for file, byte for byte** — a `stat` per file
instead of a **SHA-256 pass over 468 MB**; otherwise **rebuild** with the same writer both fetchers
already use. **Never for an incomplete folder**, because a manifest built over a truncated file
**records the truncation as correct**. **The no-op branch settles it too**, so an install an earlier
build already stripped **is healed** rather than left un-checkable forever. And
**`ModelIntegrity.assess` now distinguishes `.verified` / `.unverifiable` / `.incomplete`**: an empty
problem list only means "nothing we can see is wrong", and **without a manifest the set of things we
can see is strictly smaller**, so a **manifest-less model is never reported verified**. 1 commit
(`4410afb`).

**Second, the directories we park and then never delete.** Replacing an installed model is a **swap,
not a delete-then-move**, so that a failure halfway leaves a working model under *some* name rather
than none: `FluidAudioFetcher.fetch` parks the outgoing copy as `.replaced-<uuid>`, the migration
parks the duplicate it undoes as `.superseded-<uuid>`. Each deletes its own park immediately
afterwards — **if it gets that far**. Killed mid-swap, **the park survived and nothing ever looked at
it again**: **~468 MB stranded** under a name no presence check reads and `repair` never visits, **not
even visible as a model in Settings**. **`ParkedModelDirectories.sweep` collects them,
conservatively**: **direct children of the models root only**; **only `<a model folder name we
own>.<kind>-<a parsable UUID>`**, so a stranger's directory, a real model folder and our own
`.staging-<id>` (where a cancelled download's resumable `.partial` files live on purpose) are **all
excluded**; **never FluidAudio's own models directory**; **never symlinks**; a **15-minute grace
period** measured from the newest of creation, content and **attribute** modification time — that last
one is the point, because **parking is a rename**, and a rename bumps `st_ctime` while leaving
`st_mtime` and birth time alone, so a park made by moving a year-old tree **reads as seconds old by
the right clock**; and **claim by atomic rename to `.sweeping-<uuid>` before removing anything**, which
**exactly one racing sweeper can win** and which an open descriptor keeps reading POSIX-style
(`sweeping` is itself collectable, so an interrupted sweep is cleaned up next time rather than
becoming new litter). **`ModelRootLock` puts the whole maintenance pass under an `flock`**, so **two
VoicePlus processes launching together cannot interleave** a park, a rename and a delete over the same
two paths; the lock is per-open-file-description so **a crash cannot leave a stale one**, and **the
wait is bounded and then abandoned** — a hung holder must not become an app that never finishes
launching. **And `swift test` no longer runs maintenance inside a real model store**: eleven tests
point `ModelManager` at the real `~/Library/Application Support/VoicePlus/Models` to score WER and
golden transcripts against whatever is actually downloaded, and since maintenance runs from `init`,
those **read-only intentions were entitled to migrate and delete inside a user's 468 MB store**. They
now pass `Maintenance.skip`. **Cost on an already-migrated install: one `open`, a `stat` per model,
one directory listing.** New `Tests/EngineTests/ModelMaintenanceTests.swift` — **18 tests** over both
fixes. 1 commit (`e96a167`).

**`swift build` clean, 1430 tests passing, 0 failures** — full package, from a clean scratch path.
5 commits (`c9491df`, `8849dff`, `89611c6`, `4410afb`, `e96a167`) on top of 1.7.12. **This is the
dmg — it carries 1.7.13 and 1.7.14 as well.**

**On the owner's specific report, recorded honestly: the Bluetooth theory did not explain it.** Their
own unified log shows **41 of 41 capture graphs** at `device=MacBook Pro Microphone …
tap=44100Hz/1ch`, and **the affected dictations match that window row for row** — those were captured
on the **built-in microphone**, with **AirPods paired but not connected**. **So the live-microphone
accuracy issue remains unresolved.** The **model, decoder, DSP, conversion and post-processing are
all now measured clean**; **the open hypothesis is far-field reverberation from a MacBook microphone
at arm's length**, since **every fixture tested to date is anechoic text-to-speech with no reverb**,
and reverb is a **classic source of exactly these phonetically-adjacent, right-syllable-count
substitutions**. **The replay diagnostic is what will confirm or refute it:** if the replayed audio
**scores badly but sounds fine**, capture is faithful and **the model is failing on real-room
speech**; if the **raw file scores well and the processed one badly**, **the spectral gate is
implicated after all**.

**Untested / honest limits:**
- **Everything that needs a real microphone is unverified** — that a connected Bluetooth headset is
  actually **stepped around at the HAL**, that the **picker rebinds the live device**, and that a
  **real utterance records and replays**. No agent here has a microphone or TCC permission; the
  policy, the recorder and the replay path are covered against **protocols, mocks and fixture
  audio**, and the **replay loop was verified against a fixture** rather than against a live capture.
- **Every visual judgement is unverified** — the new **Microphone section in Settings › General**,
  the substitution note, the **orange recording note**, and **Show in Finder / Delete all**. The
  wording is tested; its appearance is not.
- **The accuracy fix itself does not exist.** The Bluetooth defect is a **real latent bug found on
  the way**, not the cause of what the owner reported, and **nothing in this build claims to have
  fixed the accuracy problem**.
- **The model-store fixes are untested against the real failures they guard.** The **sweeper has
  never collected a park left by a real crash**, and the **cross-process `flock`** has never been
  exercised by **two VoicePlus processes launching at once**; both are covered against temporary
  directories only. **On the owner's own machine the migration is a no-op**: their models root
  already holds `parakeet-tdt-0.6b-v3` and `parakeet-realtime-eou-120m-coreml-160ms`, **both with a
  valid manifest**, **no legacy folder and nothing parked**, so the first launch of this build moves
  **no bytes**.
- **The appcast enclosure URL still 404s anonymously** — private repo, pre-existing, unchanged.

### Accuracy investigations (2026-09-08, alongside 1.7.13/1.7.14) — the noise gate and biasing are both cleared

**Two plausible diagnoses of the dictation-accuracy problem, both refuted by measurement rather than
confirmed.** Neither changed any behaviour; both closed a real test gap, and both are written down so
nobody re-derives them.

- **The always-on spectral-gate noise suppressor was the first suspect. It is _better_, not worse.**
  Measured **through** the acoustic chain — 100 ms blocks, as `AcousticCaptureSource` feeds it — over
  **12 clean fixtures**: **`.raw` mean WER 0.0291 versus `.default` 0.0140**, and `.default` is equal or
  better at **every point of a 45→15 dB SNR room-floor sweep**. The pangram scored **WER 0.000 on both
  paths** across **3 accents and ±30 dB room floors**. The gate **does** mangle the waveform — **mean
  SDR 10.9 dB**, against a ~117 dB passthrough control — but **Parakeet is robust to it**, so a low SDR
  through this chain is **not by itself evidence of an accuracy bug**. A **through-the-chain WER
  regression test** now sits **alongside the existing bypass test**, so this class of question is
  **answered by measurement in future**. Recorded in `Engine/Audio/Robustness/SUITES.md`;
  `Tests/EngineTests/AcousticChainWERTests.swift`. 1 commit (`429638b`).
- **Biasing was suspected next. It was measured too.** **`FeatureFlag.contextBiasing` is off by
  default** and **no flags file exists on this machine**, so **no biaser was installed at all**; and
  **even enabled, the rescorer only adjusts the confidence of tokens already chosen** — it runs
  **after** greedy TDT has finished and **cannot substitute a word**. **Byte-identical output on all 12
  fixtures, WER 0.0291 both ways.** The new coverage exercises the decoder **as `AppContainer` actually
  builds it** — a configuration that had **never been tested**, because every existing test resolved the
  recognizer through `RecognizerFactory` and left the biaser nil. **Privacy was confirmed clean along
  the way**: screen context is **accessibility-only**, held **in memory**, **rebuilt per utterance**,
  and **never written to disk**. Recorded in `Engine/Biasing/README.md`;
  `Tests/EngineTests/BiasedDecodeWERTests.swift` and `Tests/AppTests/ShippingDecoderConfigTests.swift`.
  1 commit (`4158ec4`).

**Recorded honestly: the live-microphone accuracy issue remains unresolved.** The **model, the decoder,
the DSP and the post-processing are all measured clean on fixture audio**, so **the remaining suspect is
live capture itself**. Nothing in 1.7.13 or 1.7.14 claims to have fixed it.

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

---

# V3 improvements — build log

Executing `VoicePlus_Improvements_V3_Build.md` (contract: `VoicePlus_Improvements_V3.md`).
Baseline: 1.7.15, whole-package `swift build` clean, 1430 tests green.
DMG per wave, version bumped each time, previous DMGs kept.

| Wave | Items | Status | DMG |
|---|---|---|---|
| 0 | R0 · R1.4 · R1.5 · R2.1 · R4.1a · R5.1 · R6.1 | in progress | 1.8.0 pending |
| 1 | R2.2 · R2.3 · R2.4 · R2.5 | blocked on R2.1 | 1.9.0 pending |
| 2 | R3 · R4.1b · R4.2 · R4.3 · R5.2 · R5.3 · R6.2 | blocked on R2 | 1.10.0 pending |
| 3 | R5.4 · R7 | blocked on R5.2–R5.3, R0+R6 | 1.11.0 pending |
| 4 | R8 | blocked on R3+R7 | 1.12.0 pending |

## Wave 0 (2026-09-11)

- Launched seven parallel subagents, one per item, isolated scratch paths, scoped commits.

- Committed, wave 0: R0.1 `be0d1ca` (DESIGN.md, 769 lines) · R2.1 `c46042d` (stability/SegmentID/DeliveryOutcome,
  51 SharedTests green) · R5.1 `f52255a` (Qwen3ASR port + RefinementSession) · R4.1a `96d801d` (wakeVerb and
  adapt.lexicon append provenance; 20 real corpus files through the real `AppContainer` stage list, **202 stage
  runs, 0 contract violations**) · R1.5 `74bd335` (preview candidates, corpus scorer, light preview formatting).
- **Interrupted:** the session hit its usage limit with eight agents in flight; all eight were killed mid-edit.
  Work was left uncommitted but intact in the tree, which had exactly one compile error
  (`TextInjector.swift` calling `FocusGuard.dequeueDeliverable`, removed by the half-finished R2.3 edit).
  Relaunched agents were pointed at their predecessors' partial work rather than starting over.
- Open at that point: R1.4, R6.1 (wave 0) and R2.2, R2.3, R2.4, R2.5 (wave 1).
- Noted for the release gate: `GatekeeperLatencyTests.classifyStaysUnderBudget` failed at 144 ms against a
  15 ms budget while nine agents shared the machine. Pre-existing and load-induced, not caused by V3 work —
  re-check on an idle machine before cutting the DMG.

### Wave 0 complete · wave 1 complete · 1.8.0 candidate cut

- Wave 0 (7/7): R0.1 `be0d1ca` · R1.4 `1baf516` · R1.5 `74bd335` · R2.1 `c46042d` · R4.1a `96d801d` ·
  R5.1 `f52255a` (+ `324e635`) · R6.1 `0646ccd`.
- Wave 1 (4/4): R2.2 `d680ec1` · R2.3 `60751e6` · R2.4 `727fbd6` · R2.5 `afd959f`.
- **R1.4 reversed a prior finding.** On twenty real-room dictations the plain tap beat the spectral gate
  (WER 0.1000 vs 0.1182) and won all 7 points of a 30→0 dB sweep. `.default` is now the plain tap and the
  recorder manifest stops claiming `aec=appleVoiceProcessing` while the graph ran `vp=false`. Caveat kept
  on the record: n=20, one room, one mic, and two sentences carry most of the quiet-pass margin (the
  scorer counts "eleven forty-five" vs "11:45" as three errors). `.gate` is one line away.
- **R2.3 makes the Brave double-fire structurally impossible.** Only a method that threw *before posting*
  falls through; unconfirmable readback is now `delivered(unverified)`. 104 InjectionTests (+38); 10
  existing tests changed because the delivery rule itself inverted.
- **R2.4 deleted the 1.5 s auto-flush on focus return** that V3 §6 reverses, and fixed a `ChaosTests`
  case that had been asserting the old auto-redelivery.
- **Open gate, honestly labelled:** the Qwen port transcribes English speech into Devanagari (WER 1.000).
  The prompt/token-table fix in `324e635` was necessary but not sufficient; a dedicated agent is on the
  root cause. `qwenRefinement` stays **default off**, so dictation is unaffected.
- Tests at `727fbd6`: **1626 total, 1624 green**; both failures in the flagged Qwen path. The earlier
  `GatekeeperLatencyTests` failure was pure machine load — it passes on a quiet tree.
- **1.8.0 DMG built** from a clean worktree at `727fbd6` (not the working tree, so no in-flight wave-2
  code leaked in): `VoicePlus_V3-w01_1.8.0.dmg`, 15 MB, sha256 `caa3009d…`, `verify_install.sh` OK
  (launches, self-contained, 9/9 TCC descriptions, left the user's running instance alone).
  22 DMGs now in `Packaging/releases/` — none deleted or overwritten.
- Wave 2 launched in parallel: R4.1b, R4.2, R6.2 + the Qwen root-cause agent. R3, R4.3, R5.2, R5.3 queued.

### R5.1 gate closed — and the R5.4 decision is now visible in the data

- **Qwen root cause found (`c6c8887`), and it was not the prompt.** Qwen3-ASR picks its output language
  *in the assistant turn*: unprompted it writes its own header `language ĠHindi <|asr_text|>` and then
  transcribes in the language it just named — Indian-accented English got named Hindi, hence Devanagari.
  The port never wired forced decoder ids. Proven with a token-id probe: empty system message, correct
  English instruction, and the port's hard-coded table all produced **byte-identical** output, so the
  earlier prompt/token-table fix (`324e635`) was operating on an inert path.
- Fix: `assistantPrefixTokens` forcing `language English <|asr_text|>` (`[11528, 6364, 151704]`, built
  from `vocab.json`). Assertion left at `wer <= 0.5`. Before `WER 1.000` → after **`WER 0.000`**.
  `vocab.json` confirmed as the true tokenizer by embedding geometry (cos 0.42 vs 0.02, random ≈0.12).
- **Qwen 0.6B loses to Parakeet on this corpus: mean WER 0.1724 vs 0.0990.** R5's gate is "default-on
  only with useful gain on difficult speech and no clean-speech regression". On the evidence so far that
  gate **fails**, and `qwenRefinement` stays off. Per V3 §5.4/R5.4 either outcome is a valid completion —
  R5.4 must still break the number down by segment class before this is final, since a two-pass gain
  could survive on difficult speech alone even while the corpus mean regresses.
- Note: 1.8.0's notes describe the Devanagari bug as open, which was true of `727fbd6`. The fix lands
  in 1.9.0; the shipped 1.8.0 notes are left as an accurate record of that artifact.

### Wave 2 complete · 1.9.0 candidate cut

- Wave 2 (7/7): R3 `2785f28` · R4.1b `914ce7b` · R4.2 `baad052`+`97e55d7` · R4.3 `9f8190c` ·
  R5.2 `4075723` · R5.3 `45f4ec2`+`c903352` · R6.2 `cd053f2`. Plus AX-hints integration `51b3058`.
- **Latch actually works now.** `finalize()` had cleared the mode on every utterance, so hands-free
  ended after one sentence. 24 tests cover every row of V3 §8.
- **Two bugs found that unit tests alone would have missed.** (1) The onboarding practice field was
  never wired to the lander — it could say "heard", never "landed", so the step meant to prove
  dictation works could not. (2) `StyleStage` runs last and re-applied the exact two edits field rules
  had just decided, silently undoing R4.2 mid-sentence in the real pipeline while its own tests stayed
  green.
- **R5 decided by measurement, not caution.** Real two-pass on the corpus: pass-1 WER 0.0991 vs
  pass-2 0.1784; 1 of 20 segments improved, 7 worsened; 1.9-4.2 s against a 1500 ms deadline. Fails all
  three gate conditions → `qwenRefinement` registered and **off**. The port itself is correct (forced
  decoder ids, WER 1.000 → 0.000). Gate built and measured: recall 1.000, precision 0.167.
- **Test-suite finding (G5, generalised):** `swift test` in parallel fails ~14 timing assertions;
  `--no-parallel` is **1821/1821 green**. Caused by R5.3's real-model corpus tests competing with
  deadline assertions, not by any product change. Release verification now uses `--no-parallel`.
- G4 closed by measurement (prompt cap 1000 vs 2400: identical WER). G1/G2/G3/G7 still open.
- **1.9.0 DMG** from a clean worktree at `c903352`: `VoicePlus_V3-w2_1.9.0.dmg`, 15 MB,
  sha256 `91caf4a9…`, `verify_install.sh` OK. **23 DMGs** retained, none overwritten.
- Next: wave 3 = R5.4 (segment-class breakdown only; decision already made) + R7 (one window).

### Waves 3 and 4 complete — the V3 document is implemented · 1.10.0 candidate

- Wave 3: R5.4 `1b1e9d5` · R7.1/R7.2 `16987a7` · R7.3 `1248626` · G10 fix `f5cdca8`.
- Wave 4: R8.3/R8.4 `6dd032b` · R8.1/R8.2 `9fa61ca` + wiring `fadc4ca`. G2 rename swept `debf88a`.
- **All items R0–R8 implemented. 1970 tests, all passing** with `--no-parallel`, verified twice: in the
  working tree and again in a clean worktree at `0233c62`.
- **R5 closed on the numbers.** Per-segment-class breakdown found **no class where Qwen wins**: all 0.099
  vs 0.178, entities 0.081 vs 0.197, ≥7 s 0.182 vs 0.335, digits 0.405 vs 0.738. Under the deadline the
  gated two-pass improved **0** segments and damaged 2 (4 of 6 gated timed out); p95 1816 ms vs 1500 ms;
  peak memory measured at 1866 MB vs Parakeet's 90 MB. Flag off; a test fails if it is flipped without a
  new table. The port itself is correct (forced decoder ids, WER 1.000 → 0.000).
- **R7:** all 11 old tabs placed, 46 settings proven reachable, Lab/Data Panel/enrollment folded in,
  nine-tab TabView gone. Surfaced two settings that had been `defaults write`-only (never-inject list,
  ambient switch). `DESIGN.md` §11.4 amended rather than the code — closing G7 honestly.
- **R8.4 indicator proof:** driven through the real `PipelineAudioSource` graph — start, meter→engine
  handover, a displaced meter's late `stop`, stop — plus a 9×8 ownership × situation sweep, and a
  throwing capture source proving a failed start never lights it.
- **R8.1 never-inject proof:** four independent layers, including a *control* test that the same rig
  does deliver `source == .dictation`, so the main assertion cannot rot into a tautology.
- **Gaps closed:** G4, G5 (diagnosed), G7, G8, G10. **Still open:** G1 (Escape unbound — needs a design
  decision on Input Monitoring), G9 (no manual meeting start), G11 (ambient discards everything until
  the transcript seam carries audio), G2's one deliberate wire string.
- **1.10.0 DMG** from a clean worktree at `0233c62`: `VoicePlus_V3-w34_1.10.0.dmg`, 15 MB,
  sha256 `1dba1348…`, `verify_install.sh` OK. **24 DMGs** retained, none overwritten.
- Remaining work is the owner hardware session (build doc §5) — it cannot be done on this machine:
  no microphone, no window server, no TCC grants.


### V4 Wave 1 + Spool design → 1.11.0

#### Wave 0

- G0.4 done · 6c57b64..4d139a9 · PillState/EngineState V4 additive cases, reducer table verification · SharedTests 84 passed, AppTests 771 passed
- G0.1 done · 54d80ec..1705ac2 · Shared types (CaretState, punctuationOrigin, TurnRecord, ScreenTextReader, .partial) + decode-clamp fix · SharedTests 89 passed (+5)
- G0.3 done · 60f28aa..86351c5 · DESIGN.md v2 + DesignTokens verified, copy drift fixed against fixtures · AppTests 780 passed (+9), DesignTokenTests 22 passing
- G0.2 done · 6ad3286..ef56ebc · PipelineAudioSource forwards .vad/.endpoint/.chunk, setLatched on live pipeline · AppTests 783 passed (+3), EngineTests 457/458 passed (unrelated fixture failure)
- **Wave 0 gate passed (4/4 done).** `swift build --build-tests` clean (only the old R5.4 Sendable warning in
  `RefinementBenchmarkCorpusTests`); `swift test --no-parallel`: **2060 tests, all passing**.
- Gate fixes: `42c2c19` replay test skips saved clips under the recognizer's 300 ms floor (a 0.28 s
  recording in the owner's Recordings folder failed it; same floor as `RealEngine.stop()`) ·
  `97fe589` removed Pipeline's shadowing `Array.renderedText`, so Pipeline/App/D4 now get Shared's
  V4.13 join (skips space-only spans, collapses spaces).
- Open for wave 1: B reconciles `AudioPipeline.options.latched` vs live `isLatched` and the `.endpoint`
  doc comment; B1 hops the `@Sendable` audio callbacks to MainActor. S6: `.starting/.finishing` show as
  listening. S2: `.landedPartial` size and retract. No test covers `.partial` routing in PillDeliveryRouter.

#### Wave 1

- A1–A5 done · 657bab5..836e95a · format sync, 3/5/8 s budgets, hotkey before container, warm graph, maintenance off launch
- B1–B4 done · ced7ae6..4ed1f53 · latch endpoint loop, pause setting, segments land through the lander, timer feed
- C1–C3 done · e77834f..02b230d, b2a8318 · no-speech gate, hallucination guard, pre-roll only on a running graph
- D1–D7 done · 6bb5fb3..7347bf5 · three-valued caret, provisional punctuation, continuation table, landing memory, spacing setting
- E1–E2 done · 592bf82 · punctuation-tolerant ITN and digit runs joined by span timing
- F1 done · 06dc150 · MicQualityAnalyzer v2: pre-speech floor vs first second of speech
- G1–G3 done · 58c8902..35da7cd, c79603d · key-gated box, screenshot + OCR service, box → element + text + crop
- H2–H3 done · 9cd26b2..b88c70e, cb5c1e8 · WeSpeaker weights, passive enrollment; gate wired holds and latch audio
- I1–I2 done · 4f6ef0d..bd43acc · fn / 🌐 default key with conflict flag; Escape hotkey during a turn
- J1–J2 done · 411f669..6049b9b · recording retention setting; Claude desktop through the Electron adapter
- S1 done · 19b7b3f · Spool art ported exactly; 624 frames, 26 cameos, 6 flights match golden hashes
- S6 done · 29aaff8 · cassette menu-bar glyph and the design's status menu
- S9 done · 29980a4, f458784 · recovery catalogue (59 entries), engine errors show catalogue headlines
- **Wave 1 gate passed (13/13 done).** `swift build --build-tests` clean (this wave's new warnings fixed; the rest predate it); `swift test --no-parallel`: **2498 tests, all passing**.
- Gate fixes: `f458784` onboarding copy tests expect S9 headlines (updated copy tests) · `c79603d` deixis retention
  tests waited on regions only, crops are dropped just after (race) · `b2a8318` `RealEngine.release` commits and
  broadcasts as one step (two passes finishing together sent segment 1's `.closed` before 0's; `fullBacklogCommitsPassOne`) · `cb5c1e8` H2 app wiring (`SpeakerAudioWiring`:
  holds → `observeHoldUtterance`, latch audio → speaker guard, "Voice learned" pill line; +7 tests) · `1022fc0` new
  warnings · `d6260a9` keep-all retention copy, self-test budget text, stale v1/describe comments.
- Open for wave 2: S3 wires `EscapeHotkey` and the A06 quiet return; S2 wires `LanderLatchDelivery.onLanded`, the box chip
  and `presenceState`; S7f/S7g settings rows; 24 Spool art hex colours vs DesignTokens; DECISIONS.md SNR hypothesis (R);
  all hardware checks in build doc §5.

#### Wave 2

- S2 done · aef6b41..04bce53, 6816667 · design pill geometry and copy fixture rows, presence chin, deixis chip, non-turn buttons wired
- S3 + S11 store done · e29c9ab..88fc1e1 · TurnController preview-before-insert, commit guard by TurnID + revision, TurnStore records
- S7a done · 6c8d9c4 · window shell, sidebar, ⌘1–6/⌘F, SectionScreen protocol, components, settings re-homed
- S7b done · 8921b80 · Today held drafts first, TurnStore rows, turn detail, recovery sheet with explicit re-target
- S7c done (gate finished wiring) · db3df45, 42c8e30, 5835447 · Meetings library/detail, capture panel, Q0–Q2 pill rows, X02 recover
- S7d done (gate finished wiring) · f5712df..8e77f4a, f890f75, 5835447 · Dictionary & Apps, per-app rules now applied in the lander
- S7e done · 24995cc · Voice page: mic picker, level meter, test sentence states, enrollment, benchmarks disclosure
- S7f done · 659737c, 7e48089, 5835447 · Privacy rows, network log, scoped delete, diagnostics; gate wired hard mute
- S7g done · e23ea8d..72597d2 · seven Settings subpages incl. dwell, spacing, latch pause, models progress, providers, sync, updates
- S12 done · ad0495f..a4aa188 · SpoolSurfacePolicy table, transform before/after preview gate, outbound action preview
- S8 done · b22cf26, 8751fcb · onboarding steps with Voice step, resume, fn fallback; waitUntil hang guard
- **Wave 2 gate passed (11/11 done).** `swift build --build-tests` clean (no new warnings; only the old R5.4 Sendable one); `swift test --no-parallel`: **2956 tests, all passing** (2955 before the gate fix).
- Gate fixes: `5835447` `MeetingCaptureWiring.install` + pill meeting buttons routed first (S7c); `AppRules.applying` applies per-app style / contextual reading last in the lander's augmenter (S7d, +1 test); `PrivacyWiring.mute` = live MuteController (S7f). No test deleted, no copy test changed.
- Open: S7g double-tap latch filter + sound cues need AppDelegate hooks; history-off still saves (lander/TurnStore); Larger Text / Reduce Motion to pill (S10); theme at launch; real updater; LabWiring disclosures; word marks await S5; all hardware checks in §5.

#### Wave 3

- W3H done · 85baddd · wave-2 hand-offs: latch gesture, sound cues, launch theme, history-off gating, pill Review routing
- S4 done · 363a80b · tape flight from Spool's mouth to the verified caret; suppression matrix; golden flights
- S5 done · 434b755, 83a3473 · uncertainty marks mapped through formatting, destination overlay ladder, correction popover, range-guarded replace
- S10 done · 0df97a6, 1a334b8 · Reduce Motion, VoiceOver announcements, reading order, Escape layers, Larger Text, grapheme-safe marks
- S11 done · d54b588 · every pill/window/onboarding/menu error resolves through RecoveryCatalog; retry per action kind
- **Wave 3 gate passed (5/5 done).** `swift build --build-tests` clean (no new warnings; old LabWiring / DeliveryPillDriver / R5.4 Sendable ones remain); `swift test --no-parallel`: **3108 tests, all passing**.
- Gate fixes: `5bb52e9` preflight-bound test's release is a 60 s hang guard (3 s let loaded parallel runs fail `!passed`). No test deleted; updated copy tests: S11 in 9 suites (DeliverySurface, PillRows, MainWindowShell, OnboardingDictation, AmbientTimeline, DesignCopyParity, DictionaryAppsS7d, TransformUX, CaptureStartBudget), W3H 2 expectations in SettingsReachability.
- Open: pill "N words to review" counts low-confidence spans, not mapped marks (T05 rewrites differ); S12 manual dwell still 1.5 s for transforms; `SessionCoordinator.onRefusal` unassigned; Privacy history-off copy; NoopUpdater; all hardware checks in §5 (items 13–14, VoiceOver, AX overlays).

#### V4 Wave 1 gates — measured (W4 fixes)

- **0 mic warnings on the quiet-room corpus — FAILS (2 / 20).** _Passes 20 / 20 after 1.11.0: see "F1 fix" at the end._ `RealRoomMicQualityTests` replays the 20 `Fixtures/real-room/builtin/*-raw.wav` through `AudioPipeline` + `EnergyVAD` + MicQualityAnalyzer v2: 18 good (SNR 24–51 dB), lines 02 and 14 "bad + low level". Cause: both open with ~1.1 s of room (≈ −52 dBFS) before the first word; the energy VAD takes its floor from its first, quieter frames and opens a segment at 0.01–0.03 s, so the analyzer grades that room as the first second of speech (peak −40.5 / −43.8 dBFS < −40). The owner's speech peaks at −21 dBFS. Recorded as a known issue on those two stamps (any other warning fails); fix belongs to the VAD onset / analyzer signal window, not the thresholds. Silero (the live VAD when its model loads) was not measured: `SileroVAD.loadIfAvailable()` returns nil in the test process.
- **digits class WER < 0.20 — passes: raw 0.062 (2 / 32 words), processed 0.094 (3 / 32).** `RealRoomDigitsClassTests` (AppTests; EngineTests cannot import Pipeline) lands lines 04, 05, 11 (`RealRoomCorpus.digitLines`) of `Fixtures/real-room/builtin` through the real final model and the production `UtteranceLander` over AppContainer's stage list into a Notes body. It first measured 0.344 / 0.406: the route model reads statements like line 05 as `question` (p 0.79) and `PipelineRunner` runs only the gatekeeper for non-dictate routes, so with no selection the text landed as the recognizer wrote it ("two three four zero rupees"). Fix: the lander formats any question / transform / unconsumed repair route with nothing to act on as dictation (`PipelineRunner.runDictationStages`, additive). Remaining errors: line 11's "400050" heard as 40050 / 44050, and "Their" as "The"; line 04 processed keeps "11 forty-five" (unified ITN is V4.14). `scoreRealRoomCorpus` prints the class on the model's own text (before formatting) for comparison.

#### Wave 4 / release

- W4 audit (three auditors) found 6 / 6 / 10 gaps; all closed: S5 review count from mapped marks (`a13c8e7`), S12 manual dwell (`0ec5d8c`, `ada3e4d`, `ef04bc8`), S7f history-off sentence + counts (`4d837bd`, `4562b94`), D4 rendered text (`a868cd0`), `SessionCoordinator.onRefusal` → K05/K04/K02 (`b7e9cdb`), F1 SNR hypothesis entry (`3b859e6`), S3 focus pauses dwell (`f3b72d9`), S7e Stop cancels enrollment (`da462eb`), K02 lost key-up (`563b67a`), cold launch → first landing log (`b3d5f65`), digits gate (`0133496`), quiet-room mic gate measured (`50fa1c8`), tape cue (`e7705a7`), §13 mapping (`e881acf`), S7e flake (`5ec671b`).
- R1 at `5ec671b`: build clean; `swift test --no-parallel` **3156 tests, all passing** (one recorded known issue). Parallel runs can fail 4 timing assertions under load (Refine deadlines, golden latency); serial green.
- WER, `Fixtures/real-room/builtin` (20 files, 220 words): raw 0.100, processed 0.100 vs 1.10.0's 0.099 — within ± 0.01. Digits class 0.062 raw / 0.094 processed (< 0.20). Silent fixtures: 0 landings.
- R2 `928551d`: `Fixtures/prosody/script.md` (15 questions, 15 two-clause, 10 exclamations).
- R3 `19c22ea`: `VoicePlus_V4-w1_1.11.0.dmg`, 19 MB, sha256 `e80a1b58715c68f31661886001899246914657f03cc7ca02477caf618165cf92`, verify_install OK, 25 DMGs retained; `--no-github`.
- R4: build doc §3/§5/§7 final status, DECISIONS.md V4 Wave 1 entry.
- 1.11.1 = 1.11.0 + F1 fix: R3 `897888a`, `VoicePlus_V4-w1_1.11.1.dmg` from a clean worktree at `82ef429`, 19 MB, sha256 `8a2edfd55e788854c72f39361bb828787b25ae23bdbbfa0a387aa46cedcbf7a5`, verify_install OK, 26 DMGs retained, none overwritten; quiet-room mic gate 20 / 20; 3161 tests `--no-parallel`, all passing; tag `release/phase-V4-w1/v1.11.1`; `--no-github`.
- Open for the owner: every §5 hardware item (numbers to collect are listed per item); quiet-room mic gate fixed after 1.11.0 (F1 fix below; calibrate the SNR bounds in Wave 2); record the prosody script; create tag `release/phase-V4-w1/v1.11.0` on the final release commit (and a GitHub release if wanted); live VoiceOver cursor on the pill untested.

#### F1 fix (after 1.11.0, not in its DMG)

- **Quiet-room mic gate passes: 20 / 20 good, 0 warnings, identical at 50 ms / 10 ms / one-block replay.** Two causes. (1) Every `Fixtures/real-room/builtin` recording dips 10–20 dB below the −52 dBFS room for 30–45 ms right after capture starts; `EnergyVAD`'s plain 4 s minimum took the dip as its floor, the room sat 13 dB above it, and a segment opened at 0.01–0.15 s on 18 / 20 files — lines 02 and 14 (1.1 s of room before the first word) graded room as speech (bad + low level). Fix: `EnergyVAD.floorHold` = 3 frames — a level must last 60 ms to become the floor (fixture F1 0.983 → 0.986). (2) The analyzer took its verdict at the end of whatever block the ring handed over, with the running-minimum floor over that block's last 4 s, so the same file read 26 dB serial and 8 dB parallel. Fix: `AudioPipeline` feeds it one VAD frame at a time, just before the VAD hears it; `feed` publishes at the exact 10 ms frame. Thresholds untouched. `swift test --no-parallel`: 3161 tests, all passing (EngineTests 610 + the rest 2551; no known issue left); the gate table is identical in 3 serial runs and a parallel EngineTests run. Tests: `MicQualityDeterminismTests` (analyzer over 8 feed sizes, pipeline over 5 block sizes, the onset case end to end), `EnergyVADStartUpDipTests`; `RealRoomMicQualityTests` lost its known issue and checks block-size invariance per file. Open: the analyzer's own floors have no hold, so on 9 / 20 files the start-up dip is still its floor and the SNR reads 6–26 dB high (never a warning) — settle before Wave 2 calibration (DECISIONS.md).

#### Post-release fixes → 1.11.2

- Source: the owner's fresh install of 1.11.1. Owner decisions #1 (bundling), #2 (Qwen) and #5 (notch) and the known gaps are in `VoicePlus_ImplementationBuild_V4_Wave1+Design_Pending.md`.
- FX1 done · `16fa305`, `bdc2513` · onboarding freeze fixed. The cause was an off-main AX write into our own TextKit 2 field, which deadlocked. Own-pid writes now go through `insertText` on main, and a main-thread stall watchdog was added · 20 new tests, InjectionTests 150.
- FX2 done · `3181dc5` · the chin no longer sticks on "Working…". It now reads the unfiltered engine feed plus turn ends, and `.starting`/`.previewing` count as capture · `PresenceTurnEndTests`, filter 106.
- FX3 done · `150963e`, `6fa07b6`, `875b584` · no false "model isn't ready" after a download. Callers join the refresh in flight, the install awaits the engine swap, the loader waits for a pending swap for up to 10 s, and onboarding retries once. Real model sizes (721 MB, was 914 MB) and an "N of 3 · name · overall" progress line · `FX3ModelReadyTests`, filters 178 + 305.
- FX4 done · `7a32896` · 14 designer notes in recovery copy were rewritten at the source (design_v1), the fixture was regenerated, and `DesignCopyLintTests` was added · filter 381, spool fixtures unchanged.
- FX5 done · `5b03e94` · the chin pulse is centred. It is driven by `TimelineView` instead of `repeatForever`, and the panel frame is set before `rootView` · `PresenceLevelBarTests`.
- FX gate: build clean; `swift test --no-parallel` **3215 tests, all passing** (+54 over 1.11.1's 3161; first run 3214 / 3215 with the midnight-clock failure fixed at the gate). Gate fix: `AmbientTimelineTests` grouping test anchored at noon today (it failed between 00:00 and 01:00 because "an hour ago" was yesterday; clock-dependent, not an FX regression).
- Open: AX callers outside `LiveSystemAccess` have no own-pid guard. The pill stays up about 27 s after a landing (not investigated). The M07 2 s wait and K03 quiet first tap are not checked as coded. The installed-app re-check of all 5 fixes is the owner's. The 1.11.2 DMG is built by the release step.
- 1.11.2 DMG done · R3 `8e690f6` · `Packaging/releases/VoicePlus_V4-w1_1.11.2.dmg`, 20 MB, sha256 `86d8cdd5c4f2914e36dc7748ea274ebfe3a436c3e27bb95d52ae522713b37ae9`, from `5a02a51` in a clean worktree (`--no-github`); `verify_install.sh` OK; 27 DMGs retained, none overwritten; tag `release/phase-V4-w1/v1.11.2`.

## V3 native Spool parity — 2026-09-20
- In progress: exact `design/design_v3.html` / `.md` port; earlier design versions preserved.
- Parallel isolated worktrees: cassette/tape rendering; notch geometry/layout; preview/edit/correction flow.
- Integration gates: native visual QA, state/recovery tests, release build and self-contained DMG verification.
- Pending: merge verified milestones, install candidate and compare all states, publish tested commits and local DMG.
- Native implementation underway: cassette golden parity, fixed160pt layout, inline draft/correction flow; no completion claim before integration.
- Full installer staging: all three installed default models pass SHA256 verification; bundle lookup stays read-only and outside maintenance/deletion roots.
- Added explicit native visual-review and bundled-model self-test entry points for installed-build acceptance.

- Integrated V3 layout and draft flow; cassette/tape port has 658 exact SVG comparisons. Native layout/editing audit passes 33 focused tests; review flow passes 146.
- Full serial integration run exposed stale V1 copy, focus and pointer expectations; migrated to V3 contracts. Final full run and installed-app QA remain pending.
- Packaging now verifies default model bytes and includes pinned upstream notice/license copies; 7 packaging tests pass. Full-installer gate refuses missing model source.

- Native release candidate inspected: inline alternatives, in-notch edits, scroll-only transcript and retained corrections work; cassette/tape/state layouts checked.
- Fixed native QA findings: retained-word actions, contextual-chip viewport shrink, crowded four-action footer.
- Bundled TDT, EOU and speaker models pass real offline synthetic inference; final full suite and DMG checks running.

- Built `Packaging/releases/VoicePlus_V3-Spool-Full_1.12.0.dmg` (714,250,047 B; SHA256 `950cc8c967ebc9d3c8536f1277c66f5db14dd1d9c0f4ce0298651c758a21e4a1`). Mounted read-only model inference, clean-install launch, signature/dependency and installability checks all pass. All 27 earlier DMGs remain byte-identical.
- Source milestones pushed to `codex/spool-v3-native`. Binary remains local; existing update feed/cask kept unchanged.
- Real external-app insertion QA is awaiting explicit Accessibility approval for the installed app; no permission was changed. Native visual/review checks and mock/unit delivery checks are distinct from this pending hardware check.

- Final integration gate: **3,256 tests passed** (`swift test --no-parallel`, 448 s); latest V3 fixes also pass119 focused tests, and packaging passes7 tests. Merged the concurrent documentation-only main update; no runtime change.
- Remaining acceptance: external TextEdit insertion and visual destination tape travel after Accessibility approval. Installed app restored to normal recognition mode; no mock capture is left running.
- Review branch is pushed and clean; draft PR: https://github.com/thekatarekid/VoicePlus/pull/1. Kept draft until the permission-gated external insertion check is completed.
- Continuation audit: installed app Privacy confirms Typing access Off; Accessibility approval remains pending. GitHub CI run35481771092 started no build steps because of an account billing/spending-limit restriction; local3256-test and DMG passes remain the available validation.

- Accessibility approval received; refreshed the VoicePlus switch in macOS to On. App-side recognition and external insertion are still unverified. Relaunched app is blocked opening Settings in `SyncSettingsViewModel → SyncService.key → SecItemCopyMatching` (process sample); macOS security dialog requires user handling because computer use cannot access SecurityAgent.

- App Privacy now confirms Typing access Allowed after restart. Removed eager sync Keychain access from Settings initialization; 56 integrated sync/settings/Phase6 regression tests pass. Native menu capture QA also exposed a missing in-notch Finish affordance; correction and replacement installer are in progress.
