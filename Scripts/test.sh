#!/bin/bash
# Runs the automated tests.
#   Scripts/test.sh        unit + integration tests (Swift package) and extension tests (Node)
#   Scripts/test.sh --ui   also runs the XCUITest suite (needs macOS UI-automation approval, see TESTING.md)
set -euo pipefail
cd "$(dirname "$0")/.."
echo "== Swift package tests =="
swift test
if command -v node >/dev/null 2>&1; then
  echo "== Browser extension tests =="
  node --test BrowserExtensions/tests
else
  echo "Node is not installed: skipping extension tests."
fi
if [[ "${1:-}" == "--ui" ]]; then
  echo "== UI tests =="
  command -v xcodegen >/dev/null 2>&1 && xcodegen generate --quiet
  xcodebuild -project OleDownloadManager.xcodeproj -scheme OleDownloadManager -derivedDataPath build/DerivedData test
fi
