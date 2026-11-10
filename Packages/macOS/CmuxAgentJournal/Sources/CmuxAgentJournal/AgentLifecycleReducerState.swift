/// Accumulated reducer state: per-surface, per-agent, per-session lifecycle.
///
/// Keys are the identity strings recorded on the events themselves (the
/// runtime UUIDs at emit time); alias resolution to the current runtime
/// identity happens in the projection layer, not here, so the fold stays a
/// pure function of the event stream.
public struct AgentLifecycleReducerState: Sendable, Equatable {
    /// `surfaceId → agentKey → sessionKey → state`.
    public private(set) var sessions: [String: [String: [String: AgentSessionLifecycleState]]]
    /// Unattributed diagnostic events seen by the fold (bounded).
    public private(set) var unattributedEvents: [AgentJournalEvent]
    /// Highest sequence this state has folded.
    public private(set) var headSequence: Int64

    /// Bound on retained unattributed diagnostics.
    public static let maximumRetainedUnattributedEvents = 256

    /// Creates an empty state.
    public init() {
        self.sessions = [:]
        self.unattributedEvents = []
        self.headSequence = 0
    }

    /// The session key an event folds into: the native session id when the
    /// adapter provides one, otherwise a per-source singleton bucket.
    ///
    /// - Parameter draft: The event's draft.
    /// - Returns: The session key.
    public static func sessionKey(for draft: AgentJournalEventDraft) -> String {
        if let sessionId = draft.sessionId, !sessionId.isEmpty {
            return sessionId
        }
        return "@\(draft.source)"
    }

    /// The newest live session of one agent (cm-128.6): the greater `lastOccurredAtMs`, and on a tie the greater
    /// `lastSequence`. Older live sessions of the same agent draw nothing, and a running one no longer outranks a newer
    /// waiting one. `nil` when every session has ended.
    private static func newestLiveSession(
        in bySession: [String: AgentSessionLifecycleState]
    ) -> AgentSessionLifecycleState? {
        bySession.values.filter { !$0.ended }.max { lhs, rhs in
            if lhs.lastOccurredAtMs != rhs.lastOccurredAtMs { return lhs.lastOccurredAtMs < rhs.lastOccurredAtMs }
            return lhs.lastSequence < rhs.lastSequence
        }
    }

    /// Combined phase for one surface/agent pair: the newest live session's phase (cm-128.6), or `nil` when every
    /// session has ended (the sidebar entry clears).
    ///
    /// - Parameters:
    ///   - surfaceId: The surface UUID string as recorded on events.
    ///   - agentKey: The sidebar lifecycle status key.
    /// - Returns: The combined phase, or `nil`.
    public func combinedPhase(surfaceId: String, agentKey: String) -> AgentLifecyclePhase? { // (cm-128.6)
        guard let bySession = sessions[surfaceId]?[agentKey] else { return nil }
        return Self.newestLiveSession(in: bySession)?.phase
    }

    /// Whether the agent's error on `surfaceId` is a typed usage limit (cm-128.5): the newest live session is at `.error`
    /// and carries the flag. cm-128.6: the winning session's own flag, not the newest error session's.
    public func hasUsageLimit(surfaceId: String, agentKey: String) -> Bool { // (cm-128.6)
        guard let bySession = sessions[surfaceId]?[agentKey],
              let newest = Self.newestLiveSession(in: bySession), newest.phase == .error else { return false }
        return newest.usageLimit
    }

    /// Full combined snapshot across all surfaces and agents.
    ///
    /// - Returns: The snapshot the projection layer diffs and applies.
    public func snapshot() -> AgentLifecycleSnapshot { // (cm-128.6)
        var phases: [String: [String: AgentLifecyclePhase]] = [:]
        var newestOccurredAtMs: [String: [String: Int64]] = [:]
        var usageLimitAgentKeys: [String: Set<String>] = [:]
        for (surfaceId, byAgent) in sessions {
            for (agentKey, bySession) in byAgent {
                guard let newest = Self.newestLiveSession(in: bySession) else { continue }
                phases[surfaceId, default: [:]][agentKey] = newest.phase
                // The newest live session's own time, which is also the largest (cm-128.6).
                newestOccurredAtMs[surfaceId, default: [:]][agentKey] = newest.lastOccurredAtMs
                if hasUsageLimit(surfaceId: surfaceId, agentKey: agentKey) {
                    usageLimitAgentKeys[surfaceId, default: []].insert(agentKey)
                }
            }
        }
        return AgentLifecycleSnapshot(
            phases: phases, newestOccurredAtMs: newestOccurredAtMs, usageLimitAgentKeys: usageLimitAgentKeys)
    }

    mutating func recordUnattributed(_ event: AgentJournalEvent) {
        unattributedEvents.append(event)
        if unattributedEvents.count > Self.maximumRetainedUnattributedEvents {
            unattributedEvents.removeFirst(
                unattributedEvents.count - Self.maximumRetainedUnattributedEvents
            )
        }
    }

    mutating func advanceHead(to sequence: Int64) {
        headSequence = max(headSequence, sequence)
    }

    mutating func updateSession(
        surfaceId: String,
        agentKey: String,
        sessionKey: String,
        state: AgentSessionLifecycleState
    ) {
        sessions[surfaceId, default: [:]][agentKey, default: [:]][sessionKey] = state
    }

    func session(
        surfaceId: String,
        agentKey: String,
        sessionKey: String
    ) -> AgentSessionLifecycleState? {
        sessions[surfaceId]?[agentKey]?[sessionKey]
    }
}
