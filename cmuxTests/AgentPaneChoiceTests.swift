import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct AgentPaneChoiceTests {
    // Scenario 150: focused, sticky, live, fixed-id precedence.
    @Test func precedence() {
        let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let c = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        func pick(_ focused: UUID? = nil, _ sticky: UUID? = nil, live: Set<UUID> = []) -> UUID? {
            AgentPaneChoice.resolve(agentPanelIDs: [b, a], focused: focused, sticky: sticky, live: live)
        }
        #expect(pick(b, a, live: [a]) == b)
        #expect(pick(c, b, live: [a]) == b)
        #expect(pick(c, c, live: [b]) == b)
        #expect(pick(live: [a, b]) == a)
        #expect(pick() == a)
        #expect(AgentPaneChoice.resolve(agentPanelIDs: [], focused: a, sticky: b, live: [a]) == nil)
    }
}
