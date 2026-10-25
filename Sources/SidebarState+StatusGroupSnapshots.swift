import CmuxWorkspaces
import Foundation

extension VerticalTabsSidebar {
    /// Rebuild from current values at an event boundary, never from a row or a body mutation.
    static func statusRenderItemsForSnapshot(tabManager: TabManager, state: SidebarState) -> SidebarStatusRenderItemsResolution {
        let tabs = tabManager.tabs, groups = tabManager.workspaceGroups
        let projection = currentStatusGroupProjection(tabs: tabs, groups: groups, storedOrder: state.statusGroups?.order)
        let base = baseRenderItems(tabs: tabs, groupsById: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }),
            orderedGroups: groups, statusGroupProjection: projection) // (#cm-110.3) the walk needs the projection first
        let colors = colorSectionProjection(workspaces: tabs.map {
            SidebarWorkspaceColorSectionWorkspaceSnapshot(id: $0.id, groupId: $0.groupId,
                isPinned: $0.isPinned, customColor: $0.customColor)
        }, collapsedHexes: state.collapsedColorSectionHexes, statusGroupProjection: projection)
        return resolveRenderItems(colorSectionProjection: colors, baseItems: base, statusGroupProjection: projection,
            folds: state.statusGroups ?? .init(), tabs: tabs, groups: groups)
    }
}

@MainActor
extension SidebarState {
    func statusGroupsForSnapshot(tabManager: TabManager) -> WorkspaceStatusGroupsState? {
        guard prepareWorkspaceSections(tabManager: tabManager) else { return statusGroups }
        reconcileStatusGroupOrder(list: AppDelegate.statusListInUse)
        let saved = statusGroups?.canonicalizingSectionOrder()
        if saved != statusGroups { setStatusGroups(saved) }
        return statusGroups
    }

    /// Resolves the two-section order before an ordinary reorder; no item can become a section's anchor.
    /// Returns the resolved state for a failed move's rollback.
    @discardableResult
    func reanchorStatusAreaBeforeMove(tabManager: TabManager, movingWorkspaceIds: [UUID], movingGroupIds: [UUID]) -> WorkspaceStatusGroupsState? {
        prepareWorkspaceSections(tabManager: tabManager)
        return statusGroups
    }

    /// Puts back what `reanchorStatusAreaBeforeMove` replaced when the reorder moved nothing or failed. (#cm-110.1)
    func settleStatusAreaAfterMove(previous: WorkspaceStatusGroupsState?, moved: Bool) {
        if !moved { setStatusGroups(previous) }
    }
}
