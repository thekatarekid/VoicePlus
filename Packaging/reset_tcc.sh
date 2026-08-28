#!/bin/bash
# Reset VoicePlus's TCC (privacy) records so the next launch prompts from scratch.
#
# Why this exists: VoicePlus is ad-hoc signed (no Developer ID). An ad-hoc
# signature has no stable designated requirement — its identity IS the cdhash,
# which changes on every single build. Once macOS has a TCC record for
# in.adityakatare.voiceplus, a rebuilt binary no longer matches it, and for
# Input Monitoring (kTCCServiceListenEvent) and Accessibility the system then
# quietly refuses instead of re-prompting. That is exactly the "no prompt ever
# appeared" symptom. Clearing the records restores the first-run behaviour.
#
# Usage:
#   Packaging/reset_tcc.sh                       # in.adityakatare.voiceplus
#   Packaging/reset_tcc.sh <bundle-id>           # any other id: asks first
#   Packaging/reset_tcc.sh <bundle-id> --yes     # non-interactive override
#
# Safety: defaults to VoicePlus and will not touch another bundle id unless you
# type that id and confirm. It never runs `tccutil reset <service>` with no
# bundle id (that would wipe the setting for EVERY app on the Mac).
set -euo pipefail

DEFAULT_ID="in.adityakatare.voiceplus"
BUNDLE_ID="$DEFAULT_ID"
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) BUNDLE_ID="$arg" ;;
  esac
done

# Never let an empty/whitespace id through — `tccutil reset X ""` is global.
case "$BUNDLE_ID" in
  ""|*[[:space:]]*) echo "ERROR: invalid bundle id: '$BUNDLE_ID'" >&2; exit 2 ;;
esac
if ! printf '%s' "$BUNDLE_ID" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$'; then
  echo "ERROR: '$BUNDLE_ID' does not look like a bundle identifier." >&2
  exit 2
fi

if [ "$BUNDLE_ID" != "$DEFAULT_ID" ]; then
  echo "WARNING: this script is meant for $DEFAULT_ID."
  echo "         You asked to reset privacy permissions for: $BUNDLE_ID"
  if [ "$ASSUME_YES" != "1" ]; then
    printf "Type the bundle id again to confirm (or anything else to abort): "
    read -r confirm
    [ "$confirm" = "$BUNDLE_ID" ] || { echo "aborted."; exit 1; }
  fi
fi

# Only the services VoicePlus actually asks for.
SERVICES=(
  Microphone          # AVCaptureDevice / AVAudioEngine
  ListenEvent         # Input Monitoring — the global hotkey CGEventTap
  Accessibility       # AX text injection + cursor reads
  SpeechRecognition   # SFSpeechRecognizer (on-device)
)

echo "Resetting TCC for $BUNDLE_ID"
rc=0
for svc in "${SERVICES[@]}"; do
  if out="$(tccutil reset "$svc" "$BUNDLE_ID" 2>&1)"; then
    printf '  %-18s reset\n' "$svc"
  else
    printf '  %-18s FAILED: %s\n' "$svc" "$out"
    rc=1
  fi
done

# Quarantine is the other half of the "prompt never appears" story: a quarantined
# ad-hoc app launched from ~/Downloads or straight off the dmg gets App
# Translocation'd to a random read-only /private/var/folders path, and TCC grants
# made there do not stick. Clearing the flag on the installed copy avoids it.
APP="/Applications/VoicePlus.app"
if [ "$BUNDLE_ID" = "$DEFAULT_ID" ] && [ -d "$APP" ]; then
  if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$APP" && echo "  quarantine        cleared on $APP"
  else
    echo "  quarantine        not set on $APP"
  fi
fi

cat <<EOF

Next steps:
  1. Quit VoicePlus completely (menu bar icon > Quit), then relaunch it from
     /Applications — not from the dmg and not from ~/Downloads.
  2. Work through onboarding again; the prompts should reappear.

If Input Monitoring or Accessibility still never prompts, add the app by hand:
  System Settings > Privacy & Security > Input Monitoring  > "+" > /Applications/VoicePlus.app
  System Settings > Privacy & Security > Accessibility     > "+" > /Applications/VoicePlus.app
Remove any stale VoicePlus row with "-" first, then re-add it.
See Packaging/SIGNING.md for the full explanation.
EOF
exit $rc
