#!/bin/bash
# Assemble Packaging/build/VoicePlus.app from a SwiftPM release build.
# Usage: Packaging/make_app.sh <version> [build-number]
# Env:   SCRATCH_PATH (default .build-release), SKIP_BUILD=1 to reuse an existing build.
set -euo pipefail

VERSION="${1:?usage: make_app.sh <version> [build-number]}"
BUILD_NUMBER="${2:-$(date -u +%Y%m%d%H%M)}"

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$PKG_DIR/.." && pwd)"
SCRATCH="${SCRATCH_PATH:-$ROOT/.build-release}"
OUT="$PKG_DIR/build"
APP="$OUT/VoicePlus.app"
CONTENTS="$APP/Contents"
BIN_NAME="VoicePlus"
PRODUCT="VoicePlusApp"

log() { printf '\033[1;34m[make_app]\033[0m %s\n' "$*"; }

# --- 1. Build ---------------------------------------------------------------
cd "$ROOT"
# CLT-only machines need the toolchain shim (see CLAUDE.md); full Xcode (CI) does not.
if [ -f Scripts/bootstrap-toolchain.sh ] && ! xcode-select -p 2>/dev/null | grep -q 'Xcode.app'; then
  eval "$(Scripts/bootstrap-toolchain.sh)"
fi
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "swift build -c release --product $PRODUCT (scratch: $SCRATCH)"
  swift build -c release --product "$PRODUCT" --scratch-path "$SCRATCH" --disable-keychain
fi
BUILD_DIR="$(swift build -c release --product "$PRODUCT" --scratch-path "$SCRATCH" --show-bin-path)"
[ -x "$BUILD_DIR/$PRODUCT" ] || { echo "binary not found: $BUILD_DIR/$PRODUCT" >&2; exit 1; }

# --- 2. Bundle skeleton -----------------------------------------------------
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BUILD_DIR/$PRODUCT" "$CONTENTS/MacOS/$BIN_NAME"
chmod +x "$CONTENTS/MacOS/$BIN_NAME"

# Info.plist: prefer App/Resources/Info.plist (owned by the App module) once it exists.
TEMPLATE="$ROOT/App/Resources/Info.plist"
[ -f "$TEMPLATE" ] || TEMPLATE="$PKG_DIR/Info.plist.template"
log "Info.plist from $TEMPLATE"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" "$TEMPLATE" > "$CONTENTS/Info.plist"
P="/usr/libexec/PlistBuddy"
setkey() { "$P" -c "Set :$1 $2" "$CONTENTS/Info.plist" 2>/dev/null || "$P" -c "Add :$1 $3 $2" "$CONTENTS/Info.plist"; }
setkey CFBundleIdentifier in.adityakatare.voiceplus string
setkey CFBundleExecutable "$BIN_NAME" string
setkey CFBundleShortVersionString "$VERSION" string
setkey CFBundleVersion "$BUILD_NUMBER" string
setkey LSMinimumSystemVersion 14.0 string
setkey LSUIElement true bool
setkey CFBundleIconFile AppIcon string
"$P" -c "Print :NSMicrophoneUsageDescription" "$CONTENTS/Info.plist" >/dev/null
printf 'APPL????' > "$CONTENTS/PkgInfo"

# --- 3. Resources -----------------------------------------------------------
if [ -d "$ROOT/Fixtures/transcripts" ]; then
  mkdir -p "$CONTENTS/Resources/Fixtures"
  cp -R "$ROOT/Fixtures/transcripts" "$CONTENTS/Resources/Fixtures/"
fi
# SwiftPM resource bundles (Module_Target.bundle) sit next to the binary.
shopt -s nullglob
for b in "$BUILD_DIR"/*.bundle; do
  log "resource bundle: $(basename "$b")"
  cp -R "$b" "$CONTENTS/Resources/"
done

# --- 4. Dynamic libraries / frameworks the binary links ---------------------
# Anything under the build dir (or a binary xcframework artifact) referenced via @rpath.
ARTIFACTS="$SCRATCH/artifacts"
copy_framework() {  # $1 = path to .framework or .dylib
  local src="$1" name; name="$(basename "$src")"
  [ -e "$CONTENTS/Frameworks/$name" ] && return 0
  log "framework: $name"
  cp -R "$src" "$CONTENTS/Frameworks/"
}
for dep in $(otool -L "$CONTENTS/MacOS/$BIN_NAME" | awk 'NR>1 {print $1}'); do
  case "$dep" in
    @rpath/*)
      rel="${dep#@rpath/}"; top="${rel%%/*}"
      found=""
      for cand in "$BUILD_DIR/$top" "$BUILD_DIR/PackageFrameworks/$top"; do
        [ -e "$cand" ] && { found="$cand"; break; }
      done
      if [ -z "$found" ] && [ -d "$ARTIFACTS" ]; then
        # xcframework slice for macOS arm64/x86_64
        found="$(find "$ARTIFACTS" -path '*macos*' -name "$top" -maxdepth 8 2>/dev/null | head -1 || true)"
      fi
      if [ -n "$found" ]; then
        copy_framework "$found"
      else
        echo "WARNING: @rpath dependency not found in build dir: $dep" >&2
      fi
      ;;
    "$BUILD_DIR"/*|"$SCRATCH"/*)
      copy_framework "$dep"
      install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$CONTENTS/MacOS/$BIN_NAME"
      ;;
  esac
done
# Make sure the binary looks in Contents/Frameworks (idempotent add).
if ! otool -l "$CONTENTS/MacOS/$BIN_NAME" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/$BIN_NAME"
fi
if [ -z "$(ls -A "$CONTENTS/Frameworks")" ]; then rmdir "$CONTENTS/Frameworks"; fi

# --- 5. Icon ----------------------------------------------------------------
if [ -f "$ROOT/App/Resources/AppIcon.icns" ]; then
  cp "$ROOT/App/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
  python3 "$PKG_DIR/make_icon.py" "$CONTENTS/Resources/AppIcon.icns"
fi

# --- 6. Ad-hoc codesign -----------------------------------------------------
# DEVIATION: no Developer ID identity on this machine -> ad-hoc signature ("-"),
# no hardened runtime enforcement, no notarization. Gatekeeper will show the
# "unidentified developer" prompt; users right-click > Open once.
IDENTITY="${CODESIGN_IDENTITY:--}"
log "codesign (identity: $IDENTITY)"
if [ -d "$CONTENTS/Frameworks" ]; then
  find "$CONTENTS/Frameworks" \( -name '*.dylib' -o -name '*.framework' \) -maxdepth 1 -print0 \
    | xargs -0 -n1 codesign --force --sign "$IDENTITY" --timestamp=none 2>/dev/null || true
fi
codesign --force --deep --sign "$IDENTITY" --timestamp=none \
  --entitlements "$PKG_DIR/VoicePlus.entitlements" "$APP"
codesign -vv --deep --strict "$APP"
log "spctl (expected to be rejected for ad-hoc signatures):"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /' || true

log "built $APP ($(du -sh "$APP" | cut -f1)) version $VERSION build $BUILD_NUMBER"
