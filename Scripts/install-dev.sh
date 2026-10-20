#!/bin/bash
# Installs a build into ~/Applications (default) or /Applications (--system).
# Uses the release build if present, otherwise the debug build.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/Release/OleDownloadManager.app"
[[ -d "$SRC" ]] || SRC="build/DerivedData/Build/Products/Debug/OleDownloadManager.app"
[[ -d "$SRC" ]] || { echo "Build first: Scripts/build.sh" >&2; exit 1; }
DEST="$HOME/Applications"
[[ "${1:-}" == "--system" ]] && DEST="/Applications"
mkdir -p "$DEST"
osascript -e 'tell application id "com.oledownloadmanager.app" to quit' >/dev/null 2>&1 || true
rm -rf "$DEST/OleDownloadManager.app"
ditto "$SRC" "$DEST/OleDownloadManager.app"
echo "Installed $DEST/OleDownloadManager.app"
echo "Next: open it, then Settings › Browser to install the browser host (or Scripts/install-browser-host.sh)."
