import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxWorkspaces
import Foundation
import SwiftUI

#if DEBUG
struct SidebarDebugDropRequest: Sendable {
    let dragged: String
    let target: String
    let zone: SidebarDebugHeaderDrop.Zone
    let side: SidebarDebugHeaderDrop.Side

    init?(params: [String: Any]) {
        var values: [String: String] = [:]
        if let arguments = params["arguments"] as? [String] {
            guard arguments.count % 2 == 0 else { return nil }
            for index in stride(from: 0, to: arguments.count, by: 2) {
                let option = arguments[index]
                guard ["--drag", "--target", "--zone", "--side", "--window"].contains(option),
                      values[option] == nil else { return nil }
                values[option] = arguments[index + 1]
            }
        }
        guard let dragged = values["--drag"] ?? (params["drag"] as? String),
              let target = values["--target"] ?? (params["target"] as? String),
              let zoneRaw = values["--zone"] ?? (params["zone"] as? String),
              let sideRaw = values["--side"] ?? (params["side"] as? String),
              let zone = SidebarDebugHeaderDrop.Zone(rawValue: zoneRaw),
              let side = SidebarDebugHeaderDrop.Side(rawValue: sideRaw) else { return nil }
        self.dragged = dragged; self.target = target; self.zone = zone; self.side = side
    }
}

struct SidebarDebugDropPaint { // (#cm-110.10)
    let scope: SidebarWorkspaceReorderDropIndicatorScope // (#cm-110.10)
    let rowIds: [UUID] // (#cm-110.10)
    let level: Int? // (#cm-110.10)
    var payload: [String: Any] { // (#cm-110.10)
        let scopeText: String // (#cm-110.10)
        switch scope { // (#cm-110.10)
        case .raw: scopeText = "raw" // (#cm-110.10)
        case .topLevel: scopeText = "topLevel" // (#cm-110.10)
        case .group(let id): scopeText = "group:\(id.uuidString)" // (#cm-110.10)
        } // (#cm-110.10)
        return ["scope": scopeText, "indicator_row_ids": rowIds.map(\.uuidString), "level": level.map { $0 as Any } ?? NSNull()] // (#cm-110.10)
    } // (#cm-110.10)
} // (#cm-110.10)

struct SidebarDebugDropResult {
    let performed: Bool
    let plan: SidebarWorkspaceReorderDropPlan?
    /// A tab drop reads its admission and line from the tab drop view, which has no reorder plan. // (#cm-110.10)
    var tabDrop: (accepted: Bool, indicator: SidebarDropIndicator?)? = nil // (#cm-110.10)
    /// What the table would paint for this spot, the same fields for a workspace drag and a dragged tab. // (#cm-110.10)
    var paint: SidebarDebugDropPaint? = nil // (#cm-110.10)
    var payload: [String: Any] {
        var result: [String: Any] = ["performed": performed, "accepted": tabDrop?.accepted ?? (plan != nil)] // (#cm-110.10)
        if let indicator = tabDrop != nil ? tabDrop?.indicator : plan?.indicator { // (#cm-110.10)
            result["indicator"] = ["row_id": indicator.tabId.map { $0.uuidString as Any } ?? NSNull(),
                                   "edge": indicator.edge == .top ? "top" : "bottom"]
        }
        if let paint { result["paint"] = paint.payload } // (#cm-110.10)
        return result
    }
}

extension VerticalTabsSidebar {
    func installStatusHeaderTableActions(_ actions: inout SidebarWorkspaceTableActions,
        renderContext: WorkspaceListRenderContext,
        plan: @escaping (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID) -> SidebarWorkspaceReorderDropPlan?,
        commit: @escaping (SidebarWorkspaceReorderDropPlan) -> Bool) {
        installRichHeaderTargetPredicate(&actions, hasStatusArea: renderContext.statusGroupProjection != nil)
        actions.debugPerformSidebarDrop = { request, targets, tabDrop in // (#cm-110.10)
            performDebugSidebarDrop(request, targets: targets, renderContext: renderContext, plan: plan, commit: commit, tabDrop: tabDrop) // (#cm-110.10)
        }
    }

    func performDebugSidebarDrop(_ request: SidebarDebugDropRequest, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        renderContext: WorkspaceListRenderContext,
        plan: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID) -> SidebarWorkspaceReorderDropPlan?,
        commit: (SidebarWorkspaceReorderDropPlan) -> Bool,
        tabDrop: ((CGPoint, UUID) -> SidebarDebugDropResult?)? = nil) -> SidebarDebugDropResult? { // (#cm-110.10)
            if request.dragged.hasPrefix("tab:") { // (#cm-110.10)
                guard isPresented, dragState.currentWorkspaceDragSessionId == nil, let tabDrop, // (#cm-110.10)
                      let tabId = UUID(uuidString: String(request.dragged.dropFirst(4))), // (#cm-110.10)
                      let target = Self.debugSidebarTarget(request.target, items: renderContext.workspaceRenderItems, targets: targets), // (#cm-110.10)
                      let point = SidebarDebugHeaderDrop.point(targetId: target.id, zone: request.target == "below" ? .belowAll : request.zone, // (#cm-110.10)
                          side: request.side, targets: targets, renderItemId: target.row, pointFrames: nil) else { return nil } // (#cm-110.10)
                return tabDrop(point, tabId) // (#cm-110.10)
            } // (#cm-110.10)
            guard isPresented, dragState.currentWorkspaceDragSessionId == nil,
                  let source = debugSidebarSource(request.dragged, items: renderContext.workspaceRenderItems),
                  let target = Self.debugSidebarTarget(request.target, items: renderContext.workspaceRenderItems, targets: targets),
                  targets.contains(where: { measured in
                      if let row = target.row { return measured.renderItemId == row }
                      return measured.workspaceId == target.id
                  }) else { return nil }
            beginStatusAwareWorkspaceDrag(source.id, sourceRowId: source.row)
            defer { dragState.finishDrag() }
            var acceptedPlan: SidebarWorkspaceReorderDropPlan?
            var paint: SidebarDebugDropPaint? // (#cm-110.10)
            let pointFrames = Self.workspaceStatusDebugPointFrames(sourceId: source.id, sourceRowId: source.row, // (#cm-110.8)
                targetId: target.id, targetRowId: target.row, items: renderContext.workspaceRenderItems, // (#cm-110.8)
                projection: renderContext.statusGroupProjection, targets: targets) // (#cm-110.8)
            let performed = SidebarDebugHeaderDrop.perform(draggedId: source.id, targetId: target.id,
                zone: request.target == "below" ? .belowAll : request.zone, side: request.side, targets: targets,
                renderItemId: target.row, pointFrames: pointFrames,
                plan: { point, measured, id in
                    let resolved = plan(point, measured, id)
                    acceptedPlan = resolved
                    // Read before the commit moves rows, as a tab drop's paint is read before its move. // (#cm-110.10)
                    paint = resolved.map { SidebarDebugDropPaint(scope: $0.indicatorScope, rowIds: workspaceDropPaintFields(plan: $0, // (#cm-110.10)
                        draggedWorkspaceId: source.id, renderContext: renderContext).indicatorRowIds, // (#cm-110.10)
                        level: workspaceDropPaintFields(plan: $0, draggedWorkspaceId: source.id, renderContext: renderContext).level) } // (#cm-110.10)
                    return resolved
                }, commit: commit)
            return SidebarDebugDropResult(performed: performed, plan: acceptedPlan, paint: paint) // (#cm-110.10)
    }

    @ViewBuilder
    func makeSidebarDebugDropHost(renderContext: WorkspaceListRenderContext,
        plan: @escaping (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID) -> SidebarWorkspaceReorderDropPlan?,
        commit: @escaping (SidebarWorkspaceReorderDropPlan) -> Bool) -> some View {
        let monitor = pointerInteractionMonitor
        if let registry = AppDelegate.shared?.sidebarDebugActions {
            SidebarDebugDropHost(registry: registry, windowId: windowId,
                actions: makeSidebarDebugSectionHeaderActions(renderContext: renderContext)) { request in
                var frames: [UUID: CGRect] = [:]
                for item in renderContext.workspaceRenderItems {
                    if let id = item.headerDropIdentity, let frame = monitor.statusHeaderDropFrame(for: item.id) { frames[id] = frame }
                }
                let targets = Self.statusAwareSwiftUITargets(items: renderContext.workspaceRenderItems, frames: frames, context: renderContext)
                return performDebugSidebarDrop(request, targets: targets, renderContext: renderContext, plan: plan, commit: commit)
            }.frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }

    private func debugSidebarSource(_ raw: String, items: [SidebarWorkspaceRenderItem]) -> (id: UUID, row: SidebarWorkspaceRenderItemID?)? {
        if raw == "workspaces", WorkspaceTodoFeature.isEnabled,
           let id = SidebarDebugActions.identity(raw, items: items),
           let item = items.first(where: { $0.headerDropIdentity == id }) {
            return (id, item.id)
        }
        let list = AppDelegate.statusListInUse
        if raw == "statuses", WorkspaceTodoFeature.isEnabled, list.source != .cmux, !list.entries.isEmpty {
            return (SidebarStatusHeaderIdentity.statusesAreaUUID, .statusesArea())
        }
        if raw.hasPrefix("status:"), WorkspaceTodoFeature.isEnabled {
            let id = String(raw.dropFirst(7))
            guard list.source != .cmux, list.entry(id: id) != nil else { return nil }
            return (SidebarStatusHeaderIdentity.uuid(forStatusId: id), .statusGroup(id))
        }
        if raw.hasPrefix("workspace:") || raw.hasPrefix("group:") {
            guard let row = Self.workspaceStatusDebugSourceRow(raw, items: items),
                  let item = items.first(where: { $0.id == row }) else { return nil }
            switch item {
            case .workspace(let id): return (id, row)
            case .groupHeader(let id, let anchor):
                guard let group = tabManager.workspaceGroups.first(where: { $0.id == id }) else { return nil }
                return (group.isEmpty ? group.id : anchor, row)
            default: return nil
            }
        }
        let value = raw.hasPrefix("workspace:") ? String(raw.dropFirst(10))
            : raw.hasPrefix("group:") ? String(raw.dropFirst(6)) : raw
        guard let id = UUID(uuidString: value) else { return nil }
        if let kind = SidebarStatusHeaderIdentity.kind(forDragId: id, list: list), WorkspaceTodoFeature.isEnabled {
            let row: SidebarWorkspaceRenderItemID
            switch kind { case .statusesArea: row = .statusesArea(); case .workspacesArea: row = .workspacesArea(); case .statusGroup(let id): row = .statusGroup(id) }
            return (SidebarStatusHeaderIdentity.uuid(for: kind), row)
        }
        if let group = tabManager.workspaceGroups.first(where: { $0.id == id }) {
            guard let payload = group.isEmpty ? group.id : tabManager.workspaceGroupAnchor(for: group.id)?.id else { return nil }
            return (payload, .group(group.id))
        }
        guard let item = items.first(where: { $0.headerDropIdentity == id }) else { return nil }
        return (id, item.id)
    }

    private static func debugSidebarTarget(_ raw: String, items: [SidebarWorkspaceRenderItem],
        targets: [SidebarWorkspaceReorderDropOverlay.Target]) -> (id: UUID, row: SidebarWorkspaceRenderItemID?)? {
        if let id = SidebarDebugActions.identity(raw, items: items),
           let item = items.first(where: { $0.headerDropIdentity == id }) {
            return (id, item.id)
        }
        if raw == "below" {
            guard let last = targets.max(by: { $0.frame.maxY < $1.frame.maxY }) else { return nil }
            return (last.workspaceId, last.renderItemId)
        }
        let rawId = UUID(uuidString: raw)
        let workspaceId = raw.hasPrefix("workspace:") ? UUID(uuidString: String(raw.dropFirst(10))) : rawId
        let groupId = raw.hasPrefix("group:") ? UUID(uuidString: String(raw.dropFirst(6))) : rawId
        let item = items.first { item in
            switch item {
            case .statusesHeader: return raw == "statuses" || rawId == SidebarStatusHeaderIdentity.statusesAreaUUID
            case .workspacesHeader: return raw == "workspaces" || rawId == SidebarStatusHeaderIdentity.workspacesAreaUUID
            case .statusGroupHeader(let id): return raw == "status:\(id)" || rawId == SidebarStatusHeaderIdentity.uuid(forStatusId: id)
            case .groupHeader(let id, let anchor): return groupId == id || rawId == anchor
            case .colorSectionHeader(let section):
                return section.id.pinTier == .unpinned && raw.hasPrefix("color:")
                    && WorkspaceColorHex.normalized(String(raw.dropFirst(6))) == section.id.normalizedHex
            case .workspace(let id): return workspaceId == id
            }
        }
        guard let item, let id = item.headerDropIdentity else { return nil }
        return (id, item.id)
    }
}

private struct SidebarDebugDropHost: NSViewRepresentable {
    let registry: SidebarDebugActions
    let windowId: UUID
    let actions: [SidebarDebugActions.Action]
    let handler: (SidebarDebugDropRequest) -> SidebarDebugDropResult?
    func makeNSView(context: Context) -> SidebarDebugDropHostView { SidebarDebugDropHostView() }
    func updateNSView(_ view: SidebarDebugDropHostView, context: Context) {
        if let old = view.ownerWindowId { view.registry?.remove(windowId: old, owner: view) }
        view.registry = registry
        view.ownerWindowId = windowId
        registry.update(windowId: windowId, owner: view, actions: actions, handler: handler)
    }
    static func dismantleNSView(_ view: SidebarDebugDropHostView, coordinator: ()) {
        if let id = view.ownerWindowId { view.registry?.remove(windowId: id, owner: view) }
    }
}

private final class SidebarDebugDropHostView: NSView {
    var registry: SidebarDebugActions?
    var ownerWindowId: UUID?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension TerminalController {
    nonisolated func v2DebugSidebarDrop(params: [String: Any]) -> V2CallResult {
        guard let request = SidebarDebugDropRequest(params: params) else {
            return .err(code: "invalid_params", message: String(localized: "sidebar.drop.error.invalidArguments",
                defaultValue: "Invalid sidebar drop arguments."), data: nil)
        }
        // AppKit row geometry and the shared plan/commit actions require one synchronous main-actor snapshot.
        // The socket dispatcher and argument parsing remain on the worker. No focus or activation is requested.
        return v2MainSync {
            guard let app = AppDelegate.shared else { return self.debugSidebarDropUnavailable() }
            let manager: TabManager?
            if params["window_id"] != nil {
                guard let id = self.v2UUID(params, "window_id") else { return self.debugSidebarDropUnavailable() }
                manager = app.tabManagerFor(windowId: id)
            } else { manager = self.tabManager }
            guard let manager, let context = app.mainWindowContexts.values.first(where: { $0.tabManager === manager }),
                  let content = context.window?.contentView else { return self.debugSidebarDropUnavailable() }
            @MainActor func controller(in view: NSView) -> SidebarWorkspaceTableController? {
                guard !view.isHidden else { return nil }
                if let table = view as? SidebarWorkspaceTableViewImpl, let controller = table.workspaceController { return controller }
                for child in view.subviews { if let found = controller(in: child) { return found } }
                return nil
            }
            let result: SidebarDebugDropResult?
            if let native = controller(in: content) { result = native.debugPerformSidebarDrop(request) }
            else { result = app.sidebarDebugActions.perform(windowId: context.windowId, request: request) }
            guard let result else { return self.debugSidebarDropUnavailable() }
            return .ok(result.payload)
        }
    }

    private func debugSidebarDropUnavailable() -> V2CallResult {
        .err(code: "not_found", message: String(localized: "sidebar.drop.error.unavailable",
            defaultValue: "Sidebar drop is unavailable."), data: nil)
    }
}
#else
extension VerticalTabsSidebar {
    func installStatusHeaderTableActions(_ actions: inout SidebarWorkspaceTableActions,
        renderContext: WorkspaceListRenderContext,
        plan: @escaping (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], UUID) -> SidebarWorkspaceReorderDropPlan?,
        commit: @escaping (SidebarWorkspaceReorderDropPlan) -> Bool) { installRichHeaderTargetPredicate(&actions, hasStatusArea: renderContext.statusGroupProjection != nil) }
}
#endif

extension VerticalTabsSidebar {
    func installRichHeaderTargetPredicate(_ actions: inout SidebarWorkspaceTableActions, hasStatusArea: Bool) {
        actions.usesStatusHeaderDropTargets = {
            guard let id = dragState.currentWorkspaceDragId ?? dragState.mostRecentWorkspaceDragWorkspaceId else { return false }
            return isStatusHeaderDrag(id) || hasStatusArea
        }
    }
}
