import CmuxSettings
import CmuxWorkspaces
import Foundation

// This window's side of the reveal a move runs (#cm-110.14): the status group and the `Statuses` area, the color group, and
// `Pinned` or `Workspaces`. The selection's reveal (`prepareStatusGroupsForSelection`) already opens them for any workspace it is
// given, so a move reuses it. Fold changes happen where a move commits, never while drawing a row.
@MainActor
extension SidebarState {
    /// Joins a window's manager to this sidebar, so every move that manager commits reaches this window's folds.
    func installMoveReveal(on tabManager: TabManager) {
        tabManager.sidebarMoveReveal = SidebarMoveReveal(
            place: { [weak self, weak tabManager] workspace in
                guard let self, let tabManager else { return SidebarMovePlace() }
                return self.movePlace(of: workspace, tabManager: tabManager)
            },
            reveal: { [weak self, weak tabManager] workspace, cause, scrollsSelected in
                guard let self, let tabManager else { return }
                self.revealMoved(workspace, tabManager: tabManager, cause: cause, scrollsSelected: scrollsSelected)
            }
        )
    }

    func movePlace(of workspace: Workspace, tabManager: TabManager) -> SidebarMovePlace {
        let place = statusSidePlace(
            containing: workspace, list: AppDelegate.statusListInUse,
            resolvedHexByStatusId: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
            workspaceGroups: tabManager.workspaceGroups
        )
        return SidebarMovePlace(
            statusId: place?.statusId,
            isPinned: place?.isPinned ?? drawnPin(of: workspace, workspaceGroups: tabManager.workspaceGroups),
            // The color group the row is drawn in: a row in a workspace group, or under a status group, is not in one.
            colorHex: workspace.groupId == nil && place?.statusId == nil ? workspace.customColor.flatMap(WorkspaceColorHex.normalized) : nil,
            groupId: workspace.groupId
        )
    }

    /// The pin a row is drawn under when there is no status projection (the built-in list): the outermost group's, as
    /// `statusSidePlace` takes it, never the row's own pin while it sits in a group (#cm-110.14, fix round 2).
    private func drawnPin(of workspace: Workspace, workspaceGroups: [WorkspaceGroup]) -> Bool {
        let groupId = workspaceGroups.first { $0.liveAnchorWorkspaceId == workspace.id }?.id ?? workspace.groupId
        guard let groupId, workspaceGroups.contains(where: { $0.id == groupId }) else { return workspace.isPinned }
        let root = WorkspaceGroupTree(groups: workspaceGroups).outermost(of: groupId)
        return workspaceGroups.first { $0.id == root }?.isPinned ?? workspace.isPinned
    }

    func revealMoved(_ workspace: Workspace, tabManager: TabManager, cause: MoveRevealCause, scrollsSelected: Bool) {
        // A press of the cycle key folds back the group the previous press opened, if he has not touched it since.
        if case .cycle(let subject) = cause, var next = statusGroups,
           let id = cycleRecord?.foldBack(subject: subject, collapsedStatusIds: next.collapsedStatusIds) {
            next.collapsedStatusIds.insert(id)
            setStatusGroups(next)
        }
        cycleRecord = nil
        let foldedBefore = statusGroups?.collapsedStatusIds ?? []
        _ = prepareWorkspaceSections(tabManager: tabManager)
        prepareStatusGroupsForSelection(
            list: AppDelegate.statusListInUse,
            resolvedHexByStatusId: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
            selectedWorkspace: workspace, workspaceGroups: tabManager.workspaceGroups, revealWorkspaces: true
        )
        if case .cycle(let subject) = cause {
            cycleRecord = StatusGroupCycleRecord.recording(
                subject: subject, before: foldedBefore, after: statusGroups?.collapsedStatusIds ?? []
            )
        }
        if scrollsSelected { selectedRevealScrollToken &+= 1 }
    }
}
