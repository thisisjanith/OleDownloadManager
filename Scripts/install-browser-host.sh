#!/bin/bash
# Registers (or removes) the OleDownloadManager native messaging host for Chrome-family browsers and Firefox.
#   Scripts/install-browser-host.sh [--app /path/OleDownloadManager.app] [--uninstall]
# The same can be done from the app: Settings › Browser.
set -euo pipefail
APP="/Applications/OleDownloadManager.app"
[[ -d "$APP" ]] || APP="$HOME/Applications/OleDownloadManager.app"
UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
NAME="com.oledownloadmanager.native"
SUPPORT="$HOME/Library/Application Support"
CHROME_DIRS=("Google/Chrome" "Chromium" "BraveSoftware/Brave-Browser" "Microsoft Edge")
CHROME_ID="adndpcefokbkijmccnbhfkhllcpedgfj"
FIREFOX_ID="oledownloadmanager@oledownloadmanager.app"

if [[ $UNINSTALL -eq 1 ]]; then
  for d in "${CHROME_DIRS[@]}" "Mozilla"; do rm -f "$SUPPORT/$d/NativeMessagingHosts/$NAME.json"; done
  echo "Removed native messaging host manifests."
  exit 0
fi

HOST="$APP/Contents/Helpers/OleNativeHost"
[[ -x "$HOST" ]] || { echo "Host not found at $HOST (use --app to point at the app)." >&2; exit 1; }

for d in "${CHROME_DIRS[@]}"; do
  [[ -d "$SUPPORT/$d" ]] || continue
  mkdir -p "$SUPPORT/$d/NativeMessagingHosts"
  cat > "$SUPPORT/$d/NativeMessagingHosts/$NAME.json" <<JSON
{
  "name": "$NAME",
  "description": "OleDownloadManager browser integration",
  "path": "$HOST",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$CHROME_ID/"]
}
JSON
  echo "Installed for $d"
done
if [[ -d "$SUPPORT/Mozilla" || -d "/Applications/Firefox.app" ]]; then
  mkdir -p "$SUPPORT/Mozilla/NativeMessagingHosts"
  cat > "$SUPPORT/Mozilla/NativeMessagingHosts/$NAME.json" <<JSON
{
  "name": "$NAME",
  "description": "OleDownloadManager browser integration",
  "path": "$HOST",
  "type": "stdio",
  "allowed_extensions": ["$FIREFOX_ID"]
}
JSON
  echo "Installed for Firefox"
fi
