import CmuxWorkspaces
import Foundation

extension VerticalTabsSidebar {
    /// Rebuild from current values at an event boundary, never from a row or a body mutation.
    static func statusRenderItemsForSnapshot(tabManager: TabManager, state: SidebarState) -> SidebarStatusRenderItemsResolution {
        let tabs = tabManager.tabs, groups = tabManager.workspaceGroups
        let base = SidebarWorkspaceRenderItem.renderItems(tabs: tabs,
            groupsById: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }), orderedGroups: groups)
        let projection = currentStatusGroupProjection(tabs: tabs, groups: groups, storedOrder: state.statusGroups?.order)
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
        reconcileStatusGroupOrder(list: AppDelegate.statusListInUse)
        let items = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: tabManager, state: self).items
        let projection = VerticalTabsSidebar.currentStatusGroupProjection(tabs: tabManager.tabs, groups: tabManager.workspaceGroups, storedOrder: statusGroups?.order)
        let saved = SidebarStatusAreaLayout(items: items, tabs: tabManager.tabs,
            groups: tabManager.workspaceGroups, statusProjection: projection).saving(state: statusGroups)
        if saved != statusGroups { setStatusGroups(saved) }
        return statusGroups
    }

    /// Re-saves where the Statuses area sits before an ordinary reorder moves rows, so it stays put when the row
    /// it was saved under leaves. Statuses-aware drops save their own placement and do not call this. (#cm-110.1)
    /// Returns the state it replaced, for `settleStatusAreaAfterMove` to put back when the move does not happen.
    @discardableResult
    func reanchorStatusAreaBeforeMove(tabManager: TabManager, movingWorkspaceIds: [UUID], movingGroupIds: [UUID]) -> WorkspaceStatusGroupsState? {
        let previous = statusGroups
        guard statusGroups != nil else { return previous }
        let items = VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: tabManager, state: self).items
        guard items.contains(where: { if case .statusesHeader = $0 { return true }; return false }) else { return previous }
        let projection = VerticalTabsSidebar.currentStatusGroupProjection(tabs: tabManager.tabs, groups: tabManager.workspaceGroups, storedOrder: statusGroups?.order)
        let saved = SidebarStatusAreaLayout(items: items, tabs: tabManager.tabs,
            groups: tabManager.workspaceGroups, statusProjection: projection)
            .saving(state: statusGroups, movingWorkspaceIds: Set(movingWorkspaceIds), movingGroupIds: Set(movingGroupIds))
        if saved != statusGroups { setStatusGroups(saved) }
        return previous
    }

    /// Puts back what `reanchorStatusAreaBeforeMove` replaced when the reorder moved nothing or failed. (#cm-110.1)
    func settleStatusAreaAfterMove(previous: WorkspaceStatusGroupsState?, moved: Bool) {
        if !moved { setStatusGroups(previous) }
    }
}
