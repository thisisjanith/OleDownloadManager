#!/bin/bash
# Builds OleDownloadManager.
#   Scripts/build.sh            Debug build  → build/DerivedData/Build/Products/Debug/OleDownloadManager.app
#   Scripts/build.sh release    Release build (universal arm64 + x86_64) → build/Release/OleDownloadManager.app
# Optional: SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" to sign with hardened runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="Debug"
[[ "${1:-}" == "release" ]] && CONFIG="Release"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
fi
xcodebuild -resolvePackageDependencies -project OleDownloadManager.xcodeproj -scheme OleDownloadManager >/dev/null

xcodebuild -project OleDownloadManager.xcodeproj -scheme OleDownloadManager -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData build | (command -v xcpretty >/dev/null && xcpretty || grep -E "error|warning: |\*\* BUILD")

APP="build/DerivedData/Build/Products/$CONFIG/OleDownloadManager.app"
if [[ "$CONFIG" == "Release" ]]; then
  rm -rf build/Release && mkdir -p build/Release
  ditto "$APP" build/Release/OleDownloadManager.app
  APP="build/Release/OleDownloadManager.app"
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "Signing with: $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/OleNativeHost"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  else
    echo "No SIGN_IDENTITY set: re-signing ad hoc with hardened runtime (runs locally, not notarizable)."
    codesign --force --options runtime --sign - "$APP/Contents/Helpers/OleNativeHost"
    codesign --force --options runtime --sign - "$APP"
  fi
  codesign --verify --deep --strict "$APP"
  lipo -archs "$APP/Contents/MacOS/OleDownloadManager"
fi
echo "Built: $APP"
