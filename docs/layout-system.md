# cmux layout system — split panes, grids, and saved layouts

How cmux arranges terminals (and browsers, agent sessions, etc.) side by side, stacked, or in grids. Covers the data model, every user-facing entrypoint, rendering, persistence, and presets.

## TL;DR

- Yes, this is a fully built-in system. Two terminals side by side = one split. 2-over-2 grid or "two up top, one below" = **nested binary splits** — there is no special "grid" type.
- Split with `⌘D` (right) / `⇧⌘D` (down), drag a tab to a pane edge, use the command palette, or the CLI (`cmux new-split right`).
- Any layout can be captured as a reusable template ("Save Layout as Template…") or expressed as JSON and opened via `cmux new-workspace --layout '<json>'`.
- The engine is a vendored SwiftPM package, **bonsplit** (`vendor/bonsplit`, MIT, upstream `almonk/bonsplit`), wrapped by the first-party `Packages/macOS/CmuxPanes` package.
- A second, separate layout mode exists: **Canvas** (free-form infinite canvas, `⌃⌘C`) — see `docs/canvas-layout-design.md`. This doc covers the default tiling mode.

## Terminology hierarchy

```
Window            NSWindow                            (CLI ref: window:N)
└─ Workspace      sidebar entry, one project/cwd      (workspace:N)
   └─ Pane        one tiled region with its own tab strip   (pane:N)
      └─ Surface  a tab inside a pane: terminal, browser,
                  agent session, markdown, diff…      (surface:N)
         └─ Panel app-side content object backing a surface
                  (TerminalPanel, BrowserPanel… in Sources/Panels/)
```

- Each **Workspace** owns one `BonsplitController` — the split tree is per-workspace.
- In bonsplit's own vocabulary a "tab" is what cmux calls a **surface** (bonsplit `TabItem`/`TabID`). Surfaces map to panels via `PaneTreeModel.surfaceIdToPanelId` (`Packages/macOS/CmuxPanes/Sources/CmuxPanes/Model/PaneTreeModel.swift:42`).
- The right-sidebar **dock** has its own independent `BonsplitController` (`Sources/DockSplitStore.swift`, `docs/dock.md`).

## Data model: a binary split tree

The tree lives in bonsplit:

- `SplitNode` — `vendor/bonsplit/Sources/Bonsplit/Internal/Models/SplitNode.swift:12`
  `indirect enum SplitNode { case pane(PaneState); case split(SplitState) }`
- `SplitState` (branch) — `.../Models/SplitState.swift:12`: `orientation` (`horizontal` = side-by-side, `vertical` = stacked), exactly two children `first`/`second`, and one `dividerPosition` ratio (0.0–1.0, clamped 0.1–0.9, default 0.5).
- `PaneState` (leaf) — `.../Models/PaneState.swift:6`: `id: PaneID`, `tabs: [TabItem]`, `selectedTabId`. A leaf is itself a tab strip — each pane can hold multiple surfaces.
- Bounds are normalized 0–1, computed recursively (`SplitNode.computePaneBounds(in:)` at `SplitNode.swift:85`) and multiplied by the container frame at render time.

Every split is strictly binary. A 2×2 grid is:

```
split(vertical, 0.5)                 ← top / bottom
├─ split(horizontal, 0.5)            ← top-left | top-right
└─ split(horizontal, 0.5)            ← bottom-left | bottom-right
```

"Two side by side, one below spanning both":

```
split(vertical, 0.5)
├─ split(horizontal, 0.5)            ← the two up top
└─ pane                              ← the one below
```

### Controller and app-side wrapper

- `BonsplitController` — `vendor/bonsplit/Sources/Bonsplit/Public/BonsplitController.swift:7`, `@MainActor @Observable`. Public API: `splitPane(_:orientation:withTab:insertFirst:)` (`:427`/`:494`), `splitPane(...movingTab:)` (`:558`, drag-to-split), `closePane` (`:615`), `focusPane` (`:645`), `navigateFocus(direction:)` (`:651`), `togglePaneZoom` (`:682`), `setDividerPosition` (`:841`), snapshots `treeSnapshot()`/`layoutSnapshot()` (`:775`/`:746`).
- `Packages/macOS/CmuxPanes` adds the app-side layer:
  - `SplitLayoutModel` (`Model/SplitLayoutModel.swift:19`) — per-workspace choreography state (`isProgrammaticSplit`, detach tracking).
  - `PaneTreeModel` (`Model/PaneTreeModel.swift:17`) — panel registry + surface↔panel mapping.
  - `PaneLayoutService` (`PaneLayoutService.swift:11`) — stateless equalize/resize plan application.
  - `SplitDirection` (`Values/SplitDirection.swift`) — user-facing `left/right/up/down`, mapped to bonsplit `orientation` + `insertFirst`.
  - Geometry math in `ExternalTreeNode+SplitGeometry.swift` / `ExternalTreeNode+SpatialOrder.swift` (equalize divider plans, pixel-targeted resize, spatial pane ordering).
- cmux's `Workspace` implements `BonsplitDelegate` (`Sources/Workspace.swift:12244+`): `didSplitPane` (`:12826`) creates the app-side panel for a new surface; `didChangeGeometry` (`:13256`) triggers persistence.

## User-facing entrypoints

### Keyboard shortcuts (defaults, all rebindable in Settings and `cmux.json`)

Defined in `Sources/KeyboardShortcutSettings.swift` (actions ~`:124`, defaults ~`:430`):

| action | default | notes |
|---|---|---|
| `splitRight` | ⌘D | new terminal to the right |
| `splitDown` | ⇧⌘D | new terminal below |
| `splitBrowserRight` | ⌥⌘D | browser surface instead |
| `splitBrowserDown` | ⇧⌥⌘D | |
| `toggleSplitZoom` | ⇧⌘↩ | temporarily maximize one pane |
| `equalizeSplits` | ⌃⌘= | reset all dividers to equal sizes |
| `focusLeft/Right/Up/Down` | ⌥⌘←→↑↓ | directional pane focus |
| `toggleCanvasLayout` | ⌃⌘C | switch to the separate canvas mode |

No dedicated split-left/split-up shortcuts (available via CLI/socket direction params). No "close pane" shortcut — closing a pane's last surface (`⌘W`) auto-closes the pane.

### Menus and command palette

- Native menu items: `Sources/GhosttyTerminalView.swift:7254` (Split Down) / `:7266` (Split Right); equalize menu in `Sources/cmuxApp+EqualizeSplitsMenu.swift`; saved-layout menu in `Sources/AppDelegate+SavedLayoutMenu.swift`.
- Palette commands resolve in `Sources/ContentView+RightSidebarCommandPalette.swift:61-68` (`palette.terminalSplitRight`, `palette.terminalSplitDown`, browser variants) and `Sources/ContentView+SavedLayoutCommands.swift` (save/open layout templates).
- Tab-bar built-in actions `cmux.splitRight` / `cmux.splitDown`: `Sources/CmuxSurfaceTabBarBuiltInAction.swift:10-11`.

### Drag and drop

Dragging a surface tab to a pane edge creates a split (`BonsplitController.splitPane(...movingTab:)`). Cross-window tab and file drops go through `ExternalTabDropRequest`/`ExternalFileDropRequest` (`BonsplitController.swift:9-34`). App-side routing: `Sources/BrowserPaneSplitTarget.swift`, `Sources/TerminalPaneDropTargetView.swift`, `Sources/PaneDropRoutingSupport.swift`, `Sources/WorkspacePortalPaneDrop.swift`.

### CLI / control socket

Socket domain `pane.*` in `Packages/macOS/CmuxControlSocket/.../ControlCommandCoordinator+Pane.swift:18`:

| command | what it does |
|---|---|
| `pane.create` | split a surface into a new pane — params `direction` (left/right/up/down), `type`, `initial_divider_position`, `placement` |
| `pane.resize` | relative (`direction` + `amount`) or absolute (`absolute_axis` + `target_pixels`) |
| `pane.list` / `pane.surfaces` | enumerate panes / surfaces (grid cols/rows here = terminal character grid, not layout) |
| `pane.focus` / `pane.last` | focus a pane / the alternate pane |
| `pane.swap` | swap two panes |
| `pane.break` | detach a surface into a new workspace |
| `pane.join` | move a surface into a target pane |

CLI verbs (`CLI/cmux.swift`, contract in `docs/cli-contract.md:111-122`): `new-split <left|right|up|down>`, `new-pane`, `new-surface`, `split-off`, `drag-surface-to-split`, `move-surface`, `focus-pane`, `list-panes`, `tree`, and `new-workspace --layout '<json>'` (full tree; example JSON around `CLI/cmux.swift:15895`).

## Rendering

- SwiftUI mounts `BonsplitView` per workspace: `Sources/WorkspaceContentView.swift:187` (main area), `Sources/DockPanelView.swift:102` (dock). The content closure resolves each surface's panel via `workspace.panel(for: tab.id)`.
- Recursive tree renderer: `SplitNodeView` + `SplitContainerView` (`vendor/bonsplit/.../Internal/Views/`). `SplitContainerView` draws the divider and handles drag-to-resize (a `DragGesture` mutating `splitState.dividerPosition`). Split animations in `SplitAnimator.swift`.
- Divider appearance is configurable: `paneBorderColor` / `activePaneBorderColor` in `cmux.json` (`docs/configuration.md`), applied via `Sources/PaneChromeSettings.swift`.

## Persistence

Session restore rebuilds the exact tree across app restarts (`Sources/SessionPersistence.swift`):

- `SessionWorkspaceLayoutSnapshot` (`:1775`) mirrors the binary tree — `SessionSplitLayoutSnapshot` (`:1768`, orientation + dividerPosition + two children) and `SessionPaneLayoutSnapshot` (`:1763`, panel ids + selection). Each workspace also stores `layoutMode` (tiling vs canvas).
- Capture: `Workspace.captureLayoutDefinition()` (`Sources/Workspace+LayoutCapture.swift:22`) walks `treeSnapshot()`; saves are driven by `didChangeGeometry` notifications.
- Restore replays the snapshot as programmatic `splitPane` calls, with `SplitLayoutModel.isProgrammaticSplit` set so `didSplitPane` doesn't spawn fresh terminals (`Sources/Workspace.swift:8240`, `:12826`).

## Presets and saved layouts

No hard-coded preset buttons ("2×2", "3-up") exist. Two data-driven mechanisms cover presets:

1. **Layout JSON** — `CmuxLayoutNode` (`Sources/CmuxConfig.swift:1596`): `pane` / `split` nodes, each split requiring exactly two children plus `direction` and optional `split` ratio. Passed to `cmux new-workspace --layout` or embedded in workspace config. Any grid is nested 2-child splits.
2. **Saved layout templates** — `SavedLayoutStore` (`Sources/SavedLayoutStore.swift`) persists `CmuxSavedLayout { name, description, workspace }` to `~/.config/cmux/layouts.json`. Created via "Save Layout as Template…" from the current tree; reopened from the command palette or the saved-layout menu. This is the practical "preset" feature.

## Related docs

- `vendor/bonsplit/README.md` — full engine API (best reference for the tree itself)
- `docs/cli-contract.md` — pane/surface CLI verbs and handle model
- `docs/canvas-layout-design.md` — the separate free-form canvas mode
- `docs/dock.md` — the dock's independent split tree
- `docs/configuration.md` — divider colors, shortcut config
- repo skills: `cmux-workspace`, `cmux-architecture`, `cmux-keyboard-shortcuts`
