#!/bin/bash
# Works around a broken Command Line Tools install on this machine (no Xcode.app, no sudo).
# Two stale leftovers from older CLT versions break every SwiftPM build:
#   1. usr/lib/swift/pm/ManifestAPI/*.private.swiftinterface (Feb 2024) shadow the 6.0.3
#      interfaces -> "Undefined symbols ... Package.__allocating_init" on any Package.swift.
#   2. usr/include/swift/module.modulemap (Aug 2023) duplicates bridging.modulemap ->
#      "redefinition of module 'SwiftBridging'" -> `import Foundation` fails everywhere.
# Fix: build user-local copies without the stale files and point SwiftPM at them via env:
#   SWIFTPM_CUSTOM_LIBS_DIR  -> cleaned ManifestAPI/PluginAPI
#   SWIFT_EXEC / SWIFT_EXEC_MANIFEST -> swiftc wrapper that injects -resource-dir
# `.claude/settings.json` exports these for agent sessions. Idempotent.
# Note: this CLT has NO XCTest.framework at all; tests use Swift Testing (`import Testing`).
set -euo pipefail
CLT="$(xcode-select -p)"
LIBS="$HOME/Library/Developer/VoicePlus-swiftpm-libs"
TC="$HOME/Library/Developer/VoicePlus-toolchain"

# Disk preflight. A full `swift build --build-tests` scratch path is ~1.8 GB, and every agent
# in this checkout leaves its own `.build-<item>` behind, so the boot volume fills up quietly.
# When it does, compile/link steps die mid-write (`ld: write() failed, errno=28`) but SwiftPM's
# build DB may still consider the target up to date -- you get a scratch path holding object
# files from two different builds. Symptom seen in the wild: a test binary where LabTests was
# linked against an older layout of a `Shared` enum, so `#expect(engine.state == .idle)` both
# failed and then SIGSEGV'd inside swift-testing's reflection (EXC_BAD_ACCESS in
# _StringObject.getSharedUTF8Start) while rendering the failure -- with no defect in the source.
# Fail loudly here instead: a corrupt build that looks like memory corruption costs hours.
FREE_MB="$(df -m . | awk 'NR==2 {print $4}')"
if [ "${FREE_MB:-0}" -lt 3072 ]; then
  echo "bootstrap-toolchain: only ${FREE_MB} MB free on this volume -- refusing to build." >&2
  echo "  Builds below ~3 GB free produce truncated object files and bogus SIGSEGVs." >&2
  echo "  Reclaim space first, e.g.: du -sh .build-* | sort -h   then remove stale scratch paths." >&2
  exit 1
elif [ "${FREE_MB:-0}" -lt 10240 ]; then
  echo "bootstrap-toolchain: warning -- only ${FREE_MB} MB free. A full build+test needs ~2 GB." >&2
  echo "  If a build behaves impossibly (SIGSEGV in reflection, stale layouts), suspect this first." >&2
fi

if [ ! -f "$LIBS/ManifestAPI/libPackageDescription.dylib" ]; then
  mkdir -p "$LIBS"
  cp -R "$CLT/usr/lib/swift/pm/ManifestAPI" "$CLT/usr/lib/swift/pm/PluginAPI" "$LIBS/"
  find "$LIBS" -name "*.private.swiftinterface" -delete
fi

if [ ! -x "$TC/usr/bin/swiftc" ]; then
  mkdir -p "$TC/usr/lib" "$TC/usr/include/swift" "$TC/usr/bin"
  ln -sfn "$CLT/usr/lib/swift" "$TC/usr/lib/swift"
  # swift-testing (Testing.framework) is located relative to the toolchain root.
  ln -sfn "$CLT/Library" "$TC/Library"
  cp "$CLT/usr/include/swift/bridging" "$CLT/usr/include/swift/bridging.modulemap" "$TC/usr/include/swift/"
  cat > "$TC/usr/bin/swiftc" <<WRAP
#!/bin/bash
HERE="\$(cd "\$(dirname "\$0")/.." && pwd)"
exec "$CLT/usr/bin/swiftc" -resource-dir "\$HERE/lib/swift" "\$@"
WRAP
  chmod +x "$TC/usr/bin/swiftc"
fi

cat <<ENV
export SWIFTPM_CUSTOM_LIBS_DIR="$LIBS"
export SWIFT_EXEC="$TC/usr/bin/swiftc"
export SWIFT_EXEC_MANIFEST="$TC/usr/bin/swiftc"
ENV
