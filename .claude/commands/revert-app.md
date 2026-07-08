# Revert App

Roll `/Applications/cmux.app` back to a previous build when a promoted change goes wrong. Counterpart to `/promote`, which archives the outgoing app to `~/.cmux-backups/apps/` (last 10 kept) before every install.

## Steps

1. `./scripts/revert-local.sh --list` — show available archives (newest first; `*-pre-revert` entries are stashes made by earlier reverts)
2. `./scripts/revert-local.sh` — restore the newest archive (or `./scripts/revert-local.sh <archive-name>` for a specific one)
   - stashes the current (bad) app first, so the revert is itself revertible
   - graceful quit only — if cmux won't quit in 10s it aborts rather than killing live sessions
   - relaunches automatically (env-scrubbed) if cmux was running; session restore + agent auto-resume make it near-lossless

## Notes

- Workflow: `/promote` to ship a change into the real app → dogfood → if broken, `/revert-app` gets back the exact prior binary in ~15s.
- Archives are whole `.app` bundles; config (`~/.config/cmux/cmux.json`) and session state are untouched by revert.
