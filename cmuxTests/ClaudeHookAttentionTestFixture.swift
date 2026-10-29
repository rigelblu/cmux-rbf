import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Darwin
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Private CLI/socket/session fixture shared by Claude lifecycle behavior tests.
final class ClaudeHookAttentionTestFixture: @unchecked Sendable {
    let support = CLINotifyProcessIntegrationRegressionTests()
    let context: CLINotifyProcessIntegrationRegressionTests.ClaudeHookContext
    var sequence: Int64 = 0
    var reconciler = AgentNotificationReconciler()

    init() throws {
        let root = URL(fileURLWithPath: "/private/tmp/c128-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let socket = root.appendingPathComponent("socket").path
        context = .init(cliPath: try support.bundledCLIPath(), socketPath: socket,
            listenerFD: try support.bindUnixSocket(at: socket), state: .init(), root: root,
            workspaceId: "11111111-1111-1111-1111-111111111111",
            surfaceId: "22222222-2222-2222-2222-222222222222")
        support.startAgentHookMockServerAccepting(context: context)
    }

    deinit {
        // cm-128.1: stop only our own accept loop. `tearDown()` calls `stopAll()`, which stops every other live
        // fixture's loop too, and the suites run at the same time: the 8 s hang and the refused connections.
        CLIMockAcceptLoopRegistry.shared.stop(listenerFD: context.listenerFD)
        context.cleanup()
    }

    var environment: [String: String] {
        ["HOME": context.root.path, "CFFIXED_USER_HOME": context.root.path,
         "PWD": context.root.path, "TMPDIR": context.root.path,
         "XDG_CONFIG_HOME": context.root.appendingPathComponent(".config").path,
         "CLAUDE_CONFIG_DIR": context.root.appendingPathComponent(".claude").path,
         "CMUX_AGENT_JOURNAL_DEAD_LETTER_PATH": context.root.appendingPathComponent("dead-letter.jsonl").path,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "CMUX_SOCKET_PATH": context.socketPath,
         "CMUX_WORKSPACE_ID": context.workspaceId, "CMUX_SURFACE_ID": context.surfaceId,
         "CMUX_CLAUDE_HOOK_STATE_PATH": context.root.appendingPathComponent("claude-hook-sessions.json").path,
         "CMUX_CLI_SENTRY_DISABLED": "1", "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1"]
    }

    /// Bounds every child through its termination callback, including SIGTERM grace.
    func waitForExit(_ process: Process, exited: DispatchSemaphore, timeout: TimeInterval = 8) throws {
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw NSError(domain: "ClaudeHookAttentionResolutionTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CLI did not exit within \(timeout)s; pid \(process.processIdentifier), still running after SIGTERM: \(process.isRunning)"])
        }
    }

    /// Runs only the built CLI with private configuration, state and socket roots.
    func process(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 8) throws
        -> CLINotifyProcessIntegrationRegressionTests.ProcessRunResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: context.cliPath)
        process.arguments = arguments
        process.environment = CLIChildEnvironment(appHostEnvironment: ProcessInfo.processInfo.environment).normalizing(environment)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = context.root
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        try waitForExit(process, exited: exited, timeout: timeout)
        return .init(status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            timedOut: false)
    }

    @discardableResult
    func run(_ arguments: [String], event: String, tool: String = "Bash",
             input: [String: String] = ["command": "sleep 20"], helper: String? = nil,
             toolID: String? = nil, extra: [String: Any] = [:]) throws -> String {
        var payload: [String: Any] = ["session_id": "session", "hook_event_name": event,
                                      "tool_name": tool, "tool_input": input]
        payload.merge(extra, uniquingKeysWith: { _, value in value })
        if let helper { payload["agent_id"] = helper }
        if let toolID { payload["tool_use_id"] = toolID }
        let json = try JSONSerialization.data(withJSONObject: payload)
        let result = try process(arguments, input: String(decoding: json, as: UTF8.self))
        #expect(!result.timedOut, "\(result.stderr)")
        #expect(result.status == 0, "\(result.stderr)")
        return result.stdout
    }

    func permission(tool: String = "Bash", input: [String: String] = ["command": "sleep 20"],
                    helper: String? = nil, extra: [String: Any] = [:]) throws -> (id: String, draft: AgentJournalEventDraft) {
        let before = context.state.snapshot().count
        try run(["hooks", "feed", "--source", "claude"], event: "PermissionRequest",
                tool: tool, input: input, helper: helper, extra: extra)
        let wire = try #require(context.state.snapshot().dropFirst(before).compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  frame["method"] as? String == "feed.push",
                  let params = frame["params"] as? [String: Any] else { return nil }
            return params["event"] as? [String: Any]
        }.first)
        let id = try #require(wire["_opencode_request_id"] as? String)
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        let draft = try #require(AgentFeedSemanticInput(event: event, agentKey: "claude_code",
            notification: AgentJournalNotification(title: "Claude", subtitle: "", body: "Approve", category: "needs-permission", correlationKey: id),
            workspaceID: UUID(uuidString: context.workspaceId), surfaceID: UUID(uuidString: context.surfaceId)).draft())
        append(draft)
        return (id, draft)
    }

    @discardableResult
    func append(_ draft: AgentJournalEventDraft) -> AgentNotificationDecision {
        sequence += 1
        return reconciler.apply(AgentJournalEvent(sequence: sequence, committedAtMs: sequence, draft: draft))
    }

    func answerByKey() {
        append(AgentJournalEventDraft(kind: .attentionResolved, occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            source: "claude", agentKey: "claude_code", sessionId: "session",
            workspaceId: context.workspaceId, surfaceId: context.surfaceId,
            nativeEvent: "PaneInput", attention: AgentAttentionContext()))
    }

    func completions(tool: String = "Bash", input: [String: String] = ["command": "sleep 20"],
                     helper: String? = nil) throws -> [AgentJournalEventDraft] {
        let before = context.state.snapshot().count
        try run(["hooks", "claude", "post-tool-use"], event: "PostToolUse", tool: tool, input: input, helper: helper)
        return context.state.snapshot().dropFirst(before).compactMap { line in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self, from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }.filter { $0.kind == .attentionResolved }
    }
}
