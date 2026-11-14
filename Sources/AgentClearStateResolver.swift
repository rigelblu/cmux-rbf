import CmuxAgentJournal
import Foundation

/// Creates the journal events for Clear Agent State on one workspace. (cm-128.2)
///
/// Every event is written under the agent's own source, so the reconciler closes that agent's open requests: a clear under
/// another source opens a separate session and leaves the wait alive. The user origin is the `nativeEvent` marker, which the
/// app also reads to keep the notifications and a waiting Feed card that every other resolve removes.
struct AgentClearStateResolver: Sendable {
    /// The `native_event` on every event a clear writes.
    static let nativeEvent = "ClearAgentState"

    /// Whether a phase draws a mark on the row today: the hand (needs input, and error until `.5` gives it its own mark)
    /// and the spinner or waveform. Idle and `unknown` draw none, so a clear leaves those sessions, and an idle pane stays hibernatable.
    static func phaseDrawsMark(_ phase: AgentLifecyclePhase) -> Bool {
        switch phase {
        case .needsInput, .running, .monitoring, .error: true
        case .idle, .unknown: false
        }
    }

    /// - Parameters:
    ///   - surfaceIds: The workspace's own panels. Dock panes draw nothing on the row and are not passed in.
    ///   - occurredAtMs: The time of the clear; each session's drafts are stamped no earlier than its last event.
    func drafts(workspaceId: UUID, surfaceIds: [UUID], state: AgentLifecycleReducerState,
                notifications: AgentNotificationReconciler, occurredAtMs: Int64) -> [AgentJournalEventDraft] {
        var drafts: [AgentJournalEventDraft] = []
        for surfaceId in surfaceIds.map(\.uuidString).sorted() {
            let byAgent = state.sessions[surfaceId] ?? [:]
            for agentKey in byAgent.keys.sorted() where AgentHibernationLifecycleStatusKeys.isAllowed(agentKey) {
                let source = FeedCoordinator.source(forLifecycleStatusKey: agentKey)
                let bySession = byAgent[agentKey] ?? [:]
                for sessionId in bySession.keys.sorted() {
                    guard let lifecycle = bySession[sessionId], !lifecycle.ended else { continue }
                    let occurred = max(occurredAtMs, lifecycle.lastOccurredAtMs)
                    func draft(_ kind: AgentJournalEventKind, sessionId: String?, pendingWork: Bool = false,
                               declaredPhase: AgentLifecyclePhase? = nil,
                               attention: AgentAttentionContext? = nil) -> AgentJournalEventDraft {
                        AgentJournalEventDraft(kind: kind, occurredAtMs: occurred, source: source, agentKey: agentKey,
                            sessionId: sessionId, workspaceId: workspaceId.uuidString, surfaceId: surfaceId,
                            pendingWork: pendingWork, nativeEvent: Self.nativeEvent, declaredPhase: declaredPhase,
                            attention: attention)
                    }
                    if sessionId == "@\(source)" {
                        // The session-less bucket: the reconciler holds no request without a session id.
                        if Self.phaseDrawsMark(lifecycle.phase) { drafts.append(draft(.stateChanged, sessionId: nil, declaredPhase: .unknown)) }
                        continue
                    }
                    let requests = notifications.openRequests(source: source, sessionId: sessionId)
                    guard Self.phaseDrawsMark(lifecycle.phase) || requests.count > 0 else { continue }
                    // pendingWork keeps the one hop between a resolve and the `unknown` below on running, never idle.
                    for request in requests.identified {
                        drafts.append(draft(.attentionResolved, sessionId: sessionId, pendingWork: true,
                            attention: AgentAttentionContext(requestIdentity: request)))
                    }
                    // The one id-less request carries the session's own native turn, which is nil for Claude. The count
                    // decides, not `unidentifiedTurn`, which is nil both with no id-less wait and with Claude's.
                    if requests.count - requests.identified.count == 1 {
                        drafts.append(draft(.attentionResolved, sessionId: sessionId, pendingWork: true,
                            attention: AgentAttentionContext(turnIdentity: requests.nativeTurn)))
                    }
                    drafts.append(draft(.stateChanged, sessionId: sessionId, declaredPhase: .unknown))
                }
            }
        }
        return drafts
    }
}
