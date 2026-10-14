import Foundation
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` for the workspace-status additions of #cm-109.2: the three status methods
/// answer one scripted resolution (and record what crossed the seam), and `workspace.status.list` answers one
/// scripted snapshot.
@MainActor
final class FakeWorkspaceStatusControlCommandContext: ControlCommandContext {
    var statusResolution: ControlWorkspaceTodoStatusResolution = .tabManagerUnavailable
    var statusList: ControlWorkspaceStatusListSnapshot = .empty
    var lastStatusSetRaw: String??
    private(set) var listReads = 0

    func controlWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution { statusResolution }

    func controlSetWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?,
        statusRaw: String?
    ) -> ControlWorkspaceTodoStatusResolution {
        lastStatusSetRaw = statusRaw
        return statusResolution
    }

    func controlCycleWorkspaceTaskStatus(
        routing: ControlRoutingSelectors,
        workspaceID: UUID?
    ) -> ControlWorkspaceTodoStatusResolution { statusResolution }

    func controlWorkspaceStatusList() -> ControlWorkspaceStatusListSnapshot {
        listReads += 1
        return statusList
    }
}
