#!/bin/bash
# Assemble Packaging/build/VoicePlus.app from a SwiftPM release build.
# Usage: Packaging/make_app.sh <version> [build-number]
# Env:   SCRATCH_PATH (default .build-release), SKIP_BUILD=1 to reuse an existing build,
#        OUT_DIR (default Packaging/build), CODESIGN_IDENTITY / CODESIGN_CERT_NAME (see step 6).
set -euo pipefail

VERSION="${1:?usage: make_app.sh <version> [build-number]}"
BUILD_NUMBER="${2:-$(date -u +%Y%m%d%H%M)}"

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$PKG_DIR/.." && pwd)"
SCRATCH="${SCRATCH_PATH:-$ROOT/.build-release}"
CONFIG="${BUILD_CONFIGURATION:-release}"
case "$CONFIG" in debug|release) ;; *) echo "Invalid BUILD_CONFIGURATION" >&2; exit 2 ;; esac
if [ "${FULL_INSTALLER:-0}" = "1" ] && [ -z "${BUNDLE_MODELS_FROM:-}" ]; then
  echo "FULL_INSTALLER requires BUNDLE_MODELS_FROM; refusing a model-free installer" >&2
  exit 2
fi
OUT="${OUT_DIR:-$PKG_DIR/build}"
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
  log "swift build -c "$CONFIG" --product $PRODUCT (scratch: $SCRATCH)"
  swift build -c "$CONFIG" --product "$PRODUCT" --scratch-path "$SCRATCH" --disable-keychain
fi
BUILD_DIR="$(swift build -c "$CONFIG" --product "$PRODUCT" --scratch-path "$SCRATCH" --show-bin-path)"
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
setkey LSMinimumSystemVersion 15.0 string
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
# `Fixtures/` is NOT copied. Nothing in the shipping app reads it:
#   - transcripts/  — MockEngine scripts only, and the mock engine is now developer-opt-in
#     (VOICEPLUS_ENGINE=mock). Shipping them meant realistic human sentences ("Hi Priya, thanks
#     for the update…") sat inside the release bundle where a fallback could — and did — replay
#     and inject them as if they were the user's speech.
#   - directed/     — manifest for DirectedSpeechHarness, tests only, and it references
#     Fixtures/audio/ which was never shipped anyway.
#   - tools/        — gen_fixtures.py, a dev script.
# `Fixtures/audio` (10MB of dev-only WAVs, Lab harness) was already excluded.
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

# Full installer: a validated default stack makes first-run recognition available offline.
# Explicit opt-in preserves lightweight developer builds; the release gate supplies this source.
if [ -n "${BUNDLE_MODELS_FROM:-}" ]; then
  log "bundling verified default speech models"
  python3 "$PKG_DIR/bundle_models.py" "$BUNDLE_MODELS_FROM" "$CONTENTS/Resources/Models"
fi
# V5 C6 — Silero VAD ships in every bundle (thin or full): ~1 MB, MIT, checked in under
# Packaging/vad/, hash-verified on the way in. Without it users got EnergyVAD.
log "bundling Silero VAD"
python3 "$PKG_DIR/bundle_models.py" --vad "$CONTENTS/Resources/Models"

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
  # Dependencies are the tab-indented lines. A universal binary (llama.framework, V5 D2)
  # prints one "<path> (architecture …):" header per slice, which NR>1 misread as a dep.
  done < <(otool -L "$macho" | awk '/^\t/ {print $1}')
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

# --- 5c. Permission normalisation --------------------------------------------
# `cp -R` preserves the source mode, and a handful of files inside the SwiftPM
# resource bundles are 0444 in the build directory (GRDB's PrivacyInfo.xcprivacy,
# two FluidAudio lexicon blobs). Copied verbatim they ship read-only, and the
# very command our install instructions tell users to run then fails:
#
#   xattr: [Errno 13] Permission denied: .../GRDB_GRDB.bundle/PrivacyInfo.xcprivacy
#
# because rewriting an extended attribute requires write permission on the file
# — even when, as here, there is no com.apple.quarantine attribute to remove and
# nothing is actually broken. It reads as a broken install, and any tool that
# genuinely needs to write an xattr hits the same wall. Normalise the whole
# assembled bundle to sane modes. This MUST run before codesign: the signature
# seals the bundle, so changing a mode afterwards invalidates it.
log "normalising bundle permissions"
chmod -R u+w "$APP"                              # no file is read-only to its owner
find "$APP" -type d -exec chmod 755 {} +         # directories traversable
# Executables and Mach-O keep the executable bit (755); everything else is 644.
# The -perm +111 pass runs first so a Mach-O that is already executable is never
# demoted, and the second pass promotes any Mach-O that arrived non-executable.
find "$APP" -type f -perm +111 -exec chmod 755 {} +
find "$APP" -type f ! -perm +111 -exec sh -c '
  for f; do
    if file -b "$f" | grep -q Mach-O; then chmod 755 "$f"; else chmod 644 "$f"; fi
  done' _ {} +
[ -x "$CONTENTS/MacOS/$BIN_NAME" ] || { echo "ERROR: normalisation stripped +x from $CONTENTS/MacOS/$BIN_NAME" >&2; exit 1; }

# --- 6. Codesign -------------------------------------------------------------
# DEVIATION: no Developer ID identity on this machine -> no notarization. We
# still enable the hardened runtime, sign nested code inside-out (never `--deep`,
# which Apple deprecated and which mis-applies the app's entitlements to nested
# binaries), and pin --identifier so the bundle ID recorded in the signature
# always matches CFBundleIdentifier.
#
# WHAT TCC ACTUALLY STORES (this is the 1.6.3 "the switch is on but the app says
# it is off" bug): not "VoicePlus may listen to key events", but the app's
# *designated requirement* at the moment the switch was flipped, re-evaluated on
# every later query. A bare ad-hoc signature's requirement is
# `cdhash H"<this exact binary>"`, which changes on every build, so the stored
# row stops matching and tccd answers "not granted" while System Settings keeps
# showing the switch as on (different column). See Packaging/SIGNING.md §4.
#
# Two ways out, in order of preference:
#   1. a real code-signing certificate (self-signed is enough — no Apple
#      Developer Program needed; run Packaging/make_signing_cert.sh). codesign
#      then produces `identifier "…" and certificate leaf H"…"` by itself.
#   2. ad-hoc + an EXPLICIT designated requirement of `identifier "…"`. Also
#      build-independent, needs no keychain, no trust store and no admin
#      password — so it is the default here rather than a degraded fallback.
SIGN_ID="in.adityakatare.voiceplus"
CERT_NAME="${CODESIGN_CERT_NAME:-VoicePlus Local Signing}"
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$CERT_NAME\""; then
  IDENTITY="$CERT_NAME"
  log "found a valid code-signing identity in the keychain: $CERT_NAME"
fi
DR_ARGS=()
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  # codesign derives `identifier … and certificate leaf …` on its own; do not
  # override it with something weaker.
  log "codesign identity: $IDENTITY (certificate leaf -> TCC grants survive rebuilds)"
else
  IDENTITY="-"
  DR_ARGS=(-r "=designated => identifier \"$SIGN_ID\"")
  log "codesign identity: ad-hoc (explicitly selected or no matching certificate)"
  log "  pinning an explicit designated requirement: identifier \"$SIGN_ID\""
  log "  run Packaging/make_signing_cert.sh for the stronger certificate-backed identity"
fi
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

# 6b. Outer app last, with entitlements and (ad-hoc only) the explicit designated
# requirement. Only the outer bundle's requirement matters to TCC; nested code
# keeps codesign's default.
codesign "${SIGN_OPTS[@]}" --identifier "$SIGN_ID" "${DR_ARGS[@]+"${DR_ARGS[@]}"}" \
  --entitlements "$PKG_DIR/VoicePlus.entitlements" "$APP"

codesign -vv --strict --deep "$APP"
log "signature:"
codesign -dvvv "$APP" 2>&1 | grep -E 'Identifier|CodeDirectory|flags|CDHash|TeamIdentifier|Signature' | sed 's/^/  /'

# 6c. TCC durability gate. This is the check that would have caught the 1.6.3
# report at build time instead of on a user's Mac: if the designated requirement
# still names one exact binary, every grant this build receives dies with it.
DR="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
log "designated requirement: ${DR:-<unreadable>}"
case "$DR" in
  "")
    echo "ERROR: no designated requirement could be read back from $APP" >&2; exit 1 ;;
  *cdhash*|*CDHash*)
    log "WARNING: the designated requirement pins this build's cdhash."
    log "         Every TCC grant a user gives this build dies on the next one."
    log "         See Packaging/SIGNING.md §4." ;;
  *)
    log "designated requirement is build-independent: TCC grants survive rebuilds." ;;
esac
# Belt and braces: the app must satisfy the requirement it advertises.
codesign --verify -vv -R="$DR" "$APP" 2>&1 | sed 's/^/  /' || true

# 6d. Writability gate. Checked on the FINISHED bundle (after signing, so the
# _CodeSignature files are covered too). A single owner-read-only file is enough
# to make `xattr -dr com.apple.quarantine /Applications/VoicePlus.app` — the
# command in our own install instructions — print "Permission denied" and exit
# non-zero on a user's Mac. Fail the build instead of shipping that.
RO="$(find "$APP" -type f ! -perm -u+w)"
if [ -n "$RO" ]; then
  echo "ERROR: $(printf '%s\n' "$RO" | wc -l | tr -d ' ') file(s) in the bundle are read-only to their owner:" >&2
  printf '%s\n' "$RO" | sed "s#^$APP/#  #" >&2
  echo "  xattr (and anything else that writes an extended attribute) fails on these." >&2
  echo "  See the permission normalisation step (5c) above." >&2
  exit 1
fi
log "writability gate OK (no owner-read-only files in the bundle)"

log "spctl (expected to be rejected without a Developer ID + notarization):"
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /' || true

log "built $APP ($(du -sh "$APP" | cut -f1)) version $VERSION build $BUILD_NUMBER"
log "TCC note: existing rows created by an older build store that build's cdhash"
log "          and can never match again — see Packaging/SIGNING.md §3 step 3 or"
log "          Packaging/reset_tcc.sh. Grants made from this build onwards stick."
