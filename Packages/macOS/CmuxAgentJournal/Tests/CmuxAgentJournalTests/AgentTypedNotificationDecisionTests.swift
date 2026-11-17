import Testing
@testable import CmuxAgentJournal

/// cm-124.5: one decision per typed notification: the journal kind, the marker, and whether any row maps the type.
struct AgentTypedNotificationDecisionTests {
    private let marker = "notification-type:"

    @Test(arguments: [
        (AgentEventMeaning.question, AgentJournalEventKind.questionRequested, true),
        (.approval, .approvalRequested, false),
        (.resolved, .attentionResolved, true),
        (.ignore, .stateChanged, false),
        (.idle, .idleObserved, false),
    ])
    func eachMeaningGivesItsKindAndItsMarker(means: AgentEventMeaning, kind: AgentJournalEventKind, marked: Bool) {
        // The initializer takes any meaning, `idle` included; only a parsed edit rejects it.
        let table = AgentEventTable(userRows: [.init(agent: "claude", notification: "x_type", means: means)])
        let decided = table.decide(agent: "claude", type: "x_type")
        #expect(decided.meaning == means)
        #expect(decided.kind == kind)
        #expect(decided.detail == (marked ? marker + "x_type" : nil))
        #expect(decided.isUnmapped == false)
    }

    @Test func anUnmappedTypeIsAnObservationWithTheMarker() {
        let decided = AgentEventTable.builtIn.decide(agent: "claude", type: "worker_permission_prompt")
        #expect(decided.meaning == nil)
        #expect(decided.kind == .stateChanged)
        #expect(decided.detail == marker + "worker_permission_prompt")
        #expect(decided.isUnmapped)
    }

    @Test(arguments: ["push_notification", "auth_success", "agent_completed", "computer_use_exit"])
    func anIgnoredTypeIsAnObservationWithNoMarker(type: String) {
        let decided = AgentEventTable.builtIn.decide(agent: "claude", type: type)
        #expect(decided.meaning == .ignore)
        #expect(decided.kind == .stateChanged)
        #expect(decided.detail == nil)
        #expect(decided.isUnmapped == false)
    }

    @Test func todaysSixTypesKeepTheirKindsAndTheElicitationOnesGainTheMarker() {
        let expected: [(String, AgentJournalEventKind, String?)] = [
            ("permission_prompt", .approvalRequested, nil),
            ("idle_prompt", .idleObserved, nil),
            ("elicitation_dialog", .questionRequested, marker + "elicitation_dialog"),
            ("elicitation_url_dialog", .questionRequested, marker + "elicitation_url_dialog"),
            ("elicitation_response", .attentionResolved, marker + "elicitation_response"),
            ("elicitation_complete", .attentionResolved, marker + "elicitation_complete"),
        ]
        for (type, kind, detail) in expected {
            let decided = AgentEventTable.builtIn.decide(agent: "kimi", type: type)
            #expect(decided.kind == kind, "\(type)")
            #expect(decided.detail == detail, "\(type)")
        }
    }

    @Test func onlyHisRowIsMarkedAsHis() {
        let table = AgentEventTable(userRows: [
            .init(agent: "claude", notification: "idle_prompt", means: .ignore),
            .init(agent: "*", notification: "build_ready", means: .approval),
        ])
        #expect(table.decide(agent: "claude", type: "idle_prompt").isFromUserRow, "his row beats the built-in one")
        #expect(table.decide(agent: "kimi", type: "build_ready").isFromUserRow, "his star row")
        #expect(!table.decide(agent: "kimi", type: "idle_prompt").isFromUserRow, "the built-in row is not his")
        #expect(!table.decide(agent: "claude", type: "worker_permission_prompt").isFromUserRow, "an unmapped type has no row")
        #expect(!AgentEventTable.builtIn.decide(agent: "claude", type: "permission_prompt").isFromUserRow)
    }

    @Test func hisRowChangesTheDecisionForItsAgentOnly() {
        let table = AgentEventTable(userRows: [.init(agent: "claude", notification: "idle_prompt", means: .ignore)])
        #expect(table.decide(agent: "claude", type: "idle_prompt").kind == .stateChanged)
        #expect(table.decide(agent: "kimi", type: "idle_prompt").kind == .idleObserved)
    }
}
