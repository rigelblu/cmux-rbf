import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct AgentHibernationLifecycleStateTests {
    @Test(arguments: [AgentHibernationLifecycleState.monitoring, .error])
    func aPaneWithOnlyThisStateCannotFallBackToIdle(state: AgentHibernationLifecycleState) async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: state)
            #expect(harness.state(fallback: .idle) == state)
            #expect(!harness.state(fallback: .idle).allowsHibernation)
        }
    }

    @Test(arguments: AgentHibernationLifecycleState.allCases)
    func storedStatesRoundTripButOnlyProducerStatesAreAcceptedByTheSocket(state: AgentHibernationLifecycleState) throws {
        let decoded = try JSONDecoder().decode(AgentHibernationLifecycleState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        let derived = state == .monitoring || state == .error
        #expect(AgentHibernationLifecycleState.parseCLIValue(state.rawValue) == (derived ? nil : state))
        #expect(state.allowsHibernation == (state == .idle))
    }

    @Test func aggregateUsesTheActivityOrderBeforeAnyFallback() {
        let order: [AgentHibernationLifecycleState] = [.running, .needsInput, .monitoring, .error, .unknown, .idle]
        let keys = ["claude_code", "codex", "pi", "amp", "gemini", "copilot"]
        for index in order.indices {
            let states = Dictionary(uniqueKeysWithValues: zip(keys, order[index...]))
            #expect(AgentHibernationLifecycleState.aggregate(statusKeyedStates: states, fallback: .idle) == order[index])
        }
    }

    @Test(arguments: [AgentHibernationLifecycleState.monitoring, .error])
    func textBoxEscapeDoesNotTreatTheseStatesAsRunning(state: AgentHibernationLifecycleState) {
        #expect(AgentHibernationLifecycleState.aggregateForTextBoxEscape(statusKeyedStates: ["claude_code": state]) == .unknown)
    }
}
