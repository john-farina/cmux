import SwiftUI

/// Pure ordering/cycling logic for the sidebar unread navigator, kept free of
/// view state so it stays inspectable and testable.
enum UnreadNavigatorTargets {
    /// Unread targets in sidebar order: workspaces in tab order, each
    /// workspace's unread surfaces sorted stably, with a workspace-level entry
    /// (surfaceId == nil) when the workspace shows an unread badge that no
    /// surface key explains (manual unread, workspace-scoped notifications).
    static func ordered(
        workspaceIdsInSidebarOrder: [UUID],
        unreadSurfaceKeys: Set<SidebarSurfaceUnreadKey>,
        manualUnreadWorkspaceIds: Set<UUID>
    ) -> [SidebarSurfaceUnreadKey] {
        workspaceIdsInSidebarOrder.flatMap { workspaceId -> [SidebarSurfaceUnreadKey] in
            let keys = unreadSurfaceKeys
                .filter { $0.workspaceId == workspaceId }
                .sorted { ($0.surfaceId?.uuidString ?? "") < ($1.surfaceId?.uuidString ?? "") }
            if keys.isEmpty, manualUnreadWorkspaceIds.contains(workspaceId) {
                return [SidebarSurfaceUnreadKey(workspaceId: workspaceId, surfaceId: nil)]
            }
            return keys
        }
    }

    /// The next target `delta` steps from `lastVisited`, wrapping. When
    /// `lastVisited` is gone (read, closed, or never set), starts from the
    /// first target for forward moves and the last for backward moves.
    static func next(
        in targets: [SidebarSurfaceUnreadKey],
        after lastVisited: SidebarSurfaceUnreadKey?,
        delta: Int
    ) -> SidebarSurfaceUnreadKey? {
        guard !targets.isEmpty else { return nil }
        guard let lastVisited, let index = targets.firstIndex(of: lastVisited) else {
            return delta >= 0 ? targets.first : targets.last
        }
        let count = targets.count
        return targets[((index + delta) % count + count) % count]
    }
}

/// A pill above the sidebar workspace list that appears whenever any terminal
/// is unread. Center cycles through every unread terminal (wrapping back to
/// the start); the arrows step backward/forward. Navigation only focuses —
/// terminals are marked read by interacting with them, as usual.
struct UnreadNavigatorBar: View {
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var sidebarUnread: SidebarUnreadModel
    @State private var lastVisited: SidebarSurfaceUnreadKey?
    @State private var isHovering = false

    var body: some View {
        let targets = UnreadNavigatorTargets.ordered(
            workspaceIdsInSidebarOrder: tabManager.tabs.map(\.id),
            unreadSurfaceKeys: sidebarUnread.unreadSurfaceKeys,
            manualUnreadWorkspaceIds: sidebarUnread.manualUnreadWorkspaceIds
        )
        if !targets.isEmpty {
            HStack(spacing: 0) {
                arrowButton(
                    systemName: "chevron.left",
                    identifier: "sidebar.unreadNavigator.previous",
                    label: String(
                        localized: "sidebar.unreadNavigator.previous",
                        defaultValue: "Previous Unread Terminal"
                    )
                ) {
                    go(delta: -1, targets: targets)
                }
                Button {
                    go(delta: 1, targets: targets)
                } label: {
                    Text(
                        String(
                            localized: "sidebar.unreadNavigator.count",
                            defaultValue: "\(targets.count) unread"
                        )
                    )
                    .cmuxFont(size: 11, weight: .semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, ViewConstants.buttonVerticalPadding)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.unreadNavigator.cycle")
                .safeHelp(
                    String(
                        localized: "sidebar.unreadNavigator.cycle.tooltip",
                        defaultValue: "Cycle through unread terminals"
                    )
                )
                arrowButton(
                    systemName: "chevron.right",
                    identifier: "sidebar.unreadNavigator.next",
                    label: String(
                        localized: "sidebar.unreadNavigator.next",
                        defaultValue: "Next Unread Terminal"
                    )
                ) {
                    go(delta: 1, targets: targets)
                }
            }
            .foregroundColor(.white)
            .background(
                Capsule().fill(cmuxAccentColor().opacity(isHovering ? 1.0 : 0.88))
            )
            .onHover { isHovering = $0 }
            .padding(.horizontal, ViewConstants.horizontalInset)
            // why: top inset lands the pill at firstRowTopOffset — the y where
            // the first tab row normally starts.
            .padding(.top, ViewConstants.topInset)
            .padding(.bottom, ViewConstants.bottomInset)
            .transition(.opacity)
            .accessibilityIdentifier("sidebar.unreadNavigator")
        }
    }

    private func arrowButton(
        systemName: String,
        identifier: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            CmuxSystemSymbolImage(systemName: systemName, pointSize: 9, weight: .semibold)
                .padding(.horizontal, ViewConstants.arrowHorizontalPadding)
                .padding(.vertical, ViewConstants.buttonVerticalPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .safeHelp(label)
    }

    private func go(delta: Int, targets: [SidebarSurfaceUnreadKey]) {
        guard let target = UnreadNavigatorTargets.next(
            in: targets,
            after: lastVisited,
            delta: delta
        ) else { return }
        lastVisited = target
        CmuxLog.unreadNavigator.log(
            "navigate workspace=\(target.workspaceId, privacy: .public) surface=\(target.surfaceId?.uuidString ?? "nil", privacy: .public) delta=\(delta, privacy: .public) total=\(targets.count, privacy: .public)"
        )
        // why: peek suppresses all dismissal for this workspace until a real
        // terminal click/keystroke, so navigating never marks anything read.
        tabManager.beginUnreadNavigatorPeek(tabId: target.workspaceId)
        tabManager.focusTab(
            target.workspaceId,
            surfaceId: target.surfaceId,
            dismissRestoredUnreadOnResume: false
        )
    }
}

private enum ViewConstants {
    static let horizontalInset: CGFloat =
        SidebarWorkspaceListMetrics.rowOuterHorizontalPadding +
        SidebarWorkspaceListMetrics.rowContentHorizontalPadding
    static let topInset: CGFloat = SidebarWorkspaceListMetrics.rowVerticalPadding + 6
    static let bottomInset: CGFloat = SidebarWorkspaceListMetrics.rowVerticalPadding
    static let arrowHorizontalPadding: CGFloat = 12
    static let buttonVerticalPadding: CGFloat = 7
}
