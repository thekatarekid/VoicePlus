# VoicePlus — agent conventions (read before working)

Source of truth: `PRODUCT-SPEC.md` (why), `DESIGN.md` (anything visible), `DECISIONS.md` (flag defaults). Your assigned item ID is defined in the plan you were pointed at — Phase items (e.g. P1.8) in `docs/plans/VoicePlus_Build.md`, later waves in the other `docs/plans/` docs; the current one is `docs/plans/VoicePlus_ContextWriter_Plan.md`. Read only your item's section + the plan's Sections 0–3. Every doc is indexed in `docs/README.md`.

## Toolchain reality (no Xcode.app on this machine)
- Only Command Line Tools: Swift 6.0.3, `swift build`/`swift test`. **No `xcodebuild`, no Xcode UI tests, no simulators, and NO XCTest** (the CLT ships no XCTest.framework). **Tests use Swift Testing** (`import Testing`, `@Test`, `#expect`, `#require`) — see `Tests/SharedTests/` for the pattern.
- The CLT install is partially broken (stale files from older versions). **Run `eval "$(Scripts/bootstrap-toolchain.sh)"` once per shell** (or rely on `.claude/settings.json`, which exports the same env vars) before any `swift build`/`swift test`. Without it every build fails with `Undefined symbols ... Package.__allocating_init` or `redefinition of module 'SwiftBridging'`.
- Add `--disable-keychain` to `swift build`/`swift test`/`swift package resolve` when SwiftPM needs to download a binary artifact (FluidAudio pulls one); the keychain prompt can't be answered non-interactively. Once cached it is not needed.
- App bundle is assembled by `Packaging/make_app.sh`; DMG by `Packaging/release.sh <phase> <version>` (hdiutil). Ad-hoc codesign only (no Developer ID identity available; notarization skipped — documented deviation).
- macOS 15+ target, Swift 5 language mode in Package.swift (`swiftLanguageVersions: [.v5]`) to avoid Swift 6 strict-concurrency churn.
- Third-party deps via SwiftPM only: GRDB (SQLite), FluidAudio (ASR/VAD, Apache-2.0). Do not add deps without noting it in progress.md.

## Repo layout (SwiftPM, one package, one target per module)
Shared/ Engine/ Pipeline/ Injection/ App/ Providers/ Lab/ Actions/ Sync/ iOS/ Packaging/ Tests/ Fixtures/ Scripts/ tools/ docs/ — see Build doc §2. `Package.swift` at root. Targets: `Shared`, `Engine`, `Pipeline`, `Injection`, `Providers`, `Lab`, `Actions`, `Sync`, `KeyboardCore` (`iOS/KeyboardCore`), `VoicePlusApp` (executable, `App/`), `<Module>Tests`.

## Where docs go
Only `README.md`, `CLAUDE.md`, `PRODUCT-SPEC.md`, `DESIGN.md`, `DECISIONS.md` and `progress.md` live at the root. New investigations go to `docs/investigations/VoicePlus_Investigation_YYYY-MM-DD.md`, plans and build docs to `docs/plans/` (add a row to the timeline in `docs/README.md`), research to `docs/research/`. Release notes stay in `Packaging/notes/` (`release.sh` reads them). Tests read `DESIGN.md` and `docs/design-history/design/` by path — don't move them without updating `Tests/AppTests` and `Scripts/spool_golden.mjs`.

## Parallel-work rules (several agents work in this checkout simultaneously)
- **Only touch your module's directory + your test target.** Never edit `Shared/` or `Package.swift` unless your item says so; if you need a change there, make it minimal, additive, and mention it in your final report.
- Build/test with an isolated scratch path: `swift build --scratch-path .build-<yourItem>` and `swift test --scratch-path .build-<yourItem> --filter <YourModule>Tests`. `.build*` is gitignored. Fixtures are read from `Fixtures/` at the package root (`AppPaths.fixturesDirectory()`), not from a bundle.
- Commit often, scoped: `git add <your paths> && git commit -m "P1.x Tn: ..."`. If `index.lock` exists, wait 2s and retry. Never `git add -A`, never push (orchestrator pushes), never rebase/reset.
- Keep files small and focused. No web views, no Electron, no telemetry, no plaintext secrets.
- Pipeline stages are `[TranscriptSpan] -> [TranscriptSpan]`; never drop confidence/audioRange/provenance.
- Licensing: Muesli MIT (copy w/ attribution), FluidAudio fork/depend, FluidVoice GPLv3 design-only (never copy), Paperclip MIT.
- When real hardware/models/permissions can't be exercised in tests, test against protocols + mocks and state clearly what is untested.

## Definition of done for an item
All tasks implemented → `swift build` clean for whole package → your tests pass → acceptance criteria addressed (or explicitly noted as needing manual verification) → committed. Final report: ≤15 lines: what was built, files, test results, deviations/untested parts.
