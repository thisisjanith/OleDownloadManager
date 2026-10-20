#!/bin/bash
# Copies the shared extension sources into the Chrome and Firefox folders so each can be loaded unpacked.
set -euo pipefail
cd "$(dirname "$0")/../BrowserExtensions"
for target in Chrome Firefox; do
  rm -rf "$target/icons"
  cp -R shared/icons "$target/icons"
  cp shared/logic.js shared/background.js shared/popup.html shared/popup.css shared/popup.js "$target/"
done
echo "Synced shared sources into Chrome/ and Firefox/."
