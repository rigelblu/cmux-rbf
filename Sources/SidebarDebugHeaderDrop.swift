import AppKit
import CmuxFoundation
import Foundation

#if DEBUG
/// DEBUG drops obtain coordinates from the same measured overlay targets, then call the pointer plan and commit closures.
@MainActor
enum SidebarDebugHeaderDrop {
    enum Zone: String, CaseIterable, Sendable { case upper, lower, topEdge = "top-edge", bottomEdge = "bottom-edge", belowAll = "below-all", gap25, gap50, gap75, middle, innerTop = "inner-top", innerBottom = "inner-bottom" } // (#cm-110.10)
    enum Side: String, CaseIterable, Sendable { case left, right }

    static func point(targetId: UUID, zone: Zone, side: Side,
                      targets: [SidebarWorkspaceReorderDropOverlay.Target],
                      renderItemId: SidebarWorkspaceRenderItemID? = nil,
                      pointFrames: [UUID: CGRect]? = nil) -> CGPoint? {
        guard let target = targets.first(where: { target in
            if let renderItemId { return target.renderItemId == renderItemId }
            return target.workspaceId == targetId
        }),
              target.frame.width > 0, target.frame.height > 0 else { return nil }
        let frame = pointFrames?[target.workspaceId] ?? target.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let x = frame.minX + frame.width * (side == .left ? 0.25 : 0.75)
        let y: CGFloat
        switch zone {
        case .upper: y = frame.minY + frame.height * 0.25
        case .lower: y = frame.minY + frame.height * 0.75
        case .topEdge: y = frame.minY
        case .bottomEdge: y = frame.maxY
        case .middle: y = frame.midY // (#cm-110.10)
        case .innerTop: y = frame.minY + 2 // (#cm-110.10)
        case .innerBottom: y = frame.maxY - 2 // (#cm-110.10)
        case .belowAll: y = (targets.map { (pointFrames?[$0.workspaceId] ?? $0.frame).maxY }.max() ?? frame.maxY) + 1
        case .gap25, .gap50, .gap75:
            let ordered = targets.sorted { $0.frame.minY < $1.frame.minY }
            guard let index = ordered.firstIndex(where: {
                if let renderItemId { return $0.renderItemId == renderItemId }
                return $0.workspaceId == targetId
            }), index + 1 < ordered.count else { return nil }
            let nextTarget = ordered[index + 1]
            let next = pointFrames?[nextTarget.workspaceId] ?? nextTarget.frame
            let gap = next.minY - frame.maxY
            guard gap > 0, next.width > 0, next.height > 0 else { return nil }
            let fraction: CGFloat = zone == .gap25 ? 0.25 : zone == .gap50 ? 0.5 : 0.75
            y = frame.maxY + gap * fraction
        }
        return CGPoint(x: x, y: y)
    }

    static func perform(draggedId: UUID, targetId: UUID, zone: Zone, side: Side,
                        targets: [SidebarWorkspaceReorderDropOverlay.Target],
                        renderItemId: SidebarWorkspaceRenderItemID? = nil,
                        pointFrames: [UUID: CGRect]? = nil,
                        plan: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID) -> SidebarWorkspaceReorderDropPlan?,
                        commit: (SidebarWorkspaceReorderDropPlan) -> Bool) -> Bool {
        guard let point = point(targetId: targetId, zone: zone, side: side, targets: targets, renderItemId: renderItemId, pointFrames: pointFrames),
              let resolved = plan(point, targets, draggedId) else { return false }
        return commit(resolved)
    }
}

/// Resolves the `tab:<uuid>` of `sidebar drop` to the transfer a live tab drag would carry. // (#cm-110.10)
@MainActor
enum SidebarDebugTabDrop {
    /// Accepts a bonsplit tab id or a panel (surface) id, whichever the caller read from `list-panels` or the tree. // (#cm-110.10)
    static func transfer(forTab raw: UUID) -> BonsplitTabDragPayload.Transfer? {
        guard let app = AppDelegate.shared else { return nil }
        let located: (workspaceId: UUID, panelId: UUID, tabManager: TabManager)
        if let tab = app.locateBonsplitSurface(tabId: raw) {
            located = (tab.workspaceId, tab.panelId, tab.tabManager)
        } else if let surface = app.locateSurface(surfaceId: raw) {
            located = (surface.workspaceId, raw, surface.tabManager)
        } else { return nil }
        guard let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let tabId = workspace.surfaceIdFromPanelId(located.panelId),
              let paneId = workspace.paneId(forPanelId: located.panelId) else { return nil }
        return BonsplitTabDragPayload.Transfer(debugTabId: tabId.uuid, sourcePaneId: paneId.id)
    }
}
#endif
