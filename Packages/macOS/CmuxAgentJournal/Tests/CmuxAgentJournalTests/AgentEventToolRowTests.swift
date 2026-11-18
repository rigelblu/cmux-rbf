import Foundation
import Testing
@testable import CmuxAgentJournal

/// cm-124.6: tool rows in the table: parsing, the rules a tool row breaks, which row wins, and the row-tool flag.
struct AgentEventToolRowTests {
    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    // MARK: a tool row parses

    @Test(arguments: [("question", AgentEventMeaning.question), ("plan-review", .planReview)])
    func aToolRowParsesWithItsWord(word: String, means: AgentEventMeaning) throws {
        let rows = try json(#"[{"agent":"claude","tool":"Write","means":"\#(word)"}]"#)
        let result = AgentEventTable.builtIn.applying(rows)
        #expect(result.parse.issues.isEmpty)
        #expect(result.table.userRows == [.init(agent: "claude", tool: "Write", means: means)])
        #expect(result.table.userRows.first?.notification == nil)
        #expect(result.table.userRows.first?.tool == "Write")
    }

    @Test func aNotificationRowAndAToolRowShareTheListWithoutCollidingOnTheSameName() throws {
        let rows = try json(#"""
        [{"agent":"claude","notification":"Write","means":"ignore"},{"agent":"claude","tool":"Write","means":"question"}]
        """#)
        let result = AgentEventTable.builtIn.applying(rows)
        #expect(result.parse.issues.isEmpty, "the same text under notification and tool is two rows")
        #expect(result.table.userRows.count == 2)
    }

    @Test func fiveRowsParseAsBefore() throws {
        let rows = try json(#"[{"agent":"claude","notification":"idle_prompt","means":"ignore"}]"#)
        #expect(AgentEventTable.builtIn.applying(rows).table.userRows
            == [.init(agent: "claude", notification: "idle_prompt", means: .ignore)])
    }

    // MARK: the rules a tool row breaks, each one issue

    private struct BadEdit: Sendable, CustomTestStringConvertible {
        let name: String
        let rows: String
        let rule: AgentEventRowIssue.Rule
        let value: String?
        var testDescription: String { name }
    }

    private static let badEdits: [BadEdit] = [
        .init(name: "both keys",
              rows: #"[{"agent":"claude","notification":"x","tool":"Write","means":"question"}]"#,
              rule: .bothMatchKeys, value: nil),
        .init(name: "neither key", rows: #"[{"agent":"claude","means":"question"}]"#, rule: .noMatchKey, value: nil),
        .init(name: "ignore on a tool row", rows: #"[{"agent":"claude","tool":"Write","means":"ignore"}]"#,
              rule: .meaningNotForTool, value: "ignore"),
        .init(name: "approval on a tool row", rows: #"[{"agent":"claude","tool":"Write","means":"approval"}]"#,
              rule: .meaningNotForTool, value: "approval"),
        .init(name: "resolved on a tool row", rows: #"[{"agent":"claude","tool":"Write","means":"resolved"}]"#,
              rule: .meaningNotForTool, value: "resolved"),
        .init(name: "idle on a tool row", rows: #"[{"agent":"claude","tool":"Write","means":"idle"}]"#,
              rule: .meaningNotForTool, value: "idle"),
        .init(name: "plan-review on a notification row",
              rows: #"[{"agent":"claude","notification":"x","means":"plan-review"}]"#,
              rule: .unknownMeaning, value: "plan-review"),
        .init(name: "tool is a number", rows: #"[{"agent":"claude","tool":3,"means":"question"}]"#,
              rule: .fieldNotText(.tool), value: "3"),
        .init(name: "tool is empty", rows: #"[{"agent":"claude","tool":"","means":"question"}]"#,
              rule: .missingField(.tool), value: nil),
        .init(name: "means is missing on a tool row", rows: #"[{"agent":"claude","tool":"Write"}]"#,
              rule: .missingToolMeans, value: nil), // (#cm-124.6) its own line: a tool row can't take the notification words
        .init(name: "means is empty on a tool row", rows: #"[{"agent":"claude","tool":"Write","means":""}]"#,
              rule: .missingToolMeans, value: nil),
    ]

    @Test(arguments: badEdits)
    private func eachBadToolEditGivesOneIssueAndKeepsThePreviousRows(edit: BadEdit) throws {
        let previous = AgentEventTable(userRows: [.init(agent: "claude", tool: "Read", means: .question)])
        let result = previous.applying(try json(edit.rows))
        #expect(result.parse.issues == [AgentEventRowIssue(index: 0, rule: edit.rule, value: edit.value)])
        #expect(result.table == previous, "a bad edit changes nothing")
    }

    @Test func aRepeatedToolRowRejectsTheSecond() throws {
        let rows = try json(#"""
        [{"agent":"claude","tool":"Write","means":"question"},{"agent":"claude","tool":"Write","means":"plan-review"}]
        """#)
        #expect(AgentEventTable.validate(rows) == [AgentEventRowIssue(index: 1, rule: .duplicateToolRow(firstIndex: 0))])
    }

    @Test func aToolRowDoesNotRepeatAClaudeRowAndAStarRow() throws {
        let rows = try json(#"""
        [{"agent":"claude","tool":"Write","means":"question"},{"agent":"*","tool":"Write","means":"question"}]
        """#)
        #expect(AgentEventTable.validate(rows).isEmpty)
    }

    // MARK: reach warning

    @Test(arguments: ["codex", "pi", "kimi", "someone-else"])
    func aToolRowForAnotherAgentIsValidAndWarns(agent: String) throws {
        let rows = try json(#"[{"agent":"\#(agent)","tool":"Write","means":"question"}]"#)
        let result = AgentEventTable.builtIn.applying(rows)
        #expect(result.parse.issues.isEmpty)
        #expect(result.parse.warnings == [AgentEventRowWarning(index: 0, agent: agent, isToolRow: true)])
        #expect(result.table.userRows.count == 1)
    }

    @Test(arguments: ["claude", "*"])
    func aToolRowForClaudeOrStarGivesNoWarning(agent: String) throws {
        let rows = try json(#"[{"agent":"\#(agent)","tool":"Write","means":"question"}]"#)
        #expect(AgentEventTable.builtIn.applying(rows).parse.warnings.isEmpty)
    }

    // MARK: which row wins, and when a call is a row tool

    @Test func theTwoBuiltInToolRowsGiveTodaysWords() {
        let ask = AgentEventTable.builtIn.toolMeaning(agent: "claude", tool: "AskUserQuestion")
        let plan = AgentEventTable.builtIn.toolMeaning(agent: "claude", tool: "ExitPlanMode")
        #expect(ask?.means == .question)
        #expect(ask?.isRowTool == false)
        #expect(plan?.means == .planReview)
        #expect(plan?.isRowTool == false)
    }

    @Test func aToolWithNoRowHasNoMeaning() {
        #expect(AgentEventTable.builtIn.toolMeaning(agent: "claude", tool: "Write") == nil)
        #expect(AgentEventTable.builtIn.toolMeaning(agent: "claude", tool: "Bash") == nil)
    }

    @Test func theBuiltInToolRowsAreForClaudeOnly() {
        #expect(AgentEventTable.builtIn.toolMeaning(agent: "codex", tool: "AskUserQuestion") == nil)
    }

    @Test func hisRowForANewToolIsARowTool() {
        let table = AgentEventTable(userRows: [.init(agent: "claude", tool: "Write", means: .question)])
        let meaning = table.toolMeaning(agent: "claude", tool: "Write")
        #expect(meaning?.means == .question)
        #expect(meaning?.isRowTool == true)
    }

    @Test func hisExactRowBeatsHisStarRowBeatsTheBuiltInRow() {
        let table = AgentEventTable(userRows: [
            .init(agent: "*", tool: "Write", means: .question),
            .init(agent: "claude", tool: "Write", means: .planReview),
            .init(agent: "*", tool: "Edit", means: .planReview),
        ])
        #expect(table.toolMeaning(agent: "claude", tool: "Write")?.means == .planReview)
        #expect(table.toolMeaning(agent: "claude", tool: "Edit")?.means == .planReview, "his star row reaches claude")
    }

    @Test func hisRowThatRestatesABuiltInWordKeepsThePathBuiltIn() {
        let table = AgentEventTable(userRows: [.init(agent: "claude", tool: "AskUserQuestion", means: .question)])
        let meaning = table.toolMeaning(agent: "claude", tool: "AskUserQuestion")
        #expect(meaning?.means == .question)
        #expect(meaning?.isRowTool == false, "same word as the built-in row: today's path")
    }

    @Test func hisRowThatChangesABuiltInWordMakesItARowTool() {
        let table = AgentEventTable(userRows: [.init(agent: "claude", tool: "AskUserQuestion", means: .planReview)])
        let meaning = table.toolMeaning(agent: "claude", tool: "AskUserQuestion")
        #expect(meaning?.means == .planReview)
        #expect(meaning?.isRowTool == true)
    }

    @Test func hisStarRowThatRestatesABuiltInWordKeepsThePathBuiltIn() {
        let table = AgentEventTable(userRows: [.init(agent: "*", tool: "ExitPlanMode", means: .planReview)])
        #expect(table.toolMeaning(agent: "claude", tool: "ExitPlanMode")?.isRowTool == false)
    }

    @Test(arguments: ["askuserquestion", "ASKUSERQUESTION", "Askuserquestion"])
    func aToolRowMatchesTheNameExactly(name: String) {
        let table = AgentEventTable(userRows: [.init(agent: "claude", tool: name, means: .planReview)])
        let meaning = table.toolMeaning(agent: "claude", tool: "AskUserQuestion")
        #expect(meaning?.means == .question, "\(name) does nothing for AskUserQuestion")
        #expect(meaning?.isRowTool == false)
        #expect(table.toolMeaning(agent: "claude", tool: name)?.isRowTool == true)
    }

    @Test func aToolRowAndANotificationRowNeverAnswerForEachOther() {
        let table = AgentEventTable(userRows: [
            .init(agent: "claude", tool: "idle_prompt", means: .question),
            .init(agent: "claude", notification: "Write", means: .question),
        ])
        #expect(table.meaning(agent: "claude", notification: "idle_prompt") == .idle)
        #expect(table.toolMeaning(agent: "claude", tool: "Write") == nil)
    }
}
