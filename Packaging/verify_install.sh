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
grep -qx in.adityakatare.voiceplus <<<"$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")" || fail "bundle id"
VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
echo "[verify] version $VER"
case "$VER" in ''|*'__'*|*'${'*) fail "version placeholder was not substituted: '$VER'" ;; esac
grep -qE '^[0-9]' <<<"$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")" || fail "CFBundleVersion"
grep -qx true <<<"$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist")" || fail "LSUIElement"
grep -q . <<<"$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")" || fail "LSMinimumSystemVersion"

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
# NB: capture first, then grep. Under `set -o pipefail` a `| grep -q` can SIGPIPE
# the producer the moment grep finds its match, turning a PASS into a flaky FAIL.
sig_out="$(codesign -dvvv "$APP" 2>&1 || true)"
grep -qx 'Identifier=in.adityakatare.voiceplus' <<<"$sig_out" \
  || fail "codesign Identifier != CFBundleIdentifier"
ent_out="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
grep -q 'com.apple.security.device.audio-input' <<<"$ent_out" \
  || fail "audio-input entitlement missing"

# The designated requirement is what TCC stores when a switch is turned on and
# re-evaluates on every later query. If it names this exact binary, every grant
# the user gives this build dies on the next one — the 1.6.3 "Input Monitoring is
# on but the app says it is off" report. See Packaging/SIGNING.md section 4.
dr="$(codesign -d -r- "$APP" 2>/dev/null | sed -n 's/^#* *designated => //p')"
[ -n "$dr" ] || fail "no designated requirement in the signature"
echo "[verify] designated requirement: $dr"
case "$dr" in
  *cdhash*|*CDHash*) fail "designated requirement pins this build's cdhash — TCC grants will not survive an update" ;;
esac
echo "[verify]   build-independent: grants survive updates"

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

# Installability: what a user actually does after dragging the app to
# /Applications. In 1.6.4 three files inside the SwiftPM resource bundles shipped
# 0444 (cp -R had preserved the build directory's mode), so the documented
#   xattr -dr com.apple.quarantine /Applications/VoicePlus.app
# printed three "Permission denied" lines and exited 1. Nothing was broken —
# there was no quarantine attribute to strip — but it reads as a broken install.
echo "[verify] installability"
ro="$(find "$APP" -type f ! -perm -u+w)"
if [ -n "$ro" ]; then
  printf '%s\n' "$ro" | sed "s#^$APP/#  read-only: #" >&2
  fail "$(printf '%s\n' "$ro" | wc -l | tr -d ' ') file(s) are read-only to their owner; xattr cannot rewrite them"
fi
echo "[verify]   every file is owner-writable"

# A locally built dmg is never downloaded, so nothing in it should carry a
# quarantine attribute after a clean install.
quarantined="$(find "$APP" -exec sh -c 'xattr "$1" 2>/dev/null | grep -qx com.apple.quarantine && echo "$1"' _ {} \; || true)"
if [ -n "$quarantined" ]; then
  printf '%s\n' "$quarantined" | sed "s#^$APP/#  quarantined: #" >&2
  fail "com.apple.quarantine present in a freshly installed copy"
fi
echo "[verify]   no com.apple.quarantine anywhere in the installed copy"

# And the documented un-quarantine command must be a clean no-op: exit 0, silent.
xattr_err="$(xattr -dr com.apple.quarantine "$APP" 2>&1 >/dev/null)" && xattr_rc=0 || xattr_rc=$?
[ "$xattr_rc" = "0" ] || { printf '%s\n' "$xattr_err" | sed 's/^/  /' >&2; fail "xattr -dr com.apple.quarantine exited $xattr_rc"; }
[ -z "$xattr_err" ] || { printf '%s\n' "$xattr_err" | sed 's/^/  /' >&2; fail "xattr -dr com.apple.quarantine wrote to stderr"; }
echo "[verify]   xattr -dr com.apple.quarantine: exit 0, no stderr"

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
