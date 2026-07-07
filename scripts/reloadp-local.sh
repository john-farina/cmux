#!/usr/bin/env bash
set -euo pipefail
# why: restricted entitlements need manaflow's provisioning profile; build-only
# because the main cmux may be John's live terminal — /promote installs+relaunches.

cd "$(dirname "$0")/.."
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS' CODE_SIGN_ENTITLEMENTS="" build

APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr | head -n 1 | cut -d' ' -f2-
)"
echo "Release app:"
echo "  ${APP_PATH}"
