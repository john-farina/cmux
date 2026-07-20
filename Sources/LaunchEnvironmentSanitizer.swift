import Darwin
import Foundation

/// fork: makes any launch path safe for terminal spawning. The app's env is
/// inherited by every restored/spawned shell, so two launcher mistakes are
/// fatal to all terminals at once:
/// - session-scoped vars leaked from an agent shell (`CLAUDE*`, pane-scoped
///   `CMUX_*`) make resumed claudes think they're nested children — they
///   glitch and exit, leaving dead panes
/// - an over-stripped env (`env -i … open`) drops `SHELL`/`USER`/`TMPDIR` and
///   shells fail to spawn at all
/// Sanitizing once at process start covers Dock, `open`, promote/revert
/// scripts, and DEV reloads alike.
enum LaunchEnvironmentSanitizer {
    /// Session-scoped `CMUX_*` vars a launching pane/agent shell would carry.
    /// Deliberate launch config (tag, codesign, test flags) is NOT listed.
    /// CMUX_PORT* stay: DEBUG builds read them for the dev auth origin.
    private static let paneScopedCmuxKeys: Set<String> = [
        "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID",
        "CMUX_SOCKET", "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD",
        "CMUX_CLAUDE_PID", "CMUX_SHELL_INTEGRATION_DIR",
        "CMUX_BUNDLED_CLI_PATH", "CMUX_DEBUG_LOG_PATH",
    ]

    private static let strippablePrefixes = [
        "CLAUDE", "ANTHROPIC", "CMUX_CLAUDE_HOOK_", "CMUX_CODEX_WRAPPER_SHIM",
        "CMUX_CLAUDE_WRAPPER_SHIM",
    ]

    static func keysToStrip(in environment: [String: String]) -> [String] {
        environment.keys.filter { key in
            if paneScopedCmuxKeys.contains(key) { return true }
            return strippablePrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// Basics a stripped launcher may have dropped; every value is derivable
    /// from the user record or libc, so shells always spawn.
    static func missingBasics(
        in environment: [String: String],
        home: String? = nil,
        shell: String? = nil,
        user: String? = nil,
        temporaryDirectory: String? = nil
    ) -> [String: String] {
        var restored: [String: String] = [:]
        let passwd = getpwuid(getuid())
        let resolvedHome = home ?? passwd.flatMap { String(cString: $0.pointee.pw_dir) }
        let resolvedShell = shell ?? passwd.flatMap { String(cString: $0.pointee.pw_shell) }
        let resolvedUser = user ?? passwd.flatMap { String(cString: $0.pointee.pw_name) }
        if environment["HOME"]?.isEmpty != false, let resolvedHome { restored["HOME"] = resolvedHome }
        if environment["SHELL"]?.isEmpty != false, let resolvedShell { restored["SHELL"] = resolvedShell }
        if environment["USER"]?.isEmpty != false, let resolvedUser { restored["USER"] = resolvedUser }
        if environment["LOGNAME"]?.isEmpty != false, let resolvedUser { restored["LOGNAME"] = resolvedUser }
        if environment["TMPDIR"]?.isEmpty != false {
            let tmp = temporaryDirectory ?? darwinUserTempDir()
            if let tmp { restored["TMPDIR"] = tmp }
        }
        return restored
    }

    /// Applies both passes to the real process environment. Call once, as
    /// early as possible, before anything snapshots the environment.
    static func sanitizeProcessEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        for key in keysToStrip(in: environment) {
            unsetenv(key)
        }
        for (key, value) in missingBasics(in: environment) {
            setenv(key, value, 1)
        }
    }

    private static func darwinUserTempDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return nil }
        return String(cString: buffer)
    }
}
