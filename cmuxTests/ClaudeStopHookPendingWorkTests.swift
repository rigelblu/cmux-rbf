import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct ClaudeStopHookPendingWorkTests {
    private typealias Fixture = ClaudeHookAttentionTestFixture

    private func journalDrafts(_ lines: ArraySlice<String>) -> [AgentJournalEventDraft] {
        lines.compactMap { line in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self,
                from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }
    }

    @Test(arguments: [false, true])
    func stopUsesOnlyBackgroundWorkForBothJournalWritesPillAndFallback(pending: Bool) throws {
        let fixture = try Fixture()
        try fixture.run(["hooks", "claude", "session-start"], event: "SessionStart")
        try fixture.run(["hooks", "claude", "prompt-submit"], event: "UserPromptSubmit")
        let before = fixture.context.state.snapshot().count
        let tasks: [[String: Any]] = pending ? [["type": "shell", "status": "running", "id": "job"]] : []
        try fixture.run(["hooks", "claude", "stop"], event: "Stop", extra: [
            "stop_hook_active": true, "background_tasks": tasks, "last_assistant_message": "Done"
        ])
        let lines = fixture.context.state.snapshot().dropFirst(before)
        let drafts = journalDrafts(lines)
        let stops = drafts.filter { $0.kind == .turnCompleted }
        #expect(stops.count == 2)
        #expect(stops.allSatisfy { $0.pendingWork == pending })
        #expect(stops.filter { $0.attention?.notification != nil }.count == 1)
        #expect(!drafts.contains { $0.kind == .stateChanged && $0.declaredPhase == .running })
        #expect(lines.contains { $0.hasPrefix("set_status claude_code \(pending ? "Running" : "Idle") ") })
        let record = try fixture.support.readClaudeHookSession("session", context: fixture.context)
        #expect(record["agentLifecycle"] as? String == (pending ? "running" : "idle"))
    }

    @Test func everyClaudePromptCarriesItsOwnEventIdentityWithoutANativeTurn() throws {
        let fixture = try Fixture()
        try fixture.run(["hooks", "claude", "session-start"], event: "SessionStart")
        for prompt in ["typed-prompt", "automatic-drain-prompt"] {
            let before = fixture.context.state.snapshot().count
            try fixture.run(["hooks", "claude", "prompt-submit"], event: "UserPromptSubmit",
                extra: ["prompt_id": prompt])
            let start = try #require(journalDrafts(fixture.context.state.snapshot().dropFirst(before))
                .first { $0.kind == .turnStarted })
            #expect(start.attention?.eventIdentity == prompt)
            #expect(start.attention?.turnIdentity == nil)
        }
    }

    @Test(arguments: ["SubagentStart", "SubagentStop", "PreToolUse"])
    func helperIdentityTravelsThroughFeedOnlyForChildLifecycle(nativeEvent: String) throws {
        let fixture = try Fixture()
        try fixture.run(["hooks", "feed", "--source", "claude"], event: nativeEvent, helper: "helper-1",
            extra: ["agent_type": "general-purpose"])
        let wire = try #require(fixture.context.state.snapshot().compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  frame["method"] as? String == "feed.push",
                  let params = frame["params"] as? [String: Any] else { return nil }
            return params["event"] as? [String: Any]
        }.first)
        #expect(wire["helper_agent_id"] as? String == "helper-1")
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        let isChild = nativeEvent != "PreToolUse"
        let draft = try #require(AgentFeedSemanticInput(event: event, agentKey: "claude_code",
            notification: isChild ? nil : AgentJournalNotification(title: "Claude", subtitle: "", body: "Approve",
                category: "needs-permission"), requestID: "feed-request",
            workspaceID: UUID(uuidString: fixture.context.workspaceId),
            surfaceID: UUID(uuidString: fixture.context.surfaceId)).draft())
        #expect(draft.attention?.requestIdentity == (isChild ? "helper-1" : "feed-request"))
        if isChild {
            #expect(draft.kind == (nativeEvent == "SubagentStart" ? .childSpawned : .childCompleted))
        }
    }

    private func idleEvents(_ fixture: Fixture) throws -> [AgentJournalEventDraft] {
        let before = fixture.context.state.snapshot().count
        try fixture.run(["hooks", "claude", "notification"], event: "Notification",
            extra: ["notification_type": "idle_prompt", "message": "Waiting for your input"])
        let events = fixture.context.state.snapshot().dropFirst(before).compactMap { line -> AgentJournalEventDraft? in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self,
                from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }.filter { $0.kind == .idleObserved }
        #expect(!events.isEmpty)
        return events
    }

    private func stoppedSession(_ fixture: Fixture) throws {
        try fixture.run(["hooks", "claude", "session-start"], event: "SessionStart")
        try fixture.run(["hooks", "claude", "prompt-submit"], event: "UserPromptSubmit")
        try fixture.run(["hooks", "claude", "stop"], event: "Stop", extra: ["last_assistant_message": "Done"])
    }

    @Test(arguments: [("prompt-submit", "UserPromptSubmit"), ("pre-tool-use", "PreToolUse")])
    func activitySinceLastStopMakesIdleReminderPending(activity: (String, String)) throws {
        let fixture = try Fixture()
        try stoppedSession(fixture)
        try fixture.run(["hooks", "claude", activity.0], event: activity.1,
            extra: ["tool_input": ["command": "sleep 60", "run_in_background": true]])
        let events = try idleEvents(fixture)
        #expect(events.allSatisfy { $0.pendingWork })
        var reconciler = AgentNotificationReconciler()
        let reset = AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: events.first?.occurredAtMs ?? 0,
            source: "claude", agentKey: "claude_code", sessionId: "session",
            workspaceId: fixture.context.workspaceId, surfaceId: fixture.context.surfaceId,
            nativeEvent: "PaneInput", declaredPhase: .unknown)
        _ = reconciler.apply(AgentJournalEvent(sequence: 1, committedAtMs: 1, draft: reset))
        let idle = AgentJournalEvent(sequence: 2, committedAtMs: 2, draft: try #require(events.first))
        #expect(reconciler.apply(idle).disposition == .delayed)
        #expect(reconciler.lifecycleEvent(idle).draft.declaredPhase == .unknown)
    }

    /// cm-128.1: a fresh session waiting at its first prompt has nothing pending, so its first `idle_prompt` is a
    /// settled reminder, as at base. The Stop cache is nil there too, and nil must mean only "activity since the last Stop".
    @Test func idlePromptRightAfterSessionStartIsNotPending() throws {
        let fixture = try Fixture()
        try fixture.run(["hooks", "claude", "session-start"], event: "SessionStart")
        let events = try idleEvents(fixture)
        #expect(events.allSatisfy { !$0.pendingWork })
        let idle = try #require(events.first)
        #expect(fixture.append(idle).disposition != .delayed)
    }

    /// cm-128.1: a session cmux has no record of (it started before the hooks were installed) gives no evidence of
    /// activity, so its idle prompt is a settled reminder too.
    @Test func idlePromptForASessionWithNoRecordIsNotPending() throws {
        let fixture = try Fixture()
        #expect(try idleEvents(fixture).allSatisfy { !$0.pendingWork })
    }

    /// cm-128.1: a `compact` SessionStart continues the same session mid-turn. With work running (the cache is nil
    /// after a tool call) it must not read as "nothing pending", or an idle prompt after compaction looks settled.
    @Test func compactSessionStartKeepsTheActivityCache() throws {
        let fixture = try Fixture()
        try fixture.run(["hooks", "claude", "session-start"], event: "SessionStart")
        try fixture.run(["hooks", "claude", "pre-tool-use"], event: "PreToolUse")
        try fixture.run(["hooks", "claude", "session-start"], event: "SessionStart", extra: ["source": "compact"])
        #expect(try idleEvents(fixture).allSatisfy { $0.pendingWork })
    }

    @Test func realStopKeepsRepeatedIdleRemindersSettled() throws {
        let fixture = try Fixture()
        try stoppedSession(fixture)
        for _ in 0..<2 {
            #expect(try idleEvents(fixture).allSatisfy { !$0.pendingWork })
        }
    }

    @Test(arguments: [false, true])
    func sessionStartCapturesEditorModeWithProjectPrecedence(projectOverride: Bool) throws {
        let fixture = try Fixture()
        let user = fixture.context.root.appendingPathComponent(".claude")
        let project = fixture.context.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"editorMode":"vim"}"#.write(to: user.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        if projectOverride {
            let config = project.appendingPathComponent(".claude")
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            try #"{"editorMode":"default"}"#.write(to: config.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        }
        try fixture.run(["hooks", "claude", "session-start"], event: "SessionStart", extra: ["cwd": project.path])
        let record = try fixture.support.readClaudeHookSession("session", context: fixture.context)
        #expect(record["editorMode"] as? String == (projectOverride ? "default" : "vim"))
    }
}
