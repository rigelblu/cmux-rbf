import CMUXAgentLaunch
import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-128.5 (Scenarios 15 and 77): a Claude Notification raises a state from its typed `notification_type` and from
/// nothing else. Words, a missing type and an unmapped type journal an observation and deliver nothing.
@Suite(.serialized)
struct ClaudeHookNotificationClassificationTests {
    private typealias Fixture = ClaudeHookAttentionTestFixture

    /// Runs one real `cmux hooks claude notification` and returns the journal drafts it sent, in order.
    private func notify(
        _ fixture: Fixture, type: String?, message: String = "Claude needs your attention"
    ) throws -> [AgentJournalEventDraft] {
        let before = fixture.context.state.snapshot().count
        var extra: [String: Any] = ["message": message]
        if let type { extra["notification_type"] = type }
        try fixture.run(["hooks", "claude", "notification"], event: "Notification", extra: extra)
        return fixture.context.state.snapshot().dropFirst(before).compactMap { line in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self,
                from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }
    }

    /// The reconciler's answer to every draft one hook sent: nothing may come back accepted or change a phase.
    private func expectNothingRaised(_ drafts: [AgentJournalEventDraft], _ fixture: Fixture, _ label: String) {
        #expect(!drafts.isEmpty, "\(label): the hook journaled nothing")
        for draft in drafts {
            #expect(draft.kind == .stateChanged, "\(label): journaled \(draft.kind) for words or an unmapped type")
            #expect(draft.declaredPhase == nil, "\(label): declared phase \(String(describing: draft.declaredPhase))")
            let decision = fixture.append(draft)
            #expect(decision.disposition == .observation, "\(label): reconciler said \(decision.disposition)")
            #expect(decision.notificationEvent == nil, "\(label): reconciler delivered a notification")
        }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0, "\(label): a wait opened")
    }

    // MARK: Scenario 15 — words never raise a state

    @Test(arguments: [
        ("a permission cue", "Claude needs your permission to use Bash"),
        ("a waiting cue", "Claude is waiting for your input"),
        ("a completion cue", "Task completed successfully"),
        ("an error cue", "Build failed: exit 1"),
    ])
    func noTypeWithWordsRaisesNothing(_ cue: (String, String)) throws {
        let fixture = try Fixture()
        expectNothingRaised(try notify(fixture, type: nil, message: cue.1), fixture, cue.0)
    }

    @Test(arguments: ["auth_success", "agent_completed", "plugin_notification"])
    func untypedKindsWithWordsRaiseNothing(_ type: String) throws {
        let fixture = try Fixture()
        for message in ["Claude needs your permission", "Task completed", "Build failed: exit 1", "Waiting for your input"] {
            expectNothingRaised(try notify(fixture, type: type, message: message), fixture, "\(type) / \(message)")
        }
    }

    @Test func permissionPromptAndIdlePromptStayTyped() throws {
        let fixture = try Fixture()
        let permission = try notify(fixture, type: "permission_prompt", message: "Claude needs your permission to use Bash")
        #expect(permission.contains { $0.kind == .approvalRequested })
        let idleFixture = try Fixture()
        let idle = try notify(idleFixture, type: "idle_prompt", message: "Claude is waiting for your input")
        #expect(idle.contains { $0.kind == .idleObserved })
    }

    // MARK: Scenario 77 — the typed form and input notifications

    @Test(arguments: ["elicitation_dialog", "elicitation_url_dialog"])
    func formTypesRaiseTheHandWithNoRequestId(_ type: String) throws {
        let fixture = try Fixture()
        let drafts = try notify(fixture, type: type, message: "Pick a database")
        #expect(drafts.contains { $0.kind == .questionRequested }, "kinds: \(drafts.map(\.kind))")
        #expect(drafts.allSatisfy { $0.attention?.requestIdentity == nil })
        let raising = drafts.filter { $0.kind == .questionRequested }
        #expect(raising.allSatisfy { $0.detail == type }, "the raising event must carry its notification_type in detail")
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        let notifications = raising.compactMap { $0.attention?.notification }
        let titled = try #require(notifications.first)
        #expect(titled.title.hasSuffix("Needs your answer"), "title \(titled.title)")
    }

    @Test(arguments: [
        ("elicitation_dialog", "elicitation_response"), ("elicitation_dialog", "elicitation_complete"),
        ("elicitation_url_dialog", "elicitation_response"), ("elicitation_url_dialog", "elicitation_complete"),
    ])
    func theAnsweredTypesEndTheFormsWait(_ pair: (String, String)) throws {
        let fixture = try Fixture()
        for draft in try notify(fixture, type: pair.0, message: "Pick a database") { fixture.append(draft) }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        let answer = try notify(fixture, type: pair.1, message: "Answered")
        let resolves = answer.filter { $0.kind == .attentionResolved }
        #expect(resolves.count >= 1, "kinds: \(answer.map(\.kind))")
        #expect(resolves.allSatisfy { $0.attention?.requestIdentity == nil && !$0.pendingWork && $0.detail == pair.1 })
        #expect(answer.allSatisfy { $0.kind == .attentionResolved })
        for draft in answer { fixture.append(draft) }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func theAnsweredTypeRetiresNothingWhileAPermissionNotificationWaits() throws {
        let fixture = try Fixture()
        for draft in try notify(fixture, type: "permission_prompt", message: "Claude needs your permission") { fixture.append(draft) }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        for type in ["elicitation_response", "elicitation_complete"] {
            for draft in try notify(fixture, type: type, message: "Answered") {
                let decision = fixture.append(draft)
                #expect(decision.invalidatedCorrelationKeys.isEmpty, "\(type) invalidated \(decision.invalidatedCorrelationKeys)")
            }
            #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1,
                    "\(type) retired a permission wait")
        }
    }

    @Test func theAnsweredTypeRetiresNothingWhileAFeedPermissionWaits() throws {
        let fixture = try Fixture()
        let wait = try fixture.permission()
        for type in ["elicitation_response", "elicitation_complete"] {
            for draft in try notify(fixture, type: type, message: "Answered") {
                let decision = fixture.append(draft)
                #expect(decision.invalidatedCorrelationKeys.isEmpty, "\(type) invalidated \(decision.invalidatedCorrelationKeys)")
            }
        }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").identified == [wait.id])
    }

    @Test func hisKeyInThePaneStillEndsAFormWait() throws {
        let fixture = try Fixture()
        for draft in try notify(fixture, type: "elicitation_dialog", message: "Pick a database") { fixture.append(draft) }
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        fixture.answerByKey()
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    /// F7: the gate category of a typed notification comes from its type, not from error words in its message.
    @Test(arguments: [("elicitation_dialog", "idle-reminder"), ("permission_prompt", "needs-permission")])
    func errorWordsInATypedMessageDoNotChangeItsGateCategory(_ pair: (String, String)) throws {
        let fixture = try Fixture()
        let drafts = try notify(fixture, type: pair.0, message: "the build failed, pick one")
        let candidates = drafts.compactMap { $0.attention?.notification }
        #expect(!candidates.isEmpty, "no notification candidate for \(pair.0)")
        #expect(candidates.allSatisfy { $0.category == pair.1 }, "\(pair.0): categories \(candidates.map(\.category))")
    }

    @Test(arguments: [
        "agent_needs_input", "auth_success", "agent_completed", "plugin_notification",
        "quota_auto_resume_scheduled", "quota_auto_resume_started", "quota_auto_resume_failed",
    ])
    func otherTypesAndNoTypeRaiseNoHand(_ type: String) throws {
        let fixture = try Fixture()
        expectNothingRaised(try notify(fixture, type: type, message: "Claude needs your input"), fixture, type)
    }
}
