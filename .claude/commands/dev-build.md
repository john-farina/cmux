# Dev Build

Build a sandboxed debug cmux with the current changes and open it. Never touches John's real cmux — the tagged DEV app has its own bundle id (`com.cmuxterm.app.debug`), its own socket, its own session file, and its own DerivedData.

## Steps

1. `./scripts/reload.sh --tag john --launch`
   - only ever terminates a previous same-tag DEV app, never the main cmux
   - launch with agent env scrubbed if running from a claude shell (unset `CLAUDE*`/`ANTHROPIC*`/`CMUX_*` around `open`)
2. `CMUX_TAG=john scripts/dev-seed-sessions.sh` — ALWAYS run after launch. Seeds the DEV build with 5 random old claude sessions (`claude --resume`) so it opens populated with agents. The script excludes any session live elsewhere or active in the real build, and never passes `--name` — cmux's own titles/auto-naming name the tabs (never hand-name seeded workspaces).
3. Print the cmd-clickable app link from the `App path:` line (file:// URL, spaces as `%20`)
4. For CLI/socket testing against this build: `CMUX_TAG=john scripts/cmux-debug-cli.sh <cmd>` — never `/tmp/cmux-cli` (can point at the main app's socket)

## Notes

- Iterate freely: edit → `/dev-build` → poke at the DEV app. The real terminal, its sessions, and running agents are untouched.
- When the feature feels right, `/promote` moves it to the real app.
