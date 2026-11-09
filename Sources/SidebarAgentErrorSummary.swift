import Foundation

/// One agent stopped on an error in a workspace, for the sidebar row's triangle. (cm-128.5)
struct SidebarErroredAgent: Equatable, Sendable {
    /// The pane's agent status key, such as `claude_code`.
    let statusKey: String
    /// The agent's name as the row's tooltip says it.
    let displayName: String
    /// Whether the error was a typed usage limit (Claude's `rate_limit`, Codex's `usage_limit_exceeded`).
    let usageLimit: Bool
}

/// The triangle's data and words: which agents stopped on an error, and the one line each tooltip says. (cm-128.5)
enum SidebarAgentErrorSummary {
    /// The agent's name: the built-in definition's display name (one name table, shared with the task manager), and the
    /// bare key when no definition names it, so the function stays total.
    static func displayName(forStatusKey key: String) -> String {
        let source = FeedCoordinator.source(forLifecycleStatusKey: key)
        return CmuxTaskManagerCodingAgentDefinition.builtIns.first { $0.id == source }?.displayName ?? key
    }

    /// Each agent with a pane at `.error`, in the sidebar's pane order, one entry for each distinct (agent, usage limit)
    /// pair. Empty when the row shows no agent activity or no pane holds `.error`; the pane order is not read then.
    static func erroredAgents(
        showsAgentActivity: Bool,
        orderedPanelIds: @autoclosure () -> [UUID],
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]],
        usageLimitKeysByPanelId: [UUID: Set<String>]
    ) -> [SidebarErroredAgent] {
        guard showsAgentActivity,
              statesByPanelId.values.contains(where: { $0.values.contains(.error) })
        else { return [] }
        var seen: Set<String> = []
        var agents: [SidebarErroredAgent] = []
        for panelId in orderedPanelIds() {
            for key in (statesByPanelId[panelId] ?? [:]).filter({ $0.value == .error }).keys.sorted() {
                let flagged = usageLimitKeysByPanelId[panelId]?.contains(key) == true
                guard seen.insert("\(key)|\(flagged)").inserted else { continue }
                agents.append(SidebarErroredAgent(statusKey: key, displayName: displayName(forStatusKey: key), usageLimit: flagged))
            }
        }
        return agents
    }

    /// One tooltip line per errored agent: "<Agent> hit its usage limit" for a typed usage limit, "<Agent> stopped on an
    /// error" for anything else, in pane order. That is one line for each agent and usage-limit state, because
    /// `erroredAgents` already folds panes holding the same agent in the same state into one entry.
    static func tooltipLines(for agents: [SidebarErroredAgent]) -> [String] {
        agents.map { agent in
            agent.usageLimit
                ? String.localizedStringWithFormat(
                    String(localized: "sidebar.agentError.usageLimit.tooltip", defaultValue: "%@ hit its usage limit"),
                    agent.displayName)
                : String.localizedStringWithFormat(
                    String(localized: "sidebar.agentError.stopped.tooltip", defaultValue: "%@ stopped on an error"),
                    agent.displayName)
        }
    }

    /// The tooltip and accessibility label: the lines, one per line.
    static func tooltip(for agents: [SidebarErroredAgent]) -> String { tooltipLines(for: agents).joined(separator: "\n") }
}
