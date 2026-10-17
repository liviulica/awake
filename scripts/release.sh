#!/bin/bash
# Build, sign, notarize and publish a release of Ember from the owner's Mac
# (spec 2026-10-17 "Releasing").
#
# Usage: scripts/release.sh X.Y.Z [--dry-run] [--yes]
#
#   1. Checks: X.Y.Z is what Resources/Info.plist says, with the build number
#      X*1000000 + Y*1000 + Z (Sparkle compares that number); a clean tree on
#      main (any branch with --dry-run); no tag vX.Y.Z yet; the Developer ID
#      identity, the notarytool profile and Sparkle's sign_update are there.
#   2. scripts/build-app.sh --sign <identity>: hardened runtime, timestamp.
#   3. Verifies the signature (deep, strict), the hardened runtime of the app
#      and the helper, and that the lid simulation is not compiled in.
#   4. Notarizes the app and staples it.
#   5. Ember-X.Y.Z.dmg (the app and an Applications link), signed, notarized,
#      stapled, checked with spctl.
#   6. Signs the DMG for Sparkle (EdDSA key "ember" in the login keychain)
#      and writes appcast.xml: one item, pointing at the DMG on the GitHub
#      release.
#   7. Unless --dry-run: asks (or --yes), then `gh release create vX.Y.Z`
#      with the DMG, the same DMG as Ember.dmg (so
#      github.com/liviulica/ember/releases/latest/download/Ember.dmg and
#      chargingpixels.com/ember/download always give the newest), and
#      appcast.xml. The feed address in Info.plist,
#      chargingpixels.com/ember/appcast.xml, redirects to the latest
#      release's appcast.xml.
#
# Everything is written to dist/X.Y.Z/ in the checkout (ignored by git).
set -euo pipefail

# Fixed tool paths, never taken from PATH. ReleaseScriptTests patches these
# lines in a private copy.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_APP="$ROOT/scripts/build-app.sh"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
CODESIGN=/usr/bin/codesign
XCRUN=/usr/bin/xcrun
HDIUTIL=/usr/bin/hdiutil
DITTO=/usr/bin/ditto
SPCTL=/usr/sbin/spctl
PLUTIL=/usr/bin/plutil
SECURITY=/usr/bin/security
STRINGS=/usr/bin/strings
GIT=/usr/bin/git
GH=/opt/homebrew/bin/gh
DATE=/bin/date
RM=/bin/rm
CP=/bin/cp
MKDIR=/bin/mkdir
LN=/bin/ln
ENV=/usr/bin/env

IDENTITY="Developer ID Application: CHARGING PIXELS S.R.L. (4UA742BB8G)"
NOTARY_PROFILE=ember-notary
SPARKLE_ACCOUNT=ember
REPO=liviulica/ember
MIN_SYSTEM=26.0

usage() { echo "usage: $0 X.Y.Z [--dry-run] [--yes]" >&2; }
VERSION=""
DRY_RUN=0
YES=0
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 2 ;;
    *) [[ -z "$VERSION" ]] || { usage; exit 2; }; VERSION="$1"; shift ;;
  esac
done
[[ -n "$VERSION" ]] || { usage; exit 2; }

step() { printf '\n==> %s\n' "$*"; }
die() { echo "release: $*" >&2; exit 1; }

# The build number Sparkle compares: X*1000000 + Y*1000 + Z, each part below
# 1000.
build_number() { # X.Y.Z
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  echo $(( 10#$major * 1000000 + 10#$minor * 1000 + 10#$patch ))
}

# 1. Checks -------------------------------------------------------------------
step "Checking Ember $VERSION"
[[ "$VERSION" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "'$VERSION' is not X.Y.Z (each part 0 to 999)"
BUILD="$(build_number "$VERSION")"
INFO="$ROOT/Resources/Info.plist"
plist_short="$("$PLUTIL" -extract CFBundleShortVersionString raw -o - "$INFO")"
plist_build="$("$PLUTIL" -extract CFBundleVersion raw -o - "$INFO")"
if [[ "$plist_short" != "$VERSION" || "$plist_build" != "$BUILD" ]]; then
  die "Resources/Info.plist says $plist_short ($plist_build); set CFBundleShortVersionString to $VERSION and CFBundleVersion to $BUILD in a commit first"
fi
cd "$ROOT"
[[ -z "$("$GIT" status --porcelain)" ]] || die "the working tree has changes; commit or stash them first"
branch="$("$GIT" rev-parse --abbrev-ref HEAD)"
if (( ! DRY_RUN )) && [[ "$branch" != main ]]; then
  die "releases are made from main (this is $branch); --dry-run works from any branch"
fi
COMMIT="$("$GIT" rev-parse HEAD)"
if "$GIT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  die "tag v$VERSION already exists"
fi
identities="$("$SECURITY" find-identity -v -p codesigning)"
[[ "$identities" == *"\"$IDENTITY\""* ]] || die "the signing identity '$IDENTITY' is not in the keychain"
[[ -x "$SIGN_UPDATE" ]] || die "Sparkle's sign_update is missing at $SIGN_UPDATE; run 'swift package resolve'"
if (( ! DRY_RUN )); then
  "$GH" auth status >/dev/null 2>&1 || die "gh is not logged in"
fi

OUT="$ROOT/dist/$VERSION"
"$RM" -rf "$OUT"
"$MKDIR" -p "$OUT"
APP="$OUT/Ember.app"
DMG="$OUT/Ember-$VERSION.dmg"

# Submits $1 for notarization and waits. Fails with Apple's log when it is
# not accepted.
notarize() { # file
  local result="" id status attempt
  # Up to three uploads: notarytool gives up on a slow connection
  # (HTTPClientError.deadlineExceeded) without a status to read.
  for attempt in 1 2 3; do
    if result="$("$XCRUN" notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"; then
      break
    fi
    result=""
    echo "notarytool submit failed (attempt $attempt of 3)" >&2
  done
  id="$("$PLUTIL" -extract id raw -o - - <<<"$result" 2>/dev/null || true)"
  status="$("$PLUTIL" -extract status raw -o - - <<<"$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    echo "notarization of $1: ${status:-no status} (submission ${id:-unknown})" >&2
    if [[ -n "$id" ]]; then
      "$XCRUN" notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    exit 1
  fi
  echo "notarized $1 (submission $id)"
}

# 2. Build --------------------------------------------------------------------
step "Building and signing"
"$ENV" -u INSOMNIA_LID_SIMULATION "$BUILD_APP" --output "$OUT" --sign "$IDENTITY"

# 3. Verify -------------------------------------------------------------------
step "Verifying the bundle"
"$CODESIGN" --verify --deep --strict "$APP"
# Output is read whole before it is searched: `grep -q` stops at the first
# match, and under pipefail the writer it leaves behind fails the pipeline.
for code in "$APP" "$APP/Contents/MacOS/EmberHelper"; do
  details="$("$CODESIGN" -dv "$code" 2>&1)"
  [[ "$details" == *"flags="*"runtime"* ]] || die "$code is not signed with the hardened runtime"
done
binary_strings="$("$STRINGS" -a "$APP/Contents/MacOS/Ember")"
if [[ "$binary_strings" == *"Lid simulation build:"* ]]; then
  die "the lid simulation is compiled into this build"
fi

# 4. Notarize the app ---------------------------------------------------------
step "Notarizing the app"
"$DITTO" -c -k --keepParent "$APP" "$OUT/Ember.zip"
notarize "$OUT/Ember.zip"
"$XCRUN" stapler staple "$APP"
"$RM" -f "$OUT/Ember.zip"

# 5. DMG ----------------------------------------------------------------------
step "Making $DMG"
STAGE="$OUT/dmg"
"$MKDIR" -p "$STAGE"
"$DITTO" "$APP" "$STAGE/Ember.app"
"$LN" -s /Applications "$STAGE/Applications"
"$HDIUTIL" create -volname Ember -srcfolder "$STAGE" -ov -format UDZO "$DMG"
"$RM" -rf "$STAGE"
"$CODESIGN" --force --sign "$IDENTITY" --timestamp "$DMG"
notarize "$DMG"
"$XCRUN" stapler staple "$DMG"
"$SPCTL" -a -t open --context context:primary-signature -v "$DMG"

# 6. Appcast ------------------------------------------------------------------
step "Writing appcast.xml"
# sign_update prints the enclosure's two attributes:
#   sparkle:edSignature="..." length="..."
attributes="$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG")"
[[ "$attributes" =~ ^sparkle:edSignature=\"[^\"]+\"\ length=\"[0-9]+\"$ ]] || die "unexpected sign_update output: $attributes"
URL="https://github.com/$REPO/releases/download/v$VERSION/Ember-$VERSION.dmg"
PUB_DATE="$(LC_ALL=C "$DATE" -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Ember</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Ember $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $attributes/>
    </item>
  </channel>
</rss>
XML
echo "wrote $OUT/appcast.xml"

# 7. Publish ------------------------------------------------------------------
if (( DRY_RUN )); then
  step "Dry run: not published"
  echo "$DMG"
  echo "$OUT/appcast.xml"
  exit 0
fi
if (( ! YES )); then
  printf 'Publish Ember %s (%s) to github.com/%s? [y/N] ' "$VERSION" "${COMMIT:0:8}" "$REPO"
  read -r answer || answer=""
  [[ "$answer" == y || "$answer" == Y ]] || { echo "not published; the files stay in $OUT"; exit 1; }
fi
step "Publishing v$VERSION"
"$CP" "$DMG" "$OUT/Ember.dmg"
"$GH" release create "v$VERSION" "$DMG" "$OUT/Ember.dmg" "$OUT/appcast.xml" --repo "$REPO" --target "$COMMIT" --title "Ember $VERSION" --generate-notes
echo "published https://github.com/$REPO/releases/tag/v$VERSION"
