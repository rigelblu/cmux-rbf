import AppKit
import CmuxFoundation

/// Builds bonsplit drop geometry only while an AppKit drag requests it.
/// Workspace reorder drops resolve their targets through the dedicated overlay
/// in `SidebarWorkspaceTableController` and never touch this.
@MainActor
final class SidebarWorkspaceTableDropTargetGeometryGate {
    let bonsplitTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()

    private weak var containerView: SidebarWorkspaceTableContainerView?
    private var isBonsplitTargetCollectionActive = false

#if DEBUG
    var computationProbe: (() -> Void)?
#endif

    func attach(containerView: SidebarWorkspaceTableContainerView) {
        self.containerView = containerView
    }

    @discardableResult
    func setBonsplitTargetCollectionActive(
        _ isActive: Bool,
        rows: [SidebarWorkspaceTableRowConfiguration]
    ) -> Bool {
        guard isBonsplitTargetCollectionActive != isActive else { return false }
        isBonsplitTargetCollectionActive = isActive
        if isActive {
            return refreshIfActive(rows: rows)
        }
        clearTargets()
        return false
    }

    @discardableResult
    func refreshIfActive(rows: [SidebarWorkspaceTableRowConfiguration]) -> Bool {
        guard isBonsplitTargetCollectionActive, let container = containerView else { return false }
#if DEBUG
        computationProbe?()
#endif
        let table = container.tableView
        let visibleRange = table.rows(in: table.visibleRect)
        guard visibleRange.location != NSNotFound, visibleRange.length > 0 else {
            clearTargets()
            return true
        }

        let lower = max(0, visibleRange.location)
        let upper = min(rows.count, visibleRange.location + visibleRange.length)
        bonsplitTargetBridge.updateTargets((lower..<upper).map { row in
            let configuration = rows[row]
            return SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: configuration.workspaceId,
                isPinned: configuration.isPinned || configuration.isPinnedByGroup, // (#cm-110.5) a pinned group's members are in the pinned run, though not pinned one by one
                frame: table.convert(table.rect(ofRow: row), to: container.bonsplitDropView),
                tabIds: configuration.dropTabIds ?? configuration.defaultDropTabIds, // (#cm-110.5)
                isSectionHeader: configuration.statusHeaderKind?.isSection == true // (#cm-110.5)
            )
        })
        return true
    }

    private func clearTargets() {
        bonsplitTargetBridge.updateTargets([])
    }
}

extension SidebarWorkspaceTableRowConfiguration { // (#cm-110.5)
    /// A workspace row and a workspace group's header (it stands for the group's anchor workspace, which has its own slot) stand for their own workspace (`nil`); a status header or a color-section header stands for none unless its builder set `dropTabIds`. // (#cm-110.5)
    fileprivate var defaultDropTabIds: [UUID]? { statusHeaderKind == nil && !isColorSectionHeader ? nil : [] } // (#cm-110.5)
} // (#cm-110.5)
