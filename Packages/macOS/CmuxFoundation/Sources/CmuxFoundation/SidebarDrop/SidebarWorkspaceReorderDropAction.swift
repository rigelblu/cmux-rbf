public import Foundation

/// The commit operation produced by a resolved sidebar workspace drop plan.
public enum SidebarWorkspaceReorderDropAction: Equatable, Sendable {
    /// Reorder a workspace already present in the destination sidebar.
    case reorder(targetIndex: Int, usesTopLevelRows: Bool, explicitGroupId: UUID?)

    /// Reorder a header-only group. The plan's `draggedWorkspaceId` carries
    /// the group id because an empty group has no workspace row to drag.
    case reorderGroup(targetIndex: Int)

    /// Insert a workspace dragged from another window at the destination index.
    ///
    /// `insertionIndex` is clamped for the dragged workspace's pin state and
    /// drives the rendered single-workspace plan. `proposedInsertionIndex`
    /// preserves the raw pointer slot so multi-selection commits can clamp each
    /// pin tier independently.
    case crossWindow(insertionIndex: Int, proposedInsertionIndex: Int)

    /// Permute only the ungrouped members of one generated color section.
    case colorSection(
        targetWorkspaceId: UUID,
        insertBefore: Bool,
        memberWorkspaceIds: [UUID]
    )

    /// Reorder a status header in this window under its original opaque drag generation. // (#cm-110.1)
    case reorderStatusGroup(targetStatusId: String, insertBefore: Bool, sessionId: UUID) // (#cm-110.1)
    /// Move the complete Statuses area among whole top-level items. // (#cm-110.1)
    case moveStatusesArea(aboveRow: String, belowRow: String?, last: Bool, sessionId: UUID) // (#cm-110.1)

    case statusGroupDrop(plan: SidebarStatusGroupWorkspaceDropPlan, sessionId: UUID) // (#cm-110.1)
    case statusAreaBoundaryDrop(plan: SidebarStatusAreaBoundaryDropPlan, sessionId: UUID) // (#cm-110.1)

    // (#cm-110.1)
    /// Permute only the ungrouped members of one status group. (#cm-110.1)
    case statusGroupMove( // (#cm-110.1)
        statusId: String, // (#cm-110.1)
        targetWorkspaceId: UUID, // (#cm-110.1)
        insertBefore: Bool, // (#cm-110.1)
        memberWorkspaceIds: [UUID] // (#cm-110.1)
    ) // (#cm-110.1)
}
