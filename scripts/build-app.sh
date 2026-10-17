#!/bin/bash
# Build Ember and assemble Ember.app. install.sh runs this for source
# installs, the smoke test builds its test bundle with it, and release.sh
# builds releases with it.
#
# Usage: scripts/build-app.sh --output DIR [--sign IDENTITY]
#   Writes DIR/Ember.app, replacing a bundle already at that path. DIR is
#   created if needed. Prints the bundle path last.
#
# Bundle (spec 2026-10-17 "Bundle layout"): MacOS/Ember and MacOS/EmberHelper
# (the privileged helper), Frameworks/Sparkle.framework, the helper's launchd
# plist under Library/LaunchDaemons, and backstop.sh and uninstall.sh sealed
# under Resources. Nested code is signed inside out (Sparkle's XPC services,
# Autoupdate, Updater.app, the framework, the helper), then the app.
#
# Without --sign, or with `--sign -`, the signature is ad-hoc: it identifies
# only this build (its cdhash), as source builds always have. With a
# Developer ID identity every piece also gets the hardened runtime and a
# secure timestamp, and the app gets Resources/Ember.entitlements: what
# notarization needs. A lid simulation build (INSOMNIA_LID_SIMULATION=1)
# is never signed with an identity.
set -euo pipefail

# Fixed tool paths: never taken from PATH. Tests patch these lines in a
# private copy of the script.
SWIFT=/usr/bin/swift
CODESIGN=/usr/bin/codesign
PLUTIL=/usr/bin/plutil
RM=/bin/rm
MKDIR=/bin/mkdir
CP=/bin/cp
CHMOD=/bin/chmod
DITTO=/usr/bin/ditto

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { echo "usage: $0 --output DIR [--sign IDENTITY]" >&2; }
OUTPUT=""
IDENTITY="-"
while (( $# )); do
  case "$1" in
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --sign) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$OUTPUT" ]] || { usage; exit 2; }
if [[ "$IDENTITY" != - && "${INSOMNIA_LID_SIMULATION:-}" == 1 ]]; then
  echo "INSOMNIA_LID_SIMULATION=1 builds are for testing and are never signed with an identity; unset it or drop --sign." >&2
  exit 2
fi
# Resolved now, before the build changes into the checkout: a relative
# --output means relative to the caller's directory, not to the checkout.
"$MKDIR" -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# 1. Build -------------------------------------------------------------------
step "Building (release)"
cd "$ROOT"
# INSOMNIA_LID_SIMULATION=1 compiles the scripts/simulate-lid.sh file trigger
# (LidSimulation.swift) into this release build, for release validation on
# a machine whose lid stays open (install.sh passes it through from its own
# environment). A normal build has no watcher: nothing reads the trigger
# file. Such a build says so in the log at launch, in the status menu and in
# Settings. A release build (phase 2) must never set it.
BUILD_FLAGS=()
if [[ "${INSOMNIA_LID_SIMULATION:-}" == 1 ]]; then
  BUILD_FLAGS+=(-Xswiftc -DINSOMNIA_LID_SIMULATION)
  echo "lid simulation compiled in (INSOMNIA_LID_SIMULATION=1): scripts/simulate-lid.sh will drive the lid actions during sessions"
fi
# ${arr[@]+"${arr[@]}"}: an empty array expands to nothing under set -u on
# the bash 3.2 that ships with macOS.
"$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN_DIR="$("$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)"
BIN="$BIN_DIR/Ember"
HELPER_BIN="$BIN_DIR/EmberHelper"
SPARKLE="$BIN_DIR/Sparkle.framework"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }
[[ -x "$HELPER_BIN" ]] || { echo "helper binary not found at $HELPER_BIN" >&2; exit 1; }
[[ -d "$SPARKLE" ]] || { echo "Sparkle.framework not found at $SPARKLE" >&2; exit 1; }

# 2. Bundle ------------------------------------------------------------------
APP="$OUTPUT/Ember.app"
step "Assembling $APP"
"$RM" -rf "$APP"
"$MKDIR" -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$APP/Contents/Library/LaunchDaemons"
"$CP" "$BIN" "$APP/Contents/MacOS/Ember"
"$CP" "$HELPER_BIN" "$APP/Contents/MacOS/EmberHelper"
# ditto keeps the framework's symbolic links (Versions/Current and the links
# beside it), which the signature covers.
"$DITTO" "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
"$CP" "$ROOT/Resources/app.chargingpixels.ember.helper.plist" "$APP/Contents/Library/LaunchDaemons/app.chargingpixels.ember.helper.plist"
"$CP" "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$CP" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# backstop.sh goes into the bundle before it is signed, so the signature's
# resource seal covers it. The LaunchAgent install.sh writes verifies the
# bundle and only then runs this copy; an edited script fails that check.
"$CP" "$ROOT/scripts/backstop.sh" "$APP/Contents/Resources/backstop.sh"
"$CHMOD" 755 "$APP/Contents/Resources/backstop.sh"
# uninstall.sh too, so a DMG install can be removed without a checkout.
"$CP" "$ROOT/scripts/uninstall.sh" "$APP/Contents/Resources/uninstall.sh"
"$CHMOD" 755 "$APP/Contents/Resources/uninstall.sh"
"$PLUTIL" -lint "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchDaemons/app.chargingpixels.ember.helper.plist" >/dev/null

# 3. Sign --------------------------------------------------------------------
SIGN_FLAGS=()
APP_FLAGS=()
if [[ "$IDENTITY" == - ]]; then
  step "Signing ad-hoc (this build is identified only by its cdhash)"
else
  step "Signing with $IDENTITY (hardened runtime, secure timestamp)"
  SIGN_FLAGS=(-o runtime --timestamp)
  APP_FLAGS=(--entitlements "$ROOT/Resources/Ember.entitlements")
fi
sign() { "$CODESIGN" --force --sign "$IDENTITY" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
# The downloader's own entitlements (network client) are kept.
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign --identifier app.chargingpixels.ember.helper "$APP/Contents/MacOS/EmberHelper"
sign ${APP_FLAGS[@]+"${APP_FLAGS[@]}"} "$APP"
"$CODESIGN" --verify --deep --strict "$APP"
"$CODESIGN" -dvv "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|CDHash)=' || true
echo "$APP"
