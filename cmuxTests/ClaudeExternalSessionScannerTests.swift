import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ClaudeExternalSessionScannerTests: XCTestCase {

    private var sessionsDir: URL!

    override func setUpWithError() throws {
        sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sessionsDir)
    }

    private func writeSidecar(_ object: [String: Any], filename: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: sessionsDir.appendingPathComponent(filename))
    }

    /// Probes describing every pid as a live foreign claude.
    private func foreignClaudeProbes() -> ClaudeExternalSessionScanner.Probes {
        ClaudeExternalSessionScanner.Probes(processArguments: { _ in
            CmuxTopProcessArguments(arguments: ["node", "/usr/local/bin/claude"], environment: [:])
        })
    }

    func testScanFindsForeignInteractiveSession() throws {
        try writeSidecar(
            [
                "pid": 4242,
                "sessionId": "abc-123",
                "cwd": "/tmp/project",
                "startedAt": 1_783_400_000_000.0,
                "name": "my-agent",
                "kind": "interactive",
            ],
            filename: "4242.json"
        )
        let sessions = ClaudeExternalSessionScanner.scan(
            sessionsDirectory: sessionsDir,
            activeCmuxSessionIds: [],
            probes: foreignClaudeProbes()
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].pid, 4242)
        XCTAssertEqual(sessions[0].sessionId, "abc-123")
        XCTAssertEqual(sessions[0].cwd, "/tmp/project")
        XCTAssertEqual(sessions[0].name, "my-agent")
    }

    func testScanSkipsNonInteractiveTmpAndMalformed() throws {
        try writeSidecar(
            ["pid": 1, "sessionId": "print-run", "cwd": "/tmp", "kind": "print"],
            filename: "1.json"
        )
        try Data("not json".utf8).write(to: sessionsDir.appendingPathComponent("2.json"))
        try Data("{}".utf8).write(to: sessionsDir.appendingPathComponent("3.json"))
        // .tmp files are ignored regardless of contents.
        try writeSidecar(
            ["pid": 4, "sessionId": "tmp-file", "cwd": "/tmp", "kind": "interactive"],
            filename: "session.tmp"
        )
        let sessions = ClaudeExternalSessionScanner.scan(
            sessionsDirectory: sessionsDir,
            activeCmuxSessionIds: [],
            probes: foreignClaudeProbes()
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    func testScanSkipsCmuxOwnedProcesses() throws {
        try writeSidecar(
            ["pid": 77, "sessionId": "cmux-owned", "cwd": "/tmp", "kind": "interactive"],
            filename: "77.json"
        )
        let probes = ClaudeExternalSessionScanner.Probes(processArguments: { _ in
            CmuxTopProcessArguments(
                arguments: ["node", "/usr/local/bin/claude"],
                environment: ["CMUX_SURFACE_ID": "some-surface"]
            )
        })
        XCTAssertTrue(
            ClaudeExternalSessionScanner.scan(
                sessionsDirectory: sessionsDir,
                activeCmuxSessionIds: [],
                probes: probes
            ).isEmpty
        )
    }

    func testScanSkipsDeadOrRecycledPids() throws {
        try writeSidecar(
            ["pid": 88, "sessionId": "dead", "cwd": "/tmp", "kind": "interactive"],
            filename: "88.json"
        )
        // Dead pid: no args readable.
        let dead = ClaudeExternalSessionScanner.Probes(processArguments: { _ in nil })
        XCTAssertTrue(
            ClaudeExternalSessionScanner.scan(
                sessionsDirectory: sessionsDir, activeCmuxSessionIds: [], probes: dead
            ).isEmpty
        )
        // Recycled pid: alive but not claude.
        let recycled = ClaudeExternalSessionScanner.Probes(processArguments: { _ in
            CmuxTopProcessArguments(arguments: ["/usr/bin/vim"], environment: [:])
        })
        XCTAssertTrue(
            ClaudeExternalSessionScanner.scan(
                sessionsDirectory: sessionsDir, activeCmuxSessionIds: [], probes: recycled
            ).isEmpty
        )
    }

    func testScanSkipsSessionsActiveInCmux() throws {
        try writeSidecar(
            ["pid": 99, "sessionId": "already-here", "cwd": "/tmp", "kind": "interactive"],
            filename: "99.json"
        )
        let sessions = ClaudeExternalSessionScanner.scan(
            sessionsDirectory: sessionsDir,
            activeCmuxSessionIds: ["already-here"],
            probes: foreignClaudeProbes()
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    func testScanDedupesSameSessionIdKeepingNewest() throws {
        try writeSidecar(
            ["pid": 10, "sessionId": "dup", "cwd": "/a", "kind": "interactive", "startedAt": 1_000.0],
            filename: "10.json"
        )
        try writeSidecar(
            ["pid": 11, "sessionId": "dup", "cwd": "/b", "kind": "interactive", "startedAt": 2_000.0],
            filename: "11.json"
        )
        let sessions = ClaudeExternalSessionScanner.scan(
            sessionsDirectory: sessionsDir,
            activeCmuxSessionIds: [],
            probes: foreignClaudeProbes()
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].pid, 11)
    }

    func testTerminateSkipsWhenIdentityNoLongerMatches() {
        let session = ExternalClaudeSession(
            pid: 12345, sessionId: "s", cwd: "/tmp", name: nil, startedAt: nil
        )
        let recycled = ClaudeExternalSessionScanner.Probes(processArguments: { _ in
            CmuxTopProcessArguments(arguments: ["/usr/bin/vim"], environment: [:])
        })
        XCTAssertFalse(ClaudeExternalSessionScanner.terminateOriginal(session, probes: recycled))
    }
}
