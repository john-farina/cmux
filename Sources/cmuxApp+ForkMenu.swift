import AppKit
import Bonsplit
import CmuxSettings
import SwiftUI

extension Notification.Name {
    static let forkImportExternalSessionsRequested = Notification.Name("cmux.fork.importExternalSessionsRequested")
    static let forkAutoNameWorkspaceRequested = Notification.Name("cmux.fork.autoNameWorkspaceRequested")
    static let forkRunConfiguredActionRequested = Notification.Name("cmux.fork.runConfiguredActionRequested")
    static let forkOpenProjectRequested = Notification.Name("cmux.fork.openProjectRequested")
}

/// Target/box for NSMenuItems in the tab-bar projects menu. NSMenuItem holds
/// its target weakly, so the shared singleton keeps actions alive.
@MainActor
final class ProjectTabBarMenuHandler: NSObject {
    static let shared = ProjectTabBarMenuHandler()

    final class Box: NSObject {
        weak var workspace: Workspace?
        let pane: PaneID
        let entry: CmuxProjectMenuEntry

        init(workspace: Workspace, pane: PaneID, entry: CmuxProjectMenuEntry) {
            self.workspace = workspace
            self.pane = pane
            self.entry = entry
        }
    }

    /// Box for the "Add … to Projects" item: the current repo, not yet saved.
    final class AddBox: NSObject {
        let name: String
        let path: String

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    @objc func addCurrentRepoToProjects(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? AddBox else {
            NSSound.beep()
            return
        }
        saveProject(name: box.name, path: box.path)
    }

    @objc func openProject(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? Box,
              let workspace = box.workspace else {
            NSSound.beep()
            return
        }
        RepoUsageStore.shared.recordOpen(path: box.entry.path)
        guard workspace.newTerminalSurface(
            inPane: box.pane,
            focus: true,
            workingDirectory: box.entry.path,
            initialCommand: box.entry.command
        ) != nil else {
            NSSound.beep()
            return
        }
        CmuxLog.agentTemplates.log("project.open placement=tabBar path=\(box.entry.path, privacy: .public)")
    }
}

/// Where an opened project lands.
enum ProjectOpenPlacement: String {
    case newWorkspace
    case currentWorkspaceTab
}

/// One shared open path for every project entrypoint (Toolbelt, tab-bar
/// button, new-workspace menu, palette-adjacent). Bumps the usage counter.
@MainActor
func openRepoProject(
    name: String,
    path: String,
    command: String?,
    placement: ProjectOpenPlacement,
    tabManager: TabManager
) {
    RepoUsageStore.shared.recordOpen(path: path)
    switch placement {
    case .newWorkspace:
        _ = tabManager.addWorkspace(
            title: name,
            workingDirectory: path,
            initialTerminalCommand: command
        )
        CmuxLog.agentTemplates.log("project.open placement=workspace path=\(path, privacy: .public)")
    case .currentWorkspaceTab:
        guard let workspace = tabManager.selectedWorkspace,
              let pane = workspace.focusedPanelId.flatMap({ workspace.paneId(forPanelId: $0) })
                ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return
        }
        _ = workspace.newTerminalSurface(
            inPane: pane,
            focus: true,
            workingDirectory: path,
            initialCommand: command
        )
        CmuxLog.agentTemplates.log("project.open placement=tab path=\(path, privacy: .public)")
    }
}

/// Saved projects (usage-sorted, config order breaking ties) followed by
/// auto-detected repos from RepoUsageStore, for every project menu.
@MainActor
func combinedProjectEntries(configStore: CmuxConfigStore?) -> [CmuxProjectMenuEntry] {
    let saved = configStore?.projectMenuEntries() ?? []
    let usage = RepoUsageStore.shared
    let sortedSaved = saved.enumerated()
        .sorted { lhs, rhs in
            let lhsCount = usage.usageCount(path: lhs.element.path)
            let rhsCount = usage.usageCount(path: rhs.element.path)
            return lhsCount != rhsCount ? lhsCount > rhsCount : lhs.offset < rhs.offset
        }
        .map(\.element)
    let savedPaths = Set(saved.map(\.path))
    let autoPaths = usage.topRepos(excluding: savedPaths)
    // why: nested repos surface as "parent/child" so two repos whose folder
    // is named e.g. "ios" stay tellable apart.
    let basenames = autoPaths.map { ($0 as NSString).lastPathComponent }
    let auto = autoPaths.map { path in
        let base = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let ambiguous = basenames.filter { $0 == base }.count > 1
        return CmuxProjectMenuEntry(
            id: "cmux.fork.autoProject.\(path)",
            name: ambiguous && !parent.isEmpty ? "\(parent)/\(base)" : base,
            path: path,
            command: nil
        )
    }
    return sortedSaved + auto
}

/// Fork-added features surfaced as a native menu so they are discoverable
/// outside the command palette and context menus. Items post window-targeted
/// notifications handled by the active window's ContentView, so the menu and
/// the palette/context-menu entrypoints share one action path each.
extension cmuxApp {
    @CommandsBuilder
    var forkCommands: some Commands {
        CommandMenu(String(localized: "menu.fork.title", defaultValue: "Toolbelt")) {
            Button(String(
                localized: "command.externalSessions.import.title",
                defaultValue: "Import Claude Sessions from Other Terminals…"
            )) {
                postForkMenuAction(.forkImportExternalSessionsRequested)
            }
            Button(String(
                localized: "contextMenu.autoNameWorkspace",
                defaultValue: "Auto-Name Workspace"
            )) {
                postForkMenuAction(.forkAutoNameWorkspaceRequested)
            }
            Divider()
            // why: the titlebar iPhone button is PostHog-flag-gated and can
            // vanish on fork builds; this entry is unconditional.
            Button(String(
                localized: "command.mobileConnect.title",
                defaultValue: "Connect iPhone/iPad"
            )) {
                MobilePairingWindowController.shared.show()
            }
            Button(String(
                localized: "command.auth.signIn.title",
                defaultValue: "Sign In"
            )) {
                guard let auth = AppDelegate.shared?.auth else {
                    NSSound.beep()
                    return
                }
                // fork why: the pairing window owns the open-in-browser
                // fallback UI; a bare beginSignIn strands the user when the
                // ASWeb sheet self-dismisses.
                MobilePairingWindowController.shared.show()
                auth.browserSignIn.beginSignIn()
            }
            Button(String(
                localized: "command.auth.signOut.title",
                defaultValue: "Sign Out"
            )) {
                guard let auth = AppDelegate.shared?.auth else {
                    NSSound.beep()
                    return
                }
                Task { @MainActor in
                    await auth.browserSignIn.signOut()
                }
            }
            let templates = AppDelegate.shared?.agentTemplateMenuEntriesForCommands(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) ?? []
            if !templates.isEmpty {
                Divider()
                ForEach(templates, id: \.id) { template in
                    Button(template.title) {
                        postForkMenuAction(
                            .forkRunConfiguredActionRequested,
                            userInfo: ["actionId": template.id]
                        )
                    }
                }
            }
            let projects = AppDelegate.shared?.projectMenuEntriesForCommands(
                preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
            ) ?? []
            if !projects.isEmpty {
                Divider()
                ForEach(projects, id: \.id) { project in
                    Menu(project.name) {
                        Button(String(
                            localized: "menu.fork.project.openNewWorkspace",
                            defaultValue: "Open in New Workspace"
                        )) {
                            postForkMenuAction(
                                .forkOpenProjectRequested,
                                userInfo: forkProjectUserInfo(project, placement: .newWorkspace)
                            )
                        }
                        Button(String(
                            localized: "menu.fork.project.openTabHere",
                            defaultValue: "Open Tab in Current Workspace"
                        )) {
                            postForkMenuAction(
                                .forkOpenProjectRequested,
                                userInfo: forkProjectUserInfo(project, placement: .currentWorkspaceTab)
                            )
                        }
                    }
                }
            }
        }
    }

    private func forkProjectUserInfo(
        _ project: CmuxProjectMenuEntry,
        placement: ProjectOpenPlacement
    ) -> [String: Any] {
        var userInfo: [String: Any] = [
            "name": project.name,
            "path": project.path,
            "placement": placement.rawValue
        ]
        if let command = project.command {
            userInfo["command"] = command
        }
        return userInfo
    }

    private func postForkMenuAction(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(
            name: name,
            object: NSApp.keyWindow ?? NSApp.mainWindow,
            userInfo: userInfo
        )
    }
}

extension CmuxProject: SettingCodable {
    static func decodeFromUserDefaults(_ raw: Any?) -> CmuxProject? { decodeFromJSON(raw) }
    func encodeForUserDefaults() -> Any { encodeForJSON() }

    static func decodeFromJSON(_ raw: Any?) -> CmuxProject? {
        guard let dict = raw as? [String: Any],
              let name = dict["name"] as? String,
              let path = dict["path"] as? String else { return nil }
        return CmuxProject(name: name, path: path, template: dict["template"] as? String)
    }

    func encodeForJSON() -> Any {
        var dict: [String: Any] = ["name": name, "path": path]
        if let template { dict["template"] = template }
        return dict
    }
}

/// Appends the workspace's repo as a saved project in the global cmux.json.
/// Name comes from the workspace title, path from the focused (or first)
/// terminal's reported directory. Same-path saves update the name in place.
/// Shared by the sidebar context menu and any future palette entry.
@MainActor
func saveWorkspaceAsProject(workspace: Workspace) {
    let name = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let focusedDirectory = workspace.focusedPanelId.flatMap { workspace.panelDirectories[$0] }
    let anyDirectory = workspace.orderedPanelIds.lazy.compactMap { workspace.panelDirectories[$0] }.first
    guard let path = focusedDirectory ?? anyDirectory, !path.isEmpty, !name.isEmpty else {
        CmuxLog.agentTemplates.log("project.save.no-directory workspace=\(workspace.id.uuidString, privacy: .public)")
        NSSound.beep()
        return
    }
    saveProject(name: name, path: path)
}

/// Appends (or renames, on a same-path save) a project in the global
/// cmux.json. Shared by the sidebar save item and the tab-bar folder menu's
/// "Add to Projects".
@MainActor
func saveProject(name: String, path: String) {
    Task {
        let store = JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let key = JSONKey<[CmuxProject]>(id: "projects", defaultValue: [])
        var projects = await store.value(for: key)
        if let existing = projects.firstIndex(where: { $0.expandedPath == (path as NSString).expandingTildeInPath }) {
            projects[existing].name = name
        } else {
            projects.append(CmuxProject(name: name, path: path))
        }
        do {
            try await store.set(projects, for: key)
            CmuxLog.agentTemplates.log("project.save.ok name=\(name, privacy: .public) count=\(projects.count, privacy: .public)")
        } catch {
            CmuxLog.agentTemplates.error("project.save.failed error=\(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }
}

/// Shared by the sidebar context menu (TabItemView) and the Fork menu — one action path.
@MainActor
func triggerManualWorkspaceAutoName(workspaceIds: [UUID], tabManager: TabManager) {
    guard let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
          FileManager.default.isExecutableFile(atPath: cliURL.path) else {
        NSSound.beep()
        return
    }
    let socketPath = TerminalController.shared.activeSocketPath(
        preferredPath: SocketControlSettings.socketPath()
    )
    for workspaceId in workspaceIds {
        // why: hook store lags restarts — the app passes its own panel→session pairs
        var sessionPairs: [String] = []
        if let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
            workspace.setAutoNamingWorkingStatus()
            // Backstop: the CLI reports success or failure through
            // set_auto_title, but if it dies the pill must still resolve.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak workspace] in
                guard let workspace, workspace.hasAutoNamingWorkingStatus else { return }
                workspace.setAutoNamingFailedStatus()
            }
            for panelId in workspace.panels.keys {
                var sessionId = SharedLiveAgentIndex.shared
                    .snapshot(workspaceId: workspaceId, panelId: panelId)
                    .flatMap { $0.kind == .claude ? $0.sessionId : nil }
                if sessionId == nil,
                   let binding = workspace.surfaceResumeBindingsByPanelId[panelId],
                   binding.kind == RestorableAgentKind.claude.rawValue {
                    sessionId = binding.checkpointId
                }
                if let sessionId, !sessionId.isEmpty {
                    sessionPairs.append("\(sessionId)@\(panelId.uuidString)")
                }
            }
        }
        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "--socket", socketPath,
            "hooks", "claude", "auto-name",
            "--workspace", workspaceId.uuidString,
            "--manual",
        ]
        if !sessionPairs.isEmpty {
            arguments.append(contentsOf: ["--sessions", sessionPairs.joined(separator: ",")])
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = cliURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }
        do {
            try process.run()
            CmuxLog.agentResume.log("auto-name.manual.spawned workspace=\(workspaceId.uuidString, privacy: .public)")
        } catch {
            CmuxLog.agentResume.error("auto-name.manual.spawn-failed workspace=\(workspaceId.uuidString, privacy: .public)")
            tabManager.tabs.first(where: { $0.id == workspaceId })?.setAutoNamingFailedStatus()
            NSSound.beep()
        }
    }
}
