import Darwin
import Foundation
import os

// why: manual naming runs in a detached CLI; os_log is its only locally
// readable trail (`log show --predicate 'subsystem == "com.cmuxterm.app"'`)
private let manualAutoNameLog = Logger(subsystem: "com.cmuxterm.app", category: "agent-resume")

extension CMUXCLI {
    /// Drives one auto-naming pass for a Claude session at turn end.
    /// `manual: true` (context-menu trigger) bypasses the enabled/user-owned/
    /// staleness/throttle gates — the user explicitly asked for a rename.
    /// `panelOnly: true` names just the tab, leaving the workspace title to a
    /// later all-tabs synthesis pass. Returns the applied title, if any.
    @discardableResult
    func runClaudeAutoNameHook(
        parsedInput: ClaudeHookParsedInput,
        mappedSession: ClaudeHookSessionRecord?,
        workspaceId: String,
        surfaceId: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        manual: Bool = false,
        panelOnly: Bool = false
    ) -> String? {
        guard let sessionId = parsedInput.sessionId ?? (manual ? mappedSession?.sessionId : nil) else { return nil }
        let env = ProcessInfo.processInfo.environment
        let probe = (try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        )) ?? [:]
        if !manual {
            guard probe["enabled"] as? Bool == true else {
                telemetry.breadcrumb("claude-hook.auto-name.disabled")
                return nil
            }
            guard probe["workspace_user_owned"] as? Bool != true else {
                telemetry.breadcrumb("claude-hook.auto-name.user-owned")
                return nil
            }
        }

        let claudePid = mappedSession?.pid ?? claudeAgentPID(from: env)
        guard !shouldSuppressNestedAgentVisibleMutations(currentAgentPID: claudePid, env: env) else {
            telemetry.breadcrumb("claude-hook.auto-name.nested-suppressed")
            return nil
        }
        guard manual || shouldApplyClaudeHookVisibleMutation(
            sessionStore: sessionStore,
            parsedInput: parsedInput,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.auto-name.stale")
            return nil
        }

        let resolvedTranscriptPath = parsedInput.transcriptPath
            ?? mappedSession?.transcriptPath
            ?? (manual ? Self.claudeTranscriptPathBySessionId(sessionId) : nil)
        guard let transcriptPath = resolvedTranscriptPath else {
            if manual { manualAutoNameLog.log("auto-name.pass.no-transcript-path session=\(sessionId, privacy: .public)") }
            return nil
        }
        guard let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024), !lines.isEmpty else {
            if manual { manualAutoNameLog.log("auto-name.pass.transcript-unreadable session=\(sessionId, privacy: .public)") }
            return nil
        }
        let lineCount = textFileGrowthMetric(path: transcriptPath, fallbackLineCount: lines.count)
        let engine = AutoNamingEngine()
        guard let outcome = try? sessionStore.beginAutoNaming(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            transcriptLineCount: lineCount,
            now: Date(),
            engine: engine
        ) else { return nil }
        let baseline: Int
        switch outcome.decision {
        case .proceed(let value):
            baseline = value
        default:
            guard manual else {
                telemetry.breadcrumb("claude-hook.auto-name.throttled")
                return nil
            }
            baseline = lineCount
        }

        var confirmedTitle: String?
        defer {
            try? sessionStore.finishAutoNaming(
                sessionId: sessionId,
                appliedTitle: confirmedTitle,
                baselineLineCount: confirmedTitle != nil ? baseline : nil,
                now: Date()
            )
        }

        let messages = engine.extractMessages(fromTranscriptLines: lines)
        guard let context = engine.buildContext(from: messages) else {
            if manual { manualAutoNameLog.log("auto-name.pass.no-context session=\(sessionId, privacy: .public) lines=\(lines.count, privacy: .public)") }
            return nil
        }
        let prompt = engine.buildPrompt(currentTitle: outcome.lastTitle, context: context)

        let resolution = resolvedSummarizerAgent(
            probe: probe, sessionAgent: "claude", env: env, telemetry: telemetry
        )
        guard let rawResponse = summarize(
            summarizerAgent: resolution.agent,
            prompt: prompt,
            env: env,
            timeout: engine.config.llmTimeout,
            telemetry: telemetry
        ) else {
            telemetry.breadcrumb("claude-hook.auto-name.llm-failed")
            if manual { manualAutoNameLog.log("auto-name.pass.llm-failed session=\(sessionId, privacy: .public) agent=\(resolution.agent, privacy: .public)") }
            reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
            return nil
        }

        guard let sanitized = engine.sanitizeResponse(rawResponse, currentTitle: nil) else {
            if manual { manualAutoNameLog.log("auto-name.pass.sanitize-rejected session=\(sessionId, privacy: .public)") }
            return nil
        }
        confirmedTitle = applyAutoNamingTitle(
            sanitized,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            previousTitle: outcome.lastTitle,
            client: client,
            telemetryKey: "claude-hook.auto-name",
            telemetry: telemetry,
            manual: manual,
            panelOnly: panelOnly
        )
        // Re-report a missing override only after the fallback apply, so the
        // app's clear-on-apply doesn't immediately wipe the Settings note.
        if confirmedTitle != nil, let missing = resolution.missingOverride {
            reportAutoNamingProblem("not_installed", agent: missing, workspaceId: workspaceId, client: client)
        }
        return confirmedTitle
    }

    /// Transcript lookup by session id alone (`~/.claude/projects/*/<id>.jsonl`)
    /// for manual passes where the hook store has no record yet.
    static func claudeTranscriptPathBySessionId(_ sessionId: String) -> String? {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil
        ) else { return nil }
        var newest: (path: String, mtime: Date)?
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest!.mtime {
                newest = (candidate.path, mtime)
            }
        }
        return newest?.path
    }

    /// Manual workspace-wide naming: one panel-only pass per tab with an
    /// active session, then a workspace title synthesized from all tab names.
    /// Always resolves the sidebar's loading pill — failure is reported when
    /// nothing could be named.
    func runManualWorkspaceAutoName(
        actives: [(surfaceId: String, record: ClaudeHookSessionRecord)],
        parsedInput: ClaudeHookParsedInput,
        workspaceId: String,
        sessionStore: ClaudeHookSessionStore,
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry
    ) {
        manualAutoNameLog.log("auto-name.manual.start workspace=\(workspaceId, privacy: .public) tabs=\(actives.count, privacy: .public)")
        guard !actives.isEmpty else {
            telemetry.breadcrumb("claude-hook.auto-name.manual-no-active")
            manualAutoNameLog.log("auto-name.manual.no-active workspace=\(workspaceId, privacy: .public)")
            reportAutoNamingProblem("no_agent", agent: "claude", workspaceId: workspaceId, client: client)
            return
        }
        if actives.count == 1 {
            let entry = actives[0]
            let title = runClaudeAutoNameHook(
                parsedInput: parsedInput,
                mappedSession: entry.record,
                workspaceId: workspaceId,
                surfaceId: entry.surfaceId,
                sessionStore: sessionStore,
                client: client,
                telemetry: telemetry,
                manual: true
            )
            manualAutoNameLog.log("auto-name.manual.single applied=\(title != nil, privacy: .public) workspace=\(workspaceId, privacy: .public)")
            if title == nil {
                reportAutoNamingProblem("failed", agent: "claude", workspaceId: workspaceId, client: client)
            }
            return
        }

        var tabTitles: [String] = []
        for entry in actives {
            let title = runClaudeAutoNameHook(
                parsedInput: parsedInput,
                mappedSession: entry.record,
                workspaceId: workspaceId,
                surfaceId: entry.surfaceId,
                sessionStore: sessionStore,
                client: client,
                telemetry: telemetry,
                manual: true,
                panelOnly: true
            )
            manualAutoNameLog.log("auto-name.manual.tab surface=\(entry.surfaceId, privacy: .public) applied=\(title != nil, privacy: .public)")
            if let title {
                tabTitles.append(title)
            }
        }
        guard !tabTitles.isEmpty else {
            manualAutoNameLog.log("auto-name.manual.all-tabs-failed workspace=\(workspaceId, privacy: .public)")
            reportAutoNamingProblem("failed", agent: "claude", workspaceId: workspaceId, client: client)
            return
        }

        let env = ProcessInfo.processInfo.environment
        let engine = AutoNamingEngine()
        let probe = (try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        )) ?? [:]
        let resolution = resolvedSummarizerAgent(
            probe: probe, sessionAgent: "claude", env: env, telemetry: telemetry
        )
        let list = tabTitles.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        These terminal tabs run in one workspace:
        \(list)

        Respond with ONLY a 2-5 word name describing the workspace's overall work. No punctuation, no quotes, no explanation.
        """
        let synthesized = summarize(
            summarizerAgent: resolution.agent,
            prompt: prompt,
            env: env,
            timeout: engine.config.llmTimeout,
            telemetry: telemetry
        ).flatMap { engine.sanitizeResponse($0, currentTitle: nil) }
        // why: a failed synthesis still resolves the pill — first tab title stands in
        let workspaceTitle = synthesized ?? tabTitles[0]
        _ = applyAutoNamingTitle(
            workspaceTitle,
            workspaceId: workspaceId,
            surfaceId: nil,
            previousTitle: nil,
            client: client,
            telemetryKey: "claude-hook.auto-name.synthesis",
            telemetry: telemetry,
            manual: true
        )
    }

    /// Spawns a detached generic-agent auto-name pass via a bounded shell wrapper.
    func spawnDetachedAgentAutoName(
        def: AgentHookDef,
        sessionId: String,
        workspaceId: String,
        surfaceId: String,
        transcriptPath: String?,
        cwd: String?,
        env: [String: String],
        telemetry: CLISocketSentryTelemetry
    ) {
        let selfPath: String = {
            if let first = ProcessInfo.processInfo.arguments.first,
               first.hasPrefix("/"),
               FileManager.default.isExecutableFile(atPath: first) {
                return first
            }
            if let bundled = normalizedHookValue(env["CMUX_BUNDLED_CLI_PATH"]),
               FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
            return "cmux"
        }()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "\"$0\" hooks \"$1\" auto-name --session \"$2\" --workspace \"$3\" --surface \"$4\" --transcript \"$5\" --cwd \"$6\" </dev/null >/dev/null 2>&1 &",
            selfPath,
            def.name,
            sessionId,
            workspaceId,
            surfaceId,
            transcriptPath ?? "",
            cwd ?? ""
        ]
        var spawnEnv = env
        spawnEnv["CMUX_CLAUDE_HOOK_STATE_PATH"] = agentHookStatePath(sessionStoreSuffix: def.sessionStoreSuffix, env: env)
        process.environment = spawnEnv
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.spawn-failed")
            return
        }
        if ((try? waitForProcessExit(process, timeout: 2)) ?? false) == false {
            process.terminate()
            if ((try? waitForProcessExit(process, timeout: 1)) ?? false) == false {
                kill(process.processIdentifier, SIGKILL)
                _ = try? waitForProcessExit(process, timeout: 1)
            }
        }
    }

    /// Detached Codex naming pass.
    func runCodexAutoNameHook(
        commandArgs: [String],
        client: SocketClient,
        telemetry: CLISocketSentryTelemetry,
        env: [String: String]
    ) {
        guard let sessionId = optionValue(commandArgs, name: "--session"),
              let workspaceId = optionValue(commandArgs, name: "--workspace"),
              let surfaceId = optionValue(commandArgs, name: "--surface") else {
            return
        }
        guard let probe = try? client.sendV2(
            method: "workspace.set_auto_title",
            params: ["probe": true, "workspace_id": workspaceId]
        ), probe["enabled"] as? Bool == true else {
            telemetry.breadcrumb("codex-hook.auto-name.disabled")
            return
        }
        guard probe["workspace_user_owned"] as? Bool != true else {
            telemetry.breadcrumb("codex-hook.auto-name.user-owned")
            return
        }

        let sessionStore = ClaudeHookSessionStore(processEnv: env)
        guard (try? sessionStore.isCurrent(sessionId: sessionId, workspaceId: workspaceId, surfaceId: surfaceId)) ?? false else {
            telemetry.breadcrumb("codex-hook.auto-name.stale")
            return
        }
        let transcriptPath = normalizedHookValue(optionValue(commandArgs, name: "--transcript"))
            ?? findCodexTranscriptPath(sessionId: sessionId, env: env)
        guard let transcriptPath,
              let lines = readRecentTextFileLines(path: transcriptPath, maxBytes: 512 * 1024),
              !lines.isEmpty else {
            return
        }
        let resolution = resolvedSummarizerAgent(
            probe: probe, sessionAgent: "codex", env: env, telemetry: telemetry
        )
        runFileBackedAutoName(
            sessionId: sessionId,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            lines: lines,
            lineCount: textFileGrowthMetric(path: transcriptPath, fallbackLineCount: lines.count),
            sessionStore: sessionStore,
            client: client,
            missingOverride: resolution.missingOverride,
            telemetryKey: "codex-hook.auto-name",
            telemetry: telemetry
        ) { engine, outcome in
            let messages = engine.extractCodexMessages(fromRolloutLines: lines)
            guard let context = engine.buildContext(from: messages) else { return nil }
            let prompt = engine.buildPrompt(currentTitle: outcome.lastTitle, context: context)
            guard let raw = summarize(
                summarizerAgent: resolution.agent,
                prompt: prompt,
                env: env,
                timeout: engine.config.llmTimeout,
                telemetry: telemetry
            ) else {
                telemetry.breadcrumb("codex-hook.auto-name.llm-failed")
                reportAutoNamingProblem("failed", agent: resolution.agent, workspaceId: workspaceId, client: client)
                return nil
            }
            return raw
        }
    }
}
