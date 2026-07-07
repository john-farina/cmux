# Dev Build

Build a sandboxed debug cmux with the current changes and open it. Never touches John's real cmux — the tagged DEV app has its own bundle id (`com.cmuxterm.app.debug`), its own socket, its own session file, and its own DerivedData.

## Steps

1. `./scripts/reload.sh --tag john --launch`
   - only ever terminates a previous same-tag DEV app, never the main cmux
2. Print the cmd-clickable app link from the `App path:` line (file:// URL, spaces as `%20`)
3. For CLI/socket testing against this build: `CMUX_TAG=john scripts/cmux-debug-cli.sh <cmd>` — never `/tmp/cmux-cli` (can point at the main app's socket)

## Notes

- Iterate freely: edit → `/dev-build` → poke at the DEV app. The real terminal, its sessions, and running agents are untouched.
- When the feature feels right, `/promote` moves it to the real app.
