public import Foundation

// The nested versions of the reorder entrances (#cm-106): Move to Top, the move on a notification, and
// Move Up / Move Down / a socket index. Each upstream function in `WorkspaceReorderCoordinator` hands over
// here when the window holds a nested group, and publishes the order change itself. A row move reads the
// layout from what is stored, edits it, and writes once, and only when an edit applied.
//
// Three helpers here run in every window, and answer for a flat window as v0.31.0 does: `workspaceIdsMovedUpThrough`
// (the moved workspaces), `workspaceIdsNamedForBatchReorder` (the planned ones) and `workspaceIdsThatChangedPlace`
// (the caller checks for a nested group first).
extension WorkspacesModel {
    /// The groups from the outermost down to the innermost one that holds the workspace.
    private func nestedGroupChain(of tab: Tab, tree: WorkspaceGroupTree) -> [UUID] {
        guard let groupId = tab.groupId, tree.contains(groupId) else { return [] }
        return Array(tree.ancestors(of: groupId).reversed()) + [groupId]
    }

    /// The workspaces to name when `movedTabs` were moved to the top: the ones the user moved first, as v0.31.0 lists
    /// them, then, in tabs order, the workspaces of the groups whose row changed place because of the move
    /// (`carriedGroupIds`; none when no group moved, and none in a window with no nested group). A workspace in a group
    /// that did not move is named alone.
    func workspaceIdsMovedUpThrough(_ movedTabs: [Tab], carriedGroupIds: [UUID]) -> [UUID] {
        let moved = movedTabs.map(\.id)
        guard hasNestedWorkspaceGroup, !carriedGroupIds.isEmpty else { return moved }
        let named = Set(moved)
        let carried = Set(carriedGroupIds.flatMap { workspaceIdsInside($0) })
        return moved + tabs.map(\.id).filter { carried.contains($0) && !named.contains($0) }
    }

    /// The groups, among `groupIds`, whose row stands at another place of its level in `edited` than in `original`.
    private func groupsWhoseRowChangedPlace(
        _ groupIds: [UUID],
        from original: WorkspaceGroupLayout,
        to edited: WorkspaceGroupLayout,
        tree: WorkspaceGroupTree
    ) -> [UUID] {
        groupIds.filter { id in
            let level = tree.parent(of: id)
            return original.rows(of: level).firstIndex(of: .group(id)) != edited.rows(of: level).firstIndex(of: .group(id))
        }
    }

    /// The workspaces to name after a batch reorder (`reorder_many`): the planned ones that moved, all of them in the
    /// plan's order, as v0.31.0 lists them whether or not they stand elsewhere after the repair; and, in a window with a
    /// nested group, after them the other workspaces whose place in `tabs` differs from `previousOrder`, in tabs order,
    /// since the repair after the rebuild re-places whole groups the plan did not list. In a window with no nested
    /// group, the planned ones only.
    func workspaceIdsNamedForBatchReorder(planned: [UUID], previousOrder: [UUID]) -> [UUID] {
        guard hasNestedWorkspaceGroup else { return planned }
        let changed = Set(workspaceIdsThatChangedPlace(since: previousOrder))
        let plannedSet = Set(planned)
        return planned + tabs.map(\.id).filter { changed.contains($0) && !plannedSet.contains($0) }
    }

    /// The workspaces whose place in `tabs` differs from `previousOrder`, in tabs order. A workspace not in
    /// `previousOrder` counts as changed. The caller decides that the window holds a nested group.
    public func workspaceIdsThatChangedPlace(since previousOrder: [UUID]) -> [UUID] {
        let before = Dictionary(uniqueKeysWithValues: previousOrder.enumerated().map { ($1, $0) })
        return tabs.enumerated().compactMap { index, tab in before[tab.id] == index ? nil : tab.id }
    }

    /// Nested `moveTabsToTop`: the workspace goes first among the rows of its own tier in its group,
    /// and each group on the way up goes to the top of its tier in its level. The selected rows keep
    /// their relative order.
    /// Returns the groups whose row changed place.
    func nestedMoveTabsToTop(_ selectedTabs: [Tab]) -> [UUID] {
        var layout = nestedGroupLayout()
        let original = layout
        let tree = nestedGroupTree()
        var changed = false
        var onTheWayUp: [UUID] = []
        // Apply from the last selected so the first selected ends first.
        for tab in selectedTabs.reversed() {
            let chain = nestedGroupChain(of: tab, tree: tree)
            let isHeader = tab.groupId.flatMap { id in
                workspaceGroups.first(where: { $0.id == id })?.liveAnchorWorkspaceId
            } == tab.id
            if !isHeader {
                if layout.move(.workspace(tab.id), to: tab.groupId, at: .firstOfTier) == .moved { changed = true }
            }
            for groupId in chain.reversed() {
                onTheWayUp.append(groupId)
                if layout.move(.group(groupId), to: tree.parent(of: groupId), at: .firstOfTier) == .moved { changed = true }
            }
        }
        guard changed else { return [] }
        applyGroupLayout(layout)
        return groupsWhoseRowChangedPlace(onTheWayUp, from: original, to: layout, tree: tree)
    }

    /// Nested `moveTabToTopForNotification`: from the top level inward, each group on the way goes to
    /// the first unpinned place of its level, and the walk stops at the first pinned group, so nothing
    /// at or inside it moves. If the walk reaches the workspace it goes first among the rows of its
    /// own tier in its group. An ungrouped pinned workspace does not move.
    /// Returns the groups whose row changed place.
    func nestedMoveTabToTopForNotification(_ tab: Tab) -> [UUID] {
        var layout = nestedGroupLayout()
        let original = layout
        let tree = nestedGroupTree()
        let chain = nestedGroupChain(of: tab, tree: tree)
        var changed = false
        var walked: [UUID] = []
        func finish() -> [UUID] {
            guard changed else { return [] }
            applyGroupLayout(layout)
            return groupsWhoseRowChangedPlace(walked, from: original, to: layout, tree: tree)
        }
        for groupId in chain {
            guard let group = workspaceGroups.first(where: { $0.id == groupId }), !group.isPinned else { return finish() }
            walked.append(groupId)
            if layout.move(.group(groupId), to: tree.parent(of: groupId), at: .firstOfTier) == .moved { changed = true }
        }
        if chain.isEmpty, tab.isPinned { return [] }
        let isHeader = tab.groupId.flatMap { id in
            workspaceGroups.first(where: { $0.id == id })?.liveAnchorWorkspaceId
        } == tab.id
        if !isHeader {
            if layout.move(.workspace(tab.id), to: tab.groupId, at: .firstOfTier) == .moved { changed = true }
        }
        return finish()
    }

    /// Nested `reorderWorkspace(tabId:toIndex:)` for Move Up, Move Down and an index from the socket:
    /// one step is one row among the rows of the workspace's level and tier, a child group counting
    /// as one row; the workspace behind a group's name moves its group's row; an index is brought to
    /// the nearest such place. Nothing joins or leaves a group this way.
    func nestedReorderWorkspace(tabId: UUID, toIndex targetIndex: Int) -> Bool {
        guard let currentTabIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return false }
        let tab = tabs[currentTabIndex]
        let tree = nestedGroupTree()
        let group = tab.groupId.flatMap { id in workspaceGroups.first(where: { $0.id == id }) }
        let row: WorkspaceGroupLayout.Row
        let level: UUID?
        if let group, group.liveAnchorWorkspaceId == tabId {
            row = .group(group.id)
            level = tree.parent(of: group.id)
        } else {
            row = .workspace(tabId)
            level = group?.id
        }
        var layout = nestedGroupLayout()
        let rows = layout.rows(of: level)
        guard let currentRow = rows.firstIndex(of: row) else { return true }

        // Where each row starts in `tabs`.
        func start(_ candidate: WorkspaceGroupLayout.Row) -> Int {
            switch candidate {
            case .workspace(let id):
                return tabs.firstIndex { $0.id == id } ?? Int.max
            case .group(let id):
                return tabs.indices.first { index in
                    guard let groupId = tabs[index].groupId else { return false }
                    return groupId == id || tree.isInside(groupId, id)
                } ?? Int.max
            }
        }
        let wanted = max(0, min(targetIndex, tabs.count - 1))
        let finalRow: Int
        if wanted == currentTabIndex {
            return true
        } else if abs(wanted - currentTabIndex) == 1 {
            finalRow = max(0, min(currentRow + (wanted > currentTabIndex ? 1 : -1), rows.count - 1))
        } else {
            finalRow = rows.indices.last { start(rows[$0]) <= wanted } ?? 0
        }
        guard finalRow != currentRow else { return true }
        guard layout.move(row, to: level, at: .index(finalRow)) == .moved else { return true }
        applyGroupLayout(layout)
        return true
    }
}
