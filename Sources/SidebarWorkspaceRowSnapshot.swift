import CmuxSidebar
import Foundation

/// Complete immutable render value for one workspace row.
///
/// No observable model reference crosses the lazy-list boundary. A change in
/// workspace state rebuilds these values once in the sidebar owner; Equatable
/// rows then re-render only when their own value changed. Drop-session
/// validation remains on the parent overlay and is deliberately absent here.
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
    let settings: SidebarTabItemSettingsSnapshot
    let isChecklistExpanded: Bool
    let checklistAddFieldActivationToken: Int
    let isChecklistPopoverPresented: Bool
    let contextMenu: SidebarWorkspaceContextMenuSnapshot
    /// How many groups hold this row; 0 in a window with no nested group (#cm-106).
    var depth: Int = 0
    /// The level a reorder drop lands at, on a row that draws a drop line, for the line's indent (#cm-106).
    var dropLineLevel: Int? = nil
    /// The list's width, for the cap on the indent; nil outside the SwiftUI list (#cm-106).
    var listWidth: CGFloat? = nil

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

    /// How many steps of indent the row carries: its depth in a nested window, else one under a header (#cm-106).
    var indentLevels: Int {
        depth > 0 ? depth : (isIndentedUnderHeader ? 1 : 0)
    }
}
