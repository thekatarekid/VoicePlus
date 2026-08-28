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
# Accept both placeholder dialects so either plist can be the source.
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s/\${VERSION}/$VERSION/g" -e "s/\${BUILD}/$BUILD_NUMBER/g" \
    "$TEMPLATE" > "$CONTENTS/Info.plist"
P="/usr/libexec/PlistBuddy"
setkey() { "$P" -c "Set :$1 $2" "$CONTENTS/Info.plist" 2>/dev/null || "$P" -c "Add :$1 $3 $2" "$CONTENTS/Info.plist"; }
setkey CFBundleIdentifier in.adityakatare.voiceplus string
setkey CFBundleExecutable "$BIN_NAME" string
setkey CFBundleShortVersionString "$VERSION" string
setkey CFBundleVersion "$BUILD_NUMBER" string
setkey LSMinimumSystemVersion 14.0 string
setkey LSUIElement true bool
setkey CFBundleIconFile AppIcon string
setkey CFBundlePackageType APPL string

# --- 2b. TCC gate: every protected API we link needs its usage string ---------
# A missing NS*UsageDescription does not warn — macOS either kills the process on
# first use or silently refuses to show the prompt, which the user experiences as
# "the permission dialog never appeared". Fail the build instead of shipping that.
# (Input Monitoring / kTCCServiceListenEvent and Screen Recording have no
# usage-description key at all; they are gated on the signature — see SIGNING.md.)
REQUIRED_USAGE_KEYS=(
  NSMicrophoneUsageDescription            # AVCaptureDevice / AVAudioEngine
  NSSpeechRecognitionUsageDescription     # SFSpeechRecognizer
  NSContactsUsageDescription              # CNContactStore
  NSCalendarsFullAccessUsageDescription   # EKEventStore (macOS 14+)
  NSCalendarsUsageDescription             # EKEventStore (legacy)
  NSCameraUsageDescription                # CoreMediaIO camera-in-use polling
  NSAppleEventsUsageDescription           # Apple Events injection
  NSAccessibilityUsageDescription         # AX injection
  NSLocalNetworkUsageDescription          # OAuth loopback NWListener
)
missing=()
for k in "${REQUIRED_USAGE_KEYS[@]}"; do
  v="$("$P" -c "Print :$k" "$CONTENTS/Info.plist" 2>/dev/null || true)"
  [ -n "$v" ] || missing+=("$k")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: Info.plist is missing required TCC usage descriptions:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  echo "Add them to $TEMPLATE (see Packaging/SIGNING.md)." >&2
  exit 1
fi
log "TCC usage descriptions: all ${#REQUIRED_USAGE_KEYS[@]} present"
plutil -lint "$CONTENTS/Info.plist" >/dev/null
printf 'APPL????' > "$CONTENTS/PkgInfo"

# --- 3. Resources -----------------------------------------------------------
# Everything the app may read at runtime must live inside the bundle: an end user
# has no repo checkout, so any `#filePath`-relative lookup resolves to nothing.
# `Fixtures/audio` (10MB of dev-only WAVs, Lab harness) is deliberately excluded.
mkdir -p "$CONTENTS/Resources/Fixtures"
for f in transcripts directed tools; do
  [ -d "$ROOT/Fixtures/$f" ] && cp -R "$ROOT/Fixtures/$f" "$CONTENTS/Resources/Fixtures/"
done
rmdir "$CONTENTS/Resources/Fixtures" 2>/dev/null || true
# P4.1 — deterministic action catalogue: ActionCatalog.defaultURL() falls back to
# Bundle.main.resourceURL/catalog.json when the source checkout isn't present.
if [ -f "$ROOT/Actions/Deterministic/catalog.json" ]; then
  cp "$ROOT/Actions/Deterministic/catalog.json" "$CONTENTS/Resources/catalog.json"
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

# --- 4b. Strip build-machine rpaths ------------------------------------------
# The CLT bootstrap shim (Scripts/bootstrap-toolchain.sh) makes SwiftPM bake
# $HOME/Library/Developer/VoicePlus-toolchain/... into LC_RPATH. That directory
# does not exist on a user's Mac, and a user-writable rpath in a shipped binary
# is a dylib-injection surface. Remove any rpath that is not relocatable.
strip_absolute_rpaths() {  # $1 = Mach-O path
  local bin="$1" p
  while read -r p; do
    case "$p" in
      @executable_path*|@loader_path*|/usr/lib*|/System/*) continue ;;
    esac
    log "removing non-relocatable rpath from $(basename "$bin"): $p"
    install_name_tool -delete_rpath "$p" "$bin" 2>/dev/null || true
  done < <(otool -l "$bin" | awk '/LC_RPATH/{f=1} f&&/^ *path /{print $2; f=0}')
}
strip_absolute_rpaths "$CONTENTS/MacOS/$BIN_NAME"

# --- 5. Icon ----------------------------------------------------------------
if [ -f "$ROOT/App/Resources/AppIcon.icns" ]; then
  cp "$ROOT/App/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
else
  python3 "$PKG_DIR/make_icon.py" "$CONTENTS/Resources/AppIcon.icns"
fi

# --- 5b. Self-containment audit ----------------------------------------------
# Nothing in the bundle may reference the build machine. Runs before signing so a
# failure never produces a signed-but-broken app.
log "self-containment audit"
BAD=0
while IFS= read -r macho; do
  while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|@rpath/*|@executable_path/*|@loader_path/*) ;;
      *) echo "ERROR: $macho links non-portable path: $dep" >&2; BAD=1 ;;
    esac
  done < <(otool -L "$macho" | awk 'NR>1 {print $1}')
  while read -r p; do
    case "$p" in
      @executable_path*|@loader_path*|/usr/lib*|/System/*) ;;
      *) echo "ERROR: $macho has non-portable LC_RPATH: $p" >&2; BAD=1 ;;
    esac
  done < <(otool -l "$macho" | awk '/LC_RPATH/{f=1} f&&/^ *path /{print $2; f=0}')
done < <(find "$APP" -type f -perm +111 -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)
# Nothing under Resources/ may be a symlink escaping the bundle either.
while IFS= read -r l; do
  t="$(readlink "$l")"
  case "$t" in /*) echo "ERROR: absolute symlink in bundle: $l -> $t" >&2; BAD=1 ;; esac
done < <(find "$APP" -type l)
[ "$BAD" = "0" ] || { echo "self-containment audit FAILED" >&2; exit 1; }
log "self-containment audit OK (no /Users, /Library/Developer or scratch-dir references)"

# --- 6. Codesign -------------------------------------------------------------
# DEVIATION: no Developer ID identity on this machine -> ad-hoc signature ("-")
# and no notarization. We still enable the hardened runtime, sign nested code
# inside-out (never `--deep`, which Apple deprecated and which mis-applies the
# app's entitlements to nested binaries), and pin --identifier so the bundle ID
# recorded in the signature always matches CFBundleIdentifier. TCC keys its
# records off that identifier plus the cdhash; see Packaging/SIGNING.md for why
# an ad-hoc cdhash still changes on every build and what users must do about it.
IDENTITY="${CODESIGN_IDENTITY:--}"
SIGN_ID="in.adityakatare.voiceplus"
# AMFI's XML parser is stricter than plutil: a "--" inside an XML comment makes it
# reject the whole entitlements file ("AMFIUnserializeXML: syntax error"), which
# would ship an app with NO entitlements at all. Catch it here.
plutil -lint "$PKG_DIR/VoicePlus.entitlements" >/dev/null
python3 - "$PKG_DIR/VoicePlus.entitlements" <<'PY'
import re, sys
path = sys.argv[1]
bad = [c for c in re.findall(r'<!--(.*?)-->', open(path).read(), re.S) if '--' in c]
if bad:
    sys.stderr.write("ERROR: '--' inside an XML comment in %s (AMFI rejects it):\n" % path)
    for c in bad:
        sys.stderr.write("  %s\n" % " ".join(c.split())[:100])
    sys.exit(1)
PY
log "codesign (identity: $IDENTITY, hardened runtime)"
SIGN_OPTS=(--force --sign "$IDENTITY" --timestamp=none --options runtime)

# 6a. Nested code first (inside-out order), no entitlements on nested binaries.
# Resource-only SwiftPM bundles carry no Mach-O and no Info.plist; codesign
# rejects them ("bundle format unrecognized") and they need no signature of their
# own — the outer app's CodeResources seals them. Sign only what has real code.
has_macho() {
  [ -n "$(find "$1" -type f -perm +111 \
      -exec sh -c 'file -b "$1" | grep -q Mach-O && echo y' _ {} \; 2>/dev/null | head -1)" ]
}
while IFS= read -r nested; do
  [ "$nested" = "$APP" ] && continue
  if [ -f "$nested" ] || has_macho "$nested"; then
    log "  sign nested: ${nested#"$APP"/}"
    codesign "${SIGN_OPTS[@]}" "$nested"
  else
    log "  skip (resource-only, sealed by outer signature): ${nested#"$APP"/}"
  fi
done < <(find "$APP/Contents/Frameworks" "$APP/Contents/Resources" \
              \( -name '*.dylib' -o -name '*.framework' -o -name '*.bundle' -o -name '*.app' \) \
              -depth 2>/dev/null || true)

# 6b. Outer app last, with entitlements.
codesign "${SIGN_OPTS[@]}" --identifier "$SIGN_ID" \
  --entitlements "$PKG_DIR/VoicePlus.entitlements" "$APP"

codesign -vv --strict --deep "$APP"
log "signature:"
codesign -dvvv "$APP" 2>&1 | grep -E 'Identifier|CodeDirectory|flags|CDHash|TeamIdentifier|Signature' | sed 's/^/  /'
log "spctl (expected to be rejected for ad-hoc signatures):"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /' || true

log "built $APP ($(du -sh "$APP" | cut -f1)) version $VERSION build $BUILD_NUMBER"
log "TCC note: an ad-hoc cdhash changes on every build. If a permission prompt"
log "          never appears, see Packaging/SIGNING.md / Packaging/reset_tcc.sh."
