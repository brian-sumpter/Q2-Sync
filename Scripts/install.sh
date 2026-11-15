#!/bin/zsh
#
#  install.sh
#  Q2-Sync › Scripts
#
#  PURPOSE
#  Builds the Release version of Q2 Sync and installs it as
#  "/Applications/Q2 Sync.app", replacing any older copy there.
#  Run it again after pulling or making changes to update the app.
#
#  USAGE (from the repository root)
#      Scripts/install.sh
#
#  WHAT IT DOES
#  1. Quits Q2 Sync if it's running (so the old copy can be replaced).
#  2. Builds the Release configuration into build/Release-DerivedData.
#  3. Replaces /Applications/Q2 Sync.app with the new build.
#  It touches nothing else: no settings, no Music library, no card.
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Q2 Sync.app"
BUNDLE_ID="io.github.q2sync.Q2Sync"
DERIVED="build/Release-DerivedData"
BUILT_APP="$DERIVED/Build/Products/Release/$APP_NAME"
INSTALLED_APP="/Applications/$APP_NAME"

echo "→ Quitting Q2 Sync if it's running…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
sleep 1

echo "→ Building the Release version (this takes a minute)…"
xcodebuild -project Q2-Sync.xcodeproj -scheme Q2-Sync -configuration Release \
  -derivedDataPath "$DERIVED" build -quiet

[[ -d "$BUILT_APP" ]] || { echo "Build output not found at $BUILT_APP"; exit 1; }

echo "→ Installing to $INSTALLED_APP…"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "✓ Installed. Open Q2 Sync from Applications or Spotlight."
