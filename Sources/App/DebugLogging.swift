import os

#if DEBUG
import CMUXDebugLog

@inline(__always)
func cmuxDebugLog(_ message: @autoclosure () -> String) {
    CMUXDebugLog.logDebugEvent(message())
}
#endif

// why: release-safe loggers for post-hoc debugging via `log show` — the DEBUG
// event log above never ships, so issue reports from the real app need these.
enum CmuxLog {
    static let session = Logger(subsystem: "com.cmuxterm.app", category: "session-persistence")
    static let agentResume = Logger(subsystem: "com.cmuxterm.app", category: "agent-resume")
    static let agentTemplates = Logger(subsystem: "com.cmuxterm.app", category: "agent-templates")
    static let externalImport = Logger(subsystem: "com.cmuxterm.app", category: "external-import")
}
