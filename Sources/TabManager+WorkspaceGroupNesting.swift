import CmuxWorkspaces
import Foundation

// The forwards for the nested-group entrances (#cm-106), in a fork-only file so `TabManager.swift` takes no edit.
extension TabManager {
    /// `Move Group to`, from a header's menu: one path for every entrance. Puts a group inside another group, or at
    /// the top level when `parentId` is nil.
    @discardableResult
    func moveWorkspaceGroup(groupId: UUID, intoParent parentId: UUID?) -> WorkspaceGroupMoveIntoResult {
        let result = workspaceGrouping.moveWorkspaceGroup(groupId: groupId, intoParent: parentId)
        if case .moved = result { revealMovedGroup(groupId, opensAbove: true) } // (#cm-110.14) the folds above open, never the group's own
        return result
    }

    /// What `Move Group to` offers a group, read when the menu opens.
    func workspaceGroupMoveMenu(for groupId: UUID) -> WorkspaceGroupMoveMenu? {
        workspaceGrouping.moveMenu(for: groupId)
    }

    /// Ruling (27, #cm-110.3): the status list or Workspace Todo Controls changed, which no group edit announces. A nested group
    /// that holds a stored status but is no longer drawn under it is back inside its parent, so a selection inside it that a fold
    /// above now hides is brought back out: the folded groups above the selection open. A change that leaves every group where
    /// it was, and a selection no fold hides, open nothing.
    func revealSelectionIfItsGroupLeftItsStatus(sectionsStoppedShowing: Bool = false) {
        if sectionsStoppedShowing, let selected = selectedTab, selected.groupId != nil {
            let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
            if WorkspaceGroupWorkspaceItem(id: selected.id, groupId: selected.groupId, isPinned: selected.isPinned)
                .sidebarPin(in: groupsById, sectionsShown: true).isPinned {
                workspaces.expandWorkspaceGroupForSelectionIfNeeded()
                return
            }
        }
        guard workspaces.hasNestedWorkspaceGroup, let selectedId = selectedTabId,
              let groupId = tabs.first(where: { $0.id == selectedId })?.groupId else { return }
        let tree = WorkspaceGroupTree(groups: workspaceGroups)
        let storedStatus = Set(workspaceGroups.filter { $0.statusId != nil }.map(\.id))
        let shown = workspaces.groupIdsShownOutsideParent()
        let chain = [groupId] + tree.ancestors(of: groupId)
        guard chain.contains(where: { tree.parent(of: $0) != nil && storedStatus.contains($0) && !shown.contains($0) }) else { return }
        workspaces.expandWorkspaceGroupForSelectionIfNeeded()
    }
}
