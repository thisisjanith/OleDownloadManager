#!/bin/bash
# Prints the build environment so problems are easy to spot.
set -uo pipefail
echo "macOS:        $(sw_vers -productVersion) ($(uname -m))"
echo "Xcode:        $(xcodebuild -version 2>/dev/null | head -1 || echo 'not found')"
echo "SDK:          $(xcrun --show-sdk-version 2>/dev/null || echo '?')"
echo "Swift:        $(swift --version 2>/dev/null | head -1)"
echo "XcodeGen:     $(xcodegen --version 2>/dev/null || echo 'not installed (only needed to regenerate the project: brew install xcodegen)')"
echo "Node:         $(node --version 2>/dev/null || echo 'not installed (only needed for extension tests)')"
echo "Signing identities:"
security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /'
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
  echo "→ A Developer ID identity is available: release builds can be signed for distribution."
else
  echo "→ No Developer ID identity: release builds are ad-hoc signed and cannot be notarized."
fi
