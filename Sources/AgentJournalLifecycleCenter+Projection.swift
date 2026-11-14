import CmuxAgentJournal
import Foundation

extension AgentJournalLifecycleCenter {
    // MARK: - Consumer

    struct LifecycleApplication: Sendable {
        let assignment: AgentLifecycleAssignment
        let workspaceHint: String?
    }

    static func reduceIngest(
        _ event: AgentJournalEvent,
        aliases: AgentJournalAliasResolver,
        reducer: AgentLifecycleReducer,
        state: inout AgentLifecycleReducerState
    ) -> LifecycleApplication? {
        guard event.kind != .messagePublished else { return nil }
        let canonical = canonicalized(event, aliases: aliases)
        reducer.apply(canonical, to: &state)
        guard canonical.draft.unattributedReason == nil else {
            publishUnattributedDiagnostic(canonical)
            return nil
        }
        guard let surfaceId = canonical.draft.surfaceId else {
            publishUnattributedDiagnostic(canonical)
            return nil
        }
        guard !canonical.draft.isSubagent else { return nil }
        return LifecycleApplication(
            assignment: AgentLifecycleAssignment(
                surfaceId: surfaceId,
                agentKey: canonical.agentKey,
                phase: state.combinedPhase(surfaceId: surfaceId, agentKey: canonical.agentKey),
                usageLimit: state.hasUsageLimit(surfaceId: surfaceId, agentKey: canonical.agentKey)
            ),
            workspaceHint: canonical.draft.workspaceId
        )
    }

    static func reduceStartupReplay(
        store: AgentJournalStore,
        aliases: AgentJournalAliasResolver,
        reducer: AgentLifecycleReducer,
        replayPolicy: AgentJournalReplayPolicy,
        state: inout AgentLifecycleReducerState,
        notifications: inout AgentNotificationReconciler,
        liveness: AgentSessionLivenessResolver = AgentSessionLivenessResolver() // cm-128.1: ends waits of agents that are gone
    ) -> [AgentLifecycleAssignment] {
        var cursor: Int64 = 0
        var folded = 0
        var skipped = 0
        // cm-128.1: where each session last reported from, so a wait found dead below is ended on its own pane.
        var origins: [SessionOrigin: (source: String, workspaceId: String)] = [:]
        while true {
            let page: AgentJournalReadPage
            do {
                page = try store.readPage(afterSequence: cursor, limit: 2_048)
            } catch {
                // An incomplete fold must not paint partial replay state:
                // record the failure and paint nothing (live events still
                // reduce and self-correct per session).
                CmuxEventBus.shared.publish(
                    name: "agent.journal.replay_failed",
                    category: "agent",
                    source: "journal",
                    payload: ["cursor": cursor, "folded": folded]
                )
#if DEBUG
                cmuxDebugLog("agentJournal.replay.error cursor=\(cursor) \(String(describing: error))")
#endif
                return []
            }
            if page.isEmpty { break }
            for event in page.events {
                let canonical = canonicalized(event, aliases: aliases)
                fold(canonical, reducer: reducer, state: &state, notifications: &notifications)
                let draft = canonical.draft
                if !draft.isSubagent, let surfaceId = draft.surfaceId, let workspaceId = draft.workspaceId,
                   let sessionId = draft.sessionId {
                    origins[SessionOrigin(surfaceId: surfaceId, agentKey: canonical.agentKey, sessionId: sessionId)] =
                        (draft.source, workspaceId)
                }
            }
            folded += page.events.count
            skipped += page.skippedSequences.count
            // Advance over undecodable rows too so a foreign-schema run can
            // never stall the fold or hide the events behind it.
            cursor = page.scannedThroughSequence
        }
        // cm-128.1: a relaunch tore down the PTYs, so end the waits and errors whose agent is confirmed gone before painting.
        endDeadSessions(store: store, origins: origins, liveness: liveness, reducer: reducer,
                        state: &state, notifications: &notifications, aliases: aliases)
        let startup = replayPolicy.startupSnapshot(from: state.snapshot())
        var assignments: [AgentLifecycleAssignment] = []
        for (surfaceId, byAgent) in startup.phases {
            for (agentKey, phase) in byAgent {
                assignments.append(
                    AgentLifecycleAssignment(surfaceId: surfaceId, agentKey: agentKey, phase: phase,
                        usageLimit: startup.usageLimitAgentKeys[surfaceId]?.contains(agentKey) == true)
                )
            }
        }
#if DEBUG
        cmuxDebugLog(
            "agentJournal.replay folded=\(folded) skipped=\(skipped) " +
                "painted=\(assignments.count) unattributed=\(state.unattributedEvents.count)"
        )
#endif
        return assignments
    }

    // cm-128.1: the startup replay's liveness pass.
    private struct SessionOrigin: Hashable {
        let surfaceId: String
        let agentKey: String
        let sessionId: String
    }

    private static func fold(
        _ canonical: AgentJournalEvent,
        reducer: AgentLifecycleReducer,
        state: inout AgentLifecycleReducerState,
        notifications: inout AgentNotificationReconciler
    ) {
        let decision = notifications.apply(canonical)
        if decision.disposition != .stale, decision.projectsLifecycle {
            reducer.apply(notifications.lifecycleEvent(canonical), to: &state)
        }
    }

    /// A relaunch tears down the local PTYs, so a wait or error the journal kept may belong to an agent that is gone.
    /// Journals `sessionEnded` for each one whose process is confirmed gone, and folds it in so the next replay finds the
    /// session already ended. Anything short of confirmation (no record, no PID, unreadable evidence) keeps the mark: a
    /// missed answer costs more than a stale hand, which Clear Agent State removes.
    private static func endDeadSessions(
        store: AgentJournalStore,
        origins: [SessionOrigin: (source: String, workspaceId: String)],
        liveness: AgentSessionLivenessResolver,
        reducer: AgentLifecycleReducer,
        state: inout AgentLifecycleReducerState,
        notifications: inout AgentNotificationReconciler,
        aliases: AgentJournalAliasResolver
    ) {
        var ended: [AgentJournalEvent] = []
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        for (surfaceId, byAgent) in state.sessions {
            for (agentKey, bySession) in byAgent {
                for (sessionId, lifecycle) in bySession
                where !lifecycle.ended && (lifecycle.phase == .needsInput || lifecycle.phase == .error) {
                    guard let origin = origins[SessionOrigin(surfaceId: surfaceId, agentKey: agentKey, sessionId: sessionId)],
                          liveness.liveness(source: origin.source, sessionId: sessionId) == .dead else { continue }
                    let draft = AgentJournalEventDraft(kind: .sessionEnded,
                        occurredAtMs: max(nowMs, lifecycle.lastOccurredAtMs), source: origin.source,
                        agentKey: agentKey, sessionId: sessionId, workspaceId: origin.workspaceId,
                        surfaceId: surfaceId, nativeEvent: "StartupProcessGone")
                    // Unrecorded means unproven here: keep the wait rather than hide it.
                    guard let outcome = try? store.append(draft) else { continue }
                    ended.append(AgentJournalEvent(sequence: outcome.sequence,
                        committedAtMs: outcome.committedAtMs, draft: draft))
                }
            }
        }
        for event in ended {
            fold(canonicalized(event, aliases: aliases), reducer: reducer, state: &state, notifications: &notifications)
        }
    }

    /// Rewrites the event's identity through the restore alias chains so
    /// sessions that span an app relaunch reduce under one canonical surface.
    static func canonicalized(
        _ event: AgentJournalEvent,
        aliases: AgentJournalAliasResolver
    ) -> AgentJournalEvent {
        var draft = event.draft
        // A nil resolution means the alias chain hit its cycle cap (corrupt
        // alias state): the current identity is unknowable, so fail closed —
        // strip the target and keep the event as an explicit diagnostic
        // instead of applying state under a possibly stale identity.
        var cycled = false
        if let surfaceId = draft.surfaceId {
            if let resolved = aliases.resolvedSurfaceId(surfaceId) {
                draft.surfaceId = resolved
            } else {
                cycled = true
            }
        }
        if let workspaceId = draft.workspaceId {
            if let resolved = aliases.resolvedWorkspaceId(workspaceId) {
                draft.workspaceId = resolved
            } else {
                cycled = true
            }
        }
        if cycled {
            draft.workspaceId = nil
            draft.surfaceId = nil
            draft.unattributedReason = "alias-cycle"
        }
        return AgentJournalEvent(
            sequence: event.sequence,
            committedAtMs: event.committedAtMs,
            draft: draft
        )
    }

    static func publishUnattributedDiagnostic(_ event: AgentJournalEvent) {
        CmuxEventBus.shared.publish(
            name: "agent.journal.unattributed",
            category: "agent",
            source: "journal",
            payload: [
                "sequence": event.sequence,
                "kind": event.kind.rawValue,
                "agent": event.draft.source,
                "agent_key": event.agentKey,
                "native_event": event.draft.nativeEvent ?? "",
                "reason": event.draft.unattributedReason ?? "missing-surface",
            ]
        )
#if DEBUG
        cmuxDebugLog(
            "agentJournal.unattributed seq=\(event.sequence) kind=\(event.kind.rawValue) " +
                "agent=\(event.draft.source) reason=\(event.draft.unattributedReason ?? "missing-surface")"
        )
#endif
    }

    /// - Parameter appDelegate: Where to look the panel up; `AppDelegate.shared` when nil. A center built for a test passes
    ///   its own, so a suite that reassigns `AppDelegate.shared` meanwhile cannot redirect the projection. (cm-128.2)
    @MainActor
    static func apply(_ assignment: AgentLifecycleAssignment, workspaceHint: String?, appDelegate: AppDelegate? = nil) {
        guard AgentHibernationLifecycleStatusKeys.isAllowed(assignment.agentKey) else { return }
        guard let panelId = UUID(uuidString: assignment.surfaceId) else { return }
        let owner: ControlSidebarPanelOwner?
        if let dock = DockSplitStore.liveStores.first(where: { $0.containsPanel(panelId) }) {
            owner = .dock(dock)
        } else if let located = (appDelegate ?? AppDelegate.shared)?.workspaceContainingPanel(
            panelId: panelId,
            preferredWorkspaceId: workspaceHint.flatMap(UUID.init(uuidString:))
        ) {
            owner = .workspace(located.workspace)
        } else {
            owner = nil
        }
        guard let owner else {
            // Fail closed and record it in release builds too: the panel no
            // longer exists, so the assignment is dropped, never re-homed.
            CmuxEventBus.shared.publish(
                name: "agent.journal.apply_skipped",
                category: "agent",
                source: "journal",
                surfaceId: assignment.surfaceId,
                payload: ["agent_key": assignment.agentKey, "reason": "panelGone"]
            )
#if DEBUG
            cmuxDebugLog(
                "agentJournal.apply.skip surface=\(assignment.surfaceId.prefix(8)) " +
                    "key=\(assignment.agentKey) reason=panelGone"
            )
#endif
            return
        }
        if let phase = assignment.phase {
            // The flag first: the lifecycle write publishes the row, which reads it. A Dock pane has no triangle.
            if phase == .error, case .workspace(let workspace) = owner {
                // An error to an error with no limit drops a flag the key held: the reducer already did.
                if assignment.usageLimit {
                    workspace.setAgentUsageLimit(key: assignment.agentKey, panelId: panelId)
                } else {
                    workspace.removeAgentUsageLimit(key: assignment.agentKey, panelId: panelId)
                }
            }
            owner.setAgentLifecycle(
                key: assignment.agentKey,
                panelId: panelId,
                lifecycle: Self.lifecycle(for: phase)
            )
        } else {
            owner.clearAgentLifecycle(key: assignment.agentKey, panelId: panelId)
        }
#if DEBUG
        cmuxDebugLog(
            "agentJournal.apply surface=\(assignment.surfaceId.prefix(8)) " +
                "key=\(assignment.agentKey) phase=\(assignment.phase?.rawValue ?? "clear")"
        )
#endif
    }

    /// Projects the journal phase onto the sidebar's lifecycle enum. An error is its own per-pane value (cm-128.5, Tom,
    /// grill Q10): the hand reads needs-input only, and every other needs-you reader counts the error too.
    static func lifecycle(for phase: AgentLifecyclePhase) -> AgentHibernationLifecycleState {
        switch phase {
        case .unknown: .unknown
        case .running: .running
        case .monitoring: .monitoring
        case .needsInput: .needsInput
        case .idle: .idle
        case .error: .error
        }
    }

}
