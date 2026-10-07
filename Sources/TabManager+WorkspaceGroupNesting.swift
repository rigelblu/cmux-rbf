import CmuxWorkspaces
import Foundation

// The forwards for the nested-group entrances (#cm-106), in a fork-only file so `TabManager.swift` takes no edit.
extension TabManager {
    /// `Move Group to`, from a header's menu: one path for every entrance. Puts a group inside another group, or at
    /// the top level when `parentId` is nil.
    @discardableResult
    func moveWorkspaceGroup(groupId: UUID, intoParent parentId: UUID?) -> WorkspaceGroupMoveIntoResult {
        workspaceGrouping.moveWorkspaceGroup(groupId: groupId, intoParent: parentId)
    }

    /// What `Move Group to` offers a group, read when the menu opens.
    func workspaceGroupMoveMenu(for groupId: UUID) -> WorkspaceGroupMoveMenu? {
        workspaceGrouping.moveMenu(for: groupId)
    }
}
