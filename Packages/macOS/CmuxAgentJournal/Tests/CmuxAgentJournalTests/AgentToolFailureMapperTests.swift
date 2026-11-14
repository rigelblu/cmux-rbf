import Testing
@testable import CmuxAgentJournal

/// cm-128.5 (Scenario 74): a failed tool is the agent's work and never enters the error row; a stop that ended on an
/// error does.
@Suite("Tool failure never raises the error")
struct AgentToolFailureMapperTests {
    @Test(arguments: ["claude", "cursor", "codex", "gemini", "kimi", "pi"])
    func aToolFailureIsAnObservationForAnySource(source: String) {
        let mapper = AgentSemanticEventMapper()
        for native in ["PostToolUseFailure", "postToolUseFailure", "post_tool_use_failure"] {
            #expect(mapper.kind(source: source, nativeEvent: native, toolName: "Shell") == .stateChanged,
                    "\(source) / \(native)")
        }
    }

    @Test(arguments: ["claude", "kimi", "rovodev"])
    func aStopThatEndedOnAnErrorStillRaisesIt(source: String) {
        let mapper = AgentSemanticEventMapper()
        let native = source == "rovodev" ? "on_error" : "StopFailure"
        #expect(mapper.kind(source: source, nativeEvent: native) == .errorReported)
    }
}
