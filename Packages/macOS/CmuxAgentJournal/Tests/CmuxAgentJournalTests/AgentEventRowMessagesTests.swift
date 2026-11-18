import Testing
@testable import CmuxAgentJournal

/// cm-124.5: the English line `cmux config doctor` prints for each rule, as drawn in the design's renders.
struct AgentEventRowMessagesTests {
    @Test(arguments: [
        (AgentEventRowIssue(index: 1, rule: .unknownMeaning, value: "aprooval"), "badMeaning",
         #"agentEvents[1]: means "aprooval": use question, approval, resolved or ignore"#),
        (AgentEventRowIssue(index: 0, rule: .missingField(.agent)), "missingAgent",
         #"agentEvents[0]: "agent" is missing; name one, such as "claude", or "*""#),
        (AgentEventRowIssue(index: 0, rule: .missingField(.notification)), "missingNotification",
         #"agentEvents[0]: "notification" is missing; name a type, such as "idle_prompt""#),
        (AgentEventRowIssue(index: 0, rule: .missingField(.means)), "missingMeans",
         #"agentEvents[0]: "means" is missing; use question, approval, resolved or ignore"#),
        (AgentEventRowIssue(index: 0, rule: .fieldNotText(.agent), value: "3"), "notText",
         #"agentEvents[0]: "agent" must be text, such as "claude""#),
        (AgentEventRowIssue(index: 4, rule: .fieldNotText(.notification), value: "true"), "notText",
         #"agentEvents[4]: "notification" must be text, such as "idle_prompt""#),
        (AgentEventRowIssue(index: 0, rule: .fieldNotText(.means), value: "3"), "notText",
         #"agentEvents[0]: "means" must be text, such as "ignore""#),
        (AgentEventRowIssue(index: 2, rule: .duplicateRow(firstIndex: 0)), "duplicateRow",
         "agentEvents[2]: same agent and notification as agentEvents[0]; keep one"),
        (AgentEventRowIssue(index: 0, rule: .unknownKey, value: "event"), "unknownKey", // (#cm-124.6) names tool too
         #"agentEvents[0]: "event" is not a key: use agent, notification or tool, means"#),
        (AgentEventRowIssue(index: 0, rule: .bothMatchKeys), "bothMatchKeys",
         #"agentEvents[0]: a row has "notification" or "tool", not both"#),
        (AgentEventRowIssue(index: 5, rule: .noMatchKey), "noMatchKey",
         #"agentEvents[5]: a row needs "notification" (a type) or "tool" (a Claude tool)"#),
        (AgentEventRowIssue(index: 1, rule: .meaningNotForTool, value: "ignore"), "badToolMeaning",
         #"agentEvents[1]: means "ignore" on a tool row: use question or plan-review"#),
        (AgentEventRowIssue(index: 2, rule: .missingToolMeans), "missingToolMeans",
         #"agentEvents[2]: "means" is missing; use question or plan-review"#),
        (AgentEventRowIssue(index: 3, rule: .duplicateToolRow(firstIndex: 2)), "duplicateToolRow",
         "agentEvents[3]: same agent and tool as agentEvents[2]; keep one"),
        (AgentEventRowIssue(index: 2, rule: .fieldNotText(.tool), value: "3"), "notText",
         #"agentEvents[2]: "tool" must be text, such as "AskUserQuestion""#),
        (AgentEventRowIssue(index: 2, rule: .missingField(.tool)), "missingTool",
         #"agentEvents[2]: "tool" is missing; name a Claude tool, like "AskUserQuestion""#),
        (AgentEventRowIssue(index: 2, rule: .unknownMeaning, value: "plan-review"), "badMeaning",
         #"agentEvents[2]: means "plan-review": use question, approval, resolved or ignore"#),
        (AgentEventRowIssue(index: 3, rule: .rowNotAnObject), "rowNotObject", "agentEvents[3]: a row must be an object"),
        (AgentEventRowIssue(index: nil, rule: .notAList), "notList", "agentEvents: must be a list of rows"),
    ])
    func eachRuleHasItsRuleNameAndItsEnglishLine(issue: AgentEventRowIssue, rule: String, message: String) {
        #expect(issue.ruleName == rule)
        #expect(issue.englishMessage == message)
    }

    @Test func aWarningNamesTheRowAndTheAgent() {
        #expect(AgentEventRowWarning(index: 0, agent: "pi").englishMessage
            == "agentEvents[0] does nothing: pi's notifications never reach it")
        #expect(AgentEventRowWarning(index: 2, agent: "hermes-agent").englishMessage
            == "agentEvents[2] does nothing: hermes-agent's notifications never reach it")
        #expect(AgentEventRowWarning(index: 2, agent: "codex", isToolRow: true).englishMessage
            == "agentEvents[2] does nothing: only Claude's tools reach a tool row")
    }
}
