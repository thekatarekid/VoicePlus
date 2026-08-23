# VoicePlus — agent conventions (read before working)

Source of truth: `PRODUCT-SPEC.md` (why), `VoicePlus_Build.md` (what/how). Your assigned item ID (e.g. P1.8) is defined there — read only your item's section + Sections 0–3.

## Toolchain reality (no Xcode.app on this machine)
- Only Command Line Tools: Swift 6.0.3, `swift build`/`swift test` (XCTest works). **No `xcodebuild`, no Xcode UI tests, no simulators.**
- App bundle is assembled by `Packaging/make_app.sh`; DMG by `Packaging/release.sh <phase> <version>` (hdiutil). Ad-hoc codesign only (no Developer ID identity available; notarization skipped — documented deviation).
- macOS 14+ target, Swift 5 language mode in Package.swift (`swiftLanguageVersions: [.v5]`) to avoid Swift 6 strict-concurrency churn.
- Third-party deps via SwiftPM only: GRDB (SQLite), FluidAudio (ASR/VAD, Apache-2.0). Do not add deps without noting it in progress.md.

## Repo layout (SwiftPM, one package, one target per module)
Shared/ Engine/ Pipeline/ Injection/ App/ Providers/ Lab/ Actions/ Packaging/ Tests/ Fixtures/ — see Build doc §2. `Package.swift` at root. Targets: `Shared`, `Engine`, `Pipeline`, `Injection`, `Providers`, `Lab`, `Actions`, `VoicePlusApp` (executable), `<Module>Tests`.

## Parallel-work rules (several agents work in this checkout simultaneously)
- **Only touch your module's directory + your test target.** Never edit `Shared/` or `Package.swift` unless your item says so; if you need a change there, make it minimal, additive, and mention it in your final report.
- Build/test with an isolated scratch path: `swift build --scratch-path .build-<yourItem>` and `swift test --scratch-path .build-<yourItem> --filter <YourModule>Tests`. `.build*` is gitignored.
- Commit often, scoped: `git add <your paths> && git commit -m "P1.x Tn: ..."`. If `index.lock` exists, wait 2s and retry. Never `git add -A`, never push (orchestrator pushes), never rebase/reset.
- Keep files small and focused. No web views, no Electron, no telemetry, no plaintext secrets.
- Pipeline stages are `[TranscriptSpan] -> [TranscriptSpan]`; never drop confidence/audioRange/provenance.
- Licensing: Muesli MIT (copy w/ attribution), FluidAudio fork/depend, FluidVoice GPLv3 design-only (never copy), Paperclip MIT.
- When real hardware/models/permissions can't be exercised in tests, test against protocols + mocks and state clearly what is untested.

## Definition of done for an item
All tasks implemented → `swift build` clean for whole package → your tests pass → acceptance criteria addressed (or explicitly noted as needing manual verification) → committed. Final report: ≤15 lines: what was built, files, test results, deviations/untested parts.
