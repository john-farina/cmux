import AppKit
import CmuxSettings
import SwiftUI

extension Notification.Name {
    static let forkImportExternalSessionsRequested = Notification.Name("cmux.fork.importExternalSessionsRequested")
    static let forkAutoNameWorkspaceRequested = Notification.Name("cmux.fork.autoNameWorkspaceRequested")
    static let forkRunConfiguredActionRequested = Notification.Name("cmux.fork.runConfiguredActionRequested")
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
        }
    }

    private func postForkMenuAction(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(
            name: name,
            object: NSApp.keyWindow ?? NSApp.mainWindow,
            userInfo: userInfo
        )
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
