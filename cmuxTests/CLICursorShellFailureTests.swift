import CmuxAgentJournal
import Darwin
import XCTest

/// cm-128.5 (Scenario 74): a failed Cursor shell command is the agent's work, so it never raises the error row.
/// It restores Running: `.turnStarted`, the blue Running pill, a running session record (Tom, grill Q39).
extension CLINotifyProcessIntegrationRegressionTests {
    func testCursorShellFailureThatIsNotADenialShowsRunningNotAnError() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("cursor-shell-failure")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cursor-shell-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = "cursor-shell-failure-session"
        let environment: [String: String] = [
            "HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath, "CMUX_WORKSPACE_ID": workspaceId, "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path, "CMUX_CLI_SENTRY_DISABLED": "1",
        ]
        // An allowlist config makes an unsandboxed command outside it a pending approval: the failure then resolves it.
        let cursorDirectory = root.appendingPathComponent(".cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "approvalMode": "allowlist"], options: [.sortedKeys])
            .write(to: cursorDirectory.appendingPathComponent("cli-config.json"), options: .atomic)
        startDetachedAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId)

        func run(_ subcommand: String, _ json: String) {
            let result = runProcess(executablePath: cliPath, arguments: ["hooks", "cursor", subcommand],
                environment: environment, standardInput: json, timeout: 5)
            XCTAssertFalse(result.timedOut, result.stderr)
            XCTAssertEqual(result.status, 0, result.stderr)
        }
        run("prompt-submit", #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"beforeSubmitPrompt"}"#)
        run("shell-exec", #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"beforeShellExecution","command":"rm -rf build-output","sandbox":false}"#)
        let start = state.snapshot().count
        run("shell-failed", #"{"session_id":"\#(sessionId)","cwd":"\#(root.path)","hook_event_name":"postToolUseFailure","tool_use_id":"tool-1","tool_name":"Shell","tool_input":{"command":"rm -rf build-output","cwd":"\#(root.path)"},"error_message":"Command exited 1","failure_type":"error","sandbox":false}"#)
        let commands = Array(state.snapshot().dropFirst(start))
        let drafts = AgentJournalAppendCapture.captures(in: commands)
        XCTAssertFalse(drafts.contains { $0.kind == "agent.error.reported" }, "a failed tool must not journal an error, saw \(commands)")
        XCTAssertTrue(drafts.contains { $0.kind == "agent.turn.started" }, "a failed shell takes the finished shell's path (running), saw \(commands)")
        XCTAssertFalse(commands.contains { $0.hasPrefix("set_status cursor ") && $0.contains("exclamationmark.triangle") },
                       "no red error pill, saw \(commands)")
        XCTAssertTrue(commands.contains { $0.hasPrefix("set_status cursor Running") }, "the blue Running pill, saw \(commands)")
        let storeURL = root.appendingPathComponent("cursor-hook-sessions.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let record = try XCTUnwrap((json["sessions"] as? [String: Any])?[sessionId] as? [String: Any])
        XCTAssertNotEqual(record["runtimeStatus"] as? String, "error", "the record must read running, not an error runtime")
        XCTAssertNotEqual(record["agentLifecycle"] as? String, "needsInput")
    }
}
