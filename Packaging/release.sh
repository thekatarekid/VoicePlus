#!/bin/bash
# Reusable release pipeline. Every phase ships through this script (Build doc §11).
#
# Usage: Packaging/release.sh <phase> <version> [--no-github] [--build N]
#   e.g. Packaging/release.sh 1 1.0.0        -> Packaging/releases/VoicePlus_1_1.0.0.dmg
#        Packaging/release.sh nightly 0.0.0-nightly.20260823 --no-github
#
# Steps: make_app -> dmg (hdiutil, drag-install layout) -> archive + SHA256 ->
#        appcast.xml -> Homebrew cask -> git tag + GitHub release (unless --no-github).
# Never overwrites an existing dmg.
set -euo pipefail

PHASE="${1:?usage: release.sh <phase> <version> [--no-github]}"
VERSION="${2:?usage: release.sh <phase> <version> [--no-github]}"
shift 2
NO_GITHUB=0; BUILD_NUMBER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-github) NO_GITHUB=1 ;;
    --build) BUILD_NUMBER="$2"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$BUILD_NUMBER" ] || BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$PKG_DIR/.." && pwd)"
RELEASES="$PKG_DIR/releases"
APP="$PKG_DIR/build/VoicePlus.app"
DMG_NAME="VoicePlus_${PHASE}_${VERSION}.dmg"
DMG="$RELEASES/$DMG_NAME"
VOLNAME="VoicePlus $VERSION"
STAGING="$PKG_DIR/build/dmg-root"
TAG="release/phase-${PHASE}/v${VERSION}"
REPO_URL="$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -E 's#git@github.com:#https://github.com/#; s#\.git$##' || true)"
[ -n "$REPO_URL" ] || REPO_URL="https://github.com/thekatarekid/VoicePlus"
DOWNLOAD_URL="$REPO_URL/releases/download/$(printf '%s' "$TAG" | sed 's#/#%2F#g')/$DMG_NAME"

log() { printf '\033[1;32m[release]\033[0m %s\n' "$*"; }

mkdir -p "$RELEASES"
if [ -e "$DMG" ]; then
  echo "ABORT: $DMG already exists. Releases are immutable; bump the patch version." >&2
  exit 1
fi

# --- 1. App --------------------------------------------------------------------
"$PKG_DIR/make_app.sh" "$VERSION" "$BUILD_NUMBER"

# --- 2. DMG --------------------------------------------------------------------
log "building $DMG_NAME"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
if [ -f "$PKG_DIR/dmg-background.png" ]; then
  mkdir -p "$STAGING/.background"; cp "$PKG_DIR/dmg-background.png" "$STAGING/.background/background.png"
fi
TMP_DMG="$RELEASES/.${DMG_NAME%.dmg}.tmp.dmg"
rm -f "$TMP_DMG"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO -imagekey zlib-level=9 "$TMP_DMG"
mv "$TMP_DMG" "$DMG"
rm -rf "$STAGING"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$DMG" 2>/dev/null || true
hdiutil verify -quiet "$DMG"

# --- 3. Archive + checksum ------------------------------------------------------
SIZE_BYTES=$(stat -f %z "$DMG"); SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
printf '%s  %s\n' "$SHA" "$DMG_NAME" >> "$RELEASES/CHECKSUMS.txt"
log "$DMG_NAME  ${SIZE_MB}MB  sha256=$SHA"

# Keep dmgs locally always; commit them only when under GitHub's 100MB file limit.
GITIGNORE="$ROOT/.gitignore"; IGN_LINE="Packaging/releases/$DMG_NAME"
if [ "$SIZE_BYTES" -gt $((100 * 1024 * 1024)) ]; then
  grep -qxF "$IGN_LINE" "$GITIGNORE" 2>/dev/null || echo "$IGN_LINE" >> "$GITIGNORE"
  log "decision: ${SIZE_MB}MB > 100MB -> dmg kept locally, added to .gitignore (not committed)"
else
  log "decision: ${SIZE_MB}MB <= 100MB -> dmg will be committed to the repo"
fi

# --- 4. Appcast (Sparkle format; DEVIATION: no EdDSA signature) --------------------
APPCAST="$PKG_DIR/appcast.xml"
# V5 J5: the in-app updater (App/Core/AppcastUpdater.swift) checks length + sha256 and skips items
# whose minimum OS is above the running one — so both come from the build, not a constant.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 15.0)"
PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ITEM="$(cat <<XML
    <item>
      <title>VoicePlus $VERSION (phase $PHASE)</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:channel>$([ "$PHASE" = "nightly" ] && echo beta || echo release)</sparkle:channel>
      <sparkle:releaseNotesLink>$REPO_URL/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="$DOWNLOAD_URL" length="$SIZE_BYTES" sha256="$SHA" type="application/octet-stream" />
      <!-- unsigned: no sparkle:edSignature (no EdDSA key on this machine) -->
    </item>
XML
)"
if [ ! -f "$APPCAST" ]; then
  cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>VoicePlus</title>
    <link>$REPO_URL</link>
    <description>VoicePlus releases (appcast is UNSIGNED — Sparkle EdDSA key not available)</description>
    <language>en</language>
  </channel>
</rss>
XML
fi
# Insert newest item right after <language>.
python3 - "$APPCAST" "$ITEM" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
s = open(path).read()
marker = "<language>en</language>\n"
assert marker in s, "appcast marker missing"
s = s.replace(marker, marker + item + "\n", 1)
open(path, "w").write(s)
PY
log "appcast updated: $APPCAST"

# --- 5. Homebrew cask -----------------------------------------------------------
mkdir -p "$PKG_DIR/homebrew"
cat > "$PKG_DIR/homebrew/voiceplus.rb" <<RB
cask "voiceplus" do
  version "$VERSION"
  sha256 "$SHA"

  url "$DOWNLOAD_URL"
  name "VoicePlus"
  desc "Local-first voice dictation for macOS"
  homepage "$REPO_URL"

  depends_on macos: ">= :sonoma"

  app "VoicePlus.app"

  zap trash: [
    "~/Library/Application Support/VoicePlus",
    "~/Library/Preferences/in.adityakatare.voiceplus.plist",
  ]

  caveats <<~EOS
    VoicePlus is ad-hoc signed (not notarized). On first launch use
    right-click > Open, then grant Microphone and Accessibility access.
  EOS
end
RB
log "cask written: $PKG_DIR/homebrew/voiceplus.rb"

# --- 6. Release notes -----------------------------------------------------------
NOTES="$PKG_DIR/notes/phase-${PHASE}.md"
if [ ! -f "$NOTES" ]; then
  sed -e "s/__PHASE__/$PHASE/g" -e "s/__VERSION__/$VERSION/g" "$PKG_DIR/notes/TEMPLATE.md" > "$NOTES"
  log "created notes template: $NOTES (edit before the real release)"
fi

# --- 7. Tag + GitHub release ----------------------------------------------------
if [ "$NO_GITHUB" = "1" ]; then
  log "--no-github: skipping tag '$TAG' and GitHub release"
else
  cd "$ROOT"
  git tag -a "$TAG" -m "VoicePlus $VERSION (phase $PHASE)"
  git push origin "$TAG"
  PRE=""; [ "$PHASE" = "nightly" ] && PRE="--prerelease"
  gh release create "$TAG" "$DMG" "$APPCAST" \
    --title "VoicePlus $VERSION (phase $PHASE)" --notes-file "$NOTES" $PRE
  log "GitHub release created: $TAG"
fi

log "done: $DMG"
