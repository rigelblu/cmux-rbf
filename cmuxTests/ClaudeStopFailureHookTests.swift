import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-128.5 (Scenarios 21 and 71): Claude's `StopFailure` is a turn that ended on an API error. One hook, one journal
/// event, one notification; the triangle and "Stopped on an error" come from that one signal.
@Suite(.serialized)
struct ClaudeStopFailureHookTests {
    private typealias Fixture = ClaudeHookAttentionTestFixture

    private static let documentedErrorTypes = [
        "rate_limit", "max_output_tokens", "server_error", "overloaded", "authentication_failed", "billing_error",
        "invalid_request", "model_not_found", "oauth_org_not_allowed", "account_on_hold", "cloud_credential_error",
        "unknown",
    ]

    /// Runs one real `cmux hooks claude stop-failure` and returns every journal draft it sent, in order.
    private func stopFailure(_ fixture: Fixture, error: String, extra: [String: Any] = [:]) throws -> [AgentJournalEventDraft] {
        let before = fixture.context.state.snapshot().count
        var payload: [String: Any] = ["error": error]
        payload.merge(extra, uniquingKeysWith: { _, value in value })
        try fixture.run(["hooks", "claude", "stop-failure"], event: "StopFailure", extra: payload)
        return fixture.context.state.snapshot().dropFirst(before).compactMap { line in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self,
                from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }
    }

    @Test func settingsCarryStopFailureQueuedWithAnEmptyMatcher() throws {
        let fixture = try Fixture()
        let result = try fixture.process(["hooks", "claude", "inject-settings"])
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: [[String: Any]]])
        let groups = try #require(hooks["StopFailure"], "no StopFailure hook in \(hooks.keys.sorted())")
        #expect(groups.count == 1)
        #expect((groups.first?["matcher"] as? String) == "")
        let commands = (groups.first?["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
        #expect(commands.contains { $0.contains("hooks enqueue claude stop-failure") }, "commands \(commands)")
    }

    @Test(arguments: documentedErrorTypes)
    func everyDocumentedErrorTypeJournalsOneErrorWithItsType(_ type: String) throws {
        let fixture = try Fixture()
        let drafts = try stopFailure(fixture, error: type, extra: ["last_assistant_message": "You've hit your session limit"])
        #expect(drafts.count == 1, "one event, not a bare event plus a notify command: kinds \(drafts.map(\.kind))")
        let draft = try #require(drafts.first)
        #expect(draft.kind == .errorReported)
        #expect(draft.nativeEvent == "StopFailure")
        #expect(draft.detail == type)
        #expect(!draft.isSubagent)
        #expect(draft.attention?.notification != nil)
    }

    @Test func theBodyIsTheMessageThenTheDetailsThenTheTypeOnOneLineCutAt180() throws {
        let fixture = try Fixture()
        let long = "first line\n" + String(repeating: "x", count: 300)
        let cases: [(extra: [String: Any], check: (String) -> Bool, label: String)] = [
            (["last_assistant_message": "You've hit your session limit · resets 12:10am", "error_details": "details"],
             { $0 == "You've hit your session limit · resets 12:10am" }, "the message wins"),
            (["error_details": "529 overloaded"], { $0 == "529 overloaded" }, "else the details"),
            ([:], { $0 == "server_error" }, "else the type"),
            (["last_assistant_message": long], { !$0.contains("\n") && $0.count <= 180 && $0.hasPrefix("first line") }, "one line, at most 180"),
        ]
        for entry in cases {
            let drafts = try stopFailure(fixture, error: "server_error", extra: entry.extra)
            let body = try #require(drafts.first?.attention?.notification?.body, "\(entry.label): no notification")
            #expect(entry.check(body), "\(entry.label): body \(body)")
        }
    }

    @Test func aHelpersStopFailureIsMarkedSubagentAndTheReconcilerDropsIt() throws {
        let fixture = try Fixture()
        let drafts = try stopFailure(fixture, error: "rate_limit", extra: ["agent_id": "helper-1"])
        let draft = try #require(drafts.first)
        #expect(draft.isSubagent)
        #expect(fixture.append(draft).disposition == .subagent)
    }

    /// The payload names no event, so the Feed event name comes from the subcommand alone (`feedEventName(forClaudeSubcommand:)`).
    @Test func aStopFailureThatNamesNoEventReachesFeedAsStopFailure() throws {
        let fixture = try Fixture()
        let before = fixture.context.state.snapshot().count
        let result = try fixture.process(["hooks", "claude", "stop-failure"], input: #"{"session_id":"session","error":"server_error"}"#)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let frames = fixture.context.state.snapshot().dropFirst(before).compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  frame["method"] as? String == "feed.push",
                  let params = frame["params"] as? [String: Any] else { return nil }
            return params["event"] as? [String: Any]
        }
        let event = try #require(frames.first, "no feed.push frame; trace: \(fixture.context.state.snapshot().dropFirst(before))")
        #expect(event["hook_event_name"] as? String == "StopFailure", "event \(event)")
    }

    @Test func oneStopFailureDeliversOneStoppedOnAnErrorNotificationAndAPromptEndsIt() throws {
        let fixture = try Fixture()
        _ = try fixture.run(["hooks", "claude", "prompt-submit"], event: "UserPromptSubmit")
        let drafts = try stopFailure(fixture, error: "rate_limit", extra: ["last_assistant_message": "Session limit reached"])
        let draft = try #require(drafts.first)
        let decision = fixture.append(draft)
        #expect(decision.disposition == .accepted, "disposition \(decision.disposition)")
        let title = try #require(draft.attention?.notification?.title)
        #expect(title == "Claude Code · Stopped on an error", "title \(title)")
        #expect(draft.attention?.notification?.category == "other")
        // The pane's lifecycle: the reconciler's projection keeps the error phase, and the same event asked for the sound.
        let lifecycle = fixture.reconciler.lifecycleEvent(AgentJournalEvent(sequence: fixture.sequence, committedAtMs: fixture.sequence, draft: draft))
        #expect(lifecycle.draft.kind == .errorReported)
        // A following prompt starts a turn and invalidates the delivered notification.
        let before = fixture.context.state.snapshot().count
        try fixture.run(["hooks", "claude", "prompt-submit"], event: "UserPromptSubmit")
        let started = fixture.context.state.snapshot().dropFirst(before).compactMap { line -> AgentJournalEventDraft? in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self, from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }.first { $0.kind == .turnStarted }
        let turn = try #require(started)
        #expect(!fixture.append(turn).invalidatedCorrelationKeys.isEmpty, "the prompt must remove the error notification")
    }
}
