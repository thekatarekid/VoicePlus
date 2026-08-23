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
