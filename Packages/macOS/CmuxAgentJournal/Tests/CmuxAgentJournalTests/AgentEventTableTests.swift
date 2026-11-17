import Foundation
import Testing
@testable import CmuxAgentJournal

/// cm-124.5: the table of notification types — validation, precedence, built-in rows, reach warnings.
struct AgentEventTableTests {
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private let good = #"{"agent":"claude","notification":"idle_prompt","means":"ignore"}"#

    // MARK: validation, whole or nothing

    private struct BadEdit: Sendable, CustomTestStringConvertible {
        let name: String
        let rows: String
        let index: Int?
        let rule: AgentEventRowIssue.Rule
        let value: String?
        var testDescription: String { name }
    }

    private static let badEdits: [BadEdit] = [
        .init(name: "missing agent", rows: #"[{"notification":"x","means":"question"}]"#,
              index: 0, rule: .missingField(.agent), value: nil),
        .init(name: "empty notification", rows: #"[{"agent":"claude","notification":"","means":"question"}]"#,
              index: 0, rule: .missingField(.notification), value: nil),
        .init(name: "missing means", rows: #"[{"agent":"claude","notification":"x"}]"#,
              index: 0, rule: .missingField(.means), value: nil),
        .init(name: "means is a number", rows: #"[{"agent":"claude","notification":"x","means":3}]"#,
              index: 0, rule: .fieldNotText(.means), value: "3"),
        .init(name: "empty agent", rows: #"[{"agent":"","notification":"x","means":"question"}]"#,
              index: 0, rule: .missingField(.agent), value: nil),
        .init(name: "misspelled means", rows: #"[{"agent":"claude","notification":"x","means":"aprooval"}]"#,
              index: 0, rule: .unknownMeaning, value: "aprooval"),
        .init(name: "idle is built-in only", rows: #"[{"agent":"claude","notification":"x","means":"idle"}]"#,
              index: 0, rule: .unknownMeaning, value: "idle"),
        .init(name: "tool row before cm-124.6",
              rows: #"[{"agent":"claude","tool":"AskUserQuestion","means":"question"}]"#,
              index: 0, rule: .unknownKey, value: "tool"),
        .init(name: "row is a string", rows: #"["claude"]"#, index: 0, rule: .rowNotAnObject, value: nil),
        .init(name: "agentEvents is an object", rows: #"{"agent":"claude"}"#, index: nil, rule: .notAList, value: nil),
        .init(name: "agentEvents is null", rows: "null", index: nil, rule: .notAList, value: nil),
    ]

    @Test(arguments: badEdits)
    private func eachBadEditReturnsItsIssueAndKeepsThePreviousRows(edit: BadEdit) throws {
        let previous = AgentEventTable(userRows: [
            .init(agent: "claude", notification: "worker_permission_prompt", means: .approval),
        ])
        let result = previous.applying(try json(edit.rows))
        #expect(result.parse.issues == [AgentEventRowIssue(index: edit.index, rule: edit.rule, value: edit.value)])
        #expect(result.table == previous, "a bad edit changes nothing")
        #expect(AgentEventTable.validate(try json(edit.rows)) == result.parse.issues)
    }

    @Test func aBadRowRejectsTheWholeEditEvenBesideGoodRows() throws {
        let rows = try json("[\(good),{\"agent\":\"claude\",\"notification\":\"x\",\"means\":\"aprooval\"}]")
        let result = AgentEventTable.builtIn.applying(rows)
        #expect(result.parse.issues == [AgentEventRowIssue(index: 1, rule: .unknownMeaning, value: "aprooval")])
        #expect(result.table == AgentEventTable.builtIn)
    }

    @Test func twoRowsWithTheSameAgentAndNotificationRejectTheSecond() throws {
        let rows = try json("[\(good),{\"agent\":\"claude\",\"notification\":\"idle_prompt\",\"means\":\"question\"}]")
        #expect(AgentEventTable.validate(rows)
            == [AgentEventRowIssue(index: 1, rule: .duplicateRow(firstIndex: 0), value: nil)])
    }

    @Test func aValidEditReplacesTheUserRows() throws {
        let rows = try json("[\(good)]")
        let result = AgentEventTable.builtIn.applying(rows)
        #expect(result.parse.issues.isEmpty)
        #expect(result.table.userRows == [.init(agent: "claude", notification: "idle_prompt", means: .ignore)])
    }

    @Test func noKeyAndAnEmptyListMeanNoUserRows() throws {
        #expect(AgentEventTable.validate(nil).isEmpty)
        #expect(AgentEventTable.validate(try json("[]")).isEmpty)
        let previous = AgentEventTable(userRows: [.init(agent: "claude", notification: "x", means: .question)])
        #expect(previous.applying(nil).table.userRows.isEmpty, "deleting agentEvents brings the built-in rows back")
    }

    // MARK: built-in rows

    @Test(arguments: [
        ("permission_prompt", AgentEventMeaning.approval),
        ("idle_prompt", .idle),
        ("elicitation_dialog", .question),
        ("elicitation_url_dialog", .question),
        ("elicitation_response", .resolved),
        ("elicitation_complete", .resolved),
        ("push_notification", .ignore),
        ("auth_success", .ignore),
        ("agent_completed", .ignore),
        ("quota_auto_resume_fired", .ignore),
        ("quota_auto_resume_scheduled", .ignore),
        ("quota_auto_resume_started", .ignore),
        ("quota_auto_resume_stale", .ignore),
        ("quota_auto_resume_disabled", .ignore),
        ("computer_use_enter", .ignore),
        ("computer_use_exit", .ignore),
    ])
    func builtInRowsGiveTodaysSixAnswersAndTenIgnores(type: String, means: AgentEventMeaning) {
        for agent in ["claude", "kimi", "grok", "antigravity"] {
            #expect(AgentEventTable.builtIn.meaning(agent: agent, notification: type) == means, "\(agent) \(type)")
        }
    }

    @Test(arguments: ["auth_storage_failure", "plugin_notification", "agent_needs_input", "worker_permission_prompt", "quota_auto_resume_failed"])
    func theFourTypesWithNoRowHaveNoMeaning(type: String) {
        #expect(AgentEventTable.builtIn.meaning(agent: "claude", notification: type) == nil)
    }

    // MARK: which row wins

    @Test func hisExactRowBeatsHisStarRowBeatsTheBuiltInRow() {
        let table = AgentEventTable(userRows: [
            .init(agent: "*", notification: "idle_prompt", means: .ignore),
            .init(agent: "claude", notification: "idle_prompt", means: .question),
        ])
        #expect(table.meaning(agent: "claude", notification: "idle_prompt") == .question)
        #expect(table.meaning(agent: "pi", notification: "idle_prompt") == .ignore)
        #expect(AgentEventTable.builtIn.meaning(agent: "claude", notification: "idle_prompt") == .idle)
    }

    @Test func hisRowForAnotherAgentLeavesTheBuiltInRowAlone() {
        let table = AgentEventTable(userRows: [.init(agent: "kimi", notification: "idle_prompt", means: .question)])
        #expect(table.meaning(agent: "claude", notification: "idle_prompt") == .idle)
        #expect(table.meaning(agent: "kimi", notification: "idle_prompt") == .question)
    }

    @Test func hisRowMapsATypeNoBuiltInRowMaps() {
        let table = AgentEventTable(userRows: [
            .init(agent: "claude", notification: "worker_permission_prompt", means: .approval),
        ])
        #expect(table.meaning(agent: "claude", notification: "worker_permission_prompt") == .approval)
        #expect(table.meaning(agent: "kimi", notification: "worker_permission_prompt") == nil)
    }

    // MARK: reach warnings

    @Test(arguments: ["pi", "copilot", "codebuddy", "factory", "hermes-agent"])
    func aRowForAnAgentWhoseNotificationsNeverReachTheTableWarnsButApplies(agent: String) throws {
        let rows = try json(#"[{"agent":"\#(agent)","notification":"idle_prompt","means":"ignore"}]"#)
        let result = AgentEventTable.builtIn.applying(rows)
        #expect(result.parse.issues.isEmpty)
        #expect(result.parse.warnings == [AgentEventRowWarning(index: 0, agent: agent)])
        #expect(result.table.userRows.count == 1, "the edit still applies")
    }

    @Test(arguments: ["claude", "antigravity", "kimi", "grok", "*", "someone-else"])
    func aRowForAReachedOrUnknownAgentGivesNoWarning(agent: String) throws {
        let rows = try json(#"[{"agent":"\#(agent)","notification":"idle_prompt","means":"ignore"}]"#)
        #expect(AgentEventTable.builtIn.applying(rows).parse.warnings.isEmpty)
    }
}
