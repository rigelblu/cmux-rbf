import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// Preflights header moves, then restores model state on a failed write or move; published events are not undone.
@MainActor
struct WorkspaceGroupStatusDropPerformer {
    let tabManager: TabManager
    let sidebarState: SidebarState
    let actions: WorkspaceStatusActions
    let projection: WorkspaceStatusGroupProjection?
    let renderItems: [SidebarWorkspaceRenderItem]
    let reorder: (UUID, Int) -> Bool

    private struct Move {
        let workspaceId: UUID
        let targetIndex: Int
        let rootsAfter: [UUID]
    }

    private func refused(_ reason: String) -> Bool {
#if DEBUG
        cmuxDebugLog("sidebar.groupStatusDrop.refused reason=\(reason)")
#endif
        return false
    }

    func perform(_ plan: SidebarStatusGroupWorkspaceDropPlan, groupId: UUID, draggedId: UUID) -> Bool {
        guard actions.controlsEnabled else { return refused("controls-disabled") }
        guard actions.list.source != .cmux, !actions.list.entries.isEmpty else { return refused("no-user-status-list") }
        guard actions.list.entry(id: plan.statusId) != nil else { return refused("target-status-removed") }
        guard let group = tabManager.workspaceGroups.first(where: { $0.id == groupId }) else { return refused("source-group-missing") }
        guard !group.isEmpty, group.liveAnchorWorkspaceId == draggedId else { return refused("empty-or-stale-source-anchor") }
        guard tabManager.tabs.contains(where: { $0.id == draggedId && $0.groupId == groupId }) else { return refused("source-anchor-not-live") }
        guard plan.setsStatus == (group.statusId != plan.statusId) else { return refused("source-status-changed") }
        // Admission builds both indicators together; keep this integrity check for future plan producers.
        guard let admitted = plan.headerPlacement, admitted.indicator == plan.indicator else { return refused("invalid-admitted-proof") }
        let beforeTabs = tabManager.tabs, beforeGroups = tabManager.workspaceGroups
        let beforeSelection = tabManager.selectedTabId
        let beforeOrder = beforeTabs.map(\.id)
        let roots = tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true)
        // Header placement needs no color-section data: authoritative status projection supplies all loose membership.
        let snapshot = VerticalTabsSidebar.WorkspaceStatusDropSnapshot(tabs: beforeTabs, workspaceGroups: beforeGroups,
            workspaceRenderItems: renderItems, statusGroupProjection: projection,
            statusGroupFolds: sidebarState.statusGroups ?? .init(),
            colorSectionProjection: .project(workspaces: [], paletteEntries: [], collapsedHexes: []),
            selectedIds: [], rootWorkspaceIds: roots)
        guard let fresh = SidebarWorkspaceGroupStatusHeaderDrops(snapshot: snapshot)
            .placement(groupId: groupId, statusId: plan.statusId, target: plan.placement) else { return refused("fresh-placement-refused") }
        guard fresh == admitted else { return refused("placement-changed") }
        let tree = WorkspaceGroupTree(groups: beforeGroups)
        let inside = Set([groupId] + tree.descendants(of: groupId))
        let run = beforeTabs.filter { $0.groupId.map(inside.contains) == true }.map(\.id)
        // The model supplies contiguous runs; retain this check at the transaction boundary against stale data.
        guard run.first == draggedId, let first = beforeOrder.firstIndex(of: draggedId),
              first + run.count <= beforeOrder.count,
              Array(beforeOrder[first..<(first + run.count)]) == run else { return refused("source-run-not-contiguous") }
        let anchors = Set(beforeGroups.compactMap(\.liveAnchorWorkspaceId))
        let pinned = tabManager.sidebarReorderPinnedWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true)
        let pinnedCount = roots.filter(pinned.contains).count
        var simulated = roots
        var moves: [Move] = []
        // Keep this remove/insert simulation in sync with reorderTopLevelWorkspaceItem's index rule.
        for id in fresh.workspaceIdsInMoveOrder {
            // Current projection yields only movable loose rows; validate again against future planner drift.
            guard let workspace = beforeTabs.first(where: { $0.id == id }),
                  workspace.groupId == nil, !workspace.isPinned, !anchors.contains(id),
                  !pinned.contains(id), let from = simulated.firstIndex(of: id),
                  let side = fresh.destinationSide else { return refused("invalid-crossing-row") }
            var remaining = simulated
            remaining.remove(at: from)
            // A legal crossing cannot remove the source root; retain refusal for inconsistent future producers.
            guard let reference = remaining.firstIndex(of: draggedId) else { return refused("source-root-missing") }
            let destination = reference + (side == .afterGroup ? 1 : 0)
            // A pure crossing is neither pinned-tier nor a no-op; keep the boundary check if that contract changes.
            guard destination >= pinnedCount, destination <= remaining.count, destination != from else { return refused("invalid-crossing-index") }
            remaining.insert(id, at: destination)
            moves.append(.init(workspaceId: id, targetIndex: destination, rootsAfter: remaining))
            simulated = remaining
        }
        let groupActions = WorkspaceGroupStatusUIActions(tabManager: tabManager,
            writer: .init(list: actions.list, resolveColor: actions.resolveColor), controlsEnabled: actions.controlsEnabled)
        var committed = false
        defer {
            if !committed {
                let changedOrder = tabManager.tabs.map(\.id) != beforeOrder
                if tabManager.workspaceGroups != beforeGroups { tabManager.workspaceGroups = beforeGroups }
                if changedOrder { tabManager.tabs = beforeTabs }
                if tabManager.selectedTabId != beforeSelection { tabManager.selectedTabId = beforeSelection }
                if changedOrder { tabManager.workspaceOrderDidChange(movedWorkspaceIds: fresh.crossingWorkspaceIds) }
            }
        }
        if plan.setsStatus {
            guard groupActions.applyGroup(.status(id: plan.statusId), groupId: groupId) else { return refused("status-write-refused") }
        }
        // Status writes currently preserve roots; restore model state if that shared contract changes.
        guard tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true) == roots else { return refused("roots-changed-by-status-write") }
        for move in moves {
            guard reorder(move.workspaceId, move.targetIndex) else { return refused("reorder-refused") }
            // The shared coordinator matches the simulation today; retain the post-check against future drift.
            guard tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true) == move.rootsAfter
            else { return refused("roots-changed-after-move") }
        }
        committed = true
        return true
    }
}
