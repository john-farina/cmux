# Promote

Move the current fork changes into John's REAL cmux (`/Applications/cmux.app`) without losing open terminal sessions or running agents. Restart is unavoidable (no live-process checkpointing exists), but cmux's built-in restore makes it lossless-enough: state autosaves every ~8s to `~/Library/Application Support/cmux/session-{bundleId}.json`, and `terminal.autoResumeAgentSessions` (default ON) re-runs `claude --resume <session>` per pane on relaunch.

## Preflight

1. Changes committed? If dirty, ask whether to commit first (promoting uncommitted code makes rollback archaeology painful).
2. Sanity: the feature was verified in a DEV build (`/dev-build`). If not, suggest that first — promote is not the place to discover a crash.
3. Confirm with John before proceeding — this restarts his real terminal.

## Steps

1. `./scripts/reloadp-local.sh` — does everything: build, verify bundle, archive the current app to `~/.cmux-backups/apps/` (last 10 kept), install to /Applications, graceful quit + relaunch if cmux was running. Refuses to force-kill if cmux won't quit. `--no-install` for build-only.
2. Verify: process running from `/Applications`, workspaces restored, agent panes resumed. If the new build fails to launch or restore, roll back immediately (below), then debug in a DEV build.

## Rollback

`/revert-app` (runs `./scripts/revert-local.sh`) — restores the newest archive from `~/.cmux-backups/apps/`, stashing the current app first so the revert is itself revertible. `--list` to pick a specific archive.

## Invariants

- NEVER `pkill -9` / force-quit the real cmux — graceful quit only, so the last autosave wins.
- NEVER promote a build that hasn't launched successfully as a DEV build.
- The DEV app (`com.cmuxterm.app.debug`) and real app have separate session files — promoting can't corrupt DEV state and vice versa.
- `CMUX_DISABLE_SESSION_RESTORE` must not be set in the environment when relaunching.
