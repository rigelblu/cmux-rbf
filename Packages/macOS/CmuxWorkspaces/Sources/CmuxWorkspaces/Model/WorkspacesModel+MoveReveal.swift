public import Foundation

// The folds a move opens (#cm-110.14). A move someone asks for opens every folded workspace group above where the workspace
// lands, by the rules a workspace switch already uses; the status side (status group, `Statuses` area, color group, `Pinned`,
// `Workspaces`) is the sidebar's. A whole group moved keeps its own fold.
extension WorkspacesModel {
    /// Opens the folded groups above each workspace: its group and every group above it, as a selection of it would, stopping
    /// at a group the sidebar draws under a status. A workspace behind a group's name keeps its own group as it is.
    public func expandWorkspaceGroups(containing workspaceIds: [UUID]) {
        for id in workspaceIds { expandWorkspaceGroups(containing: id) }
    }

    /// The one walk, for a selection (`expandWorkspaceGroupForSelectionIfNeeded`) and for a move. A window that holds a nested group
    /// hands over to `nestedExpandWorkspaceGroups(containing:)`; a flat window's group has no group above it.
    func expandWorkspaceGroups(containing workspaceId: UUID) {
        if hasNestedWorkspaceGroup { return nestedExpandWorkspaceGroups(containing: workspaceId) }
        guard !workspaceIdsShownInPinned().contains(workspaceId) else { return }
        guard let groupId = tabs.first(where: { $0.id == workspaceId })?.groupId,
              let index = workspaceGroups.firstIndex(where: { $0.id == groupId }),
              workspaceGroups[index].isCollapsed,
              workspaceGroups[index].anchorWorkspaceId != workspaceId else { return }
        workspaceGroups[index].isCollapsed = false
    }

    /// Opens the folded groups above a group that was moved, and never the group itself. A group drawn under a status has no
    /// fold above it that hides it, so the walk stops there. A window with no nested group has nothing above a group.
    public func expandWorkspaceGroups(above groupId: UUID) {
        guard hasNestedWorkspaceGroup else { return }
        let shown = groupIdsShownOutsideParent()
        var chain = [groupId] + nestedGroupTree().ancestors(of: groupId)
        if let root = chain.firstIndex(where: shown.contains) { chain = Array(chain[...root]) }
        for id in chain.dropFirst() {
            if let index = workspaceGroups.firstIndex(where: { $0.id == id }), workspaceGroups[index].isCollapsed {
                workspaceGroups[index].isCollapsed = false
            }
        }
    }
}
