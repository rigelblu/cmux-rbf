import CmuxAgentJournal
import Foundation

/// Creates the journal events for accepted human input on one pane.
struct AgentPaneInputResolver: Sendable {
    struct Session {
        let source: String
        let agentKey: String
        let sessionId: String
        let lifecycle: AgentSessionLifecycleState
    }

    func newestSession(surfaceId: String, state: AgentLifecycleReducerState) -> Session? {
        var newest: Session?
        for (agentKey, sessions) in state.sessions[surfaceId] ?? [:] {
            guard AgentHibernationLifecycleStatusKeys.isAllowed(agentKey) else { continue }
            let source = FeedCoordinator.source(forLifecycleStatusKey: agentKey)
            for (sessionId, lifecycle) in sessions where !lifecycle.ended && sessionId != "@\(source)" {
                if let previous = newest,
                   lifecycle.lastOccurredAtMs < previous.lifecycle.lastOccurredAtMs
                    || (lifecycle.lastOccurredAtMs == previous.lifecycle.lastOccurredAtMs
                        && lifecycle.lastSequence <= previous.lifecycle.lastSequence) { continue }
                newest = Session(source: source, agentKey: agentKey, sessionId: sessionId, lifecycle: lifecycle)
            }
        }
        return newest
    }

    func drafts(workspaceId: UUID, surfaceId: UUID, isEscape: Bool,
                state: AgentLifecycleReducerState, notifications: AgentNotificationReconciler,
                occurredAtMs: Int64) -> [AgentJournalEventDraft] {
        guard let session = newestSession(surfaceId: surfaceId.uuidString, state: state) else { return [] }
        let requests = notifications.openRequests(source: session.source, sessionId: session.sessionId)
        guard requests.count == 1 || (requests.count == 0 && isEscape && session.lifecycle.phase == .running) else { return [] }
        let occurred = max(occurredAtMs, session.lifecycle.lastOccurredAtMs)
        var drafts: [AgentJournalEventDraft] = []
        if requests.count == 1 {
            drafts.append(AgentJournalEventDraft(kind: .attentionResolved, occurredAtMs: occurred,
                source: session.source, agentKey: session.agentKey, sessionId: session.sessionId,
                workspaceId: workspaceId.uuidString, surfaceId: surfaceId.uuidString,
                pendingWork: false, nativeEvent: "PaneInput",
                attention: AgentAttentionContext(turnIdentity: requests.nativeTurn)))
        }
        if isEscape {
            drafts.append(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: occurred,
                source: session.source, agentKey: session.agentKey, sessionId: session.sessionId,
                workspaceId: workspaceId.uuidString, surfaceId: surfaceId.uuidString,
                nativeEvent: "PaneInput", declaredPhase: .unknown))
        }
        return drafts
    }
}
