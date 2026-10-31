import Foundation

/// The latest immutable input delivered by the SwiftUI table bridge.
@MainActor
struct SidebarWorkspaceTableApplyInput {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    /// Counts the moves after which the selected row is scrolled into view (#cm-110.14).
    let selectedRevealScrollToken: Int
    /// Restores the mounted table's viewport after a hidden-presentation pass
    /// mutated the controller snapshot and requires an authoritative reload.
    let forcedReloadViewportOrigin: CGPoint?

    /// Whether this input must reconcile a table graph pruned while hidden.
    var forceTableReload: Bool { forcedReloadViewportOrigin != nil }

    init(
        rows: [SidebarWorkspaceTableRowConfiguration],
        actions: SidebarWorkspaceTableActions,
        workspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        selectedScrollTargetWorkspaceId: UUID?,
        selectedRevealScrollToken: Int = 0, // (#cm-110.14)
        forcedReloadViewportOrigin: CGPoint? = nil
    ) {
        self.rows = rows
        self.actions = actions
        self.workspaceIds = workspaceIds
        self.selectedWorkspaceId = selectedWorkspaceId
        self.selectedScrollTargetWorkspaceId = selectedScrollTargetWorkspaceId
        self.selectedRevealScrollToken = selectedRevealScrollToken // (#cm-110.14)
        self.forcedReloadViewportOrigin = forcedReloadViewportOrigin
    }
}
