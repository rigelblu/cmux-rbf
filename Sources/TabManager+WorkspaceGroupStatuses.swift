import CmuxWorkspaces
import Foundation

extension TabManager {
    /// Read the current palette synchronously, including a palette edit not yet observed by the status store.
    var workspaceGroupStatusActions: WorkspaceGroupStatusActions {
        WorkspaceGroupStatusActions(list: AppDelegate.statusListInUse,
                                    resolveColor: { WorkspaceTabColorSettings.resolvedColorHex($0) })
    }

    /// Palette propagation and rollback restore the pair without treating the hex as a user pick.
    func restoreWorkspaceGroupStatus(groupId: UUID, statusId: String?, hex: String?) {
        workspaceGrouping.restoreWorkspaceGroupStatus(groupId: groupId, statusId: statusId, hex: hex)
    }
}
