# Promote

Move the current fork changes into John's REAL cmux (`/Applications/cmux.app`) without losing open terminal sessions or running agents. Restart is unavoidable (no live-process checkpointing exists), but cmux's built-in restore makes it lossless-enough: state autosaves every ~8s to `~/Library/Application Support/cmux/session-{bundleId}.json`, and `terminal.autoResumeAgentSessions` (default ON) re-runs `claude --resume <session>` per pane on relaunch.

## Preflight

1. Changes committed? If dirty, ask whether to commit first (promoting uncommitted code makes rollback archaeology painful).
2. Sanity: the feature was verified in a DEV build (`/dev-build`). If not, suggest that first — promote is not the place to discover a crash.
3. Confirm with John before proceeding — this restarts his real terminal.

## Steps

1. Build: `./scripts/reloadp-local.sh` (build-only; prints the Release app path)
2. Verify the bundle: app path exists, `Contents/MacOS/cmux` executable present
3. Archive the current app (rollback net, mirrors the ghostty gc-rollback pattern):
   ```bash
   ts=$(date +%Y%m%d-%H%M%S)
   mkdir -p ~/.cmux-backups/apps/$ts
   [ -d /Applications/cmux.app ] && ditto /Applications/cmux.app ~/.cmux-backups/apps/$ts/cmux.app
   ls -dt ~/.cmux-backups/apps/*/ | tail -n +11 | xargs rm -rf   # keep last 10
   ```
4. Install: `rm -rf /Applications/cmux.app && ditto "<release app path>" /Applications/cmux.app`
5. Restart gracefully (SIGTERM lets the final autosave land; never `kill -9`):
   ```bash
   osascript -e 'quit app "cmux"'; sleep 2
   open /Applications/cmux.app
   ```
6. Verify: process running from `/Applications`, workspaces restored, agent panes resumed. If the new build fails to launch or restore, roll back immediately (below), then debug in a DEV build.

## Rollback

```bash
osascript -e 'quit app "cmux"'; sleep 2
rm -rf /Applications/cmux.app
ditto "$(ls -dt ~/.cmux-backups/apps/*/ | head -1)cmux.app" /Applications/cmux.app
open /Applications/cmux.app
```

## Invariants

- NEVER `pkill -9` / force-quit the real cmux — graceful quit only, so the last autosave wins.
- NEVER promote a build that hasn't launched successfully as a DEV build.
- The DEV app (`com.cmuxterm.app.debug`) and real app have separate session files — promoting can't corrupt DEV state and vice versa.
- `CMUX_DISABLE_SESSION_RESTORE` must not be set in the environment when relaunching.
