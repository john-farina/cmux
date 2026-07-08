# fork features × iphone companion — parity system

Every fork feature added to the mac app must decide, at planning time, what the iphone companion sees. This doc is that system: classify the feature into a tier, follow the tier's checklist, and record the classification in the feature's design doc. Companion architecture, RPC/capability mechanics, and build workflow live in `docs/fork-mobile-companion.md` (read §1, §4, §7 first).

## Why tiers

The companion is not a second implementation of cmux — it's a viewer/controller over the mac's state, fed by observers (`MobileWorkspaceListObserver`, `MobileTerminalByteTee`, `MobileTerminalRenderObserver`) and a capability-gated RPC surface (`MobileHostService.swift` dispatch, `MobileHostService+Capabilities.swift`). So "does this feature translate to mobile" decomposes into: does the phone's mirrored state change, does the phone need to *show* something new, and can the phone *trigger* it. Those are the tiers.

## The tiers

### tier 0 — invisible to the phone

Pure mac-side UX with no observable state change: divider colors, menu placement, keyboard shortcuts, animations.

**Checklist:** none. State "tier 0" in the design doc and move on.

### tier 1 — mirrored state changes (the default for most features)

The feature mutates state the phone already mirrors: the workspace list, surface membership, titles, agent sessions, terminal content. Examples: auto-naming (titles change), external session import (workspaces appear), workspace drag-merge (workspaces disappear, surfaces move).

**Checklist:**
1. **Route mutations through the existing observed paths.** If the feature composes existing primitives (workspace close, surface detach/attach, title set), the observers fire for free. A feature that mutates the model through a new side door must poke the same observers the primitives do.
2. **Handle the phone-is-watching case.** If the phone can be attached to or viewing an entity the feature removes or moves (a workspace being merged away, a surface being reparented), verify the phone's existing "entity gone" handling covers it, and that live terminal streams survive or re-home. Test with the phone attached during the operation.
3. **No new RPC, no new capability** — that's the point of this tier.

### tier 2 — phone needs to display something new

The feature introduces state worth *seeing* on the phone that no existing surface carries: a layout tree, a status pill, a new panel type.

**Checklist (in addition to tier 1's):**
1. Wire types shared by both sides go in `Packages/Shared/CMUXMobileCore` (`MobileSyncProtocol.swift`).
2. New RPC/event: mac handler in the `MobileHostService.swift` dispatch region (add to `requiresAuthorization` deliberately — stack auth is the sole gate), phone types in `Packages/iOS/CmuxMobileRPC`.
3. Advertise a **capability string** in `MobileHostService+Capabilities.swift`; the phone feature-detects on the capability, never on version. Old phone builds must degrade gracefully (they simply don't see the new state).
4. Phone UI per the extension conventions (`fork-mobile-companion.md` §7): views in `CmuxMobileShellUI` on value snapshots, logic on `MobileShellComposite`, pure policies in testable packages.

### tier 3 — phone can trigger the feature

Action parity: the phone invokes the feature (rename a workspace, launch an agent template, merge workspaces).

**Checklist (in addition to tier 2's):**
1. **One shared action path** (repo shared-behavior policy): the RPC handler calls the *same* mac-side function the menu/palette/shortcut calls — never a parallel implementation. This is why every fork feature's core primitive should be a single well-named function (e.g. `mergeWorkspace(sourceId:into:destination:)`), not logic inlined into a drop handler: it makes tier 3 a thin RPC wrapper whenever we want it.
2. **Undo works regardless of trigger side.** If the feature pushes a `ClosedItemHistoryStore` entry, a phone-triggered invocation pushes the same entry; restore happens on the mac and the phone sees it as tier-1 mirrored state.
3. Phone UI failure states use the classified errors (`account_mismatch`, capability missing) — actionable copy, not generic failure.

## Rules that apply at every tier ≥ 1

- **Design docs must carry a "mobile companion impact" section**: the tier, which checklist items apply, and what was deliberately deferred (e.g. "tier 3 deferred; primitive is RPC-ready"). No fork feature plan is complete without it.
- **Localization both sides** when tier ≥ 2 adds phone strings: mac keys in `Resources/Localizable.xcstrings`, phone keys in the owning package's xcstrings, en + ja.
- **Logging both sides**: mac `CmuxLog` category; phone `MobileDebugLog`/`DiagnosticEvent` lines for anything the phone renders or triggers, so `scripts/ios-pull-logs.sh` tells the story after the fact.
- **Session persistence is mac-owned.** The phone never persists layout/workspace state — it re-mirrors on connect. Features only need their mac-side persistence story; the companion inherits it.
- **Capability strings are forever.** Once advertised, never repurpose one; old installed builds feature-detect against them.

## Applying it (worked example: workspace drag-merge)

- **Tier 1 now.** The merge composes existing primitives (`detachSurface`/`attachDetachedSurface`, workspace close), so `MobileWorkspaceListObserver` and the terminal feeds fire for free — the phone sees the source workspace vanish and the target gain surfaces. The one real check: a phone viewing the *source* workspace mid-merge must land somewhere sane (existing workspace-closed handling; verify live, with `ios-pull-logs.sh` confirming the observer sequence).
- **Tier 3 ready, deferred.** The primitive is one function, so a future `workspace.merge` RPC + capability (`workspace-merge.v1`) is a thin wrapper. Not built until there's a phone UX reason.
- The feature's own doc (`docs/workspace-drag-merge-design.md`) carries this as its mobile-impact section.
