#!/bin/bash
# Creates dist/OleDownloadManager-<version>.dmg from build/Release/OleDownloadManager.app.
# Run Scripts/build.sh release first. If NOTARY_PROFILE is set (a notarytool keychain profile) and the
# app is Developer ID signed, the DMG is notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Release/OleDownloadManager.app"
[[ -d "$APP" ]] || { echo "Missing $APP — run Scripts/build.sh release first." >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/OleDownloadManager.app"
ln -s /Applications "$STAGE/Applications"
DMG="dist/OleDownloadManager-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "OleDownloadManager $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "Not notarized (set SIGN_IDENTITY and NOTARY_PROFILE for a distributable build)."
fi
hdiutil verify "$DMG" >/dev/null && echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
