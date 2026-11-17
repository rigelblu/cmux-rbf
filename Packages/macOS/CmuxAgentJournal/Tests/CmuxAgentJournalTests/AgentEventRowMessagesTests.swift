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
        (AgentEventRowIssue(index: 0, rule: .unknownKey, value: "tool"), "unknownKey",
         #"agentEvents[0]: "tool" isn't a row key; a row has agent, notification, means"#),
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
    }
}
