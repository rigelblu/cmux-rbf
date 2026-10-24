import AppKit
import CmuxFoundation
import CmuxSidebar
import CmuxWorkspaces
import Foundation

@MainActor
extension SidebarWorkspaceRenderItem {
    var headerDropIdentity: UUID? {
        switch self {
        case .statusesHeader: return SidebarStatusHeaderIdentity.statusesAreaUUID
        case .workspacesHeader: return SidebarStatusHeaderIdentity.workspacesAreaUUID
        case .pinnedHeader: return SidebarStatusHeaderIdentity.pinnedAreaUUID // (#cm-110.5)
        case .statusGroupHeader(let id): return SidebarStatusHeaderIdentity.uuid(forStatusId: id)
        case .colorSectionHeader: return id.colorHeaderDropIdentity
        default: return rowWorkspaceId
        }
    }
}

@MainActor
extension SidebarWorkspaceTableRowConfiguration {
    var headerDropIdentity: UUID { id.colorHeaderDropIdentity ?? workspaceId }
}

enum SidebarStatusHeaderDropAdapter {
    /// A generated status scope is identified by its actual typed header, not an ordinary group's anchor.
    @MainActor
    static func isWorkspaceStatusScope(_ painter: SidebarWorkspaceTableReorderIndicatorPainter?,
        rows: [SidebarWorkspaceTableRowConfiguration]) -> Bool {
        guard let painter, case .group(let id) = painter.scope else { return false }
        return rows.contains { row in
            guard case .some(.statusGroup(_)) = row.statusHeaderKind else { return false }
            return row.headerDropIdentity == id
        }
    }

    @MainActor
    static func cellPainter(_ painter: SidebarWorkspaceTableReorderIndicatorPainter?,
        rows: [SidebarWorkspaceTableRowConfiguration]) -> SidebarWorkspaceTableReorderIndicatorPainter? {
        isWorkspaceStatusScope(painter, rows: rows) ? nil : painter
    }

    /// One canonical gap, shared by the native container and immutable SwiftUI parent overlay.
    nonisolated static func workspaceIndicator(indicator: SidebarDropIndicator?, draggedId: UUID?,
        rowIds: [UUID]) -> SidebarDropIndicator? {
        guard draggedId != nil, let first = rowIds.first, let indicator else { return nil }
        let predicate = SidebarTabDropIndicatorPredicate()
        if let next = rowIds.first(where: {
            predicate.topVisible(forTabId: $0, draggedTabId: draggedId, dropIndicator: indicator, tabIds: rowIds)
        }) { return .init(tabId: next, edge: .top) }
        if let last = rowIds.last,
           predicate.bottomVisible(forTabId: last, draggedTabId: draggedId, dropIndicator: indicator,
                tabIds: rowIds, indicatorScope: .group(first)) {
            return .init(tabId: last, edge: .bottom)
        }
        return nil
    }

    @MainActor
    static func includesInMeasurement(_ row: SidebarWorkspaceTableRowConfiguration, includeHeaders: Bool) -> Bool {
        if row.statusHeaderKind != nil { return includeHeaders }
        if row.isColorSectionHeader { return includeHeaders }
        return true
    }

    /// Generic color cells and the suppressed source cell cannot own this canonical line.
    @MainActor
    static func externalIndicator(painter: SidebarWorkspaceTableReorderIndicatorPainter?,
                                  rows: [SidebarWorkspaceTableRowConfiguration]) -> SidebarDropIndicator? {
        guard let painter else { return nil }
        if isWorkspaceStatusScope(painter, rows: rows) {
            return workspaceIndicator(indicator: painter.indicator, draggedId: painter.draggedWorkspaceId,
                rowIds: painter.indicatorRowIds)
        }
        guard !painter.scope.isGroup,
              rows.contains(where: { $0.headerDropIdentity == painter.draggedWorkspaceId && $0.statusHeaderKind != nil }) else { return nil }
        let predicate = SidebarTabDropIndicatorPredicate()
        guard let target = rows.first(where: {
            predicate.topVisible(forTabId: $0.headerDropIdentity, draggedTabId: painter.draggedWorkspaceId,
                dropIndicator: painter.indicator, tabIds: painter.indicatorRowIds)
        }), target.isColorSectionHeader || target.headerDropIdentity == painter.draggedWorkspaceId else { return nil }
        return .init(tabId: target.headerDropIdentity, edge: .top)
    }

    nonisolated static func lineLevel(for action: SidebarWorkspaceReorderDropAction) -> Int? {
        switch action {
        case .statusGroupDrop: return 2
        case .statusAreaBoundaryDrop: return 0
        case .reorderStatusGroup: return 1
        case .moveStatusesArea: return 0
        default: return nil
        }
    }
}

enum SidebarStatusHeaderPlanResult {
    case notHeader
    case refused
    case plan(SidebarWorkspaceReorderDropPlan)
}

extension VerticalTabsSidebar {
    func isStatusHeaderDrag(_ id: UUID) -> Bool {
        return SidebarStatusHeaderDragSession.shared.isKnownHeader(id)
            || SidebarStatusHeaderIdentity.kind(forDragId: id, list: AppDelegate.statusListInUse) != nil
    }

    /// Workspace-only extension delegates must never interpret a header capability as a workspace.
    func statusHeaderAllowsWorkspaceBinding(_ id: UUID) -> Bool { !isStatusHeaderDrag(id) }

    func activateStatusHeaderDrag(_ id: UUID) -> Bool? {
        guard id != SidebarStatusHeaderIdentity.pinnedAreaUUID else { return nil } // (#cm-110.5)
        guard isStatusHeaderDrag(id) else { return nil }
        guard WorkspaceTodoFeature.isEnabled,
              SidebarStatusHeaderIdentity.kind(forDragId: id, list: AppDelegate.statusListInUse) != nil else { return false }
        return SidebarStatusHeaderDragSession.shared.activateIfLocal(headerId: id, windowId: windowId, dragState: dragState)
    }

    func beginStatusAwareWorkspaceDrag(_ id: UUID, sourceRowId: SidebarWorkspaceRenderItemID? = nil) {
        guard id != SidebarStatusHeaderIdentity.pinnedAreaUUID else { return } // (#cm-110.5)
        let session = dragState.beginDragging(tabId: id)
        SidebarStatusGroupDragSource.shared.began(windowId: windowId, session: session, rowId: sourceRowId)
        if isStatusHeaderDrag(id) { SidebarStatusHeaderDragSession.shared.began(windowId: windowId, session: session) }
    }

    func beginSidebarNativeDrag(dragId: UUID, sourceView: NSView, event: NSEvent, draggingFrame: NSRect, dragImage: NSImage, sourceRowId: SidebarWorkspaceRenderItemID? = nil) -> Bool {
        guard dragId != SidebarStatusHeaderIdentity.pinnedAreaUUID else { return false } // (#cm-110.5)
        let workspaceId: UUID
        if isStatusHeaderDrag(dragId) {
            guard WorkspaceTodoFeature.isEnabled,
                  SidebarStatusHeaderIdentity.kind(forDragId: dragId, list: AppDelegate.statusListInUse) != nil else { return false }
            workspaceId = dragId
        } else if tabManager.tabs.contains(where: { $0.id == dragId }) { workspaceId = dragId }
        else if let group = tabManager.workspaceGroups.first(where: { $0.id == dragId }) {
            if group.isEmpty { workspaceId = group.id }
            else {
                guard let anchor = tabManager.workspaceGroupAnchor(for: group.id)?.id else { return false }
                workspaceId = anchor
            }
        } else { return false }
        let began = dragState.beginNativeDragging(tabId: workspaceId,
            pasteboardItem: SidebarTabDragPayload(tabId: workspaceId).pasteboardItem(), sourceView: sourceView,
            event: event, draggingFrame: draggingFrame, dragImage: dragImage)
        if began, let token = dragState.currentWorkspaceDragSessionId {
            SidebarStatusGroupDragSource.shared.began(windowId: windowId,
                session: .init(id: token, workspaceId: workspaceId), rowId: sourceRowId)
        }
        if began, isStatusHeaderDrag(workspaceId), let token = dragState.currentWorkspaceDragSessionId {
            SidebarStatusHeaderDragSession.shared.began(windowId: windowId,
                session: SidebarWorkspaceDragSession(id: token, workspaceId: workspaceId))
        }
        return began
    }

    func statusHeaderIndicatorRows(draggedId: UUID?, items: [SidebarWorkspaceRenderItem]) -> [UUID]? {
        guard let draggedId, isStatusHeaderDrag(draggedId) else { return nil }
        return items.compactMap(\.headerDropIdentity)
    }

    func statusHeaderReorderPlan(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
                                 context: WorkspaceListRenderContext, draggedId: UUID,
                                 pendingSessionId: UUID? = nil) -> SidebarStatusHeaderPlanResult {
        guard isStatusHeaderDrag(draggedId) else { return .notHeader }
        let list = AppDelegate.statusListInUse
        guard WorkspaceTodoFeature.isEnabled, context.statusGroupProjection != nil,
              let kind = SidebarStatusHeaderIdentity.kind(forDragId: draggedId, list: list),
              kind != .pinnedArea, // (#cm-110.5) Pinned header does not drag
              let token = pendingSessionId ?? dragState.currentWorkspaceDragSessionId,
              SidebarStatusHeaderDragSession.shared.acceptsCommit(headerId: draggedId, windowId: windowId,
                sessionId: token, dragState: dragState) else { return .refused }
        let statusId: String?
        switch kind { case .statusesArea: statusId = nil; case .statusGroup(let id): statusId = id; case .workspacesArea: statusId = nil; case .pinnedArea: statusId = nil }
        let layout = SidebarStatusAreaLayout(items: context.workspaceRenderItems, tabs: context.tabs,
            groups: context.workspaceGroups, statusProjection: context.statusGroupProjection)
        guard let plan = SidebarStatusHeaderDropPlanner().plan(point: point, draggedStatusId: statusId,
            targets: layout.headerDropTargets(measured: targets), draggedWorkspacesArea: kind == .workspacesArea) else { return .refused }
        let action: SidebarWorkspaceReorderDropAction
        switch plan.action {
        case .statusGroup(let target, let before):
            action = .reorderStatusGroup(targetStatusId: target, insertBefore: before, sessionId: token)
        case .area(let above, let below, let last):
            action = .moveStatusesArea(aboveRow: above, belowRow: below, last: last, sessionId: token)
        }
        return .plan(.init(draggedWorkspaceId: draggedId, indicator: plan.indicator, indicatorScope: .raw, action: action))
    }

    /// Keeps ordinary workspace admission unchanged when SwiftUI supplies richer header measurements.
    static func workspaceOnlyDropTargets(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
                                         items: [SidebarWorkspaceRenderItem]) -> [SidebarWorkspaceReorderDropOverlay.Target]? {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var result: [SidebarWorkspaceReorderDropOverlay.Target] = []
        for target in targets {
            guard let rowId = target.renderItemId, let item = byId[rowId] else { result.append(target); continue }
            switch item {
            case .statusesHeader, .workspacesHeader, .pinnedHeader, .statusGroupHeader: // (#cm-110.5)
                if target.frame.contains(point) { return nil }
            case .colorSectionHeader: break
            default: result.append(target)
            }
        }
        return result
    }

    /// Validates the cached generation before committing its original action, including after native source end.
    func performStatusHeaderReorderPlan(_ plan: SidebarWorkspaceReorderDropPlan) -> Bool {
        let token: UUID
        let action: SidebarStatusHeaderDropPlan.Action
        switch plan.action {
        case .reorderStatusGroup(let target, let before, let session):
            token = session; action = .statusGroup(targetStatusId: target, insertBefore: before)
        case .moveStatusesArea(let above, let below, let last, let session):
            token = session; action = .area(aboveRow: above, belowRow: below, last: last)
        default: return false
        }
        let list = AppDelegate.statusListInUse
        guard WorkspaceTodoFeature.isEnabled,
              let kind = SidebarStatusHeaderIdentity.kind(forDragId: plan.draggedWorkspaceId, list: list),
              let indicator = plan.indicator else { return false }
        return SidebarStatusHeaderDragSession.shared.commitIfAccepted(headerId: plan.draggedWorkspaceId,
            windowId: windowId, sessionId: token, dragState: dragState) {
                sidebarState.prepareWorkspaceSections(tabManager: tabManager) // (#cm-110.4)
                let items = Self.statusRenderItemsForSnapshot(tabManager: tabManager, state: sidebarState).items
                let projection = Self.currentStatusGroupProjection(tabs: tabManager.tabs, groups: tabManager.workspaceGroups, storedOrder: sidebarState.statusGroups?.order)
                let layout = SidebarStatusAreaLayout(items: items, tabs: tabManager.tabs,
                    groups: tabManager.workspaceGroups, statusProjection: projection)
                return sidebarState.commitStatusHeaderDrop(source: kind, plan: .init(indicator: indicator, action: action),
                    list: list, controlsEnabled: true, validTopLevelRowIds: layout.topLevelRowIds)
            }
    }
}
