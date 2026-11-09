/// Combined lifecycle view derived from the journal: `surfaceId → agentKey →
/// phase`, plus the newest producer timestamp behind each entry.
///
/// Consumers diff successive snapshots and apply the delta to the sidebar
/// (set changed entries, clear vanished ones).
public struct AgentLifecycleSnapshot: Sendable, Equatable {
    /// Combined phase per surface and agent key.
    public var phases: [String: [String: AgentLifecyclePhase]]
    /// Producer timestamp (ms since Unix epoch) of the newest live event
    /// behind each entry; used by replay policy decisions.
    public var newestOccurredAtMs: [String: [String: Int64]]
    /// Agent keys per surface whose error is a typed usage limit (cm-128.5), for the triangle's tooltip.
    public var usageLimitAgentKeys: [String: Set<String>]

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - phases: Combined phase per surface and agent key.
    ///   - newestOccurredAtMs: Newest producer timestamp behind each entry.
    public init(
        phases: [String: [String: AgentLifecyclePhase]] = [:],
        newestOccurredAtMs: [String: [String: Int64]] = [:],
        usageLimitAgentKeys: [String: Set<String>] = [:]
    ) {
        self.phases = phases
        self.newestOccurredAtMs = newestOccurredAtMs
        self.usageLimitAgentKeys = usageLimitAgentKeys
    }

    /// Computes the assignments needed to move the sidebar from `previous`
    /// to this snapshot.
    ///
    /// - Parameter previous: The last applied snapshot.
    /// - Returns: Assignments for every changed entry, including explicit
    ///   clears (`phase == nil`) for entries that vanished.
    public func assignments(since previous: AgentLifecycleSnapshot) -> [AgentLifecycleAssignment] {
        var result: [AgentLifecycleAssignment] = []
        for (surfaceId, byAgent) in phases {
            for (agentKey, phase) in byAgent {
                let usageLimit = usageLimitAgentKeys[surfaceId]?.contains(agentKey) == true
                let previousUsageLimit = previous.usageLimitAgentKeys[surfaceId]?.contains(agentKey) == true
                guard previous.phases[surfaceId]?[agentKey] != phase || usageLimit != previousUsageLimit else { continue }
                result.append(
                    AgentLifecycleAssignment(surfaceId: surfaceId, agentKey: agentKey, phase: phase, usageLimit: usageLimit)
                )
            }
        }
        for (surfaceId, byAgent) in previous.phases {
            for (agentKey, _) in byAgent where phases[surfaceId]?[agentKey] == nil {
                result.append(
                    AgentLifecycleAssignment(surfaceId: surfaceId, agentKey: agentKey, phase: nil)
                )
            }
        }
        return result.sorted { lhs, rhs in
            (lhs.surfaceId, lhs.agentKey) < (rhs.surfaceId, rhs.agentKey)
        }
    }
}
