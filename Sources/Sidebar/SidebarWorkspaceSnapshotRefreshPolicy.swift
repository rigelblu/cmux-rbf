import CmuxWorkspaces

extension SidebarWorkspaceSnapshotBuilder.Snapshot {
    struct ContextMenuImmediateFields: Equatable {
        let title: String
        let customDescription: String?
        let isPinned: Bool
        let isMuted: Bool
        let cloudWorkspaceLabel: String?
        let customColorHex: String?
        let finderDirectoryPath: String?
        let mediaActivity: BrowserMediaActivity
        let taskStatus: WorkspaceTaskStatus?
        let todoStatusMenuModel: SidebarWorkspaceCompactStatusMenuModel?
        let hasManualTaskStatus: Bool
        let attentionTaskStatus: WorkspaceTaskStatus?
        let checklistItems: [WorkspaceChecklistItem]
        let checklistCompletedCount: Int
        let checklistTotalCount: Int
        let checklistFirstUncheckedText: String?
        let taskStatusInput: SidebarWorkspaceTaskStatusSnapshot
        /// cm-128.6: the lists in the places of the spinner's count, the hand, the triangle and the waveform's count; the
        /// three counts below are computed from them, so a changed name or count redraws the row.
        let agentLists: SidebarAgentStateLists
        var showsRaisedHand: Bool { agentLists.showsRaisedHand } // (#cm-109.3)
        var activeCodingAgentCount: Int { agentLists.activeCodingAgentCount }
        var monitoringAgentCount: Int { agentLists.monitoringAgentCount }
    }

    var contextMenuImmediateFields: ContextMenuImmediateFields {
        ContextMenuImmediateFields(
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            isMuted: isMuted,
            cloudWorkspaceLabel: cloudWorkspaceLabel,
            customColorHex: customColorHex,
            finderDirectoryPath: finderDirectoryPath,
            mediaActivity: mediaActivity,
            taskStatus: taskStatus,
            todoStatusMenuModel: todoStatusMenuModel,
            hasManualTaskStatus: hasManualTaskStatus,
            attentionTaskStatus: attentionTaskStatus,
            checklistItems: checklistItems,
            checklistCompletedCount: checklistCompletedCount,
            checklistTotalCount: checklistTotalCount,
            checklistFirstUncheckedText: checklistFirstUncheckedText,
            taskStatusInput: taskStatusInput,
            agentLists: agentLists // (cm-128.6)
        )
    }

    func applyingContextMenuImmediateFields(from snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot) -> Self {
        guard contextMenuImmediateFields != snapshot.contextMenuImmediateFields else { return self }
        return Self(
            presentationKey: snapshot.presentationKey,
            title: snapshot.title,
            customDescription: snapshot.customDescription,
            isPinned: snapshot.isPinned,
            isMuted: snapshot.isMuted,
            customColorHex: snapshot.customColorHex,
            cloudWorkspaceLabel: snapshot.cloudWorkspaceLabel,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            showsRemoteReconnectAffordance: showsRemoteReconnectAffordance,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: latestConversationMessage,
            metadataEntries: metadataEntries,
            metadataBlocks: metadataBlocks,
            latestLog: latestLog,
            progress: progress,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: listeningPorts,
            finderDirectoryPath: snapshot.finderDirectoryPath,
            // Media activity drives a leading row glyph, so stale values are
            // visually worse than ordinary telemetry text while the menu is open.
            mediaActivity: snapshot.mediaActivity,
            // Todo status/checklist are mutated FROM this context menu (Status
            // submenu, Mark as Done, checkbox clicks), so the done-row dim,
            // the strip suppression (`attentionTaskStatus`), and the checklist
            // must reflect the change immediately, not on menu close.
            taskStatus: snapshot.taskStatus,
            todoStatusMenuModel: snapshot.todoStatusMenuModel,
            hasManualTaskStatus: snapshot.hasManualTaskStatus,
            attentionTaskStatus: snapshot.attentionTaskStatus,
            checklistItems: snapshot.checklistItems,
            checklistCompletedCount: snapshot.checklistCompletedCount,
            checklistTotalCount: snapshot.checklistTotalCount,
            checklistFirstUncheckedText: snapshot.checklistFirstUncheckedText,
            taskStatusInput: snapshot.taskStatusInput,
            // cm-128.6: the lists carry the hand, the triangle, the spinner and the waveform, which are leading row glyphs like
            // mediaActivity, so they also update immediately while the context menu is open.
            agentLists: snapshot.agentLists
        )
    }
}

// Context-menu actions should update stable row affordances immediately while
// keeping telemetry-heavy sidebar details frozen until the menu lifecycle ends.
struct SidebarWorkspaceSnapshotRefreshPolicy {
    struct Decision: Equatable {
        let workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
        let pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
        let hasDeferredWorkspaceObservationInvalidation: Bool
    }

    func decision(
        current: SidebarWorkspaceSnapshotBuilder.Snapshot?,
        next: SidebarWorkspaceSnapshotBuilder.Snapshot,
        force: Bool,
        contextMenuVisible: Bool
    ) -> Decision {
        guard contextMenuVisible else {
            return Decision(
                workspaceSnapshotStorage: force || current != next ? next : current,
                pendingWorkspaceSnapshot: nil,
                hasDeferredWorkspaceObservationInvalidation: false
            )
        }

        let displayedBaseline = current ?? next
        let displayedSnapshot = displayedBaseline.applyingContextMenuImmediateFields(from: next)
        let hasDeferredChanges = force || displayedSnapshot != next

        return Decision(
            workspaceSnapshotStorage: displayedSnapshot,
            pendingWorkspaceSnapshot: hasDeferredChanges ? next : nil,
            hasDeferredWorkspaceObservationInvalidation: hasDeferredChanges
        )
    }
}
