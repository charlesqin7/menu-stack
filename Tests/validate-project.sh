#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

for plist in \
  VerticalMenu.plist \
  layout/Library/PreferenceLoader/Preferences/VerticalMenu.plist \
  Prefs/Resources/Info.plist \
  Prefs/Resources/Root.plist; do
  plutil -lint "$plist"
done

CONTROL_VERSION="$(awk '/^Version:/{print $2; exit}' control)"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Prefs/Resources/Info.plist)"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Prefs/Resources/Info.plist)"

test -n "$CONTROL_VERSION"
test "$CONTROL_VERSION" = "$SHORT_VERSION"
test "$CONTROL_VERSION" = "$BUNDLE_VERSION"

echo "Project metadata is valid for version $CONTROL_VERSION"
