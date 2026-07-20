# cmux agent notes

## Initial setup

Run the setup script to initialize submodules, build GhosttyKit, and install the pbxproj normalization pre-commit hook:

```bash
./scripts/setup.sh
```

## Local dev

After making code changes, always run the reload script with a tag to build the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

By default, `reload.sh` builds but does **not** launch the app. The script prints the `.app` path so the user can cmd-click to open it. After a successful build, it always terminates any running app with the same tag (so cmd-clicking launches the freshly-built binary instead of foregrounding the stale instance). Pass `--launch` to open the app automatically after the build:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions --launch
```

`reload.sh` prints an `App path:` line with the absolute path to the built `.app`. Use that path to build a cmd-clickable `file://` URL. Steps:

1. Grab the path from the `App path:` line in `reload.sh` output.
2. Prepend `file://` and URL-encode spaces as `%20`. Do not hardcode any part of the path.
3. Format it as a markdown link using the template for your agent type.

Example. If `reload.sh` output contains:

```text
App path:
  /Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux DEV my-tag.app
```

**Claude Code** outputs:

```markdown
-------------------------------------------------------
[cmux DEV my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app)
-------------------------------------------------------
```

**Codex** outputs:

```markdown
-------------------------------------------------------
[my-tag: file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app](file:///Users/someone/Library/Developer/Xcode/DerivedData/cmux-my-tag/Build/Products/Debug/cmux%20DEV%20my-tag.app)
-------------------------------------------------------
```

Never use `/tmp/cmux-<tag>/...` app links in chat output.

For CLI or socket dogfood against a tagged Debug app, use the tag-bound helper and set `CMUX_TAG`.
Do not use `/tmp/cmux-cli` for tagged dogfood, since that symlink points at the most recently reloaded build and can target the user's main app socket.

```bash
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh list-workspaces
CMUX_TAG=<tag> scripts/cmux-debug-cli.sh send --workspace workspace:1 --surface surface:1 "echo ok"
```

The helper refuses to run without `CMUX_TAG`, targets `/tmp/cmux-debug-<tag>.sock`, and uses the matching tagged CLI from `~/Library/Developer/Xcode/DerivedData/cmux-<tag>/...`. It also scrubs ambient cmux terminal context (`CMUX_SOCKET`, `CMUX_SOCKET_PASSWORD`, workspace/surface/tab/panel IDs, cmuxd socket, and debug log), then sets `CMUX_SOCKET_PATH`, `CMUX_BUNDLE_ID`, and `CMUX_BUNDLED_CLI_PATH` for the selected tag.

After making code changes, always use `reload.sh --tag` to build. **Never run bare `xcodebuild` or `open` an untagged `cmux DEV.app`.** Untagged builds share the default debug socket and bundle ID with other agents, causing conflicts and stealing focus.

```bash
./scripts/reload.sh --tag <your-branch-slug>
```

If you only need to verify the build compiles (no launch), use a tagged derivedDataPath:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<your-tag> build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

When rebuilding cmuxd for release/bundling, always use ReleaseFast:

```bash
cd cmuxd && zig build -Doptimize=ReleaseFast
```

`reload` = build the Debug app (tag required) and terminate any running app with the same tag. Pass `--launch` to also open the freshly-built app:

```bash
./scripts/reload.sh --tag <tag>
./scripts/reload.sh --tag <tag> --launch
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reloads` = kill and launch the Release app as "cmux STAGING" (isolated from production cmux):

```bash
./scripts/reloads.sh
```

`reload2` = reload both Debug and Release (tag required for Debug reload):

```bash
./scripts/reload2.sh --tag <tag>
```

For parallel/isolated builds (e.g., testing a feature alongside the main app), use `--tag` with a short descriptive name:

```bash
./scripts/reload.sh --tag fix-blur-effect
```

This creates an isolated app with its own name, bundle ID, socket, and derived data path so it runs side-by-side with the main app. Important: use a non-`/tmp` derived data path if you need xcframework resolution (the script handles this automatically).

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

For iOS dev auth, `ios/scripts/reload.sh` and `scripts/mobile-dev-launch.sh` auto-sign-in from `~/.secrets/cmuxterm-dev.env`. If the phone lands on the login screen or the helper reports missing dev sign-in credentials, do not ask the user to manually authenticate every build. Tell them to run `scripts/setup-team-dev.sh` once from any cmux checkout; it prompts for and verifies their Stack login, writes `~/.secrets/cmuxterm-dev.env` with chmod 600, and future agents can auto-auth iOS DEBUG reloads. Manual fallback: create that file with `CMUX_DOGFOOD_STACK_EMAIL=...` and `CMUX_DOGFOOD_STACK_PASSWORD=...`.

## Regression test commit policy

When adding a regression test for a bug fix, use a two-commit structure so CI proves the test catches the bug:

1. **Commit 1:** Add the failing test only (no fix). CI should go red.
2. **Commit 2:** Add the fix. CI should go green.

This makes it visible in the GitHub PR UI (Commits tab, check statuses) that the test genuinely fails without the fix.

## First pass, then dogfood

A task's first pass ends when the change is implemented, the tagged build succeeded on the pushed HEAD, focused tests ran, and the PR is open (for `web/` PRs, also the live Vercel preview URL given to the user). Then hand off to the user for dogfood. Do not fix CI failures, merge conflicts, or review findings inline in the main conversation after that point.

At handoff, launch one background `$autoreview` subagent with a bounded prompt (PR URL, worktree, base ref, allowed write scope, required verification), never a vague "make it green". That loop owns CI: it runs structured review plus PR feedback, and only when a check actually fails does it spawn a bounded repair subagent with that check's name and log context. Do not launch a separate parallel CI repair agent; two agents mutating one worktree race each other. One writer per worktree: if dogfood feedback needs main-agent edits while the loop runs, stop the loop first or give it its own sibling worktree. In Claude Code spawn the loop with the agent/task tool; in Codex use a background sub-task or bounded background `codex exec`.

The loop may commit and push scoped fixes but never merges and never rebuilds the user's tagged build. The main agent inspects every pushed commit, rejects out-of-scope edits, and owns dogfood, approval, and merge. Merging app/runtime/UI changes still requires the user's explicit approval after dogfood; if a pushed fix changes runtime behavior mid-dogfood, rebuild the tag and re-notify, since the earlier verdict covers only the build the user tested.

Notify through `cmux notify` so the user can leave and return. At handoff the main agent sends `cmux notify --title "Dogfood ready: <short task>" --subtitle "<branch> · <tag>" --body "Was: <prior bad behavior>. Now: <expected behavior>. <concrete check>. CI + review in background. PR: <pr-url>"`. The loop sends its outcome when done or blocked, e.g. `--title "CI green: <branch>"`, `--title "Review clean: <branch>" --body "fixed <n> findings, pushed"`, or `--title "CI blocked: <branch>" --body "<check>: <one-line cause>, needs your decision"`. Titles carry the outcome and branch; bodies say what happened and the single next action. If there is no cmux socket, skip notify and rely on the chat handoff.

## Shared behavior policy

- When a behavior is exposed through multiple entrypoints (keyboard shortcut, command palette, context menu, CLI, settings, debug menu), implement one shared action/model path and verify every entrypoint that should invoke it. Do not patch one surface while leaving the others with duplicated logic.
- For optimistic UI or CLI updates, keep one mutation path, record pending state with a request id or previous snapshot, reconcile from the authoritative result, and handle failure with an explicit rollback or error state. Do not let each entrypoint maintain its own optimistic copy.
- When a user says tests missed a bug, add or adjust behavior-level coverage around the exact repro path before claiming the fix is complete.

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.cmux.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Typing-latency-sensitive paths** (read carefully before touching these areas):
  - `WindowTerminalHostView.hitTest()` in `TerminalWindowPortal.swift`: called on every event including keyboard. All divider/sidebar/drag routing is gated to pointer events only. Do not add work outside the `isPointerEvent` guard.
  - `TabItemView` in `ContentView.swift`: uses `Equatable` conformance + `.equatable()` to skip body re-evaluation during typing. Do not add `@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties without updating the `==` function. Do not remove `.equatable()` from the ForEach call site. Do not read `tabManager` or `notificationStore` in the body; use the precomputed `let` parameters instead.
  - `TerminalSurface.forceRefresh()` in `GhosttyTerminalView.swift`: called on every keystroke. Do not add allocations, file I/O, or formatting here.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`.
- **All user-facing strings must be localized.** Use `String(localized: "key.name", defaultValue: "English text")` for every string shown in the UI (labels, buttons, menus, dialogs, tooltips, error messages). Keys go in `Resources/Localizable.xcstrings` with translations for all supported languages (currently English and Japanese). Never use bare string literals in SwiftUI `Text()`, `Button()`, alert titles, etc.
- **Localization audit is required for every user-facing change.** Before finishing a task that changes UI, Settings rows, menus, shortcut metadata, schema/config text, docs, command/help text, alerts, or tooltips, enumerate the changed user-facing surfaces and verify each one has entries for every supported locale. `defaultValue`, English fallback text, schema descriptions, or copied English strings do not count as localization. For Swift/AppKit strings, update `Resources/Localizable.xcstrings`; for localized web/docs content, update every supported message catalog (currently `web/messages/en.json` and `web/messages/ja.json`) and any localized data structures that carry inline translations. Parse touched localization files, compare changed message keys across locales, and use `rg` over changed Swift/TS/TSX/docs files for newly introduced bare English. The final handoff must state what localization audit was performed or explicitly say what could not be verified.
- **Shortcut policy:** Every new cmux-owned keyboard shortcut must be added to `KeyboardShortcutSettings`, visible/editable in Settings, supported in `~/.config/cmux/cmux.json`, and documented in the keyboard shortcut and configuration docs.
- **Snapshot boundary for list subtrees.** In any SwiftUI panel whose `body` contains a `LazyVStack` / `LazyHStack` / `List` / `ForEach` of rows, no view below that boundary may hold a reference to an `ObservableObject` / `@Observable` store (no `@ObservedObject`, `@EnvironmentObject`, `@StateObject`, `@Bindable`, or even a plain `let store: SomeStore` property). Rows and drop-gaps receive immutable value snapshots plus closure action bundles only. Violating this reintroduces the "orthogonal @Published change invalidates every row and thrashes `LazyLayoutViewCache`" class of 100% CPU spin loop that hit the Sessions panel and the workspace sidebar (https://github.com/manaflow-ai/cmux/issues/2586). Reference pattern: `IndexSectionActions` / `SectionGapActions` / `SessionSearchFn` in `Sources/SessionIndexView.swift`.
- **No state mutation inside view-body computations.** A function called from `body` (directly or through a helper) must not write `@Published` state, schedule a `Task { @MainActor in store.x = … }`, or `DispatchQueue.main.async` a store write. That creates a re-render feedback loop and pegs the main thread (same root-cause family as the snapshot-boundary rule). State-changing work triggered by "new data appeared" belongs in a `reload()` completion, a `didSet`, or a property-observer — never in the projection that feeds `ForEach`.
- **Foundation, SwiftUI, AttributeGraph, and WebKit semantics change silently between macOS major versions.** A function that "obviously" returns the same value on every macOS is not a reliable assumption. Concrete case from https://github.com/manaflow-ai/cmux/issues/4529: `URL(fileURLWithPath: "/").deletingLastPathComponent().path` returns `"/.."` on macOS 14 and 15 but `"/"` on macOS 26 — Apple silently fixed the underlying CFURL normalization. The repo's `macos-26` CI and every maintainer's dev machine were on the fixed-behavior side; every reporter on the issue was on the broken side. Always test on the reporter's macOS before declaring a user-reported repro disproven. AWS M4 Pro builders (`cmux-aws-mac`, `cmux-aws-m4pro`, `aws-m4pro-1..6`) are pre-provisioned on macOS 15.7.4 and the preferred empirical-repro path; see the `regression-hunt` skill in the cmuxterm-hq sibling repo for the full playbook.
- **Test files in `cmuxTests/` must be wired into `cmux.xcodeproj/project.pbxproj`.** A `.swift` file added to the worktree without a matching `PBXFileReference` + `PBXSourcesBuildPhase` entry is silently ignored by Xcode and never compiles or runs on CI. Both `xcodebuild test -only-testing:cmuxTests/<TestClass>` and bot reviews pass with "Executed 0 tests" — so the missing wiring is indistinguishable from a clean two-commit red/green regression test until a real user hits the bug. The `workflow-guard-tests` job runs `./scripts/lint-pbxproj-test-wiring.sh` to catch this at PR time; surfaced during the https://github.com/manaflow-ai/cmux/issues/4529 investigation against https://github.com/manaflow-ai/cmux/pull/4536. Add via Xcode (drag the file into the cmuxTests target) or hand-edit the four pbxproj entries; reference any wired sibling like `TabManagerUnitTests.swift` as a template.
- **SPM packages live in group folders, and the root workspace mirrors that folder shape exactly.** Every Swift package lives physically under exactly one group directory — `Packages/Shared/<pkg>` (used by both apps), `Packages/iOS/<pkg>` (iOS app only), or `Packages/macOS/<pkg>` (macOS app only) — and `cmux.xcworkspace/contents.xcworkspacedata` has three groups whose container locations are those folders, with every package directory appearing as a FileRef under its folder's group. So opening the workspace shows all packages grouped exactly like the directory tree. The folder is the source of truth: to move a package between groups, `git mv` its directory, then run `python3 scripts/check-workspace-package-groups.py --write` to regenerate the workspace. A new package goes in the group folder matching its consumers (both apps → Shared, iOS only → iOS, macOS only → macOS). Cross-group `.package(path:)` deps use `../../<Group>/<Name>`; never hand-edit the workspace group membership. CI's `python3 scripts/check-workspace-package-groups.py --check` fails on drift.
- **Do not ignore cmux-owned `Package.resolved` files.** SwiftPM resolution changes must be visible in PR diffs. Track the root Xcode lockfile and every cmux-owned package-local `Package.resolved` generated by standalone `swift package resolve`, `swift build`, or `swift test`; a package-local lockfile is the source of truth for that package's standalone resolution and is not replaced by `cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Vendored third-party directories may preserve their upstream ignore policy, but cmux-owned package `.gitignore` files must not ignore `Package.resolved`. CI's `python3 scripts/check-package-resolved-policy.py` fails if this drifts.

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = upstream, manaflow = fork
git checkout -b <branch>
git add <files>
git commit -m "..."
git push manaflow <branch>
```

To keep the fork up to date with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Use the `/release` command to prepare a new release. This will:
1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the docs changelog page at `web/app/docs/changelog/page.tsx` reads from it)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, run `./scripts/release-pretag-guard.sh`, tag, and push

Version bumping:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). The build number is auto-incremented and is required for Sparkle auto-update to work.

Before creating a release tag, run:

```bash
./scripts/release-pretag-guard.sh
```

If it fails, run `./scripts/bump-version.sh`, commit the build-number bump, then retry tagging.

Manual release steps (if not using the command):

```bash
./scripts/release-pretag-guard.sh
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/cmux
```

Notes:
- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `cmux-macos.dmg` attached to the tag.
- README download button points to `releases/latest/download/cmux-macos.dmg`.
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
- Changelog: update `CHANGELOG.md`; docs changelog is rendered from it.

## Skills

Detailed cmux contributor rules live in repo skills under `skills/`; use the task-specific skill before changing that area.

Core skill map:

- `cmux-dev-workflow`: setup, tagged reloads, Xcode project normalization, sidebar extension tagging, local dev build isolation.
- `cmux-architecture`: package boundaries, refactor architecture, file/API discipline, testability, Swift concurrency rules.
- `cmux-backend`: backend TypeScript, Effect, Cloud VM control plane, provider secrets, Postgres and migrations.
- `cmux-billing`: Stripe checkout, entitlements, webhooks, pricing dev stack, live provisioning.
- `cmux-debugging`: debug event log, Debug menu, runtime pitfalls, typing-sensitive paths, SwiftUI list boundaries.
- `cmux-localization`: user-facing strings, localization files, shortcut text, and localization audit.
- `cmux-testing`: regression policy, Swift Testing, test quality, test wiring, local vs CI validation.
- `cmux-socket-policy`: socket command threading and focus preservation.
- `cmux-shared-behavior`: shared action paths for multi-entrypoint behavior and optimistic updates.
- `cmux-ghostty`: Ghostty submodule and GhosttyKit workflow.
- `cmux-release`: release, version bump, changelog, pretag guard, and release asset workflow.

## Fork notes (john-farina/cmux)

This is John's fork. `origin` = john-farina/cmux (push here), `upstream` = manaflow-ai/cmux (pull only, never push).

### Git + repo basics

- **Plain git, no Graphite** — commit/push with git directly, to `origin` only.
- **Commit-when-done rule**: every finished unit of work — feature, fix, config/docs change — gets its own clean commit pushed to `origin/main` immediately. One concern per commit, imperative subject describing WHAT changed (the fork's git log is the changelog). Don't batch unrelated changes; don't leave finished work uncommitted. Verified work only — build/test first (a DEV build for app code).
- **Sync with upstream: `/sync-upstream`**. Upstream's `/pull` and `/sync-branch` assume `origin` = manaflow — don't use them here.
- **CodeGraph is indexed** (`.codegraph/`, git-excluded locally). Prefer `codegraph_*` MCP tools over grep/glob for symbol lookup, callers/callees, exploration. Watcher lags edits ~500ms.
- `.claude/settings.json` (fork-added) denies reads of node_modules/dist/xcframework/zig caches. `git add -f` for anything under `.claude/` — John's global gitignore ignores that dir.
- Team dogfood / Stack auto-sign-in (`scripts/setup-team-dev.sh`) is manaflow-internal — skip it.

### Build + ship flow

- **`/dev-build`** (or `./scripts/reload.sh --tag john --launch`): sandboxed DEBUG app — own bundle id (`com.cmuxterm.app.debug`), socket, session file, DerivedData. Never touches the real cmux. All feature dev and testing happens here. After launch it ALWAYS runs `scripts/dev-seed-sessions.sh` (5 random old claude sessions as `--resume` tabs, incl. one multi-tab workspace; never picks sessions live elsewhere or active in the real build; never `--name` — cmux titles/auto-naming own tab names).
- DEV builds are signed with a stable Apple Development identity (auto-detected; override `CMUX_DEV_CODESIGN_IDENTITY`) so macOS TCC permission grants persist across rebuilds — ad-hoc fallback if no cert. Rebuilding a tag TERMINATES the running same-tag app: warn John before rebuilding mid-dogfood.
- **`/promote`** (runs `./scripts/reloadp-local.sh`): Release build → archive current app to `~/.cmux-backups/apps/` (last 10) → install to `/Applications/cmux.app` → **graceful** quit + relaunch. Built-in session restore + agent auto-resume make the restart near-lossless. The script refuses to force-kill; `--no-install` for build-only.
- **`/revert-app`** (runs `./scripts/revert-local.sh`): one-command rollback of the promoted app — restores an archive (newest by default, `--list` to browse), stashes the current app as `<ts>-pre-revert` first, same graceful-quit rules.

### Fork features (docs to keep in sync when touching them)

- **Toolbelt menu**: native "Toolbelt" menu-bar menu (repositioned right of File via AppDelegate.installToolbeltMenuRepositioner) surfacing fork features — import external claude sessions, manual auto-name workspace, and one item per agent launch template. `Sources/cmuxApp+ForkMenu.swift` (CommandMenu + window-targeted notifications), observers in `Sources/ContentView.swift`, template entries via `CmuxConfigStore.agentTemplateMenuEntries()` + `AppDelegate.agentTemplateMenuEntriesForCommands`. Menu items reuse the palette/context-menu localization keys; new key `menu.fork.title` only.

- **iPhone companion (mobile pairing)**: READ `docs/fork-mobile-companion.md` BEFORE touching anything mobile — architecture, auth (`--prod-auth`), pairing, tailscale-only transport, build/debug workflow (`scripts/ios-phone-build.sh`, `scripts/ios-pull-logs.sh`), plus §8 current state/open items and gotchas already hit. Toolbelt has Connect iPhone/iPad + Sign In/Out (titlebar iPhone button is posthog-flag-gated, hidden on fork builds).
- **Companion parity rule**: every fork feature plan must classify its mobile impact per `docs/fork-feature-companion-parity.md` (tier 0 invisible / 1 mirrored state / 2 new phone display / 3 phone-triggered) and carry a "mobile companion impact" section in its design doc. Core primitives stay single well-named functions so tier 3 is a thin RPC wrapper later.
- **Agent launch templates**: `templates` key in `cmux.json` → palette "New Agent: <name>", explicit-invoke only. Decode + synthesis in `Sources/CmuxConfig.swift` (`CmuxAgentTemplate`); docs `docs/configuration.md#templates`, schema `web/data/cmux.schema.json`; tests in `CmuxConfigTests`.
- **Saved projects**: `projects` key in `cmux.json` (name + path + optional template ref) → palette "Project: <name>", Toolbelt submenu (open in new workspace / open tab in current), sidebar right-click "Save as Project" (writes global cmux.json via `JSONConfigStore`, name from workspace title, path from focused terminal cwd; same-path save renames). Decode + synthesis `Sources/CmuxConfig.swift` (`CmuxProject`), save helper + SettingCodable in `Sources/cmuxApp+ForkMenu.swift`; docs `docs/configuration.md#projects`, schema, `CmuxConfigTests`. Mobile impact: tier 1 (opened workspaces mirror via existing sync); "open project from phone" is a future tier 3 thin RPC over the same open path. Log lines `project.save.*` / `projects.loaded` under the `agentTemplates` CmuxLog category.
- **External claude session import**: palette "Import Claude Sessions from Other Terminals…" — scans `~/.claude/sessions/<pid>.json` sidecars, resumes into new tabs, ask-then-SIGTERM originals. `Sources/ClaudeExternalSessionScanner.swift` + `Sources/ContentView+ExternalSessionImport.swift`; tests `ClaudeExternalSessionScannerTests`. Log category `external-import`.
- **Auto-naming**: fork default ON (`AutomationCatalogSection.workspaceAutoNaming`); manual renames always win. Right-click "Auto-Name Workspace" = explicit re-apply (bypasses gates, may replace user titles): per-tab passes then all-tabs workspace synthesis, "Naming…"/failure pill on the row. Manual pipeline in `CLI/CMUXCLI+AutoNamingHooks.swift` (`runManualWorkspaceAutoName`), apply handler `TerminalController.v2WorkspaceSetAutoTitle` (`manual`/`panel_only` params); docs `docs/workspace-auto-naming.md`. Gotcha: claude ≥ 2.1.x requires `--mcp-config '{"mcpServers":{}}'` — bare `{}` breaks all summarizer passes. Log category `agent-resume` (`auto-name.*` lines).
- **Release signing**: upstream `reloadp.sh` needs manaflow's Apple team (7WLXT3NR37) for restricted entitlements; `reloadp-local.sh` drops `CODE_SIGN_ENTITLEMENTS` and ad-hoc signs. Cost: passkeys-in-browser + shared keychain don't work in fork release builds. It also pre-strips Finder xattrs (launching from DerivedData leaves detritus that fails codesign).
- **Env hygiene**: `open` propagates the caller's env. Launching the real cmux from a claude/agent shell leaks `CLAUDECODE`/`CLAUDE_CODE_SESSION_ID`/etc into every pane — resumed claudes then think they're nested child sessions, show spurious allow/deny prompts, and exit (blank pane). `reloadp-local.sh` scrubs `CLAUDE*`/`ANTHROPIC*`/stray `CMUX_*`; any other launch path must too (or launch from Dock/Spotlight).

### Never wreck John's live session

cmux may BE the terminal John is working in. Never kill, restart, or steal focus from his main cmux (or ghostty).

- Dev/testing only via the tagged DEV app; `reload.sh` only terminates the same-tag app.
- CLI/socket dogfood: `CMUX_TAG=john scripts/cmux-debug-cli.sh ...`, never `/tmp/cmux-cli` (can point at the main app's socket).
- Research a non-disruptive, isolated test path FIRST (temp dirs, stubs, separate instance, background launch). Screenshots via `screencapture -l<CGWindowID>`, no focus steal. If touching live state is unavoidable, say so and get an OK first; verify state unchanged after.
- Restarting the real app: graceful quit only (SIGTERM/osascript) so the final ~8s-cadence session autosave lands.

### Logging discipline (applies to ALL new features and touched code)

Claudes debug this app after the fact from John's issue reports. Every feature must leave a readable trail.

- **Release-safe logging via `CmuxLog`** (`Sources/App/DebugLogging.swift`): `os.Logger`, subsystem `com.cmuxterm.app`, one kebab-case category per feature area. Existing categories + probe locations: `session-persistence` (SessionPersistence.swift restore policy, AppDelegate.swift snapshot save/load/restore driver), `agent-resume` (Workspace.swift resume/hibernation decisions).
- **When adding or meaningfully touching a code path, add probes at**: state transitions, decisions (log the decision AND the reason, especially skip/early-return reasons), and failure branches. One line, `key=value` style: `logger.log("restore.window workspaces=\(n, privacy: .public)")`.
- **Levels**: `.log` lifecycle/decisions (persisted), `.error`/`.fault` failures, `.debug` high-frequency ticks (memory-only — the ~8s autosave success is `.debug` for this reason).
- **Never log**: scrollback contents, env values, full commands (may embed tokens). Command PRESENCE, agent kind, panel/session UUIDs are fine. Mark interpolations `privacy: .public` (personal local build).
- **DEBUG-only probes** still use `cmuxDebugLog` (upstream convention, `#if DEBUG`); temporary probes get removed before commit — `CmuxLog` probes are permanent.

**Reading logs when John reports an issue** (do this FIRST, before theorizing):
```bash
# /usr/bin/log, not bare `log` — zsh has a `log` builtin that shadows it
/usr/bin/log show --last 2h --predicate 'subsystem == "com.cmuxterm.app"'
/usr/bin/log show --last 1d --predicate 'subsystem == "com.cmuxterm.app" AND category == "agent-resume"'
```
Also useful: `~/.cmuxterm/events.jsonl` (agent hook events: SessionStart/Stop per session id — tells you whether a resumed claude actually attached). Debug builds additionally: `tail -f "$(cat /tmp/cmux-last-debug-log-path 2>/dev/null || echo /tmp/cmux-debug.log)"` and the `cmux-debugging` skill.

### Ghostty submodule (knowledge from ~/Developer/ghostty clone)

- **Zig version trap**: ghostty requires zig 0.15.x and REJECTS brew's 0.16 (`requireZig`; 0.16 changed `readFileAlloc` so build.zig won't parse). Ignore CONTRIBUTING's `brew install zig`. John pins 0.15.2 at `~/.local/bin/zig` → `~/.zig/current` (wins over brew on PATH). Verify `zig version` before any GhosttyKit rebuild; bump by dropping a new tarball in `~/.zig/` and repointing `~/.zig/current`.
- **Where to edit in `ghostty/`**: terminal core/renderer → Zig in `src/`; macOS shell → Swift in `macos/`; C ABI in `include/`. cmux consumes it as GhosttyKit.xcframework — see the `cmux-ghostty` skill.
- John also keeps a standalone ghostty clone at `~/Developer/ghostty` (straight clone, own CLAUDE.local.md / reinstall flow) — reference for upstream ghostty behavior; don't confuse it with the submodule.
