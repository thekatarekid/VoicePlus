# VoicePlus

A macOS dictation layer: speak anywhere, and the text lands in the focused field. Speech recognition runs on-device (FluidAudio); an optional writer cleans the text up using the context of where it is going.

## Build and test

```bash
eval "$(Scripts/bootstrap-toolchain.sh)"   # needed on Command-Line-Tools-only machines, once per shell
swift build
swift test                                  # Swift Testing, no XCTest
```

## Package and release

```bash
Packaging/make_app.sh                       # assemble VoicePlus.app
Packaging/release.sh <phase> <version>      # DMG + GitHub release
```

DMGs are written to `Packaging/releases/` and published as GitHub Releases; they are not committed. Signing and permission details: `Packaging/SIGNING.md`.

## Layout

One SwiftPM package, one target per module: `Shared`, `Engine`, `Pipeline`, `Injection`, `Providers`, `Lab`, `Actions`, `Sync`, `iOS/KeyboardCore`, and the `App` executable. Tests are in `Tests/<Module>Tests`, fixtures in `Fixtures/`, helper tools in `tools/` and `Scripts/`.

## Docs

Start with [`PRODUCT-SPEC.md`](PRODUCT-SPEC.md) (why) and [`DESIGN.md`](DESIGN.md) (what it looks like). Every other doc is indexed in [`docs/README.md`](docs/README.md). Agents: read [`CLAUDE.md`](CLAUDE.md).

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): free for personal, research, educational and other noncommercial use; commercial use needs a separate license from the author. Third-party components keep their own licenses — see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
