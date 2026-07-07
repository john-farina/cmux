#!/usr/bin/env bash
set -euo pipefail
# ponytail: fork-local release build — drops CODE_SIGN_ENTITLEMENTS because the
# restricted entitlements (passkeys, keychain group) need manaflow's provisioning
# profile. everything else matches upstream reloadp.sh.

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
pkill -x cmux || true
sleep 0.2
env -u GIT_PAGER -u GH_PAGER open -g "$APP_PATH"
