import AppKit
import CmuxCommandPalette
import Foundation
import SwiftUI

// MARK: - Import claude sessions running in other terminals

extension ContentView {
    static let commandPaletteImportExternalSessionsCommandId = "palette.externalSessions.import"

    static func commandPaletteExternalSessionImportContributions() -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: commandPaletteImportExternalSessionsCommandId,
                title: { _ in
                    String(
                        localized: "command.externalSessions.import.title",
                        defaultValue: "Import Claude Sessions from Other Terminals…"
                    )
                },
                subtitle: { _ in
                    String(
                        localized: "command.externalSessions.import.subtitle",
                        defaultValue: "Agent Sessions"
                    )
                },
                keywords: ["import", "claude", "session", "external", "terminal", "adopt", "migrate"]
            ),
        ]
    }

    func registerExternalSessionImportCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.commandPaletteImportExternalSessionsCommandId) {
            presentExternalSessionImport()
        }
    }

    func presentExternalSessionImport() {
        let sessions = ClaudeExternalSessionScanner.scan()
        guard !sessions.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "dialog.externalSessions.none.title",
                defaultValue: "No External Claude Sessions"
            )
            alert.informativeText = String(
                localized: "dialog.externalSessions.none.message",
                defaultValue: "No claude sessions running outside cmux were found."
            )
            alert.runModal()
            return
        }
        externalImportCandidates = sessions
        isExternalImportSheetPresented = true
    }

    /// Opens each selected session in a new cmux tab via `claude --resume`,
    /// then offers to SIGTERM the original processes so two claudes don't
    /// share one session id. The other terminal's window stays open.
    func importExternalSessions(_ sessions: [ExternalClaudeSession]) {
        var imported: [ExternalClaudeSession] = []
        for session in sessions {
            guard let resumeCommand = AgentResumeCommandBuilder.resumeShellCommand(
                kind: .claude,
                sessionId: session.sessionId,
                launchCommand: nil,
                workingDirectory: session.cwd,
                includeWorkingDirectoryPrefix: false
            ) else {
                CmuxLog.externalImport.error(
                    "import.skip reason=no-resume-command session=\(session.sessionId, privacy: .public)"
                )
                continue
            }
            tabManager.addWorkspace(
                workingDirectory: session.cwd,
                initialTerminalInput: resumeCommand + "\n"
            )
            CmuxLog.externalImport.log(
                "import.spawned session=\(session.sessionId, privacy: .public) pid=\(session.pid, privacy: .public)"
            )
            imported.append(session)
        }
        guard !imported.isEmpty else { return }
        offerToCloseOriginals(imported)
    }

    private func offerToCloseOriginals(_ sessions: [ExternalClaudeSession]) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "dialog.externalSessions.close.title",
            defaultValue: "Close Original Sessions?"
        )
        let list = sessions
            .map { "\($0.name ?? $0.sessionId) (pid \($0.pid))" }
            .joined(separator: "\n")
        let messageFormat = String(
            localized: "dialog.externalSessions.close.message",
            defaultValue: "The sessions were imported into cmux. Closing the originals avoids two processes resuming the same session:\n\n%@\n\nThe other terminal's window stays open; only the claude process is quit."
        )
        alert.informativeText = String(format: messageFormat, list)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(
            localized: "dialog.externalSessions.close.confirm",
            defaultValue: "Close Originals"
        ))
        alert.addButton(withTitle: String(
            localized: "dialog.externalSessions.close.keep",
            defaultValue: "Keep Running"
        ))
        guard alert.runModal() == .alertFirstButtonReturn else {
            CmuxLog.externalImport.log("close-originals.declined count=\(sessions.count, privacy: .public)")
            return
        }
        for session in sessions {
            ClaudeExternalSessionScanner.terminateOriginal(session)
        }
    }
}

/// Checkbox list of detected foreign claude sessions; all pre-selected.
struct ExternalSessionImportSheet: View {
    let sessions: [ExternalClaudeSession]
    let onImport: ([ExternalClaudeSession]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<String>

    init(sessions: [ExternalClaudeSession], onImport: @escaping ([ExternalClaudeSession]) -> Void) {
        self.sessions = sessions
        self.onImport = onImport
        _selectedIds = State(initialValue: Set(sessions.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ViewConstants.sectionSpacing) {
            Text(String(
                localized: "dialog.externalSessions.sheet.title",
                defaultValue: "Import Claude Sessions"
            ))
            .font(.headline)

            Text(String(
                localized: "dialog.externalSessions.sheet.subtitle",
                defaultValue: "These claude sessions are running in other terminals. Selected sessions open in new cmux tabs via --resume."
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: ViewConstants.rowSpacing) {
                    ForEach(sessions) { session in
                        Toggle(isOn: Binding(
                            get: { selectedIds.contains(session.id) },
                            set: { isOn in
                                if isOn {
                                    selectedIds.insert(session.id)
                                } else {
                                    selectedIds.remove(session.id)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: session.name ?? session.sessionId)
                                    .lineLimit(1)
                                Text(verbatim: "\(session.cwd) · pid \(session.pid)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: ViewConstants.listMaxHeight)

            HStack {
                Spacer()
                Button(String(
                    localized: "dialog.externalSessions.sheet.cancel",
                    defaultValue: "Cancel"
                )) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(String(
                    localized: "dialog.externalSessions.sheet.import",
                    defaultValue: "Import"
                )) {
                    let selected = sessions.filter { selectedIds.contains($0.id) }
                    dismiss()
                    onImport(selected)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIds.isEmpty)
            }
        }
        .padding(ViewConstants.sheetPadding)
        .frame(width: ViewConstants.sheetWidth)
    }
}

private enum ViewConstants {
    static let sheetWidth: CGFloat = 460
    static let sheetPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 8
    static let listMaxHeight: CGFloat = 260
}
