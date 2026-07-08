#!/usr/bin/env bash
# Usage: scripts/revert-local.sh [--list | <archive-name>]
# why: /promote archives the previous /Applications/cmux.app before installing;
# this restores one of those archives (default: newest) with the same
# graceful-quit rules — never force-kill live sessions.
set -euo pipefail

BACKUP_ROOT="$HOME/.cmux-backups/apps"
INSTALL_PATH="/Applications/cmux.app"

if [[ "${1:-}" == "--list" ]]; then
  ls -dt "$BACKUP_ROOT"/*/ 2>/dev/null | sed "s|$BACKUP_ROOT/||; s|/$||" || echo "(no archives)"
  exit 0
fi

CHOICE="${1:-}"
if [[ -n "$CHOICE" ]]; then
  ARCHIVE="$BACKUP_ROOT/$CHOICE/cmux.app"
else
  NEWEST="$(ls -dt "$BACKUP_ROOT"/*/ 2>/dev/null | head -1 || true)"
  [[ -n "$NEWEST" ]] || { echo "error: no archives in $BACKUP_ROOT" >&2; exit 1; }
  ARCHIVE="${NEWEST%/}/cmux.app"
fi
[[ -x "$ARCHIVE/Contents/MacOS/cmux" ]] || { echo "error: no app at $ARCHIVE" >&2; exit 1; }

# Stash the current install so the revert is itself revertible.
if [[ -d "$INSTALL_PATH" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)-pre-revert"
  mkdir -p "$BACKUP_ROOT/$ts"
  ditto "$INSTALL_PATH" "$BACKUP_ROOT/$ts/cmux.app"
  echo "==> stashed current app to $BACKUP_ROOT/$ts"
  ls -dt "$BACKUP_ROOT"/*/ 2>/dev/null | tail -n +11 | xargs rm -rf
fi

WAS_RUNNING=0
if pgrep -qx cmux; then
  WAS_RUNNING=1
  echo "==> quitting running cmux (graceful; autosave + restore cover the restart)"
  osascript -e 'quit app "cmux"' || true
  for _ in $(seq 1 40); do pgrep -qx cmux || break; sleep 0.25; done
  if pgrep -qx cmux; then
    echo "error: cmux did not quit within 10s; NOT force-killing (live sessions). Revert aborted." >&2
    exit 1
  fi
fi

rm -rf "$INSTALL_PATH"
ditto "$ARCHIVE" "$INSTALL_PATH"
echo "==> reverted $INSTALL_PATH to $(dirname "${ARCHIVE#"$BACKUP_ROOT"/}")"

if [[ "$WAS_RUNNING" == "1" ]]; then
  UNSET_FLAGS=(-u GIT_PAGER -u GH_PAGER)
  while IFS= read -r key; do UNSET_FLAGS+=(-u "$key"); done \
    < <(env | grep -oE '^(CLAUDE[A-Z_]*|CLAUDECODE|ANTHROPIC[A-Z_]*|CMUX_[A-Z_]*)=' | sed 's/=$//')
  env "${UNSET_FLAGS[@]}" open "$INSTALL_PATH"
  echo "==> relaunched; workspaces + agent sessions restore automatically"
fi
