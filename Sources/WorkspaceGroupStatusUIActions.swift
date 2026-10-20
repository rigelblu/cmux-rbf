import CmuxWorkspaces
import Foundation

/// UI-only targeting: a selected anchor represents its group, while explicit workspace actions remain workspace-owned.
@MainActor
struct WorkspaceGroupStatusUIActions {
    let tabManager: TabManager
    let writer: WorkspaceGroupStatusActions
    let controlsEnabled: Bool

    /// Capture the current list and gate when the action runs, rather than when a menu was built.
    static func app(tabManager: TabManager, controlsEnabled: Bool? = nil) -> Self {
        Self(tabManager: tabManager, writer: tabManager.workspaceGroupStatusActions,
             controlsEnabled: controlsEnabled ?? WorkspaceTodoFeature.isEnabled)
    }

    private var selectedGroupId: UUID? {
        guard let selected = tabManager.selectedTabId else { return nil }
        return tabManager.workspaceGroups.first { $0.liveAnchorWorkspaceId == selected }?.id
    }

    @discardableResult
    func applyGroup(_ action: WorkspaceStatusPickAction, groupId: UUID) -> Bool {
        guard controlsEnabled, writer.list.source != .cmux else { return false }
        return tabManager.workspaceGrouping.setWorkspaceGroupStatus(groupId: groupId, action: action, actions: writer)
    }

    @discardableResult
    func applySelected(_ action: WorkspaceStatusPickAction,
                       workspaceApply: ((WorkspaceStatusPickAction, [Workspace]) -> Void)? = nil) -> Bool {
        guard controlsEnabled, let workspace = tabManager.selectedWorkspace else { return false }
        if writer.list.source != .cmux, let groupId = selectedGroupId { return applyGroup(action, groupId: groupId) }
        if let workspaceApply { workspaceApply(action, [workspace]) }
        else { WorkspaceTodoActions.applyStatusOverride(action, to: [workspace]) }
        return true
    }

    @discardableResult
    func cycleSelected(workspaceCycle: ((Workspace) -> Void)? = nil) -> Bool {
        guard controlsEnabled, let workspace = tabManager.selectedWorkspace else { return false }
        guard writer.list.source == .cmux || !writer.list.entries.isEmpty else { return false }
        if writer.list.source != .cmux, let groupId = selectedGroupId {
            let group = tabManager.workspaceGroups.first { $0.id == groupId }
            if let target = WorkspaceGroupStatusCycle().target(statusId: group?.statusId, list: writer.list) {
                return applyGroup(.status(id: target), groupId: groupId)
            }
            return false
        } else if let workspaceCycle { workspaceCycle(workspace) }
        else { WorkspaceTodoActions.cycleStatus(for: workspace) }
        return true
    }
}
