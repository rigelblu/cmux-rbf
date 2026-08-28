import CmuxSidebar
import Foundation

/// Complete immutable render value for one workspace row.
///
/// No observable model reference crosses the lazy-list boundary. A change in
/// workspace state rebuilds these values once in the sidebar owner; Equatable
/// rows then re-render only when their own value changed.
struct SidebarWorkspaceRowSnapshot: Equatable {
    let workspaceId: UUID
    let groupId: UUID?
    /// Whether this row sits under a generated color-section header (`#cm-56`).
    /// Mutually exclusive with `groupId != nil` — a workspace inside a real
    /// group is never projected into a color section.
    let isColorSectionMember: Bool
    let index: Int
    let workspaceCount: Int
    let workspace: SidebarWorkspaceSnapshotBuilder.Snapshot
    let isActive: Bool
    let isMultiSelected: Bool
    let hasUserCustomTitle: Bool
    let hasCustomTitle: Bool
    let hasCustomDescription: Bool
    let customTitle: String?
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let unreadCount: Int
    let latestNotificationText: String?
    let showsAgentActivity: Bool
    let rowSpacing: CGFloat
    let showsModifierShortcutHints: Bool
    let isPointerHovering: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    let isBonsplitWorkspaceDropActive: Bool
    let settings: SidebarTabItemSettingsSnapshot
    let isChecklistExpanded: Bool
    let checklistAddFieldActivationToken: Int
    let isChecklistPopoverPresented: Bool
    let contextMenu: SidebarWorkspaceContextMenuSnapshot

    /// Rows that sit *inside* a header — a real workspace group or a generated
    /// color section — carry the same leading indent, so the container reads as
    /// a container in both cases. Defined once here and mirrored by the AppKit
    /// row model, rather than recomputed at each place that draws an inset.
    var isIndentedUnderHeader: Bool {
        SidebarWorkspaceColorSectionDropPolicy.indentsUnderHeader(
            isGrouped: groupId != nil,
            isColorSectionMember: isColorSectionMember
        )
    }
}
