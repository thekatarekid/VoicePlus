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
- [ ] P1.12 integration — in progress.
