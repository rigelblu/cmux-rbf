import CmuxControlSocket
import CmuxWorkspaces
import Foundation

// `workspace.group.move` in a window that holds a nested group (#cm-106). The handler hands over here with one line;
// a flat window keeps the handler's index arithmetic and its answers exactly.
extension TerminalController {
    /// Moves a group by `to_index`, `before_group_id` or `after_group_id`, saying what happened:
    /// - `to_index` names the group now at that index of the list as `list` returns it (the coordinator refuses one in another
    ///   parent); an index past either end is brought to the nearest slot among the groups beside it, not refused;
    /// - `before` and `after` name a sibling and put the group directly before it, or directly after its whole run;
    /// - a target in a different parent is refused (`targetNotBeside`), and nothing moves;
    /// - the answer is `moved` only when something moved, and `unchanged` when the group is already there.
    static func controlMoveNestedWorkspaceGroup(
        tabManager: TabManager,
        groupID: UUID,
        toIndex: Int?,
        beforeGroupID: UUID?,
        afterGroupID: UUID?
    ) -> ControlWorkspaceGroupMoveResolution {
        let coordinator = tabManager.workspaceGrouping
        let groupIds = tabManager.workspaceGroups.map(\.id)
        if let toIndex {
            return resolution(coordinator.moveWorkspaceGroupReportingResult(groupId: groupID, toIndex: toIndex))
        }
        // The same order the flat arithmetic tries: `before` first, then `after`, each only if it names a group.
        if let before = beforeGroupID, groupIds.contains(before) {
            return resolution(coordinator.moveWorkspaceGroup(groupId: groupID, beside: before, after: false))
        }
        if let after = afterGroupID, groupIds.contains(after) {
            return resolution(coordinator.moveWorkspaceGroup(groupId: groupID, beside: after, after: true))
        }
        return .unresolved
    }

    private static func resolution(_ result: WorkspaceGroupMoveBesideResult) -> ControlWorkspaceGroupMoveResolution {
        switch result {
        case .moved: return .moved
        case .unchanged: return .unchanged
        case .groupNotFound, .targetNotFound: return .unresolved
        case .targetNotBeside: return .targetNotBeside
        }
    }
}
