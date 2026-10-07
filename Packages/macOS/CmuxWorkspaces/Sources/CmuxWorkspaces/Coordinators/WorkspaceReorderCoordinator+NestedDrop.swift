import Foundation

// The nested commit of a sidebar drop (#cm-106): what `reorderSidebarWorkspace` and `reorderSidebarWorkspaces` hand
// over here when the drop is a nested group's header, a workspace dropped into a group of a window that holds a
// nested group, or several workspaces dropped at a top-level place of such a window. The place is checked against
// the live tree in `WorkspacesModel+NestedDrop.swift`; each function here publishes the order change when the model
// moved, and answers true for a plan that fits and moves nothing, so the table does not animate a snap-back.
extension WorkspaceReorderCoordinator {
    /// A drag of a nested group's header: one layout edit that moves the group's row inside its parent. Refused
    /// anywhere else: a top-level plan, or a group other than the one that holds it now.
    func reorderNestedGroupHeader(tabId: UUID, toIndex targetIndex: Int, usesTopLevelRows: Bool, explicitGroupId: UUID?) -> Bool {
        guard !usesTopLevelRows, let parent = explicitGroupId,
              let group = model.workspaceGroups.first(where: { $0.liveAnchorWorkspaceId == tabId }) else { return false }
        return reorderNestedGroupRows(groupIds: [group.id], grabbed: group.id, parent: parent, toIndex: targetIndex)
    }

    /// A drag of several selected headers, taken only when every one sits in the same parent as the grabbed one.
    func reorderNestedGroupHeaders(
        movingAnchorIds: [UUID],
        draggedTabId: UUID,
        toIndex targetIndex: Int,
        usesTopLevelRows: Bool,
        explicitGroupId: UUID?
    ) -> Bool {
        guard !usesTopLevelRows, let parent = explicitGroupId,
              let grabbed = model.workspaceGroups.first(where: { $0.liveAnchorWorkspaceId == draggedTabId }) else { return false }
        let groupIds = movingAnchorIds.compactMap { id in model.workspaceGroups.first { $0.liveAnchorWorkspaceId == id }?.id }
        guard groupIds.count == movingAnchorIds.count else { return false }
        return reorderNestedGroupRows(groupIds: groupIds, grabbed: grabbed.id, parent: parent, toIndex: targetIndex)
    }

    private func reorderNestedGroupRows(groupIds: [UUID], grabbed: UUID, parent: UUID, toIndex targetIndex: Int) -> Bool {
        switch model.nestedDropGroupRows(groupIds: groupIds, grabbed: grabbed, parent: parent, toIndex: targetIndex) {
        case .refused:
            return false
        case .unchanged:
            return true
        case .moved:
            // Every workspace inside each moved group, in tabs order, as v0.31.0 names a moved group's workspaces.
            let moved = Set(groupIds.flatMap { model.workspaceIdsInside($0) })
            host?.workspaceOrderDidChange(movedWorkspaceIds: model.tabs.map(\.id).filter(moved.contains))
            return true
        }
    }

    /// A drag of one or more workspaces onto a group of a window that holds a nested group: every one goes to that
    /// group, as row moves in sidebar order. The notice names the dragged workspaces, as v0.31.0 does.
    func reorderNestedWorkspacesIntoGroup(movingIds: [UUID], draggedTabId: UUID, toIndex targetIndex: Int, groupId: UUID) -> Bool {
        switch model.nestedDropWorkspaces(movingIds, grabbed: draggedTabId, intoGroup: groupId, toIndex: targetIndex) {
        case .refused:
            return false
        case .unchanged:
            return true
        case .moved:
            host?.workspaceOrderDidChange(movedWorkspaceIds: movingIds)
            return true
        }
    }

    /// A drag of several workspaces at a top-level place of a window that holds a nested group: every one goes to the
    /// top level, directly before the first top-level row at or after the place that is not being moved. The plan's index
    /// is either an index among the top-level rows (`usesTopLevelRows`, a header with no workspace counted) or, for a
    /// plan among loose rows, an index into `tabs`; both are indexes in the order without the grabbed row.
    func reorderNestedWorkspacesToTopLevel(movingIds: [UUID], draggedTabId: UUID, toIndex targetIndex: Int, usesTopLevelRows: Bool) -> Bool {
        let rowSpace = (usesTopLevelRows
            ? model.sidebarTopLevelWorkspaceIdsIncludingEmptyGroups(promotingWorkspaceId: draggedTabId)
            : model.tabs.map(\.id)
        ).filter { $0 != draggedTabId }
        let movingSet = Set(movingIds)
        let start = max(0, targetIndex)
        let reference = start < rowSpace.count ? rowSpace[start...].first { !movingSet.contains($0) } : nil
        switch model.nestedDropWorkspacesToTopLevel(movingIds, grabbed: draggedTabId, before: reference) {
        case .refused:
            return false
        case .unchanged:
            return true
        case .moved:
            host?.workspaceOrderDidChange(movedWorkspaceIds: movingIds)
            return true
        }
    }
}
