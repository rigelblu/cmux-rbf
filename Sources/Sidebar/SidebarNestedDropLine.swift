import CmuxFoundation
import CmuxWorkspaces
import CoreGraphics
import Foundation

/// How far a drop line is drawn in (#cm-106). The line is indented to the level the drop lands at, in both sidebar
/// renderers: the number of groups that hold the rows it lands among. A window with no nested group has none, and
/// its lines are drawn as before.
enum SidebarNestedDropLine {
    /// The level a plan lands at, or nil in a window with no nested group (`depthById` is empty then).
    /// - A top-level plan, or a loose row dropped among loose rows: 0.
    /// - A workspace or a nested header placed in a group: one more than that group's depth.
    /// - A header with no workspace of its own, placed among the groups beside it: its own depth.
    static func level(for plan: SidebarWorkspaceReorderDropPlan, depthById: [UUID: Int]) -> Int? {
        guard !depthById.isEmpty else { return nil }
        switch plan.action {
        case .reorder(_, _, let group?):
            return depthById[group].map { $0 + 1 }
        case .reorder:
            return 0
        case .reorderGroup:
            return depthById[plan.draggedWorkspaceId] ?? 0
        case .crossWindow, .colorSection:
            return nil
        }
    }

    /// The visible rows of a group's whole run, in display order: its header, its workspaces, and every row of every
    /// group inside it. Nil when no group is nested, where the rows are the group's direct members as before.
    @MainActor
    static func runRowIds(
        groupId: UUID,
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        visibleRowIds: [UUID]
    ) -> [UUID]? {
        guard groups.contains(where: { $0.parentGroupId != nil }) else { return nil }
        let tree = WorkspaceGroupTree(groups: groups)
        let groupByAnchor = Dictionary(groups.map { ($0.anchorWorkspaceId, $0.id) }, uniquingKeysWith: { first, _ in first })
        let groupOfTab = Dictionary(tabs.compactMap { tab in tab.groupId.map { (tab.id, $0) } }, uniquingKeysWith: { first, _ in first })
        return visibleRowIds.filter { id in
            guard let row = groupByAnchor[id] ?? groupOfTab[id], tree.contains(row) else { return false }
            return row == groupId || tree.isInside(row, groupId)
        }
    }

    /// The leading inset of a line at a level, in points.
    static func inset(level: Int?, availableWidth: CGFloat?) -> CGFloat {
        level.map { SidebarNestedIndent.points(levels: $0, availableWidth: availableWidth) } ?? 0
    }
}
