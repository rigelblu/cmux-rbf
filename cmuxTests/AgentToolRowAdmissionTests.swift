import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-124.6: the app decides a Claude tool's word once, when the queue admits its `pre-tool-use` or `post-tool-use`.
/// The class, the retry count and the handler's `CMUX_AGENT_TOOL_MEANS` all read that one stored word. Every test passes
/// its own table, so none touches `AgentEventTableStore.shared`.
struct AgentToolRowAdmissionTests {
    private func table(_ rows: [AgentEventRow]) -> AgentEventTable { AgentEventTable(userRows: rows) }

    private let writeQuestion = AgentEventRow(agent: "claude", tool: "Write", means: .question)

    private func event(
        agent: String = "claude",
        subcommand: String = "pre-tool-use",
        tool: String? = "Write",
        relayBacked: Bool = false,
        payload: String? = nil
    ) throws -> AgentHookDeliveryEvent {
        let body = payload ?? (tool.map { #"{"session_id":"s1","tool_name":"\#($0)","tool_use_id":"toolu_1"}"# } ?? #"{"session_id":"s1"}"#)
        var params: [String: Any] = [
            "agent": agent,
            "subcommand": subcommand,
            "payload": body,
            "socket_path": "/tmp/cmux-test.sock",
            "environment": ["CMUX_SURFACE_ID": "surface-a"],
        ]
        if relayBacked { params["relay_backed"] = true }
        return try #require(AgentHookDeliveryEvent(params: params))
    }

    // MARK: a row tool takes the lifecycle class

    @Test(arguments: [("question", AgentEventMeaning.question), ("plan-review", .planReview)])
    func aRowToolStoresItsWordAndTakesTheLifecycleClassOnBothHooks(label: String, means: AgentEventMeaning) throws {
        let rows = [AgentEventRow(agent: "claude", tool: "Write", means: means)]
        for subcommand in ["pre-tool-use", "post-tool-use"] {
            let admitted = try event(subcommand: subcommand).decidingToolRow(table: { table(rows) })
            #expect(admitted.toolMeans == means, "\(label) \(subcommand)")
            #expect(!admitted.isBestEffortTelemetry, "\(label) \(subcommand): never dropped by the best-effort rule")
        }
    }

    @Test func theWordIsDecidedOnceAndASecondTableChangesNothing() throws {
        let admitted = try event().decidingToolRow(table: { table([writeQuestion]) })
        #expect(admitted.toolMeans == .question)
        #expect(!admitted.isBestEffortTelemetry, "the class reads the stored word; no table is consulted again")
    }

    @Test func aToolWithNoRowKeepsTodaysClasses() throws {
        let pre = try event(tool: "Bash").decidingToolRow(table: { table([writeQuestion]) })
        let post = try event(subcommand: "post-tool-use", tool: "Bash").decidingToolRow(table: { table([writeQuestion]) })
        #expect(pre.toolMeans == nil && post.toolMeans == nil)
        #expect(pre.isBestEffortTelemetry, "a Claude pre-tool-use for an unknown tool is best-effort today")
        #expect(post.isBestEffortTelemetry)
    }

    // MARK: the two built-in tools

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode"])
    func aBuiltInToolWithNoRowsIsNotARowToolAndKeepsItsClasses(tool: String) throws {
        let pre = try event(tool: tool).decidingToolRow(table: { .builtIn })
        let post = try event(subcommand: "post-tool-use", tool: tool).decidingToolRow(table: { .builtIn })
        #expect(pre.toolMeans == nil && post.toolMeans == nil)
        #expect(!pre.isBestEffortTelemetry, "a form tool's pre-tool-use never drops")
        #expect(post.isBestEffortTelemetry, "its post-tool-use is best-effort, as today")
    }

    @Test func hisRowThatRestatesABuiltInWordKeepsTheBuiltInPath() throws {
        let restated = table([.init(agent: "claude", tool: "AskUserQuestion", means: .question)])
        let post = try event(subcommand: "post-tool-use", tool: "AskUserQuestion").decidingToolRow(table: { restated })
        #expect(post.toolMeans == nil)
        #expect(post.isBestEffortTelemetry)
    }

    @Test func hisRowThatChangesABuiltInWordMakesItARowTool() throws {
        let changed = table([.init(agent: "claude", tool: "AskUserQuestion", means: .planReview)])
        let post = try event(subcommand: "post-tool-use", tool: "AskUserQuestion").decidingToolRow(table: { changed })
        #expect(post.toolMeans == .planReview)
        #expect(!post.isBestEffortTelemetry)
    }

    // MARK: what is never decided

    @Test func aRelayBackedEventGetsNoWordAndKeepsTodaysClass() throws {
        let admitted = try event(relayBacked: true).decidingToolRow(table: { table([writeQuestion]) })
        #expect(admitted.toolMeans == nil, "a remote Claude keeps the built-in rows")
        #expect(admitted.isBestEffortTelemetry)
    }

    @Test(arguments: ["codex"])
    func anotherAgentGetsNoWord(agent: String) throws {
        let starRow = table([.init(agent: "*", tool: "Write", means: .question)])
        let admitted = try event(agent: agent).decidingToolRow(table: { starRow })
        #expect(admitted.toolMeans == nil)
    }

    @Test(arguments: ["prompt-submit", "notification", "stop", "session-start", "feed"])
    func onlyPreAndPostToolUseAreDecided(subcommand: String) throws {
        let admitted = try event(subcommand: subcommand).decidingToolRow(table: {
            Issue.record("\(subcommand) must not read the table")
            return table([writeQuestion])
        })
        #expect(admitted.toolMeans == nil)
    }

    @Test(arguments: [#"{"session_id":"s1"}"#, "not json", #"{"tool_name":3}"#, "[]"])
    func aPayloadWithoutATextToolNameIsNotDecided(payload: String) throws {
        let admitted = try event(payload: payload).decidingToolRow(table: { table([writeQuestion]) })
        #expect(admitted.toolMeans == nil)
    }

    @Test func theCamelCaseToolNameKeyIsReadToo() throws {
        let admitted = try event(payload: #"{"toolName":"Write"}"#).decidingToolRow(table: { table([writeQuestion]) })
        #expect(admitted.toolMeans == .question)
    }

    // MARK: the handler's environment

    private func environment(for event: AgentHookDeliveryEvent) -> [String: String] {
        AgentHookDeliveryProcess().deliveryEnvironment(event: event, executableURL: URL(fileURLWithPath: "/tmp/cmux-cli"))
    }

    @Test(arguments: [("question", AgentEventMeaning.question), ("plan-review", .planReview)])
    func aRowToolsHandlerGetsItsWordInTheEnvironment(label: String, means: AgentEventMeaning) throws {
        let rows = [AgentEventRow(agent: "claude", tool: "Write", means: means)]
        for subcommand in ["pre-tool-use", "post-tool-use"] {
            let admitted = try event(subcommand: subcommand).decidingToolRow(table: { table(rows) })
            #expect(environment(for: admitted)["CMUX_AGENT_TOOL_MEANS"] == label, "\(label) \(subcommand)")
        }
    }

    @Test func noStampForABuiltInToolAToolWithNoRowOrAnUndecidedEvent() throws {
        let stampless = [
            try event(tool: "AskUserQuestion").decidingToolRow(table: { .builtIn }),
            try event(tool: "Bash").decidingToolRow(table: { table([writeQuestion]) }),
            try event(), // never admitted: no decision
            try event(relayBacked: true).decidingToolRow(table: { table([writeQuestion]) }),
        ]
        for admitted in stampless {
            #expect(environment(for: admitted)["CMUX_AGENT_TOOL_MEANS"] == nil)
        }
    }

    // MARK: the tool name is parsed once

    @Test func theToolNameIsParsedOnceAtInitForClaudeToolHooksOnly() throws {
        #expect(try event(tool: "Write").toolName == "Write")
        #expect(try event(subcommand: "post-tool-use", tool: "Write").toolName == "Write")
        #expect(try event(payload: #"{"toolName":"Edit"}"#).toolName == "Edit")
        #expect(try event(tool: nil).toolName == nil)
        #expect(try event(subcommand: "prompt-submit", tool: "Write").toolName == nil)
        #expect(try event(agent: "codex", tool: "Write").toolName == nil)
    }

    // MARK: a stamp already in the environment never survives

    @Test func aStampAlreadyInTheEnvironmentIsRemovedBeforeTheAppsOwnIsSet() throws {
        let spoofed = ["CMUX_AGENT_TOOL_MEANS": "plan-review", "HOME": "/scratch"]
        let undecided = try event()
        let none = AgentHookDeliveryProcess.stampingToolMeans(in: spoofed, for: undecided)
        #expect(none["CMUX_AGENT_TOOL_MEANS"] == nil, "no decision, no stamp: a leftover one is removed")
        #expect(none["HOME"] == "/scratch", "everything else is kept")
        let row = try event().decidingToolRow(table: { table([writeQuestion]) })
        let stamped = AgentHookDeliveryProcess.stampingToolMeans(in: spoofed, for: row)
        #expect(stamped["CMUX_AGENT_TOOL_MEANS"] == "question", "the app's word, not the one already there")
        let relay = try event(relayBacked: true).decidingToolRow(table: { table([writeQuestion]) })
        #expect(AgentHookDeliveryProcess.stampingToolMeans(in: spoofed, for: relay)["CMUX_AGENT_TOOL_MEANS"] == nil)
    }

    @Test func anAgentCannotSetTheStampThroughTheEventEnvironment() {
        let event = AgentHookDeliveryEvent(params: [
            "agent": "claude",
            "subcommand": "pre-tool-use",
            "payload": #"{"tool_name":"Write"}"#,
            "socket_path": "/tmp/cmux-test.sock",
            "environment": ["CMUX_SURFACE_ID": "surface-a", "CMUX_AGENT_TOOL_MEANS": "question"],
        ])
        #expect(event == nil, "the environment allowlist rejects the key, so an agent can't spoof the stamp")
    }
}
