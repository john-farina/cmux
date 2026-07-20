# design: drag a workspace into another workspace's split tree

Drag a workspace row from the sidebar onto another workspace's terminal area. Edge-hover zones highlight where it will land (left/right/top/bottom), dropping merges the dragged workspace's content into the target's split tree as a new pane. Undoable, persisted.

## What already exists (and gets reused verbatim)

The investigation found most of the machinery is built:

| piece | where | status |
|---|---|---|
| edge-zone detection (left/right/top/bottom/center, 25% edge ratio) | `PaneDropRouting.zone(for:in:)` — `Sources/PaneDropRoutingSupport.swift:58` | reuse as-is |
| animated drop highlight overlay | `PaneDropZoneOverlayAnimator` — `PaneDropRoutingSupport.swift:150` | reuse as-is |
| zone → split/insert action | `Workspace.performPortalPaneDrop` — `Sources/WorkspacePortalPaneDrop.swift:29` | template |
| live surface move across workspaces/windows (ghostty surface reparented, never recreated; agent runtime carried along) | `detachSurface`/`attachDetachedSurface` + `DetachedSurfaceTransfer` — `Sources/Workspace.swift:9497,9548`, `AppDelegate.moveSurface` — `AppDelegate.swift:4861` | reuse as-is |
| sidebar workspace drag payload | `SidebarTabDragPayload` (`com.cmux.sidebar-tab-reorder`, carries workspace UUID) — `Sources/Sidebar/SidebarTabDragPayload.swift:5` | reuse as-is |
| closed-thing restore stack (⇧⌘T) | `ClosedItemHistoryStore` — `Sources/AppDelegate+ClosedItemHistory.swift` | extend |
| workspace close snapshot | `TabManager.closeWorkspace` + `Workspace.sessionSnapshot` — `Sources/TabManager.swift:1997` | reuse |

**Surface/tab drags already do this feature.** Dragging a surface tab to a pane edge (same or other window) already shows these zones and moves the live terminal. So "work with separate tabs too" is done today; the new work is making **workspace rows** participate, and it will feel identical because it reuses the same zones and overlay.

## The gaps

1. **No terminal-area drop target accepts the sidebar drag type.** `PaneDropTargetView` registers only bonsplit-tab-transfer + file URLs (`Sources/TerminalPaneDropTargetView.swift:21-23`), and the terminal portal hit-test gate (`TerminalWindowPortal.swift:176-204`) doesn't pass sidebar-reorder drags through. (The *browser* portal branch already recognizes the type — `DragOverlayRoutingPolicy.swift:342` — so there's precedent.)
2. **No whole-workspace merge primitive.** Everything today moves one surface at a time. Nothing grafts a workspace's content into another tree.
3. **No undo for this path.** Worse: when a surface move empties a workspace, `cleanupEmptySourceWorkspaceAfterSurfaceMove` (`AppDelegate.swift:5852`) closes it with `recordHistory: false` — no history entry gets pushed.

## Interaction design

### zones

Two tiers, matching the user's mental model:

- **Pane-edge zones** (existing behavior): hovering the left/right/top/bottom quarter of any pane splits *that pane*. With one terminal open, hovering the left half shows "drop here → side by side". Center zone = join as tabs in that pane.
- **Root-edge band** (new, small): a thin outer band (~8%, min 40pt) around the whole workspace content area splits at the *root* of the tree — this is the "two side by side, drop on bottom → new pane spanning below both" case. Without this, a bottom drop would only split one of the two panes.

Zone resolution order: root band wins at the outer strip, pane zones inside. `PaneDropRouting.zone` gets one new case; the overlay animator already handles arbitrary rects.

### rules

- dropping a workspace onto **itself** = no zones, no highlight (silent no-op).
- **Esc** during drag cancels (free — AppKit drag session default).
- drag image: the sidebar row itself (SwiftUI `.onDrag` default preview is fine for v1).
- after drop: focus the newly added pane; source workspace's sidebar row disappears (it's now empty and gets cleaned up); a transient confirmation affordance appears (see undo).
- source workspace in a **group**: group membership recorded in the undo snapshot; if the group empties, existing group-deletion path handles it.

### undo — "bring them back to where they were"

Before executing the merge, capture a restore bundle: source workspace `sessionSnapshot` (layout + surfaces + agent state), sidebar index, group membership, window. Push it as a new `ClosedItemHistoryEntry` case (`.workspaceMerge`) **before** the cleanup path runs (bypassing the `recordHistory: false` hole).

Restoring (⇧⌘T or palette "Reopen…"):
1. detach the merged surfaces back out of the target (they're the same live panels — `detachSurface` again, no terminal state lost),
2. recreate the workspace at its old sidebar index/group,
3. attach the surfaces and replay the old layout snapshot (same programmatic-split replay session restore already uses).

Plus a lightweight toast/pill on drop — "moved <name> into <target> · Undo" — as the discoverable path; ⇧⌘T is the durable one.

### persistence

Mostly free. The target workspace's enlarged tree persists through the existing `didChangeGeometry` → `SessionWorkspaceLayoutSnapshot` flow; the source's entry disappears with its close. Agent sessions ride along in `DetachedSurfaceTransfer.agentRuntime` and are captured in the target's snapshot like any other surface — same guarantees agents get today. The undo bundle lives in `ClosedItemHistoryStore` (in-memory, session-scoped — same durability as closed-workspace restore today; acceptable).

## Implementation plan

### phase 1 — accept the drag (plumbing)

- Register `DragOverlayRoutingPolicy.sidebarTabReorderType` on `PaneDropTargetView` (`TerminalPaneDropTargetView.swift:21`).
- Extend the terminal branch of `shouldPassThroughTerminalPortalHitTesting` / `WindowInputRoutingContext` to route sidebar-reorder drags to the drop target, mirroring what the browser branch already does. **Constraint:** `WindowTerminalHostView.hitTest` is typing-latency-sensitive — all new checks stay inside the existing `isPointerEvent`/drag-active gate; the check itself is a pasteboard-type test identical in cost to the existing ones.
- Decode `SidebarTabDragPayload` in `performDragOperation`; resolve workspace UUID → live `Workspace`; reject self-drops in `draggingUpdated` (return `[]`, no overlay).

### phase 2 — merge primitive

`AppDelegate.mergeWorkspace(sourceId:into:destination:)` where destination = pane split / pane insert / root split.

- **v1 (ship this):** loop the source workspace's panels through the existing `detachSurface` → `attachDetachedSurface` machinery into one new pane created at the drop zone. A multi-pane source collapses into a single tabbed pane in the target. Simple, reuses proven code, and most dragged workspaces are single-pane anyway.
- **v2 (fidelity, only if v1 feels lossy in practice):** subtree graft — add a bonsplit API to graft an `ExternalTreeNode` subtree into the tree, preserving the source's internal splits. bonsplit is vendored (`vendor/bonsplit`), so adding `BonsplitController.graftSubtree(_:at:)` is ours to do; `LayoutSnapshot` types already model the shape.
- Root-split destination: split at the tree root (bonsplit `splitPane` on the root node's spanning axis — verify the API reaches the root; if not, that's a small vendored addition too).
- Reuse `cleanupEmptySourceWorkspaceAfterSurfaceMove` for the emptied source, after the undo bundle is captured.

### phase 3 — root-edge band + overlay polish

- New zone case in `PaneDropRouting` for the outer band, with its own overlay frame (full-width strip along the workspace container edge).
- Overlay copy stays visual-only (accent highlight) — matches existing pane-drop feel.

### phase 4 — undo

- New `ClosedItemHistoryEntry.workspaceMerge(bundle)` in `AppDelegate+ClosedItemHistory.swift`; capture before merge executes.
- Restore path per the interaction design above; wire into `reopenMostRecentlyClosedItem` and the history menu/palette.
- Drop toast with inline Undo button (check for an existing toast/pill component before building one — the auto-naming "Naming…" pill is a candidate pattern).

### phase 5 — verification + hygiene

- Localization audit: toast text, any menu/palette strings → `Resources/Localizable.xcstrings` (en + ja).
- Regression tests (two-commit red/green policy): merge primitive round-trip (merge → undo → layouts identical), self-drop no-op, empty-source cleanup ordering vs undo capture. Wire into `project.pbxproj` (lint guard exists).
- `CmuxLog` probes: new category `workspace-merge` — log zone chosen, source/target ids, surface count, undo capture, restore.
- Manual dogfood checklist: 1-pane target (all 4 edges), 2-pane target (pane edges + root band top/bottom), multi-pane source, workspace-in-group source, cross-window drag, Esc cancel, ⇧⌘T restore, restart-and-verify persistence, typing latency spot-check while a drag is NOT active, and iphone attached to the source workspace during a live merge (see mobile companion impact below).

## Mobile companion impact

Classified per `docs/fork-feature-companion-parity.md`: **tier 1** (mirrored state changes), tier 3 ready but deferred.

- The merge composes existing primitives (`detachSurface`/`attachDetachedSurface`, workspace close), so the phone's observers (`MobileWorkspaceListObserver`, terminal feeds) fire without new work — the phone sees the source workspace vanish and the target gain surfaces. Undo restores are likewise just mirrored list changes.
- **Required check (tier 1 item 2):** a phone attached to or viewing the *source* workspace mid-merge must land somewhere sane. The surfaces survive (live panels reparent), but the workspace id they lived under disappears — verify the phone's workspace-gone handling covers merge like it covers close, with the phone attached during a live merge (`scripts/ios-pull-logs.sh` to confirm the observer sequence). Add this to the dogfood checklist in phase 5.
- **Tier 3 deferred:** because the primitive is one function (`mergeWorkspace(sourceId:into:destination:)`), a future `workspace.merge` RPC + `workspace-merge.v1` capability is a thin wrapper per the parity doc's shared-action-path rule. Not built until there's a phone UX reason.

## Risks

- **hitTest perf path** — mitigated by keeping all new logic behind the existing drag-active gate; this is the one area to review extra carefully.
- **focus/first-responder churn** after reparenting multiple surfaces at once — the single-surface path is proven; the loop needs a single focus decision at the end, not per-surface.
- **v1 layout collapse** of multi-pane sources may feel lossy — that's the trigger for v2, not a v1 blocker. The undo path restores the original layout regardless (snapshot is captured pre-merge).

## Rough sizing

phase 1+2 (v1) are the feature: ~2-3 focused files touched plus `AppDelegate`/`Workspace` extensions. phase 3 and 4 are each small. v2 subtree graft is the only genuinely new algorithmic work and is deferred until proven necessary.
