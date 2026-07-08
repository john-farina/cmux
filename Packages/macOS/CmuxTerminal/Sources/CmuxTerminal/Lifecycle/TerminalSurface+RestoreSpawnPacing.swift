import Foundation
import os

extension TerminalSurface {
    private static let resumeInputLogger = Logger(subsystem: "com.cmuxterm.app", category: "agent-resume")

    /// (Re)arms the size-settle debounce for a deferred restore startup input.
    /// Called at runtime-surface creation and on every applied resize; fires
    /// 300ms after the last resize, capped at 3s total so the resume can never
    /// be stranded by continuous layout churn.
    @MainActor
    func scheduleDeferredInitialInputSend() {
        guard pendingDeferredInitialInput != nil else { return }
        deferredInitialInputWorkItem?.cancel()
        let deadline = deferredInitialInputDeadline ?? Date().addingTimeInterval(3)
        deferredInitialInputDeadline = deadline
        let settled = Date() >= deadline
        let item = DispatchWorkItem { [weak self] in
            self?.flushDeferredInitialInput(reason: settled ? "deadline" : "size-settled")
        }
        deferredInitialInputWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (settled ? 0 : 0.3), execute: item)
    }

    @MainActor
    private func flushDeferredInitialInput(reason: String) {
        deferredInitialInputWorkItem = nil
        deferredInitialInputDeadline = nil
        guard let input = pendingDeferredInitialInput else { return }
        pendingDeferredInitialInput = nil
        let sent = sendText(input)
        Self.resumeInputLogger.log(
            "resume.deferred-input surface=\(self.id.uuidString.prefix(8), privacy: .public) sent=\(sent ? 1 : 0, privacy: .public) reason=\(reason, privacy: .public) bytes=\(input.utf8.count, privacy: .public)"
        )
    }

    @MainActor
    func shouldPaceRuntimeSurfaceCreation(source: RuntimeSurfaceCreationSource) -> Bool {
        guard requiresRestoreSpawnPacing else { return false }
        guard source == .normal else { return false }
        guard surface == nil else { return false }
        return true
    }

    @MainActor
    func enqueueRestoredRuntimeSurfaceCreation(for view: any TerminalSurfaceNativeViewing) {
        guard !restoredRuntimeSurfaceStartQueued else { return }
        restoredRuntimeSurfaceStartQueued = true
        let surfaceId = id
        restoreSpawnScheduler.scheduleRestoredSurfaceSpawn(surfaceId: surfaceId) { [weak self, weak view] in
            guard let self else { return }
            self.restoredRuntimeSurfaceStartQueued = false
            guard self.allowsRuntimeSurfaceCreation() else { return }
            guard self.surface == nil else { return }
            guard let view, view.window != nil else { return }
            guard self.attachedView === view else { return }
            self.createSurface(for: view, source: .scheduledRestore)
        }
    }
}
