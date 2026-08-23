# VoicePlus — Progress Log

## Environment / deviations
- 2026-08-23: No Xcode.app (CLT only, Swift 6.0.3). Build via SwiftPM; .app assembled by script; DMG via hdiutil; ad-hoc codesign, no notarization (no Developer ID identity). Unit/integration tests only (Swift Testing — see next line) — no Xcode UI tests.

- 2026-08-23 (P1.0): CLT has **no XCTest.framework** → all tests use **Swift Testing**. CLT also has stale leftovers (old `ManifestAPI/*.private.swiftinterface`, duplicate `usr/include/swift/module.modulemap`) that break every SwiftPM build; `Scripts/bootstrap-toolchain.sh` builds a cleaned user-local toolchain shim and `.claude/settings.json` exports `SWIFTPM_CUSTOM_LIBS_DIR`, `SWIFT_EXEC`, `SWIFT_EXEC_MANIFEST`. No sudo available to fix the CLT itself.
- 2026-08-23 (P1.0): Deps added via SwiftPM: GRDB.swift 7.8.0 (Shared), FluidAudio 0.15.6 (Engine; pulls a binary xcframework artifact → use `--disable-keychain` on first resolve).
- CI (`.github/workflows/ci.yml`) targets macos-14 + Xcode 16.2 and is unverified from this machine (no `gh` run possible offline); swiftlint step is conditional on the binary being present.

## Phase 1
- [x] P1.0 Shared foundation — done 2026-08-23. Frozen API: `TranscriptSpan`, `Alternate`, `StageID`, `Utterance`, `EngineState`, `MicQuality`, `FeatureFlag`, `PipelineStage`/`StageContext`/`ConfidenceContract`, `AppDatabase` + `*Record` structs, `EngineProtocol`/`EngineEvent`/`EngineEventBroadcaster`/`MockEngine`/`TranscriptFixture`, `Log`/`LogBuffer`, `FeatureFlagService`, `AppPaths`. 42 tests green.
