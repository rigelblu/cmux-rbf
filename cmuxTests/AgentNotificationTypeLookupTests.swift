import CmuxAgentJournal
import Foundation
import Testing

/// cm-124.5: a typed notification's meaning comes from the table, on Claude's own handler and on the generic route.
/// Each test runs the real built CLI against a mock app that answers `agent_events.rows` and reconciles every journal
/// append with the real reconciler and receipts, so a banner shows here only when the app would deliver it.
@Suite(.serialized)
struct AgentNotificationTypeLookupTests {
    private typealias Fixture = ClaudeHookAttentionTestFixture
    private let marker = "notification-type:"

    private struct Sent {
        let drafts: [AgentJournalEventDraft]
        /// Each delivered banner as `[title, subtitle, body, meta]`.
        let banners: [[String]]
        let commands: [String]
        let seconds: TimeInterval

        var rowFetches: Int { commands.filter { $0.contains("\"method\":\"agent_events.rows\"") }.count }
    }

    /// Runs one real `cmux hooks <agent> <subcommand>` and returns what it sent, in order.
    @discardableResult
    private func hook(
        _ fixture: Fixture, agent: String = "claude", subcommand: String = "notification",
        _ fields: [String: Any]
    ) throws -> Sent {
        var payload: [String: Any] = ["session_id": "session", "cwd": fixture.context.root.path]
        payload.merge(fields, uniquingKeysWith: { _, value in value })
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let before = fixture.context.state.snapshot().count
        let started = Date()
        let result = try fixture.process(["hooks", agent, subcommand], input: json)
        let seconds = Date().timeIntervalSince(started)
        #expect(result.status == 0, "\(result.stderr)")
        let commands = Array(fixture.context.state.snapshot().dropFirst(before))
        let drafts = commands.compactMap { line -> AgentJournalEventDraft? in
            guard line.hasPrefix("agent_journal_append ") else { return nil }
            return try? JSONDecoder().decode(AgentJournalEventDraft.self,
                from: Data(line.dropFirst("agent_journal_append ".count).utf8))
        }
        let banners = commands.compactMap { line -> [String]? in
            let prefix = "notify_target_async "
            guard line.hasPrefix(prefix) else { return nil }
            let rest = line.dropFirst(prefix.count).split(separator: " ", maxSplits: 2).map(String.init)
            guard rest.count == 3 else { return nil }
            return rest[2].components(separatedBy: "|")
        }
        return Sent(drafts: drafts, banners: banners, commands: commands, seconds: seconds)
    }

    private func notify(_ fixture: Fixture, agent: String = "claude", type: String?, message: String? = nil,
                        event: String = "Notification") throws -> Sent {
        var fields: [String: Any] = ["hook_event_name": event]
        if let type { fields["notification_type"] = type }
        if let message { fields["message"] = message }
        return try hook(fixture, agent: agent, fields)
    }

    private func register(_ fixture: Fixture, agent: String, camelCase: Bool = false) throws {
        try hook(fixture, agent: agent, subcommand: "session-start",
                 camelCase ? ["hookEventName": "SessionStart", "sessionId": "session"] : ["hook_event_name": "SessionStart"])
    }

    private func feed(_ fixture: Fixture, _ drafts: [AgentJournalEventDraft]) {
        for draft in drafts { fixture.append(draft) }
    }

    private func rows(_ fixture: Fixture, _ rows: [[String: String]], delay: TimeInterval = 0) {
        fixture.context.state.setAgentEventRows(rows, delay: delay)
    }

    private func row(_ agent: String, _ type: String, _ means: String) -> [String: String] {
        ["agent": agent, "notification": type, "means": means]
    }

    // MARK: an unmapped type pings once, with the agent's own words

    @Test func anUnmappedClaudeTypeIsMarkedAndPingsOnceWithTheRawMessageAndRaisesNoHand() throws {
        let fixture = try Fixture()
        let type = "worker_permission_prompt"
        let first = try notify(fixture, type: type, message: "A worker wants to run Bash in cm-124.5")
        #expect(!first.drafts.isEmpty)
        #expect(first.drafts.allSatisfy { $0.kind == .stateChanged && $0.detail == marker + type },
                "drafts: \(first.drafts.map { "\($0.kind) \($0.detail ?? "nil")" })")
        #expect(first.banners.count == 1, "banners: \(first.banners)")
        let banner = try #require(first.banners.first)
        #expect(banner[0] == "Claude Code · New notification type: worker_permission_prompt", "title \(banner[0])")
        #expect(banner[1] == fixture.context.root.lastPathComponent, "subtitle is the working folder: \(banner[1])")
        #expect(banner[2] == "A worker wants to run Bash in cm-124.5")
        #expect(banner[3].contains("c=other") && banner[3].contains("p=0"), "meta \(banner[3])")
        feed(fixture, first.drafts)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0, "a hand rose")

        let second = try notify(fixture, type: type, message: "A worker wants to run Bash again")
        #expect(second.banners.isEmpty, "pinged twice: \(second.banners)")
        #expect(second.drafts.allSatisfy { $0.detail == marker + type }, "the second one is still recorded")
    }

    @Test func anUnmappedTypeKeepsItsRawMessageWhateverWordsItHolds() throws {
        let fixture = try Fixture()
        let result = try notify(fixture, type: "cm124_words_type", message: "Build failed: approval needed")
        let banner = try #require(result.banners.first, "no banner: \(result.commands)")
        #expect(banner[2] == "Build failed: approval needed")
        #expect(banner[3].contains("c=other"), "the words picked a gate: \(banner[3])")
    }

    @Test func anUnmappedTypeWithNoMessageGivesNoBannerSpendsNoPingAndNeverReusesASavedBody() throws {
        let fixture = try Fixture()
        // A saved body from an earlier needs-input event, which the old code reused for any empty message.
        let saved = try notify(fixture, type: "permission_prompt", message: "Claude needs your permission to use Bash")
        feed(fixture, saved.drafts)
        let type = "agent_needs_input"
        let silent = try notify(fixture, type: type)
        #expect(silent.banners.isEmpty, "a banner without a message of its own: \(silent.banners)")
        #expect(silent.commands.filter { $0.hasPrefix("agent_journal_append ") }.allSatisfy { !$0.contains("Approval needed") })
        #expect(silent.drafts.contains { $0.detail == marker + type }, "the type is still recorded")
        let later = try notify(fixture, type: type, message: "Claude has a question")
        #expect(later.banners.count == 1, "the ping was spent: \(later.banners)")
        #expect(later.banners.first?[2] == "Claude has a question")
    }

    @Test(arguments: ["push_notification", "auth_success", "agent_completed", "computer_use_enter"])
    func anInformationalTypeGivesNoBannerAndNoMarker(type: String) throws {
        let fixture = try Fixture()
        let result = try notify(fixture, type: type, message: "Something happened")
        #expect(result.banners.isEmpty, "banners: \(result.banners)")
        #expect(result.drafts.allSatisfy { $0.detail == nil && $0.kind == .stateChanged })
    }

    @Test func aNotificationWithNoTypeStaysSilentAndUnmarked() throws {
        let fixture = try Fixture()
        let result = try notify(fixture, type: nil, message: "Claude needs your attention")
        #expect(result.banners.isEmpty)
        #expect(result.drafts.allSatisfy { $0.detail == nil })
    }

    // MARK: his rows

    @Test func hisApprovalRowRaisesTheHandWithTodaysApprovalBanner() throws {
        let fixture = try Fixture()
        rows(fixture, [row("claude", "worker_permission_prompt", "approval")])
        let result = try notify(fixture, type: "worker_permission_prompt", message: "A worker wants to run Bash")
        #expect(result.drafts.contains { $0.kind == .approvalRequested }, "kinds \(result.drafts.map(\.kind))")
        #expect(result.drafts.allSatisfy { $0.detail == nil })
        #expect(result.banners.first?[3].contains("c=needs-permission") == true, "banners \(result.banners)")
        #expect(result.banners.first?[0].contains("New notification type") == false, "a mapped type keeps today's approval title")
        feed(fixture, result.drafts)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
    }

    @Test func hisQuestionRowRaisesTheHandAndHisResolvedRowRetiresIt() throws {
        let fixture = try Fixture()
        rows(fixture, [row("claude", "x_asked", "question"), row("claude", "x_answered", "resolved")])
        let asked = try notify(fixture, type: "x_asked", message: "Pick one")
        #expect(asked.drafts.contains { $0.kind == .questionRequested && $0.detail == marker + "x_asked" })
        #expect(asked.banners.first?[3].contains("c=idle-reminder") == true, "banners \(asked.banners)")
        feed(fixture, asked.drafts)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        let answered = try notify(fixture, type: "x_answered", message: "Answered")
        #expect(answered.drafts.allSatisfy { $0.kind == .attentionResolved && $0.detail == marker + "x_answered" })
        #expect(answered.banners.isEmpty)
        feed(fixture, answered.drafts)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func hisResolvedRowNeverRetiresAWaitingApproval() throws {
        let fixture = try Fixture()
        rows(fixture, [row("claude", "x_answered", "resolved")])
        feed(fixture, try notify(fixture, type: "permission_prompt", message: "Claude needs your permission").drafts)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        feed(fixture, try notify(fixture, type: "x_answered", message: "Answered").drafts)
        #expect(fixture.reconciler.openRequests(source: "claude", sessionId: "session").count == 1, "an approval retired")
    }

    @Test func hisIgnoreRowSilencesAnIdlePromptAndDeletingItBringsTodayBack() throws {
        let fixture = try Fixture()
        rows(fixture, [row("claude", "idle_prompt", "ignore")])
        let ignored = try notify(fixture, type: "idle_prompt", message: "Claude is waiting for your input")
        #expect(ignored.drafts.allSatisfy { $0.kind == .stateChanged && $0.detail == nil }, "kinds \(ignored.drafts.map(\.kind))")
        #expect(ignored.banners.isEmpty)
        rows(fixture, [])
        let back = try notify(fixture, type: "idle_prompt", message: "Claude is waiting for your input")
        #expect(back.drafts.contains { $0.kind == .idleObserved }, "kinds \(back.drafts.map(\.kind))")
    }

    @Test func hisExactAgentRowBeatsHisStarRow() throws {
        let fixture = try Fixture()
        rows(fixture, [row("*", "idle_prompt", "ignore"), row("claude", "idle_prompt", "question")])
        let result = try notify(fixture, type: "idle_prompt", message: "Claude is waiting for your input")
        #expect(result.drafts.contains { $0.kind == .questionRequested }, "kinds \(result.drafts.map(\.kind))")
    }

    // MARK: when the rows are fetched

    @Test func theRowsAreFetchedOnceForATypedNotificationAndNeverWhenNothingNeedsThem() throws {
        let fixture = try Fixture()
        rows(fixture, [])
        #expect(try notify(fixture, type: "worker_permission_prompt", message: "x").rowFetches == 1)
        #expect(try notify(fixture, type: nil, message: "no type").rowFetches == 0, "fetched with no type")
        let declared = try hook(fixture, ["hook_event_name": "QuestionAsked", "request_id": "r-1",
                                          "notification_type": "idle_prompt", "message": "Declared ask"])
        #expect(declared.rowFetches == 0, "fetched for a declared wait")
        try register(fixture, agent: "kimi")
        let mapperDecided = try notify(fixture, agent: "kimi", type: "worker_permission_prompt", message: "x",
                                       event: "StopFailure")
        #expect(mapperDecided.rowFetches == 0, "fetched where the mapper had already decided the kind")
    }

    @Test func aSlowAppNeverHoldsTheHookAndItFallsBackToTheBuiltInRows() throws {
        let fixture = try Fixture()
        rows(fixture, [row("claude", "worker_permission_prompt", "approval")], delay: 3)
        let result = try notify(fixture, type: "worker_permission_prompt", message: "A worker wants to run Bash")
        #expect(result.seconds < 1.0, "the hook waited \(result.seconds)s for a 3 s answer")
        #expect(result.drafts.allSatisfy { $0.kind == .stateChanged && $0.detail == marker + "worker_permission_prompt" },
                "used his row it never received: \(result.drafts.map(\.kind))")
        #expect(result.banners.count == 1)
    }

    @Test func anAppThatDoesNotKnowTheMethodFallsBackToTheBuiltInRows() throws {
        let fixture = try Fixture()
        let result = try notify(fixture, type: "permission_prompt", message: "Claude needs your permission")
        #expect(result.rowFetches == 1)
        #expect(result.drafts.contains { $0.kind == .approvalRequested })
    }

    // MARK: the generic route

    @Test func anUnmappedKimiTypePingsOnceUnderItsOwnNameAndClaudeGetsItsOwnFirstTime() throws {
        let fixture = try Fixture()
        try register(fixture, agent: "kimi")
        let type = "cm124_kimi_type"
        let first = try notify(fixture, agent: "kimi", type: type, message: "Kimi found something")
        #expect(first.drafts.allSatisfy { $0.kind == .stateChanged && $0.detail == marker + type },
                "drafts: \(first.drafts.map { "\($0.kind) \($0.detail ?? "nil")" })")
        #expect(first.banners.count == 1, "banners: \(first.banners)")
        #expect(first.banners.first?[2] == "Kimi found something")
        #expect(first.banners.first?[0].hasSuffix("· New notification type: cm124_kimi_type") == true, "title \(first.banners.first?[0] ?? "nil")")
        #expect(first.banners.first?[3].contains("c=other") == true)
        feed(fixture, first.drafts)
        #expect(fixture.reconciler.openRequests(source: "kimi", sessionId: "session").count == 0)
        #expect(try notify(fixture, agent: "kimi", type: type, message: "Again").banners.isEmpty)
        #expect(try notify(fixture, type: type, message: "Claude says the same").banners.count == 1, "Claude's own first time")
    }

    @Test func anUnmappedKimiTypeKeepsItsRawMessageAndNeverTheSavedBody() throws {
        let fixture = try Fixture()
        try register(fixture, agent: "kimi")
        feed(fixture, try notify(fixture, agent: "kimi", type: "permission_prompt", message: "Kimi needs a decision").drafts)
        let silent = try notify(fixture, agent: "kimi", type: "cm124_kimi_type")
        #expect(silent.banners.isEmpty, "banners: \(silent.banners)")
        #expect(silent.drafts.contains { $0.detail == marker + "cm124_kimi_type" })
    }

    // R2: his row says this type asks, so antigravity's word-based skips (a "waiting" message while it reports background
    // work, `fullyIdle: false`) can't swallow it, as they can't swallow a declared ask.
    // "Waiting for your review" reads as an idle nag and "Task completed ..." as a turn end: each has its own skip.
    @Test(arguments: [("approval", AgentJournalEventKind.approvalRequested, "c=needs-permission", "Waiting for your review"),
                      ("question", AgentJournalEventKind.questionRequested, "c=idle-reminder", "Waiting for your review"),
                      ("approval", AgentJournalEventKind.approvalRequested, "c=needs-permission", "Task completed, please review the result"),
                      ("question", AgentJournalEventKind.questionRequested, "c=idle-reminder", "Task completed, which branch next?")])
    func hisAskingRowSurvivesAntigravitysWordBasedSkips(means: String, kind: AgentJournalEventKind, gate: String,
                                                        message: String) throws {
        let fixture = try Fixture()
        try register(fixture, agent: "antigravity")
        rows(fixture, [row("antigravity", "build_ready", means)])
        let result = try hook(fixture, agent: "antigravity", [
            "hook_event_name": "Notification", "notification_type": "build_ready",
            "message": message, "fullyIdle": false,
        ])
        #expect(result.drafts.contains { $0.kind == kind }, "kinds \(result.drafts.map(\.kind))")
        #expect(result.banners.first?[3].contains(gate) == true, "banners \(result.banners)")
        feed(fixture, result.drafts)
        #expect(fixture.reconciler.openRequests(source: "antigravity", sessionId: "session").count == 1, "no hand rose")
    }

    // The exemption is his row's only. A built-in `question` row keeps today's result, which the words decide: measured on the
    // base build (cm-124.5, 2026-11-17), antigravity's `elicitation_dialog` with a "waiting" message and background work
    // journals two `agent.state.changed` rows and raises nothing.
    @Test func aBuiltInQuestionRowKeepsTodaysAntigravityWordSkip() throws {
        let fixture = try Fixture()
        try register(fixture, agent: "antigravity")
        let result = try hook(fixture, agent: "antigravity", [
            "hook_event_name": "Notification", "notification_type": "elicitation_dialog",
            "message": "Waiting for your review", "fullyIdle": false,
        ])
        #expect(!result.drafts.isEmpty)
        #expect(result.drafts.allSatisfy { $0.kind == .stateChanged }, "kinds \(result.drafts.map(\.kind))")
        feed(fixture, result.drafts)
        #expect(fixture.reconciler.openRequests(source: "antigravity", sessionId: "session").count == 0, "a hand rose")
    }

    @Test func hisKimiRowRaisesAnApprovalAndLeavesClaudeAlone() throws {
        let fixture = try Fixture()
        try register(fixture, agent: "kimi")
        rows(fixture, [row("kimi", "cm124_kimi_type", "approval")])
        let kimi = try notify(fixture, agent: "kimi", type: "cm124_kimi_type", message: "Kimi wants to run a command")
        #expect(kimi.drafts.contains { $0.kind == .approvalRequested }, "kinds \(kimi.drafts.map(\.kind))")
        #expect(kimi.banners.first?[3].contains("c=needs-permission") == true, "banners \(kimi.banners)")
        let claude = try notify(fixture, type: "cm124_kimi_type", message: "Claude sends it too")
        #expect(claude.drafts.allSatisfy { $0.kind == .stateChanged }, "kinds \(claude.drafts.map(\.kind))")
    }

    @Test func grokUnmappedTypeInItsRealCamelCaseShapePingsEvenWithNoStatusCue() throws {
        let fixture = try Fixture()
        try register(fixture, agent: "grok", camelCase: true)
        let result = try hook(fixture, agent: "grok", [
            "hookEventName": "notification", "sessionId": "session", "notificationType": "cm124_grok_type",
            "message": "Grok wants a look", "level": "info",
        ])
        // The emit row and the banner row both carry the marker: the unmapped type is journaled before grok's skip.
        #expect(result.drafts.filter { $0.detail == marker + "cm124_grok_type" }.count == 2,
                "journaled \(result.drafts.map { $0.detail ?? "nil" }): \(result.commands)")
        #expect(result.banners.count == 1, "banners: \(result.banners) commands: \(result.commands)")
        #expect(result.banners.first?[2] == "Grok wants a look")
        #expect(result.banners.first?[0].hasSuffix("· New notification type: cm124_grok_type") == true, "title \(result.banners.first?[0] ?? "nil")")
    }
}
