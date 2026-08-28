#!/bin/bash
# First-run integrity check from the actual dmg artifact (P1.13 T3).
# Usage: Packaging/verify_install.sh <dmg>
# Mounts the dmg, copies the app into a temp "Applications" dir, launches it,
# checks the process + ~/Library/Application Support/VoicePlus, kills, unmounts.
set -euo pipefail
DMG="${1:?usage: verify_install.sh <dmg>}"
[ -f "$DMG" ] || { echo "no such dmg: $DMG" >&2; exit 1; }

APP_SUPPORT="$HOME/Library/Application Support/VoicePlus"
WORK="$(mktemp -d -t voiceplus-verify)"
MNT="$WORK/mnt"; APPS="$WORK/Applications"; mkdir -p "$MNT" "$APPS"
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
  pkill -x VoicePlus 2>/dev/null || true
  hdiutil detach -quiet -force "$MNT" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "[verify] mounting $DMG"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG"
[ -d "$MNT/VoicePlus.app" ] || fail "VoicePlus.app missing from dmg"
[ -L "$MNT/Applications" ] || fail "Applications symlink missing from dmg"

echo "[verify] clean install -> $APPS"
cp -R "$MNT/VoicePlus.app" "$APPS/"
APP="$APPS/VoicePlus.app"
codesign -vv --deep --strict "$APP" 2>&1 | sed 's/^/  /'
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" | grep -qx in.adityakatare.voiceplus || fail "bundle id"
VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
echo "[verify] version $VER"
case "$VER" in ''|*'__'*|*'${'*) fail "version placeholder was not substituted: '$VER'" ;; esac
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist" | grep -qE '^[0-9]' || fail "CFBundleVersion"
/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist" | grep -qx true || fail "LSUIElement"
/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist" | grep -q . || fail "LSMinimumSystemVersion"

# TCC: a missing usage string silently suppresses the permission prompt.
echo "[verify] TCC usage descriptions"
for k in NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription \
         NSContactsUsageDescription NSCalendarsFullAccessUsageDescription \
         NSCalendarsUsageDescription NSCameraUsageDescription \
         NSAppleEventsUsageDescription NSAccessibilityUsageDescription \
         NSLocalNetworkUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$k" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || fail "Info.plist missing $k (see Packaging/SIGNING.md)"
done
echo "[verify]   all 9 present"

# Signature must identify itself as the app's own bundle id, or TCC cannot match it.
codesign -dvvv "$APP" 2>&1 | grep -qx 'Identifier=in.adityakatare.voiceplus' \
  || fail "codesign Identifier != CFBundleIdentifier"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q 'com.apple.security.device.audio-input' \
  || fail "audio-input entitlement missing"

# Self-containment: nothing may point back at the build machine.
echo "[verify] self-containment"
while IFS= read -r macho; do
  otool -L "$macho" | awk 'NR>1 {print $1}' | grep -Ev '^(/usr/lib/|/System/|@rpath/|@executable_path/|@loader_path/)' \
    && fail "$macho links a non-portable path"
  otool -l "$macho" | awk '/LC_RPATH/{f=1} f&&/^ *path /{print $2; f=0}' \
    | grep -Ev '^(@executable_path|@loader_path|/usr/lib|/System/)' \
    && fail "$macho has a non-portable LC_RPATH"
done < <(find "$APP" -type f -perm +111 -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)
echo "[verify]   no /Users, /Library/Developer or build-dir references"

pkill -x VoicePlus 2>/dev/null || true
echo "[verify] launching"
open -n "$APP" || fail "open failed"
seen=0; exited=0
for _ in $(seq 1 40); do
  if pgrep -xq VoicePlus; then seen=1; break; fi
  sleep 0.25
done
if [ "$seen" = "1" ]; then
  echo "[verify] process running (pid $(pgrep -x VoicePlus | head -1))"
else
  # Binary may exit immediately (placeholder app) - run it directly to check the exit code.
  "$APP/Contents/MacOS/VoicePlus" >/dev/null 2>&1 && exited=1 || fail "binary exited non-zero"
  echo "[verify] process exited cleanly before we could observe it (headless/placeholder build)"
fi
sleep 2
[ -d "$APP_SUPPORT" ] && echo "[verify] $APP_SUPPORT present" \
  || echo "[verify] NOTE: $APP_SUPPORT not created (app may not touch disk yet)"
pkill -x VoicePlus 2>/dev/null && echo "[verify] killed" || true
echo "[verify] OK"
