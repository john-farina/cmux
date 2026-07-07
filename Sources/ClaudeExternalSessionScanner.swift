import Darwin
import Foundation

/// A live claude code session running in a terminal cmux does not own.
struct ExternalClaudeSession: Sendable, Hashable, Identifiable {
    let pid: pid_t
    let sessionId: String
    let cwd: String
    let name: String?
    let startedAt: Date?

    var id: String { sessionId }
}

/// Discovers claude code sessions running in other terminal apps by reading
/// claude's own live-session sidecars (`~/.claude/sessions/<pid>.json`,
/// `{pid, sessionId, cwd, startedAt, name, kind}`), then filtering to
/// processes that are alive, are actually claude (argv check — we may later
/// SIGTERM this pid, so a recycled pid must never match), and are NOT
/// cmux-owned (no `CMUX_SURFACE_ID`/`CMUX_WORKSPACE_ID` in the process env).
/// On-demand only; nothing polls.
enum ClaudeExternalSessionScanner {

    /// Process probes, injectable for tests.
    struct Probes: Sendable {
        var processArguments: @Sendable (pid_t) -> CmuxTopProcessArguments?

        static let live = Probes(
            processArguments: { pid in
                CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: Int(pid))
            }
        )
    }

    static func defaultSessionsDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Session ids currently bound to a cmux surface, per the claude hook
    /// store — used to skip sessions cmux already hosts (e.g. after import).
    static func activeCmuxClaudeSessionIds(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Set<String> {
        let file = homeDirectory
            .appendingPathComponent(".cmuxterm", isDirectory: true)
            .appendingPathComponent("claude-hook-sessions.json", isDirectory: false)
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = root["activeSessionsBySurface"] as? [String: Any] else {
            return []
        }
        return Set(active.values.compactMap { value in
            (value as? [String: Any])?["sessionId"] as? String
        })
    }

    static func scan(
        sessionsDirectory: URL? = nil,
        activeCmuxSessionIds: Set<String>? = nil,
        probes: Probes = .live
    ) -> [ExternalClaudeSession] {
        let directory = sessionsDirectory ?? defaultSessionsDirectory()
        let activeIds = activeCmuxSessionIds ?? activeCmuxClaudeSessionIds()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var bySessionId: [String: ExternalClaudeSession] = [:]
        for file in files where file.pathExtension == "json" {
            guard let session = parseSidecar(at: file) else { continue }
            if activeIds.contains(session.sessionId) {
                CmuxLog.externalImport.log(
                    "scan.skip reason=active-in-cmux session=\(session.sessionId, privacy: .public)"
                )
                continue
            }
            guard isForeignLiveClaudeProcess(pid: session.pid, probes: probes) else { continue }
            // Two sidecars can carry one session id (resumed elsewhere); keep the newest.
            if let existing = bySessionId[session.sessionId],
               (existing.startedAt ?? .distantPast) >= (session.startedAt ?? .distantPast) {
                continue
            }
            bySessionId[session.sessionId] = session
        }
        let sessions = bySessionId.values.sorted {
            ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
        }
        CmuxLog.externalImport.log("scan.done found=\(sessions.count, privacy: .public)")
        return sessions
    }

    /// True when `pid` is alive, is a claude process, and carries no cmux
    /// surface/workspace scope in its environment. Fail-closed: unreadable
    /// args/env (dead pid, other user) never qualify.
    static func isForeignLiveClaudeProcess(pid: pid_t, probes: Probes = .live) -> Bool {
        guard pid > 0, let args = probes.processArguments(pid) else { return false }
        let isClaude = args.arguments.prefix(3).contains { argument in
            argument == "claude" || argument.hasSuffix("/claude")
        }
        guard isClaude else { return false }
        let env = args.environment
        return env["CMUX_SURFACE_ID"] == nil && env["CMUX_WORKSPACE_ID"] == nil
    }

    /// Sends SIGTERM to a previously discovered session's process after
    /// re-verifying it is still the same foreign claude (guards pid reuse
    /// between the import sheet appearing and the user confirming).
    @discardableResult
    static func terminateOriginal(_ session: ExternalClaudeSession, probes: Probes = .live) -> Bool {
        guard isForeignLiveClaudeProcess(pid: session.pid, probes: probes) else {
            CmuxLog.externalImport.log(
                "terminate.skip reason=identity-mismatch pid=\(session.pid, privacy: .public) session=\(session.sessionId, privacy: .public)"
            )
            return false
        }
        let result = kill(session.pid, SIGTERM)
        CmuxLog.externalImport.log(
            "terminate.sent pid=\(session.pid, privacy: .public) session=\(session.sessionId, privacy: .public) result=\(result, privacy: .public)"
        )
        return result == 0
    }

    static func parseSidecar(at url: URL) -> ExternalClaudeSession? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = object["pid"] as? Int, pid > 0,
              let sessionId = object["sessionId"] as? String, !sessionId.isEmpty,
              let cwd = object["cwd"] as? String, !cwd.isEmpty else {
            return nil
        }
        // `kind` distinguishes interactive TUIs from `-p` runs; only
        // interactive sessions are importable. Tolerate its absence.
        if let kind = object["kind"] as? String, kind != "interactive" {
            return nil
        }
        let startedAt = (object["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        let name = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ExternalClaudeSession(
            pid: pid_t(pid),
            sessionId: sessionId,
            cwd: cwd,
            name: name,
            startedAt: startedAt
        )
    }
}
