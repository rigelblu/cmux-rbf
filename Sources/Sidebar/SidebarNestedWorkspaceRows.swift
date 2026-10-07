import CmuxWorkspaces
import Foundation

/// The nested list of sidebar rows (#cm-106). `SidebarWorkspaceRenderItem.renderItems` hands over to `items` when the
/// window holds a nested group; a window with none draws what it draws today. `hasNestedGroup` and `depthById` run
/// on every pass of the sidebar in every window, and a flat window answers "no" and an empty depth map. The
/// walk itself is `WorkspaceGroupRowWalk` in the package, over plain values; this file turns its rows into the
/// render items both sidebar renderers already consume, and works out each row's depth for them.
@MainActor
enum SidebarNestedWorkspaceRows {
    /// Whether any group sits inside another group.
    static func hasNestedGroup(_ groupsById: [UUID: WorkspaceGroup]) -> Bool {
        groupsById.values.contains { $0.parentGroupId != nil }
    }

    /// The render items of a nested window: a header, then the rows inside it, a folded group hiding everything
    /// inside at every level.
    static func items(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        orderedGroups: [WorkspaceGroup]?,
        effectiveMembership: [UUID: UUID?]
    ) -> [SidebarWorkspaceRenderItem] {
        let groups = orderedGroups ?? groupsById.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let workspaces = tabs.map {
            WorkspaceGroupWorkspaceItem(id: $0.id, groupId: effectiveMembership[$0.id] ?? nil, isPinned: $0.isPinned)
        }
        return WorkspaceGroupRowWalk.rows(groups: groups, workspaces: workspaces).compactMap { row in
            switch row.kind {
            case .header(let groupId):
                guard let group = groupsById[groupId] else { return nil }
                return .groupHeader(groupId: group.id, anchorWorkspaceId: group.anchorWorkspaceId)
            case .workspace(let workspaceId):
                return .workspace(workspaceId: workspaceId)
            }
        }
    }

    /// How many groups hold each row, by group id for a header and workspace id for a row. Empty when no group is
    /// nested, so a flat window carries no depth and its rows keep the one step a member already has.
    static func depthById(
        groupsById: [UUID: WorkspaceGroup],
        effectiveMembership: [UUID: UUID?]
    ) -> [UUID: Int] {
        guard hasNestedGroup(groupsById) else { return [:] }
        let tree = WorkspaceGroupTree(groups: Array(groupsById.values))
        var result: [UUID: Int] = [:]
        result.reserveCapacity(effectiveMembership.count + groupsById.count)
        for groupId in groupsById.keys {
            result[groupId] = tree.depth(of: groupId)
        }
        for (workspaceId, groupId) in effectiveMembership {
            if let groupId { result[workspaceId] = tree.depth(of: groupId) + 1 }
        }
        return result
    }

    /// Every workspace inside each group at any level, in tabs order, for the unread sum and Mark All. Equal to the
    /// direct members of each group in a window with no nested group.
    static func workspaceIdsInside(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        effectiveMembership: [UUID: UUID?]
    ) -> [UUID: [UUID]] {
        let workspaces = tabs.map {
            WorkspaceGroupWorkspaceItem(id: $0.id, groupId: effectiveMembership[$0.id] ?? nil, isPinned: $0.isPinned)
        }
        return WorkspaceGroupRowWalk.workspaceIdsInside(groups: Array(groupsById.values), workspaces: workspaces)
    }
}
