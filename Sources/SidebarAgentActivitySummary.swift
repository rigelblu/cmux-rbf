import Foundation

enum SidebarAgentActivitySummary {
    static func visibleMonitoringAgentCount(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return statesByPanelId().values.reduce(0) { count, states in
            count + states.values.filter { $0 == .monitoring }.count
        }
    }

    static func visibleActiveCodingAgentCount(
        showsAgentActivity: Bool,
        statesByPanelId: @autoclosure () -> [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        guard showsAgentActivity else { return 0 }
        return activeCodingAgentCount(statesByPanelId: statesByPanelId())
    }

    static func activeCodingAgentCount(
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]]
    ) -> Int {
        statesByPanelId.values.reduce(0) { partial, panelStates in
            partial + panelStates.values.reduce(0) { $1 == .running ? $0 + 1 : $0 }
        }
    }
}
