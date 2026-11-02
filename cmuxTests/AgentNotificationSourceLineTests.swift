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
struct AgentNotificationSourceLineTests {
    @Test(arguments: [("claude", "Claude Code"), ("opencode", "OpenCode"), ("hermes-agent", "Hermes Agent"), ("mycustomagent", "Mycustomagent")])
    func feedQuestionUsesOneDisplayNameAndTheAgentsWords(_ source: String, _ name: String) throws {
        let event = WorkstreamEvent(sessionId: "session", hookEventName: .askUserQuestion,
            source: source, cwd: "/work/cm-128", toolName: "AskUserQuestion",
            toolInputJSON: #"{"questions":[{"question":"Which branch?","options":[]}]}"#)
        let content = try #require(FeedCoordinator.notificationContent(for: event))
        #expect(content.title == "\(name) · Needs your answer")
        #expect(content.subtitle == "cm-128")
        #expect(content.body == "Which branch?")
    }

    @Test(arguments: [
        ("Bash", #"{"command":"swift test\n--parallel"}"#, "Bash · swift test --parallel"),
        ("Edit", #"{"file_path":"/work/a.swift","old_string":"secret old contents","new_string":"secret new contents"}"#, "Edit · /work/a.swift"),
        ("Write", #"{"file_path":"/work/a.swift","content":"secret file contents"}"#, "Write · /work/a.swift"),
        ("Read", #"{"file_path":"/work/a.swift"}"#, "Read · /work/a.swift"),
        ("WebFetch", #"{"url":"https://example.com/guide","prompt":"secret instructions"}"#, "WebFetch · https://example.com/guide")
    ])
    func feedPermissionUsesOnlyItsToolAndTarget(_ tool: String, _ input: String, _ expected: String) throws {
        let content = try #require(FeedCoordinator.notificationContent(for: .init(sessionId: "session",
            hookEventName: .permissionRequest, source: "claude", cwd: "/work/cm-128",
            toolName: tool, toolInputJSON: input)))
        #expect(content.title == "Claude Code · Needs your approval")
        #expect(content.subtitle == "cm-128")
        #expect(content.body == expected)
        #expect(!content.body.contains("secret"))
    }

    @Test(arguments: [WorkstreamEvent.HookEventName.askUserQuestion, .exitPlanMode, .permissionRequest])
    func feedBodiesCollapseAndCutAt180(_ eventName: WorkstreamEvent.HookEventName) throws {
        let text = "First line\n" + String(repeating: "x", count: 200)
        let input: [String: Any]
        switch eventName {
        case .askUserQuestion: input = ["questions": [["question": text, "options": []]]]
        case .exitPlanMode: input = ["plan": text]
        default: input = ["command": text]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        let content = try #require(FeedCoordinator.notificationContent(for: .init(sessionId: "session",
            hookEventName: eventName, source: "claude", toolName: "Bash", toolInputJSON: json)))
        let expected = (eventName == .permissionRequest ? "Bash · " : "") + text.replacingOccurrences(of: "\n", with: " ")
        #expect(content.body == String(expected.prefix(177)) + "...")
        #expect(content.body.count == 180)
        #expect(!content.body.contains("\n"))
        #expect(content.subtitle.isEmpty)
        if eventName == .exitPlanMode { #expect(content.title == "Claude Code · Needs your answer") }
    }

    @Test func missingToolFieldsKeepTheExistingFallbackWithoutLeakingContents() throws {
        let content = try #require(FeedCoordinator.notificationContent(for: .init(sessionId: "session",
            hookEventName: .permissionRequest, source: "claude", toolName: "Edit",
            toolInputJSON: #"{"content":"secret file contents"}"#)))
        #expect(content.body == "Edit needs approval")
    }

    @Test(arguments: ["claude", "codex"], [
        ("Permission", "approval", "Needs your approval"),
        ("Waiting", "waiting for input", "Needs your answer"),
        ("Error", "error", "Stopped on an error"),
        ("Completed", "completed", "Finished")
    ])
    func hookClassifierTokensStillChooseTheirCategories(_ source: String, _ input: (String, String, String)) throws {
        let (token, message, kind) = input
        let fixture = try ClaudeHookAttentionTestFixture()
        try fixture.run(["hooks", source, "notification"], event: "Notification",
            extra: ["cwd": "/work/cm-128", "message": message])
        let draft = try #require(fixture.context.state.snapshot().compactMap { line -> AgentJournalEventDraft? in
            let prefix = "agent_journal_append "
            guard line.hasPrefix(prefix) else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self, from: Data(line.dropFirst(prefix.count).utf8))
        }.last { $0.attention?.notification != nil })
        let notification = try #require(draft.attention?.notification)
        let name = source == "claude" ? "Claude Code" : "Codex"
        #expect(notification.title == "\(name) · \(kind)")
        #expect(notification.subtitle == "cm-128")
        let category = token == "Permission" ? "needs-permission" : token == "Waiting" ? "idle-reminder" : token == "Completed" ? "turn-complete" : "other"
        #expect(notification.category == category)
    }

    @Test func pushNotificationKeepsTheBareNameAndGetsTheFolder() throws {
        let fixture = try ClaudeHookAttentionTestFixture()
        try fixture.run(["hooks", "claude", "push-notification"], event: "PostToolUse",
            tool: "PushNotification", input: ["message": "My own message"],
            extra: ["cwd": "/work/cm-128", "tool_response": ["localSent": true]])
        let draft = try #require(fixture.context.state.snapshot().compactMap { line -> AgentJournalEventDraft? in
            let prefix = "agent_journal_append "
            guard line.hasPrefix(prefix) else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self, from: Data(line.dropFirst(prefix.count).utf8))
        }.last { $0.kind == .messagePublished })
        let notification = try #require(draft.attention?.notification)
        #expect(notification.title == "Claude Code")
        #expect(notification.subtitle == "cm-128")
        #expect(notification.body == "My own message")
    }

}
