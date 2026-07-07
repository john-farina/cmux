#!/usr/bin/env bash
set -euo pipefail
# why: entitlements dropped (need manaflow's provisioning profile); restart is
# graceful-only so the final session autosave lands — never kill -9 live sessions.

cd "$(dirname "$0")/.."

BACKUP_ROOT="$HOME/.cmux-backups/apps"
INSTALL_PATH="/Applications/cmux.app"

# why: launching from DerivedData leaves Finder xattrs that fail codesign
find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -path "*/Build/Products/Release/cmux.app" -exec xattr -rc {} \; 2>/dev/null || true

xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Release \
  -destination 'platform=macOS' CODE_SIGN_ENTITLEMENTS="" build

APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Release/cmux.app" -print0 \
  | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
  | sort -nr | head -n 1 | cut -d' ' -f2-
)"
[[ -x "$APP_PATH/Contents/MacOS/cmux" ]] || { echo "error: no executable at $APP_PATH" >&2; exit 1; }

if [[ "${1:-}" == "--no-install" ]]; then
  echo "Release app (not installed):"
  echo "  $APP_PATH"
  exit 0
fi

if [[ -d "$INSTALL_PATH" ]]; then
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_ROOT/$ts"
  ditto "$INSTALL_PATH" "$BACKUP_ROOT/$ts/cmux.app"
  echo "==> archived previous app to $BACKUP_ROOT/$ts"
  ls -dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +11 | xargs rm -rf
fi

WAS_RUNNING=0
if pgrep -qx cmux; then
  WAS_RUNNING=1
  echo "==> quitting running cmux (graceful; autosave + restore cover the restart)"
  osascript -e 'quit app "cmux"' || true
  for _ in $(seq 1 40); do pgrep -qx cmux || break; sleep 0.25; done
  if pgrep -qx cmux; then
    echo "error: cmux did not quit within 10s; NOT force-killing (live sessions). Install aborted." >&2
    exit 1
  fi
fi

rm -rf "$INSTALL_PATH"
ditto "$APP_PATH" "$INSTALL_PATH"
echo "==> installed $INSTALL_PATH"

if [[ "$WAS_RUNNING" == "1" || "${1:-}" == "--launch" ]]; then
  env -u GIT_PAGER -u GH_PAGER open "$INSTALL_PATH"
  echo "==> relaunched; workspaces + agent sessions restore automatically"
fi

echo "Rollback: newest archive in $BACKUP_ROOT (quit cmux, ditto it back, reopen)"
