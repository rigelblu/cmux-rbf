import Foundation

/// Clear Agent State (cm-128.2): the one action behind the row menu, the command palette and `cmux clear-agent-state`, and
/// the one check that enables the first two.
extension Workspace {
    /// Whether a sidebar status entry is an agent's pill: keyed by an allowed agent key, by `<key>.<sessionId>`, or by a
    /// Feed attention slot. His own `set-status` pills are none of these.
    nonisolated static func isAgentStatusPillKey(_ key: String) -> Bool {
        if key.hasPrefix(FeedCoordinator.attentionStatusKeyPrefix) { return true }
        let head = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key
        return AgentHibernationLifecycleStatusKeys.isAllowed(head)
    }

    /// Whether a per-pane lifecycle key can hold an agent mark: an allowed agent key, or a Feed attention slot. Manual
    /// loading keys (`manual`, `manual:<id>`) are neither.
    nonisolated static func isAgentMarkLifecycleKey(_ key: String) -> Bool {
        AgentHibernationLifecycleStatusKeys.isAllowed(key) || key.hasPrefix(FeedCoordinator.attentionStatusKeyPrefix)
    }

    /// **The** enabled check for Clear Agent State, read by the menu item (both builders) and the palette entry: any agent
    /// mark (needs you, running or monitoring, from any writer) or agent pill on any of the workspace's panels. `unknown`, which a clear
    /// leaves, does not count, and neither does Dock-pane state.
    var hasClearableAgentState: Bool {
        for (panelId, states) in agentLifecycleStatesByPanelId where panels[panelId] != nil {
            for (key, state) in states where Self.isAgentMarkLifecycleKey(key) && (state == .needsInput || state == .error || state == .running || state == .monitoring) {
                return true
            }
        }
        return statusEntries.keys.contains(where: Self.isAgentStatusPillKey)
    }

    /// Clears the workspace's wrong agent state in one step and keeps it cleared: writes the journal under each agent's own
    /// source, drops the Feed's attention slot (the card stays), sets every other mark to `unknown`, removes the agent pills
    /// and marks every notification read (kept, not deleted; his own unread marks stay). Never writes `idle`, so a clear
    /// never makes a pane hibernatable. With nothing to clear it changes nothing.
    /// - Returns: Whether there was agent state to clear.
    @discardableResult
    func clearAgentState(journal: AgentJournalLifecycleCenter = .shared, feed: FeedCoordinator = .shared,
                         notifications: TerminalNotificationStore = .shared) -> Bool {
        guard hasClearableAgentState else { return false }
        journal.clearAgentState(workspaceId: id, surfaceIds: Array(panels.keys))
        let droppedSlots = feed.drainAttention(inWorkspace: self)
        var droppedSlotKeysByPanel: [UUID: [String]] = Dictionary(grouping: droppedSlots, by: \.panelId)
            .mapValues { $0.map(\.statusKey) }
        for panelId in Array(agentLifecycleStatesByPanelId.keys) where panels[panelId] != nil {
            for (key, state) in agentLifecycleStatesByPanelId[panelId] ?? [:] where Self.isAgentMarkLifecycleKey(key) {
                if key.hasPrefix(FeedCoordinator.attentionStatusKeyPrefix) {
                    // A slot with no pending decision behind it: nobody else will remove it.
                    clearAgentLifecycle(key: key, panelId: panelId)
                    droppedSlotKeysByPanel[panelId, default: []].append(key)
                } else if state == .needsInput || state == .error || state == .running || state == .monitoring {
                    // `unknown`, never a removal: with no key left the pane would fall back to the CLI's record, which can be
                    // `idle` and hibernatable.
                    setAgentLifecycle(key: key, panelId: panelId, lifecycle: .unknown)
                }
            }
        }
        // A pane the Feed slot was the only agent key of must still read `unknown`, not the CLI record's `idle`.
        let slotPrefix = FeedCoordinator.attentionStatusKeyPrefix
        for (panelId, slotKeys) in droppedSlotKeysByPanel where panels[panelId] != nil {
            let hasAgentKey = (agentLifecycleStatesByPanelId[panelId] ?? [:]).keys.contains {
                !AgentHibernationLifecycleStatusKeys.isManualKey($0)
            }
            guard !hasAgentKey, let slotKey = slotKeys.first else { continue }
            let agentKey = String(slotKey.dropFirst(slotPrefix.count))
            if AgentHibernationLifecycleStatusKeys.isAllowed(agentKey) {
                setAgentLifecycle(key: agentKey, panelId: panelId, lifecycle: .unknown)
            }
        }
        for key in Array(statusEntries.keys) where Self.isAgentStatusPillKey(key) {
            statusEntries.removeValue(forKey: key)
        }
        notifications.markRead(forTabId: id, keepingOwnUnreadMarks: true)
        return true
    }
}

extension TabManager {
    /// The menu entrances' enabled check over a selection: any target has agent state to clear. (cm-128.2)
    func canClearAgentState(workspaceIds: [UUID]) -> Bool {
        workspaceIds.contains { workspacesById[$0]?.hasClearableAgentState == true }
    }

    /// The menu entrances' action over a selection: each target runs the one shared action. (cm-128.2)
    func clearAgentState(workspaceIds: [UUID], notifications: TerminalNotificationStore = .shared) {
        for id in workspaceIds {
            workspacesById[id]?.clearAgentState(notifications: notifications)
        }
    }
}
