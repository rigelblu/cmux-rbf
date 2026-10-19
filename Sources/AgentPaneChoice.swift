import Foundation

// cmux-rbf #cm-73.17: the Reply panel and Figma menu share this stable choice.
struct AgentPaneChoice {
    static func resolve(agentPanelIDs: [UUID], focused: UUID?, sticky: UUID?, live: Set<UUID>) -> UUID? {
        if let focused, agentPanelIDs.contains(focused) { return focused }
        if let sticky, agentPanelIDs.contains(sticky) { return sticky }
        let liveCandidates = agentPanelIDs.filter { live.contains($0) }
        return (liveCandidates.isEmpty ? agentPanelIDs : liveCandidates).min { $0.uuidString < $1.uuidString }
    }
}
