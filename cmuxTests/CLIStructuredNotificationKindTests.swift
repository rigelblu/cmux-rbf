import CmuxAgentJournal
import Darwin
import XCTest

/// cm-128.5 (Scenarios 15, 79, 81, 84): a generic agent's notification raises a state from a typed field or from
/// cmux's own decision, never from the words in its message.
extension CLINotifyProcessIntegrationRegressionTests {
    private struct StructuredKindContext {
        let cliPath: String
        let socketPath: String
        let listenerFD: Int32
        let state: MockSocketServerState
        let root: URL
        let workspaceId: String
        let surfaceId: String
        let environment: [String: String]

        func cleanup() {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeStructuredKindContext(_ name: String) throws -> StructuredKindContext {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath(name)
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-\(name)-\(UUID().uuidString)", isDirectory: true)
        let workspaceId = "11111111-1111-1111-1111-111111111111"
        let surfaceId = "22222222-2222-2222-2222-222222222222"
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
            "GROK_HOME": root.appendingPathComponent("grok-home", isDirectory: true).path,
        ]
        startDetachedAgentHookMockServer(listenerFD: listenerFD, state: state, surfaceId: surfaceId)
        return StructuredKindContext(
            cliPath: cliPath, socketPath: socketPath, listenerFD: listenerFD, state: state, root: root,
            workspaceId: workspaceId, surfaceId: surfaceId, environment: environment)
    }

    /// Runs one real hook and returns what it sent over the socket, in order.
    @discardableResult
    private func runStructuredKindHook(
        _ context: StructuredKindContext, agent: String, _ subcommand: String, _ fields: [String: Any]
    ) throws -> [String] {
        var payload: [String: Any] = ["session_id": "structured-kind-session", "cwd": context.root.path]
        payload.merge(fields, uniquingKeysWith: { _, value in value })
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let before = context.state.snapshot().count
        let result = runProcess(
            executablePath: context.cliPath, arguments: ["hooks", agent, subcommand],
            environment: context.environment, standardInput: json, timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        return Array(context.state.snapshot().dropFirst(before))
    }

    private func journalDrafts(_ commands: [String]) -> [AgentJournalAppendCapture] {
        AgentJournalAppendCapture.captures(in: commands)
    }

    private func notifications(_ commands: [String]) -> [String] {
        commands.filter { $0.hasPrefix("notify_target_async ") }
    }

    private func statusCommands(_ commands: [String], agent: String) -> [String] {
        commands.filter { $0.hasPrefix("set_status \(agent) ") }
    }

    private func sessionRecord(_ context: StructuredKindContext, agent: String) throws -> [String: Any] {
        let storeURL = context.root.appendingPathComponent("\(agent)-hook-sessions.json", isDirectory: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: storeURL)) as? [String: Any])
        let sessions = try XCTUnwrap(json["sessions"] as? [String: Any])
        return try XCTUnwrap(sessions["structured-kind-session"] as? [String: Any])
    }

    // MARK: Scenarios 15 and 81 — words raise no state, no pill and no session record

    func testGenericAgentWordsNeverRaiseAStateOrAPing() throws {
        for (label, message) in [
            ("permission and error words", "Build failed: approval needed"),
            ("waiting words", "waiting for input"),
            ("completion words", "Turn complete in 1.2s."),
        ] {
            let context = try makeStructuredKindContext("structured-words")
            defer { context.cleanup() }
            try runStructuredKindHook(context, agent: "kimi", "session-start", ["hook_event_name": "SessionStart"])
            let commands = try runStructuredKindHook(
                context, agent: "kimi", "notification", ["hook_event_name": "Notification", "message": message])
            let drafts = journalDrafts(commands)
            XCTAssertFalse(drafts.isEmpty, "\(label): nothing journaled, saw \(commands)")
            for draft in drafts {
                XCTAssertEqual(draft.kind, "agent.state.changed", "\(label): journaled \(draft.kind ?? "nil"), saw \(commands)")
                XCTAssertNil(draft.draft["declared_phase"], "\(label): declared a phase, saw \(commands)")
            }
            XCTAssertTrue(notifications(commands).isEmpty, "\(label): delivered a ping, saw \(commands)")
        }
    }

    func testGenericAgentWordsWriteNoPillAndNoSessionRecord() throws {
        for (label, message) in [("error words", "Build failed: exit 1"), ("approval words", "approval needed"),
                                 ("completion words", "Turn complete in 1.2s.")] {
            let context = try makeStructuredKindContext("structured-pill")
            defer { context.cleanup() }
            try runStructuredKindHook(context, agent: "kimi", "session-start", ["hook_event_name": "SessionStart"])
            let commands = try runStructuredKindHook(
                context, agent: "kimi", "notification", ["hook_event_name": "Notification", "message": message])
            XCTAssertTrue(statusCommands(commands, agent: "kimi").isEmpty, "\(label): wrote a pill, saw \(commands)")
            let record = try sessionRecord(context, agent: "kimi")
            XCTAssertNil(record["lastNotificationStatus"], "\(label): wrote \(String(describing: record["lastNotificationStatus"]))")
            XCTAssertNotEqual(record["agentLifecycle"] as? String, "needsInput", "\(label): record reads needs input")
            XCTAssertNotEqual(record["runtimeStatus"] as? String, "error", "\(label): record reads an error runtime")
        }
    }

    func testGenericStructuredErrorStillWritesItsPillAndRecord() throws {
        let context = try makeStructuredKindContext("structured-error-pill")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "kimi", "session-start", ["hook_event_name": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "kimi", "notification",
            ["hook_event_name": "StopFailure", "message": "Rate limit reached"])
        XCTAssertTrue(
            journalDrafts(commands).contains { $0.kind == "agent.error.reported" },
            "A structured StopFailure must still journal an error, saw \(commands)")
        XCTAssertEqual(statusCommands(commands, agent: "kimi").filter { $0.contains("exclamationmark.triangle.fill") }.count, 1,
                       "A structured error keeps its pill until .6, saw \(commands)")
        let record = try sessionRecord(context, agent: "kimi")
        XCTAssertEqual(record["lastNotificationStatus"] as? String, "error")
    }

    // MARK: Scenario 79 — typed fields and cmux's own decisions

    func testGenericTypedNotificationTypeMapsPermissionAndIdle() throws {
        for (type, kind) in [("permission_prompt", "agent.approval.requested"), ("idle_prompt", "agent.idle.observed")] {
            let context = try makeStructuredKindContext("structured-typed")
            defer { context.cleanup() }
            try runStructuredKindHook(context, agent: "kimi", "session-start", ["hook_event_name": "SessionStart"])
            let commands = try runStructuredKindHook(
                context, agent: "kimi", "notification",
                ["hook_event_name": "Notification", "notification_type": type, "message": "Kimi needs a decision"])
            XCTAssertTrue(journalDrafts(commands).contains { $0.kind == kind },
                          "\(type) must journal \(kind), saw \(commands)")
        }
    }

    func testGenericTypedFormTypeRaisesAQuestionWithItsTypeInDetail() throws {
        let context = try makeStructuredKindContext("structured-form")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "kimi", "session-start", ["hook_event_name": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "kimi", "notification",
            ["hook_event_name": "Notification", "notification_type": "elicitation_dialog", "message": "Pick one"])
        let questions = journalDrafts(commands).filter { $0.kind == "agent.question.requested" }
        XCTAssertFalse(questions.isEmpty, "saw \(commands)")
        XCTAssertTrue(questions.allSatisfy { $0.draft["detail"] as? String == "elicitation_dialog" }, "saw \(commands)")
        let answer = try runStructuredKindHook(
            context, agent: "kimi", "notification",
            ["hook_event_name": "Notification", "notification_type": "elicitation_response", "message": "Answered"])
        let resolves = journalDrafts(answer)
        XCTAssertFalse(resolves.isEmpty)
        XCTAssertTrue(resolves.allSatisfy { $0.kind == "agent.attention.resolved" && $0.draft["detail"] as? String == "elicitation_response" },
                      "saw \(answer)")
    }

    /// Review follow-up: `.questionRequested` is the one kind `semanticNotificationCommand` leaves its category alone for, so the
    /// category from the kind is all that gates a typed form whose message has error words (else the meta is nil and it reads "other").
    func testGenericTypedFormWithErrorWordsStillGatesAsAnIdleReminder() throws {
        let context = try makeStructuredKindContext("structured-form-error-words")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "kimi", "session-start", ["hook_event_name": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "kimi", "notification",
            ["hook_event_name": "Notification", "notification_type": "elicitation_dialog", "message": "the build failed, pick one"])
        XCTAssertTrue(journalDrafts(commands).contains { $0.kind == "agent.question.requested" }, "saw \(commands)")
        let pings = notifications(commands)
        XCTAssertEqual(pings.count, 1, "saw \(commands)")
        XCTAssertTrue(pings.first?.contains("|c=idle-reminder;") == true, "saw \(pings)")
    }

    /// A typed kind must not be dropped as noise just because its words say nothing: grok's noise filter keeps only
    /// what no fact names.
    func testGrokTypedFormNotificationWithNeutralWordsStillRaisesTheQuestion() throws {
        let context = try makeStructuredKindContext("structured-grok-form")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "grok", "session-start", ["hookEventName": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "grok", "notification",
            ["hookEventName": "Notification", "notificationType": "elicitation_dialog", "message": "Pick one"])
        XCTAssertTrue(
            journalDrafts(commands).contains { $0.kind == "agent.question.requested" },
            "A typed form must raise the hand whatever its words say, saw \(commands)")
    }

    /// F1: Pi's real payload is `notification: {type: <stopReason>}`, usually `stop`, which no cue word matches. The
    /// ping's gate category comes from the kind (a fact), not from whether the assistant's message has a cue word.
    func testPiTurnEndWithACuelessMessageStillGatesAsATurnComplete() throws {
        let context = try makeStructuredKindContext("structured-pi-cueless")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "pi", "session-start", ["hook_event_name": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "pi", "notification",
            ["hook_event_name": "Notification", "message": "Refactored the parser", "notification": ["type": "stop"]])
        let pings = notifications(commands)
        XCTAssertEqual(pings.count, 1, "saw \(commands)")
        XCTAssertTrue(pings.first?.contains("|c=turn-complete;") == true, "saw \(pings)")
    }

    /// F1: error words in a Pi turn end must not make the ping ungated or lose `pending_work` on the notify append.
    func testPiTurnEndWithErrorWordsAndPendingWorkKeepsBothAppendsPending() throws {
        let context = try makeStructuredKindContext("structured-pi-failed-pending")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "pi", "session-start", ["hook_event_name": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "pi", "notification",
            ["hook_event_name": "Notification", "message": "the test failed", "notification": ["type": "stop"],
             "pending_work": true])
        let drafts = journalDrafts(commands)
        XCTAssertEqual(drafts.count, 2, "saw \(commands)")
        XCTAssertTrue(drafts.allSatisfy { $0.kind == "agent.turn.completed" && $0.pendingWork },
                      "both appends must be pending turn completions, saw \(commands)")
        XCTAssertFalse(notifications(commands).contains { $0.contains("p=0") }, "saw \(commands)")
    }

    func testPiTurnEndNotificationJournalsTurnCompletedAndPingsFinished() throws {
        let context = try makeStructuredKindContext("structured-pi")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "pi", "session-start", ["hook_event_name": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "pi", "notification",
            ["hook_event_name": "Notification", "message": "Refactor done", "notification": ["type": "completed"]])
        let drafts = journalDrafts(commands)
        XCTAssertFalse(drafts.isEmpty, "saw \(commands)")
        XCTAssertTrue(drafts.allSatisfy { $0.kind == "agent.turn.completed" }, "saw \(commands)")
        XCTAssertTrue(drafts.allSatisfy { !$0.pendingWork }, "saw \(commands)")
        let pings = notifications(commands)
        XCTAssertEqual(pings.count, 1, "saw \(commands)")
        XCTAssertTrue(pings.first?.contains("Finished") == true && pings.first?.contains("Pi") == true, "saw \(pings)")
    }

    func testPiTurnEndWithTypedPendingWorkKeepsBothAppendsPending() throws {
        let context = try makeStructuredKindContext("structured-pi-pending")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "pi", "session-start", ["hook_event_name": "SessionStart"])
        let commands = try runStructuredKindHook(
            context, agent: "pi", "notification",
            ["hook_event_name": "Notification", "message": "Refactor done", "notification": ["type": "completed"],
             "pending_work": true])
        let drafts = journalDrafts(commands)
        XCTAssertEqual(drafts.count, 2, "the bare event and the notify command's append, saw \(commands)")
        XCTAssertTrue(drafts.allSatisfy { $0.kind == "agent.turn.completed" && $0.pendingWork },
                      "both appends must be pending turn completions, saw \(commands)")
        // A pending Pi turn must not fold the session to idle on the notify command's append either.
        XCTAssertFalse(notifications(commands).contains { $0.contains("p=0") }, "saw \(commands)")
        // ... and it leaves no Idle pill and no idle record behind while the work is still running.
        XCTAssertFalse(statusCommands(commands, agent: "pi").contains { $0.contains(" Idle ") }, "saw \(commands)")
        let record = try sessionRecord(context, agent: "pi")
        XCTAssertEqual(record["agentLifecycle"] as? String, "running", "a pending Pi turn end must keep the record running")
    }

    func testGrokNotificationWordsRaiseNothingAndItsStopPingsOnce() throws {
        let context = try makeStructuredKindContext("structured-grok")
        defer { context.cleanup() }
        try runStructuredKindHook(context, agent: "grok", "session-start", ["hookEventName": "SessionStart"])
        let notification = try runStructuredKindHook(
            context, agent: "grok", "notification",
            ["hookEventName": "Notification", "message": "Turn complete in 3.8s."])
        XCTAssertTrue(journalDrafts(notification).allSatisfy { $0.kind == "agent.state.changed" }, "saw \(notification)")
        XCTAssertTrue(notifications(notification).isEmpty, "a grok Notification's words must deliver nothing, saw \(notification)")
        // cwd is set and there is no assistant message: the case that pinged nowhere once the words were cut.
        let stop = try runStructuredKindHook(context, agent: "grok", "stop", ["hookEventName": "Stop"])
        XCTAssertTrue(journalDrafts(stop).contains { $0.kind == "agent.turn.completed" }, "saw \(stop)")
        let pings = notifications(stop)
        XCTAssertEqual(pings.count, 1, "saw \(stop)")
        XCTAssertTrue(pings.first?.contains("Grok · Finished") == true && pings.first?.contains("Task completed") == true,
                      "saw \(pings)")
    }

    // MARK: Scenario 84 — a structured error event that routes to a Stop

    func testRovoDevOnErrorStopJournalsAnErrorOnBothAppendsAndPingsOnce() throws {
        let context = try makeStructuredKindContext("structured-rovo-error")
        defer { context.cleanup() }
        let commands = try runStructuredKindHook(
            context, agent: "rovodev", "stop",
            ["hook_event_name": "on_error", "last_assistant_message": "Model unavailable"])
        let drafts = journalDrafts(commands)
        XCTAssertEqual(drafts.count, 2, "the bare event and the ping's append, saw \(commands)")
        XCTAssertTrue(drafts.allSatisfy { $0.kind == "agent.error.reported" },
                      "neither append may carry turnCompleted, saw \(drafts.map { $0.kind ?? "nil" })")
        let record = try sessionRecord(context, agent: "rovodev")
        XCTAssertEqual(record["lastNotificationStatus"] as? String, "error")
        let pings = notifications(commands)
        XCTAssertEqual(pings.count, 1, "saw \(commands)")
        XCTAssertTrue(pings.first?.contains("Rovo Dev · Stopped on an error") == true, "saw \(pings)")
        XCTAssertTrue(pings.first?.contains("Model unavailable") == true, "saw \(pings)")
        XCTAssertFalse(pings.contains { $0.contains("Completed") || $0.contains("Task completed") }, "saw \(pings)")
        // The reconciler's session phase ends at error, not idle (the pane's triangle is Scenario 23's). An idle
        // reminder is refused on an error session (`.delayed`) and settles on an idle one (`.observation`).
        var reconciler = AgentNotificationReconciler()
        var newest: Int64 = 0
        for (index, capture) in drafts.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: capture.draft)
            let draft = try JSONDecoder().decode(AgentJournalEventDraft.self, from: data)
            newest = max(newest, draft.occurredAtMs)
            _ = reconciler.apply(AgentJournalEvent(sequence: Int64(index + 1), committedAtMs: Int64(index + 1), draft: draft))
        }
        let probe = AgentJournalEventDraft(
            kind: .idleObserved, occurredAtMs: newest + 1_000, source: "rovodev", agentKey: "rovodev",
            sessionId: "structured-kind-session", workspaceId: context.workspaceId, surfaceId: context.surfaceId)
        let decision = reconciler.apply(AgentJournalEvent(sequence: 99, committedAtMs: 99, draft: probe))
        XCTAssertEqual(decision.disposition, .delayed, "the session phase must end at error, not idle")
    }

    func testRovoDevOnErrorWithoutAMessageSaysItStoppedOnAnError() throws {
        let context = try makeStructuredKindContext("structured-rovo-error-bare")
        defer { context.cleanup() }
        let commands = try runStructuredKindHook(context, agent: "rovodev", "stop", ["hook_event_name": "on_error"])
        let pings = notifications(commands)
        XCTAssertEqual(pings.count, 1, "saw \(commands)")
        XCTAssertTrue(pings.first?.contains("Rovo Dev stopped on an error") == true, "saw \(pings)")
        XCTAssertFalse(pings.contains { $0.contains("Task completed") }, "saw \(pings)")
    }

    func testRovoDevOnCompleteStillJournalsTurnCompletedAndPingsCompleted() throws {
        let context = try makeStructuredKindContext("structured-rovo-complete")
        defer { context.cleanup() }
        let commands = try runStructuredKindHook(
            context, agent: "rovodev", "stop",
            ["hook_event_name": "on_complete", "last_assistant_message": "Remote Rovo completed"])
        let drafts = journalDrafts(commands)
        XCTAssertEqual(drafts.count, 2, "saw \(commands)")
        XCTAssertTrue(drafts.allSatisfy { $0.kind == "agent.turn.completed" }, "saw \(commands)")
        XCTAssertEqual(notifications(commands).count, 1, "saw \(commands)")
        let record = try sessionRecord(context, agent: "rovodev")
        XCTAssertEqual(record["lastNotificationStatus"] as? String, "idle")
    }
}
