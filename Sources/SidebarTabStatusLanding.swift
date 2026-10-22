import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation
import os

/// Where a dragged tab's new workspace lands among the status groups, decided by the plan a workspace dropped there uses. (#cm-110.10)
///
/// The plan treats the tab as a loose, unpinned workspace that does not exist yet (`standInId`). The drop makes the real
/// workspace first, then commits this plan with it, so the place and the status never come from the tab drop's own index.
struct SidebarTabStatusLanding {
    let plan: SidebarWorkspaceReorderDropPlan
    let indicator: SidebarDropIndicator
    var standInId: UUID { plan.draggedWorkspaceId }
}

extension VerticalTabsSidebar {
    /// `headersOnly` limits the landing to a point inside a status group's header: a header has no "into" zone for a tab.
    static func tabStatusLanding(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        snapshot: WorkspaceStatusDropSnapshot, headersOnly: Bool,
        controlsEnabled: Bool, hasUserStatusList: Bool) -> SidebarTabStatusLanding? {
        guard snapshot.statusGroupProjection != nil else { return nil }
        if headersOnly {
            let byId = Dictionary(snapshot.workspaceRenderItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let onHeader = targets.contains { target in
                guard case .statusGroupHeader? = byId[target.renderItemId ?? .workspace(target.workspaceId)] else { return false }
                return target.frame.contains(point)
            }
            guard onHeader else { return nil }
        }
        let standIn = UUID()
        var standInSnapshot = snapshot
        standInSnapshot.standInWorkspaceId = standIn
        let result = workspaceStatusRoute(point: point, targets: targets, snapshot: standInSnapshot, draggedId: standIn,
            sourceKind: .workspace, token: standIn, foreignDraggedIsPinned: false,
            controlsEnabled: controlsEnabled, hasUserStatusList: hasUserStatusList, ordinary: { _, _, _ in nil })
        guard case .plan(let plan) = result, let indicator = plan.indicator else { return nil }
        switch plan.action {
        case .statusGroupDrop: return SidebarTabStatusLanding(plan: plan, indicator: indicator)
        // Between the member rows of a workspace group under a status: the tab joins that group, as a workspace does there.
        case .reorder(_, false, .some): return SidebarTabStatusLanding(plan: plan, indicator: indicator)
        // Below the last row, the area boundary and everything else keep what the tab drop does today.
        default: return nil
        }
    }

    func tabStatusLanding(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        renderContext: WorkspaceListRenderContext, headersOnly: Bool) -> SidebarTabStatusLanding? {
        let list = AppDelegate.statusListInUse
        return Self.tabStatusLanding(point: point, targets: targets,
            snapshot: .init(context: renderContext, selectedIds: selectedTabIds,
                rootWorkspaceIds: tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true)),
            headersOnly: headersOnly, controlsEnabled: WorkspaceTodoFeature.isEnabled,
            hasUserStatusList: list.source != .cmux && !list.entries.isEmpty)
    }

    /// Makes the workspace from the tab at the end of the tab order, then commits the landing with it; selected and focused as
    /// today's tab drop leaves it. A commit that fails leaves the workspace made, and the drop still reports success. Two
    /// outcomes follow. If the status write failed, the workspace sits at the end of the tab order with no status, a loose
    /// workspace as the tab drop made before. If the status was written and the reorder failed, it has the status but sits
    /// last in that status group, not where the line was. Both are logged (also in Release); neither is rolled back.
    func moveBonsplitTabToNewWorkspace(at landing: SidebarTabStatusLanding, transfer: BonsplitTabDragPayload.Transfer) -> UUID? {
        guard let app = AppDelegate.shared,
              let result = app.moveBonsplitTabToNewWorkspace(tabId: transfer.tab.id, destinationManager: tabManager,
                focus: true, focusWindow: true, placementOverride: .end),
              let created = tabManager.tabs.first(where: { $0.id == result.destinationWorkspaceId }) else { return nil }
        if !commitTabStatusLanding(landing, newWorkspace: created) {
            WorkspaceStatusListStore.log.error("a tab's new workspace was made but its status landing failed: new=\(created.id.uuidString.prefix(8), privacy: .public) hasStatus=\(created.todoState.ownStatus != nil, privacy: .public)")
        }
        return created.id
    }

    @discardableResult
    func commitTabStatusLanding(_ landing: SidebarTabStatusLanding, newWorkspace: Workspace) -> Bool {
        Self.commitTabStatusLanding(landing, newWorkspace: newWorkspace, tabManager: tabManager,
            sidebarState: sidebarState, actions: .app())
    }

    @discardableResult
    static func commitTabStatusLanding(_ landing: SidebarTabStatusLanding, newWorkspace: Workspace,
        tabManager: TabManager, sidebarState: SidebarState, actions: WorkspaceStatusActions,
        currentProjection: (() -> WorkspaceStatusGroupProjection?)? = nil) -> Bool {
        switch landing.plan.action {
        case .statusGroupDrop(let value, _):
            let projection = currentProjection ?? { currentStatusGroupProjection(tabs: tabManager.tabs, groups: tabManager.workspaceGroups,
                storedOrder: sidebarState.statusGroups?.order) }
            if let handled = performWorkspaceProjectedStatusDrop(value, dragged: newWorkspace, sourceKind: .workspace,
                tabManager: tabManager, actions: actions, projection: projection()) { return handled }
            return StatusGroupDropPerformer(statusActions: actions, currentProjection: projection,
                reorder: { id, target, before, members in tabManager.reorderWorkspaceWithinColorSection(tabId: id,
                    targetWorkspaceId: target, insertBefore: before, memberWorkspaceIds: members) })
                .perform(value, dragged: newWorkspace, sourceKind: .workspace)
        case .reorder(let index, let usesTopLevelRows, let explicitGroupId):
            let previous = sidebarState.reanchorStatusAreaBeforeMove(tabManager: tabManager,
                movingWorkspaceIds: [newWorkspace.id], movingGroupIds: [])
            let orderBefore = tabManager.tabs.map(\.id)
            let moved = tabManager.reorderSidebarWorkspace(tabId: newWorkspace.id, toIndex: index, isDragOperation: true,
                usesTopLevelRows: usesTopLevelRows, explicitGroupId: explicitGroupId)
            sidebarState.settleStatusAreaAfterMove(previous: previous, moved: moved && tabManager.tabs.map(\.id) != orderBefore)
            return moved
        default: return false
        }
    }

    /// What the AppKit table paints for a landing: the update a workspace dropped at the same spot would paint. // (#cm-110.10)
    func tabLandingPaintUpdate(for landing: SidebarTabStatusLanding, renderContext: WorkspaceListRenderContext) -> SidebarWorkspaceTableReorderDropUpdate {
        let paint = workspaceDropPaintFields(plan: landing.plan, draggedWorkspaceId: landing.standInId, renderContext: renderContext)
        return SidebarWorkspaceTableReorderDropUpdate(indicator: landing.indicator, scope: landing.plan.indicatorScope,
            draggedWorkspaceId: landing.standInId, indicatorRowIds: paint.indicatorRowIds, plan: landing.plan, level: paint.level)
    }

    func installTabStatusLandingActions(_ actions: inout SidebarWorkspaceTableActions, renderContext: WorkspaceListRenderContext) {
        actions.resolveTabStatusLanding = { point, targets, headersOnly in
            tabStatusLanding(point: point, targets: targets, renderContext: renderContext, headersOnly: headersOnly)
        }
        actions.tabLandingPaintUpdate = { landing in
            tabLandingPaintUpdate(for: landing, renderContext: renderContext)
        }
        actions.moveBonsplitToNewWorkspaceAtLanding = { landing, transfer in
            moveBonsplitTabToNewWorkspace(at: landing, transfer: transfer)
        }
    }
}
