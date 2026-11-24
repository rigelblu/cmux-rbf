import CmuxAgentJournal
import CmuxSettings
import Foundation

extension AgentJournalLifecycleCenter {
    static func claimNotification(_ event: AgentJournalEvent, decision: AgentNotificationDecision,
                                  store: AgentJournalStore) -> Bool {
        guard event.draft.attention?.notification != nil else { return false }
        guard decision.disposition == .accepted, let identity = decision.identity else {
            notificationDiagnostic(event.draft, reason: decision.disposition.rawValue)
            return false
        }
        do {
            let accepted = try store.claimNotification(identity: identity)
            notificationDiagnostic(event.draft, reason: accepted ? "accepted" : "deduplicated", identity: identity)
            return accepted
        } catch {
            notificationDiagnostic(event.draft, reason: "receipt-unavailable", identity: identity)
            return false
        }
    }

    /// An idle reminder repeats its turn's completion. cmux-rbf (#cm-128.4, #cm-142.1): once the notification store
    /// recorded that completion, read or unread, no agent's idle reminder comes back as a new notification; an unread
    /// one may get cmux's own reminder instead (AgentUnattendedNudgeDelivery: only with the idle-reminder setting on,
    /// for a turn with no pending work that isn't a prompt turn, and only while the user is away). The durable receipt
    /// is not evidence here: it is claimed before mute and policy gates, so only a completion that was never recorded
    /// keeps its reminder.
    @MainActor
    static func reminderRepeatsAcknowledgedCompletion(
        _ completion: AgentNotificationDecision.RemindedCompletion
    ) -> Bool {
        let state = TerminalNotificationStore.shared.agentNotificationState(correlationKey: completion.correlationKey)
        // cmux-rbf (#cm-128.4, #cm-142.1): an unread recorded completion may get cmux's own reminder instead
        // (AgentUnattendedNudgeDelivery). Tom's rule: "A finished turn left unread gets one banner-only reminder 60 s
        // after it finishes, in cmux's words" (2026-11-02, d189e4fafd). Reading "one" as cmux's reminder alone, any
        // agent's own idle reminder repeats a completion only when it was never recorded, as the fork did before this
        // merge: the conductor's reading (cm-142.1). Upstream's #20547 also keeps the reminder while it is unread.
        return state.recorded
    }

    static func clearInvalidatedNotifications(_ event: AgentJournalEvent, decision: AgentNotificationDecision) {
        // cm-128.2: a clear closes the request but keeps its notification (marked read by the clear) and a waiting Feed card.
        guard event.draft.nativeEvent != AgentClearStateResolver.nativeEvent else { return }
        guard let workspaceID = event.draft.workspaceId.flatMap(UUID.init(uuidString:)),
              let surfaceID = event.draft.surfaceId.flatMap(UUID.init(uuidString:)) else { return }
        for key in decision.invalidatedCorrelationKeys {
            TerminalMutationBus.shared.enqueueClearNotifications(forTabId: workspaceID,
                surfaceId: surfaceID, correlationKey: key)
            if let sessionID = event.draft.sessionId {
                FeedCoordinator.shared.invalidateSemanticRequest(requestId: key, source: event.draft.source, sessionId: sessionID)
            }
        }
    }

    @MainActor
    static func notificationTargetIsCurrent(_ draft: AgentJournalEventDraft) -> Bool {
        notificationTarget(draft) != nil
    }

    @MainActor
    private static func notificationTarget(_ draft: AgentJournalEventDraft) -> (tabId: UUID, surfaceId: UUID)? {
        guard let workspaceID = draft.workspaceId.flatMap(UUID.init(uuidString:)),
              let surfaceID = draft.surfaceId.flatMap(UUID.init(uuidString:)),
              let live = AppDelegate.shared?.agentNotificationDeliveryTarget(
                claimedTabId: workspaceID, surfaceId: surfaceID),
              let panelID = live.surfaceId else {
            notificationDiagnostic(draft, reason: "route-unavailable")
            return nil
        }
        let binding = DockSplitStore.liveStores.first { $0.containsPanel(panelID) }?
            .surfaceResumeBindingsByPanelId[panelID]
            ?? AppDelegate.shared?.workspaceContainingPanel(panelId: panelID,
                preferredWorkspaceId: live.tabId)?.workspace.surfaceResumeBindingsByPanelId[panelID]
        if let binding, binding.isAgentHookBinding {
            guard binding.checkpointId == draft.sessionId,
                  binding.kind == nil || binding.kind?.lowercased() == draft.source.lowercased() else {
                notificationDiagnostic(draft, reason: "session-superseded")
                return nil
            }
        } else {
            let active = SharedLiveAgentIndex.shared.index?.entryForStablePanel(
                workspaceId: live.tabId, panelId: panelID, revalidateProcessEvidence: false)
            guard let sessionID = draft.sessionId,
                  AgentResumeLiveness.hasLiveProcess(for: active, kind: draft.source, sessionId: sessionID) else {
                notificationDiagnostic(draft, reason: "session-unbound")
                return nil
            }
        }
        return (live.tabId, panelID)
    }

    /// cmux-rbf: a new type's one ping is spent only when its banner can show (#cm-124.5). In a muted workspace the
    /// store drops it, and in the pane focused in the frontmost cmux it keeps it inside cmux; either way the type's
    /// name never reaches him, so it is held back before its receipt is claimed and the first one that can show pings.
    /// Every other notification keeps claiming first and lets the store's own mute and focus rules act after. The test
    /// is the reconciler's unmapped branch, not the marker alone: a typed question carries the marker too.
    @MainActor
    static func holdsBackNewTypePing(_ draft: AgentJournalEventDraft) -> Bool {
        guard draft.kind == .stateChanged, draft.declaredPhase == nil,
              AgentNotificationTypeMarker.type(inDetail: draft.detail) != nil,
              let live = notificationTarget(draft) else { return false }
        let store = TerminalNotificationStore.shared
        guard store.isWorkspaceNotificationsMuted(forTabId: live.tabId)
            || store.shouldSuppressExternalDelivery(tabId: live.tabId, surfaceId: live.surfaceId) else { return false }
        notificationDiagnostic(draft, reason: "new-type-held-back")
        return true
    }

    @MainActor
    static func notificationAdmission(_ draft: AgentJournalEventDraft) -> AgentNotificationDelivery? {
        guard let notification = draft.attention?.notification,
              notificationTarget(draft) != nil else { return nil }
        let delivery = AgentNotificationDelivery()
        guard delivery.allows(category: AgentNotifyCategory(rawValue: notification.category), pending: draft.pendingWork) else {
            notificationDiagnostic(draft, reason: "preference-filtered")
            return nil
        }
        return delivery
    }

    @MainActor
    static func deliverNotification(_ event: AgentJournalEvent, identity: String,
                                    admission: AgentNotificationDelivery? = nil) {
        let draft = event.draft
        guard let notification = draft.attention?.notification,
              let delivery = admission ?? notificationAdmission(draft),
              let live = notificationTarget(draft) else { return }
        let liveSurfaceID = live.surfaceId
        let category = AgentNotifyCategory(rawValue: notification.category)
        let alert: NotificationSoundAlertType? = draft.kind == .errorReported ? .errorStalled : category?.soundAlertType
        let sound = alert.flatMap { NotificationSoundOverrideContext(agentID: draft.source, alertType: $0) }
        // cmux-rbf (#cm-128.4, #cm-142.1): the title is the CLI's source line, `<Agent> · <kind>`, and the folder
        // is the subtitle. Upstream's #16869 workspace prefix is not taken here; reject a revert on upstream sync.
        let title = notification.title
        let delivered = delivery.enqueue(
            workspaceID: live.tabId, surfaceID: liveSurfaceID,
            title: title, subtitle: notification.subtitle, body: notification.body,
            category: category, pending: draft.pendingWork, soundContext: sound,
            agentKind: draft.source, isSubagent: draft.isSubagent,
            correlationKey: notification.correlationKey ?? identity,
            sessionId: draft.sessionId,
            coalesces: false,
            sourceTitle: notification.sourceTitle,
            journalKind: draft.kind,
            agentKey: draft.agentKey
        )
        if !delivered { notificationDiagnostic(draft, reason: "preference-filtered", identity: identity) }
    }

    @MainActor
    static func notificationRequestIsCurrent(_ request: TerminalNotificationPolicyRequest) -> Bool {
        guard let sessionID = request.agent?.sessionId, let surfaceID = request.surfaceId else { return true }
        return notificationTargetIsCurrent(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 0,
            source: request.agent?.kind ?? "agent", agentKey: request.agent?.kind ?? "agent",
            sessionId: sessionID, workspaceId: request.tabId.uuidString, surfaceId: surfaceID.uuidString))
    }

    static func notificationDiagnostic(_ draft: AgentJournalEventDraft, reason: String, identity: String? = nil) {
        CmuxEventBus.shared.publish(name: "agent.notification.decision", category: "agent", source: "journal",
            surfaceId: draft.surfaceId, payload: ["reason": reason, "kind": draft.kind.rawValue,
                "agent": draft.source, "identity": identity ?? "", "event_id": draft.eventId])
    }
}
