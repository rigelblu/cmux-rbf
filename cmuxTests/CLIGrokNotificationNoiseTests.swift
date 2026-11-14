import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    // cmux-rbf: changed on purpose (#cm-128.5): a grok Notification's words raise no state and no ping, so repeated
    // waiting words have nothing to dedupe. The structured grok ping comes from its Stop.
    func testGrokWaitingWordsRaiseNothingEvenWhenRepeated() throws {
        let context = try makeGrokNoiseContext(name: "grok-wait-words")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let firstStart = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))

        let commands = Array(context.state.snapshot().dropFirst(firstStart))
        XCTAssertEqual(notifyCommands(in: commands).count, 0, "Waiting words must not ping, saw \(commands)")
        XCTAssertTrue(
            AgentJournalAppendCapture.captures(in: commands).allSatisfy { $0.kind == "agent.state.changed" },
            "Waiting words must journal an observation only, saw \(commands)"
        )
    }

    // cmux-rbf: changed on purpose (#cm-128.5): the rebuilt-from-stored-summary Notification carries no typed field
    // either, so it raises and pings nothing, however many times it arrives.
    func testGrokUnclassifiedFallbackRebuildRaisesNothing() throws {
        let context = try makeGrokNoiseContext(name: "grok-fallback-gate", sessionId: nil)
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "Grok needs permission to run rm"))
        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))

        let fallbackStart = context.state.snapshot().count
        let unclassified = grokUnclassifiedPayload(context)
        try runGrokNoiseHook(context, "notification", payload: unclassified)
        try runGrokNoiseHook(context, "notification", payload: unclassified)

        let commands = Array(context.state.snapshot().dropFirst(fallbackStart))
        XCTAssertEqual(notifyCommands(in: commands).count, 0, "A words-only fallback re-notification must not ping, saw \(commands)")
        XCTAssertFalse(
            AgentJournalAppendCapture.captures(in: commands).contains { $0.kind != "agent.state.changed" },
            "A words-only fallback re-notification must journal an observation only, saw \(commands)"
        )
    }

    // cmux-rbf: changed on purpose (#cm-128.5): the notifications ping nothing; the one completion is the Stop's, and
    // an incidental completion cue after it still does not re-ding.
    func testGrokIncidentalCompletionCueAfterTheStopDoesNotReding() throws {
        let context = try makeGrokNoiseContext(name: "grok-incidental")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "Turn complete in 1.2s."))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "waiting for input"))
        XCTAssertEqual(notifyCommands(in: Array(context.state.snapshot().dropFirst(start))).count, 0, "The words must not ping")
        try runGrokNoiseHook(context, "stop", payload: grokNoisePayload(context, event: "Stop"))
        try runGrokNoiseHook(context, "notification", payload: grokNoisePayload(context, event: "Notification", message: "All done reviewing the files you asked about"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "Only the Stop should ping, saw \(notifications)")
        // cmux-rbf: changed on purpose (#cm-128.4): source line and working folder.
        XCTAssertEqual(notifications.filter { $0.contains("Grok · Finished|\(context.root.lastPathComponent)|") }.count, 1, notifications.joined(separator: "\n"))
    }

    // cmux-rbf: changed on purpose (#cm-128.5): the notifications ping nothing, a SessionStart refire changes nothing,
    // and the completion is the one the Stop sends.
    func testGrokSessionStartRefireDoesNotAddACompletionPing() throws {
        let context = try makeGrokNoiseContext(name: "grok-start-refire")
        defer { context.cleanup() }

        let startPayload = grokNoisePayload(context, event: "SessionStart")
        let completionPayload = grokNoisePayload(context, event: "Notification", message: "Turn complete in 1.2s.")
        try runGrokNoiseHook(context, "session-start", payload: startPayload)
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: completionPayload)
        try runGrokNoiseHook(context, "session-start", payload: startPayload)
        try runGrokNoiseHook(context, "notification", payload: completionPayload)
        XCTAssertEqual(notifyCommands(in: Array(context.state.snapshot().dropFirst(start))).count, 0, "The words must not ping")
        try runGrokNoiseHook(context, "stop", payload: grokNoisePayload(context, event: "Stop"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 1, "Only the Stop should ping, saw \(notifications)")
    }

    func testGrokRepeatedIdenticalPermissionPromptsDedupePerTurn() throws {
        let context = try makeGrokNoiseContext(name: "grok-permission")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        let permissionPrompt = grokPermissionPromptPayload(context)
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)

        let firstTurnNotifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(firstTurnNotifications.count, 1, "Repeated identical permission prompts should dedupe per turn, saw \(firstTurnNotifications)")
        XCTAssertTrue(
            firstTurnNotifications.first?.contains("|c=needs-permission;p=0") == true,
            firstTurnNotifications.joined(separator: "\n")
        )

        try runGrokNoiseHook(context, "prompt-submit", payload: grokNoisePayload(context, event: "UserPromptSubmit"))
        try runGrokNoiseHook(context, "notification", payload: permissionPrompt)

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 2, "Prompt submit should re-arm permission prompt delivery for the next turn, saw \(notifications)")
        XCTAssertTrue(notifications.allSatisfy { $0.contains("|c=needs-permission;p=0") }, notifications.joined(separator: "\n"))
        XCTAssertTrue(notifications.allSatisfy { $0.contains(";s=needsInput") }, notifications.joined(separator: "\n"))
    }

    func testGrokDistinctPermissionPromptsAlwaysDeliver() throws {
        let context = try makeGrokNoiseContext(name: "grok-distinct-permission")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: grokNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to run rm"))
        try runGrokNoiseHook(context, "notification", payload: grokPermissionPromptPayload(context, message: "Grok needs permission to edit config.yaml"))

        let notifications = notifyCommands(in: Array(context.state.snapshot().dropFirst(start)))
        XCTAssertEqual(notifications.count, 2, "Distinct permission prompts should each deliver, saw \(notifications)")
        XCTAssertTrue(notifications.allSatisfy { $0.contains("|c=needs-permission;p=0") }, notifications.joined(separator: "\n"))
        XCTAssertTrue(notifications.allSatisfy { $0.contains(";s=needsInput") }, notifications.joined(separator: "\n"))
    }

    // cmux-rbf: changed on purpose (#cm-128.5): the mapper has no agy `notification` arm, so its kind came only from
    // the shared word fallback, which .5 cuts. The words now raise no error and no error ping (agy's typed error is .7's).
    func testAntigravityErrorWordsRaiseNoErrorPing() throws {
        let context = try makeGrokNoiseContext(name: "antigravity-error", agent: "antigravity")
        defer { context.cleanup() }

        try runGrokNoiseHook(context, "session-start", payload: antigravityNoisePayload(context, event: "SessionStart"))
        let start = context.state.snapshot().count
        try runGrokNoiseHook(context, "notification", payload: antigravityNoisePayload(context, event: "Notification", message: "Build failed: exit 1"))

        let commands = Array(context.state.snapshot().dropFirst(start))
        XCTAssertTrue(notifyCommands(in: commands).isEmpty, "Error words must not ping, saw \(commands)")
        XCTAssertFalse(
            AgentJournalAppendCapture.captures(in: commands).contains { $0.kind == "agent.error.reported" },
            "Error words must not journal an error, saw \(commands)"
        )
    }

    private struct GrokNoiseContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String
        let sessionId: String
        let agent: String
        let environment: [String: String]

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeGrokNoiseContext(
        name: String,
        agent: String = "grok",
        sessionId requestedSessionId: String? = "grok-noise-session"
    ) throws -> GrokNoiseContext {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
        let sessionId = requestedSessionId ?? surfaceId
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment: [String: String] = [
            "HOME": root.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "PWD": root.path,
            "CMUX_SOCKET_PATH": socketPath,
            "CMUX_WORKSPACE_ID": workspaceId,
            "CMUX_SURFACE_ID": surfaceId,
            "CMUX_AGENT_HOOK_STATE_DIR": root.path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "GROK_HOME": grokHome.path,
        ]

        startDetachedAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId)
        return GrokNoiseContext(
            cliPath: cliPath,
            socketPath: socketPath,
            listenerFD: listenerFD,
            state: state,
            root: root,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            sessionId: sessionId,
            agent: agent,
            environment: environment
        )
    }

    private func runGrokNoiseHook(_ context: GrokNoiseContext, _ subcommand: String, payload: String) throws {
        let result = runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", context.agent, subcommand],
            environment: context.environment,
            standardInput: payload,
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "{}\n")
    }

    private func grokNoisePayload(_ context: GrokNoiseContext, event: String, message: String? = nil) -> String {
        notificationNoisePayload(sessionKey: "sessionId", context: context, eventKey: "hookEventName", event: event, message: message)
    }

    private func grokPermissionPromptPayload(
        _ context: GrokNoiseContext,
        message: String = "Tool permission requested"
    ) -> String {
        #"{"hookEventName":"notification","sessionId":"\#(context.sessionId)","cwd":"\#(context.root.path)","notificationType":"permission_prompt","message":"\#(message)","level":"info"}"#
    }

    private func antigravityNoisePayload(_ context: GrokNoiseContext, event: String, message: String? = nil) -> String {
        notificationNoisePayload(sessionKey: "session_id", context: context, eventKey: "hook_event_name", event: event, message: message)
    }

    private func grokUnclassifiedPayload(_ context: GrokNoiseContext) -> String {
        #"{"sessionId":"\#(context.sessionId)","cwd":"\#(context.root.path)","unparseable":true}"#
    }

    private func notificationNoisePayload(
        sessionKey: String,
        context: GrokNoiseContext,
        eventKey: String,
        event: String,
        message: String?
    ) -> String {
        var fields = [
            #""\#(sessionKey)":"\#(context.sessionId)""#,
            #""cwd":"\#(context.root.path)""#,
            #""\#(eventKey)":"\#(event)""#,
        ]
        if let message {
            fields.append(#""message":"\#(message)""#)
        }
        return "{\(fields.joined(separator: ","))}"
    }

    private func notifyCommands(in commands: [String]) -> [String] {
        commands.filter { $0.hasPrefix("notify_target_async ") }
    }
}
