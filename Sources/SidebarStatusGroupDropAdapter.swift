import AppKit
import CmuxFoundation
import CmuxSidebar
import CmuxWorkspaces
import Foundation

extension VerticalTabsSidebar {
    /// Native raw row targets retain intercell spacing; status admission also receives the actual cell bounds.
    static func workspaceStatusContentFrame(table: NSTableView, row: Int, overlay: NSView) -> CGRect? {
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
        let frame = cell.convert(cell.bounds, to: overlay)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    /// Immutable inputs for the shared status adapter and the real legacy continuation.
    struct WorkspaceStatusDropSnapshot {
        let tabs: [Workspace]
        let workspaceGroups: [WorkspaceGroup]
        let workspaceRenderItems: [SidebarWorkspaceRenderItem]
        let statusGroupProjection: WorkspaceStatusGroupProjection?
        let statusGroupFolds: WorkspaceStatusGroupsState
        let colorSectionProjection: SidebarWorkspaceColorSectionProjection
        let selectedIds: Set<UUID>
        let rootWorkspaceIds: [UUID]

        init(context: WorkspaceListRenderContext, selectedIds: Set<UUID>, rootWorkspaceIds: [UUID] = []) {
            self.init(tabs: context.tabs, workspaceGroups: context.workspaceGroups,
                workspaceRenderItems: context.workspaceRenderItems, statusGroupProjection: context.statusGroupProjection,
                statusGroupFolds: context.statusGroupFolds, colorSectionProjection: context.colorSectionProjection, selectedIds: selectedIds, rootWorkspaceIds: rootWorkspaceIds)
        }
        init(tabs: [Workspace], workspaceGroups: [WorkspaceGroup], workspaceRenderItems: [SidebarWorkspaceRenderItem],
            statusGroupProjection: WorkspaceStatusGroupProjection?, statusGroupFolds: WorkspaceStatusGroupsState,
            colorSectionProjection: SidebarWorkspaceColorSectionProjection, selectedIds: Set<UUID>, rootWorkspaceIds: [UUID] = []) {
            self.tabs = tabs; self.workspaceGroups = workspaceGroups; self.workspaceRenderItems = workspaceRenderItems
            self.statusGroupProjection = statusGroupProjection; self.statusGroupFolds = statusGroupFolds
            self.colorSectionProjection = colorSectionProjection; self.selectedIds = selectedIds; self.rootWorkspaceIds = rootWorkspaceIds
        }
    }

    func workspaceStatusReorderPlan(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        context: WorkspaceListRenderContext, draggedId: UUID, sessionId: UUID?, bypass: Bool,
        ordinary: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], Bool) -> SidebarWorkspaceReorderDropPlan?) -> SidebarStatusHeaderPlanResult {
        guard !bypass, context.statusGroupProjection != nil else { return .notHeader }
        let token = sessionId ?? dragState.currentWorkspaceDragSessionId
        let record = token.flatMap { SidebarStatusGroupDragSource.shared.source(windowId: windowId,
            workspaceId: draggedId, sessionId: $0, dragState: dragState) }
        let list = AppDelegate.statusListInUse
        return Self.workspaceStatusRoute(point: point, targets: targets,
            snapshot: .init(context: context, selectedIds: selectedTabIds, rootWorkspaceIds: tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true)), draggedId: draggedId,
            sourceKind: record?.kind, token: token, foreignDraggedIsPinned: dragState.foreignDraggedIsPinned,
            controlsEnabled: WorkspaceTodoFeature.isEnabled, hasUserStatusList: list.source != .cmux && !list.entries.isEmpty,
            ordinary: ordinary)
    }

    /// The caller's unchanged status-or-ordinary dispatch, shared with integration coverage.
    static func workspaceStatusOrOrdinaryPlan(status: SidebarStatusHeaderPlanResult,
        ordinary: () -> SidebarWorkspaceReorderDropPlan?) -> SidebarWorkspaceReorderDropPlan? {
        switch status {
        case .notHeader: return ordinary()
        case .refused: return nil
        case .plan(let plan): return plan
        }
    }

    /// Contains the production target filtering and pointer forwarding; no test-side routing copy.
    static func workspaceStatusRoute(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        snapshot: WorkspaceStatusDropSnapshot, draggedId: UUID, sourceKind: SidebarStatusGroupDropRules.SourceKind?,
        token: UUID?, foreignDraggedIsPinned: Bool?, controlsEnabled: Bool, hasUserStatusList: Bool,
        ordinary: (CGPoint, [SidebarWorkspaceReorderDropOverlay.Target], Bool) -> SidebarWorkspaceReorderDropPlan?) -> SidebarStatusHeaderPlanResult {
        guard let projection = snapshot.statusGroupProjection else { return .notHeader }
        // Headers displayed under a status stay inert until cm-110.8, including ordinary destinations.
        if workspaceProjectedStatusHeaderIsRefused(draggedId: draggedId, sourceKind: sourceKind,
            groups: snapshot.workspaceGroups, projection: projection) { return .refused }
        if let join = workspaceProjectedGroupJoin(point: point, targets: targets, snapshot: snapshot,
            draggedId: draggedId, sourceKind: sourceKind, token: token,
            controlsEnabled: controlsEnabled, hasUserStatusList: hasUserStatusList) { return join }
        let workspace = snapshot.tabs.first { $0.id == draggedId }
        let sourceGroup: WorkspaceGroup?
        if case .workspaceGroupHeader(let id)? = sourceKind { sourceGroup = snapshot.workspaceGroups.first { $0.id == id } }
        else { sourceGroup = nil }
        let layout = SidebarStatusAreaLayout(items: snapshot.workspaceRenderItems, tabs: snapshot.tabs,
            groups: snapshot.workspaceGroups, statusProjection: projection)
        let request = SidebarStatusGroupDropRules.Request(point: point,
            source: .init(workspaceId: draggedId, kind: sourceKind ?? .unknown,
                isLocal: workspace != nil || sourceGroup != nil,
                isPinned: sourceGroup?.isPinned ?? workspace?.isPinned ?? foreignDraggedIsPinned ?? false,
                groupId: projection.contains(workspaceId: draggedId) ? nil : workspace?.groupId,
                isColorSectionMember: snapshot.colorSectionProjection.sectionByWorkspaceId[draggedId] != nil),
            targets: Self.workspaceStatusDropTargets(items: snapshot.workspaceRenderItems, measured: targets, useContentFrames: sourceKind == .workspace),
            groups: projection.groups.map { .init(statusId: $0.statusId,
                memberWorkspaceIds: workspaceStatusDisplayDropMembers(statusId: $0.statusId,
                    projection: projection, items: snapshot.workspaceRenderItems)) },
            areaIsLast: layout.saving(state: snapshot.statusGroupFolds)?.last == true,
            controlsEnabled: controlsEnabled, hasUserStatusList: hasUserStatusList)
        let rootPoint = CGPoint(x: targets.map(\.frame.minX).min() ?? point.x, y: point.y)
        let lastMeasuredBottom = request.targets.filter { $0.frame.width > 0 && $0.frame.height > 0 }.map(\.frame.maxY).max()
        let belowLastArea = request.areaIsLast && request.targets.contains { $0.kind == .statusesArea }
            && lastMeasuredBottom.map { point.y > $0 } == true
        switch SidebarStatusGroupDropRules().plan(request) {
        case .refused: return .refused
        case .unrelated:
            // A pinned workspace keeps the legacy pin-tier action, but the last area has no right-hand group.
            if belowLastArea, request.source.isPinned, request.source.isLocal,
               sourceKind == .workspace, token != nil, controlsEnabled, hasUserStatusList {
                guard let plan = ordinary(rootPoint, targets, true) else { return .refused }
                return .plan(.init(draggedWorkspaceId: plan.draggedWorkspaceId,
                    indicator: .init(tabId: nil, edge: .bottom), indicatorScope: .raw, action: plan.action))
            }
            guard projection.contains(workspaceId: draggedId) else { return .notHeader }
            guard let plan = ordinary(point, targets, false), SidebarStatusGroupDropRules().permitsLeavingStatusGroup(action: plan.action) else { return .refused }
            return .plan(plan)
        case .statusGroup(let value):
            guard let token, sourceKind == .workspace else { return .refused }
            return .plan(.init(draggedWorkspaceId: draggedId, indicator: value.indicator,
                indicatorScope: .group(SidebarStatusHeaderIdentity.uuid(forStatusId: value.statusId)),
                action: .statusGroupDrop(plan: .init(statusId: value.statusId, placement: value.placement,
                    setsStatus: projection.group(for: value.statusId)?.memberWorkspaceIds.contains(draggedId) != true,
                    indicator: value.indicator), sessionId: token)))
        case .areaBoundary(let boundary, let indicator):
            guard let token, sourceKind != nil else { return .refused }
            let ordinaryTargets = targets.filter { target in
                guard let item = snapshot.workspaceRenderItems.first(where: { $0.id == (target.renderItemId ?? .workspace(target.workspaceId)) }) else { return true }
                switch item {
                case .statusesHeader, .statusGroupHeader: return false
                case .workspace(let id): return boundary != .aboveArea || !projection.contains(workspaceId: id)
                default: return true
                }
            }
            let move: SidebarStatusAreaBoundaryDropPlan.Move
            if let child = workspaceStatusChildRootDestination(boundary: boundary, draggedId: draggedId,
                kind: sourceKind ?? .unknown, tabs: snapshot.tabs, groups: snapshot.workspaceGroups,
                items: snapshot.workspaceRenderItems, projection: projection, selectedIds: snapshot.selectedIds,
                rootWorkspaceIds: snapshot.rootWorkspaceIds) {
                move = .workspaces(targetIndex: child.targetIndex, usesTopLevelRows: true, explicitGroupId: nil)
            } else if let base = ordinary(boundary == .belowAll ? rootPoint : point, ordinaryTargets, boundary == .belowAll) {
                switch base.action {
                case .reorder(let index, let top, let group): move = .workspaces(targetIndex: index, usesTopLevelRows: top, explicitGroupId: group)
                case .reorderGroup(let index): move = .group(targetIndex: index)
                default: return .refused
                }
            } else if let unchanged = workspaceAreaOrdinaryNoOp(boundary: boundary, snapshot: snapshot,
                draggedId: draggedId, kind: sourceKind ?? .unknown) {
                move = unchanged
            } else { return .refused }
            return .plan(.init(draggedWorkspaceId: draggedId, indicator: indicator, indicatorScope: .raw,
                action: .statusAreaBoundaryDrop(plan: .init(boundary: boundary, move: move), sessionId: token)))
        }
    }

    private struct WorkspaceStatusChildRootDestination {
        let groupId: UUID
        let targetIndex: Int
        let referenceId: UUID?
    }

    /// A child-header exception belongs only to an explicit Statuses boundary, never the ordinary nested planner.
    private static func workspaceStatusChildRootDestination(boundary: SidebarStatusGroupDropRules.AreaBoundary,
        draggedId: UUID, kind: SidebarStatusGroupDropRules.SourceKind, tabs: [Workspace], groups: [WorkspaceGroup],
        items: [SidebarWorkspaceRenderItem], projection: WorkspaceStatusGroupProjection?, selectedIds: Set<UUID>,
        rootWorkspaceIds: [UUID]) -> WorkspaceStatusChildRootDestination? {
        guard case .workspaceGroupHeader(let id) = kind,
              let group = groups.first(where: { $0.id == id }), group.parentGroupId != nil,
              !group.isEmpty, !group.isPinned, group.liveAnchorWorkspaceId == draggedId,
              let workspace = tabs.first(where: { $0.id == draggedId }), !workspace.isPinned,
              let area = items.firstIndex(where: { $0.id == .statusesArea() }), projection != nil,
              !rootWorkspaceIds.isEmpty else { return nil }
        let tree = WorkspaceGroupTree(groups: groups)
        guard groups.first(where: { $0.id == tree.outermost(of: id) })?.isPinned == false else { return nil }
        let moving = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(orderedWorkspaceIds: tabs.map(\.id),
            selectedIds: selectedIds, draggedId: draggedId, anchorIds: Set(groups.compactMap(\.liveAnchorWorkspaceId)))
        let movingGroups = groups.filter { $0.liveAnchorWorkspaceId.map(moving.contains) == true }.map(\.id)
        guard movingGroups == [id] else { return nil }
        let layout = SidebarStatusAreaLayout(items: items, tabs: tabs, groups: groups, statusProjection: projection)
        let rootIds = rootWorkspaceIds.filter { $0 != draggedId }
        var reference: UUID?
        if boundary == .aboveArea,
           let following = items.dropFirst(area + 1).compactMap({ layout.owner(of: $0.id) })
                .first(where: { layout.topLevelRowIds.contains($0) && $0 != "group:\(id.uuidString)" }) {
            reference = rootIds.first { candidate in
                let row: SidebarWorkspaceRenderItemID
                if let owner = groups.first(where: { ($0.isEmpty ? $0.id : $0.anchorWorkspaceId) == candidate }) {
                    row = .group(owner.id)
                } else { row = .workspace(candidate) }
                return layout.owner(of: row) == following
            }
            guard reference != nil else { return nil }
        }
        let index = reference.flatMap { rootIds.firstIndex(of: $0) } ?? rootIds.count
        return .init(groupId: id, targetIndex: index, referenceId: reference)
    }

    /// Reparent through the existing model action, then place the new root relative to the unchanged root reference.
    private static func performWorkspaceStatusChildRootMove(_ destination: WorkspaceStatusChildRootDestination,
        plan: SidebarWorkspaceReorderDropPlan, tabManager: TabManager,
        performOrdinary: (SidebarWorkspaceReorderDropPlan) -> Bool) -> Bool {
        let originalTabs = tabManager.tabs, originalGroups = tabManager.workspaceGroups
        let originalSelection = tabManager.selectedTabId
        let originalOrder = originalTabs.map(\.id)
        let movedIds = tabManager.workspaces.workspaceIdsInside(destination.groupId)
        let folds = Dictionary(uniqueKeysWithValues: originalGroups.map { ($0.id, $0.isCollapsed) })
        var committed = false
        defer {
            let restoreOrder = !committed && (tabManager.workspaceGroups != originalGroups || tabManager.tabs.map(\.id) != originalOrder)
            if !committed {
                if tabManager.workspaceGroups != originalGroups { tabManager.workspaceGroups = originalGroups }
                if tabManager.tabs.map(\.id) != originalOrder { tabManager.tabs = originalTabs }
                if tabManager.selectedTabId != originalSelection { tabManager.selectedTabId = originalSelection }
            }
            for group in tabManager.workspaceGroups {
                if let collapsed = folds[group.id], group.isCollapsed != collapsed {
                    tabManager.setWorkspaceGroupCollapsed(groupId: group.id, isCollapsed: collapsed)
                }
            }
            if restoreOrder { tabManager.workspaceOrderDidChange(movedWorkspaceIds: movedIds) }
        }
        let reparent = tabManager.moveWorkspaceGroup(groupId: destination.groupId, intoParent: nil)
        guard reparent == .moved || reparent == .unchanged,
              tabManager.workspaceGroups.first(where: { $0.id == destination.groupId })?.parentGroupId == nil else { return false }
        let roots = tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true)
        let remaining = roots.filter { $0 != plan.draggedWorkspaceId }
        let index: Int
        if let reference = destination.referenceId {
            guard let position = remaining.firstIndex(of: reference) else { return false }
            index = position
        } else { index = remaining.count }
        guard let current = roots.firstIndex(of: plan.draggedWorkspaceId) else { return false }
        if current == index { committed = true; return true }
        let handled = performOrdinary(.init(draggedWorkspaceId: plan.draggedWorkspaceId, indicator: plan.indicator,
            indicatorScope: plan.indicatorScope, action: .reorder(targetIndex: index, usesTopLevelRows: true, explicitGroupId: nil)))
        let final = tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true)
        committed = handled && final.firstIndex(of: plan.draggedWorkspaceId) == index
            && final.filter { $0 != plan.draggedWorkspaceId } == remaining
        return committed
    }

    /// Legacy no-op suppression cannot suppress an actual crossing of the separately placed Statuses area.
    private static func workspaceAreaOrdinaryNoOp(boundary: SidebarStatusGroupDropRules.AreaBoundary,
        snapshot: WorkspaceStatusDropSnapshot, draggedId: UUID, kind: SidebarStatusGroupDropRules.SourceKind) -> SidebarStatusAreaBoundaryDropPlan.Move? {
        let moving = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(orderedWorkspaceIds: snapshot.tabs.map(\.id),
            selectedIds: snapshot.selectedIds, draggedId: draggedId, anchorIds: Set(snapshot.workspaceGroups.compactMap(\.liveAnchorWorkspaceId)))
        switch kind {
        case .workspace:
            guard boundary == .belowAll, !moving.isEmpty,
                  snapshot.tabs.suffix(moving.count).map(\.id) == moving,
                  snapshot.tabs.filter({ moving.contains($0.id) }).allSatisfy({ !$0.isPinned && $0.groupId == nil }) else { return nil }
            return .workspaces(targetIndex: snapshot.tabs.count, usesTopLevelRows: true, explicitGroupId: nil)
        case .workspaceGroupHeader(let id):
            guard let source = snapshot.workspaceGroups.first(where: { $0.id == id }), !source.isPinned,
                  source.parentGroupId == nil, (source.isEmpty ? source.id : source.anchorWorkspaceId) == draggedId else { return nil }
            let roots = snapshot.workspaceGroups.filter { $0.id == id || $0.liveAnchorWorkspaceId.map(moving.contains) == true }
            guard roots.allSatisfy({ !$0.isPinned && $0.parentGroupId == nil }) else { return nil }
            let layout = SidebarStatusAreaLayout(items: snapshot.workspaceRenderItems, tabs: snapshot.tabs,
                groups: snapshot.workspaceGroups, statusProjection: snapshot.statusGroupProjection)
            let owners = Set(roots.compactMap { layout.owner(of: .group($0.id)) })
            guard !owners.isEmpty else { return nil }
            let orderedOwners = snapshot.workspaceRenderItems.compactMap { layout.owner(of: $0.id) }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            if boundary == .belowAll {
                guard Set(orderedOwners.suffix(owners.count)) == owners else { return nil }
            } else {
                guard let area = snapshot.workspaceRenderItems.firstIndex(where: { $0.id == .statusesArea() }) else { return nil }
                let before = snapshot.workspaceRenderItems[..<area].compactMap { layout.owner(of: $0.id) }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                let after = snapshot.workspaceRenderItems.dropFirst(area + 1).compactMap { layout.owner(of: $0.id) }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                guard Set(before.suffix(owners.count)) == owners || Set(after.prefix(owners.count)) == owners else { return nil }
            }
            if source.isEmpty, roots.count == 1,
               let index = snapshot.workspaceGroups.firstIndex(where: { $0.id == id }) { return .group(targetIndex: index) }
            let tree = WorkspaceGroupTree(groups: snapshot.workspaceGroups)
            let movingIds = snapshot.tabs.filter { tab in
                if roots.contains(where: { $0.liveAnchorWorkspaceId == tab.id }) { return true }
                guard let group = tab.groupId else { return false }
                return roots.contains { group == $0.id || tree.isInside(group, $0.id) }
            }.map(\.id)
            guard !movingIds.isEmpty else { return nil }
            if boundary == .belowAll {
                guard snapshot.tabs.suffix(movingIds.count).map(\.id) == movingIds else { return nil }
            }
            guard let firstIndex = snapshot.tabs.firstIndex(where: { movingIds.contains($0.id) }) else { return nil }
            let index = boundary == .belowAll ? snapshot.tabs.count : firstIndex
            return .workspaces(targetIndex: index, usesTopLevelRows: true, explicitGroupId: nil)
        case .unknown: return nil
        }
    }

    /// The existing resolver and color policy, with the hidden-status alias exception scoped to an explicit outer-area drop.
    static func workspaceOrdinaryReorderPlan(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        snapshot: WorkspaceStatusDropSnapshot, draggedTabId: UUID, foreignDraggedIsPinned: Bool?,
        permitsGroupEscape: Bool, permitsStatusBoundaryAlias: Bool = false) -> SidebarWorkspaceReorderDropPlan? {
        guard let basePlan = workspaceLegacyBaseReorderPlan(point: point, targets: targets, snapshot: snapshot,
            draggedTabId: draggedTabId, foreignDraggedIsPinned: foreignDraggedIsPinned) else { return nil }
        switch statusGroupInterimDrop(draggedTabId: draggedTabId, basePlan: basePlan, projection: snapshot.statusGroupProjection, permitsGroupEscape: permitsGroupEscape) { // (#cm-110.1)
        case .refused:
            // A root pin-end indicator may name the raw hidden status member; the explicit outer-area drop is not entry into that group.
            guard permitsStatusBoundaryAlias, snapshot.statusGroupProjection?.contains(workspaceId: draggedTabId) != true,
                  case .reorder(_, _, nil) = basePlan.action,
                  let target = basePlan.indicator?.tabId,
                  snapshot.statusGroupProjection?.contains(workspaceId: target) == true else { return nil }
        case .plan(let statusPlan): return statusPlan // (#cm-110.1)
        case .notStatusRelated: break // (#cm-110.1)
        } // (#cm-110.1)
        guard let sourceSection = snapshot.colorSectionProjection.sectionByWorkspaceId[draggedTabId] else {
            return basePlan
        }
        if SidebarWorkspaceColorSectionDropPolicy.allowsDropOutOfSection(action: basePlan.action) {
            return basePlan
        }
        guard let indicator = basePlan.indicator,
              let targetWorkspaceId = indicator.tabId,
              let targetSection = snapshot.colorSectionProjection.sectionByWorkspaceId[targetWorkspaceId],
              targetSection.id == sourceSection.id else { return nil }
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: draggedTabId,
            indicator: indicator,
            indicatorScope: .raw,
            action: .colorSection(
                targetWorkspaceId: targetWorkspaceId,
                insertBefore: indicator.edge == .top,
                memberWorkspaceIds: sourceSection.memberWorkspaceIds
            )
        )
    }

    /// The actual legacy resolver input, before the existing interim status/color policy.
    static func workspaceLegacyBaseReorderPlan(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        snapshot: WorkspaceStatusDropSnapshot, draggedTabId: UUID, foreignDraggedIsPinned: Bool?) -> SidebarWorkspaceReorderDropPlan? {
        guard let targets = workspaceOnlyDropTargets(point: point, targets: targets, items: snapshot.workspaceRenderItems) else { return nil } // (#cm-110.1)
        let draggedBlockIds = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(
            orderedWorkspaceIds: snapshot.tabs.map(\.id),
            selectedIds: snapshot.selectedIds,
            draggedId: draggedTabId,
            anchorIds: Set(snapshot.workspaceGroups.map(\.anchorWorkspaceId))
        )
        return SidebarWorkspaceReorderDropResolver().plan(
            for: SidebarWorkspaceReorderDropRequest(
                point: point,
                draggedWorkspaceId: draggedTabId,
                foreignDraggedIsPinned: foreignDraggedIsPinned,
                workspaces: snapshot.tabs.map {
                    SidebarWorkspaceReorderWorkspaceSnapshot(
                        id: $0.id,
                        isPinned: $0.isPinned,
                        groupId: $0.groupId
                    )
                },
                groups: snapshot.workspaceGroups.map {
                        SidebarWorkspaceReorderGroupSnapshot(
                            id: $0.id,
                            anchorWorkspaceId: $0.anchorWorkspaceId,
                            isPinned: $0.isPinned,
                            isEmpty: $0.isEmpty,
                            parentGroupId: $0.parentGroupId // (#cm-106)
                        )
                },
                targets: targets.map {
                    SidebarWorkspaceReorderDropTarget(
                        workspaceId: $0.workspaceId,
                        groupId: $0.groupId,
                        isGroupHeader: $0.isGroupHeader,
                        frame: $0.frame
                    )
                },
                draggedBlockWorkspaceIds: Set(draggedBlockIds)
            )
        )
    }

    static func workspaceStatusFeedbackRows(plan: SidebarWorkspaceReorderDropPlan,
        items: [SidebarWorkspaceRenderItem], projection: WorkspaceStatusGroupProjection?) -> [UUID]? {
        switch plan.action {
        case .statusGroupDrop(let value, _):
            return workspaceStatusDropIndicatorRows(statusId: value.statusId, items: items,
                memberWorkspaceIds: projection.map { workspaceStatusDisplayDropMembers(statusId: value.statusId,
                    projection: $0, items: items) } ?? [])
        case .statusAreaBoundaryDrop: return items.compactMap(\.headerDropIdentity)
        case .reorder(_, _, nil) where plan.indicatorScope == .raw
            && plan.indicator == SidebarDropIndicator(tabId: nil, edge: .bottom)
            && projection != nil && items.contains(where: { $0.id == .statusesArea() }):
            return items.compactMap(\.headerDropIdentity)
        default: return nil
        }
    }

    static func workspaceAreaBoundaryPaintRows(draggedId: UUID?, scope: SidebarWorkspaceReorderDropIndicatorScope,
        indicator: SidebarDropIndicator?, level: Int?, items: [SidebarWorkspaceRenderItem],
        projection: WorkspaceStatusGroupProjection?) -> [UUID]? {
        guard let draggedId, draggedId != SidebarStatusHeaderIdentity.statusesAreaUUID, projection != nil,
              scope == .raw, let indicator,
              (level == 0 || (level == nil && indicator.tabId == nil && indicator.edge == .bottom)),
              (indicator.tabId == SidebarStatusHeaderIdentity.statusesAreaUUID && indicator.edge == .top)
                || (indicator.tabId == nil && indicator.edge == .bottom) else { return nil }
        return items.compactMap(\.headerDropIdentity)
    }
    /// Typed status targets are built from actual render identities, never from a header's anchor UUID.
    static func workspaceStatusDropTargets(items: [SidebarWorkspaceRenderItem],
        measured: [SidebarWorkspaceReorderDropOverlay.Target], useContentFrames: Bool = true) -> [SidebarWorkspaceReorderDropTarget] {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return measured.compactMap { target in
            let rowId = target.renderItemId ?? .workspace(target.workspaceId)
            guard let item = byId[rowId] else { return nil }
            let kind: SidebarWorkspaceReorderDropTargetKind
            switch item {
            case .statusesHeader: kind = .statusesArea
            case .statusGroupHeader(let id): kind = .statusGroupHeader(statusId: id)
            case .colorSectionHeader: kind = .colorSectionHeader
            default: kind = .workspace
            }
            return .init(workspaceId: target.workspaceId, groupId: target.groupId,
                isGroupHeader: target.isGroupHeader, frame: useContentFrames ? (target.statusContentFrame ?? target.frame) : target.frame, kind: kind)
        }
    }

    /// The status-group header and visible members form one immutable painter row space.
    static func workspaceStatusDropIndicatorRows(statusId: String, items: [SidebarWorkspaceRenderItem],
        memberWorkspaceIds: [UUID]) -> [UUID]? {
        guard items.contains(where: { $0.id == .statusGroup(statusId) }) else { return nil }
        let members = Set(memberWorkspaceIds)
        return items.compactMap { item in
            switch item {
            case .statusGroupHeader(let id) where id == statusId:
                return SidebarStatusHeaderIdentity.uuid(forStatusId: id)
            case .workspace(let id) where members.contains(id): return id
            case .groupHeader(_, let anchor) where members.contains(anchor): return anchor
            default: return nil
            }
        }
    }

    static func workspaceStatusDropScopeId(scope: SidebarWorkspaceReorderDropIndicatorScope,
        projection: WorkspaceStatusGroupProjection?) -> String? {
        guard case .group(let id) = scope else { return nil }
        return projection?.groups.first { SidebarStatusHeaderIdentity.uuid(forStatusId: $0.statusId) == id }?.statusId
    }

    /// One parent/container overlay owns workspace-status paint, including the suppressed source and final append.
    static func workspaceStatusDropGapFrame(statusId: String, draggedId: UUID?, indicator: SidebarDropIndicator?,
        items: [SidebarWorkspaceRenderItem], memberWorkspaceIds: [UUID], frames: [UUID: CGRect], width: CGFloat) -> CGRect? {
        guard width > 0,
              let rows = workspaceStatusDropIndicatorRows(statusId: statusId, items: items, memberWorkspaceIds: memberWorkspaceIds),
              let canonical = SidebarStatusHeaderDropAdapter.workspaceIndicator(indicator: indicator, draggedId: draggedId, rowIds: rows),
              let id = canonical.tabId, let row = frames[id], row.width > 0, row.height > 0 else { return nil }
        let inset = SidebarNestedDropLine.inset(level: 2, availableWidth: width)
        return CGRect(x: 8 + inset, y: (canonical.edge == .top ? row.minY : row.maxY) - 1,
            width: max(0, width - 16 - inset), height: 2)
    }

#if DEBUG
    static func workspaceStatusDebugSourceRow(_ selector: String, items: [SidebarWorkspaceRenderItem]) -> SidebarWorkspaceRenderItemID? {
        let row: SidebarWorkspaceRenderItemID
        if selector.hasPrefix("workspace:"), let id = UUID(uuidString: String(selector.dropFirst("workspace:".count))) {
            row = .workspace(id)
        } else if selector.hasPrefix("group:"), let id = UUID(uuidString: String(selector.dropFirst("group:".count))) {
            row = .group(id)
        } else { return nil }
        return items.first(where: { $0.id == row })?.id
    }
#endif

    func performWorkspaceStatusAwarePlan(_ plan: SidebarWorkspaceReorderDropPlan,
        performOrdinary: @escaping (SidebarWorkspaceReorderDropPlan) -> Bool) -> Bool {
        Self.performWorkspaceStatusAwarePlan(plan, windowId: windowId, dragState: dragState,
            sourceRecorder: .shared, selectedIds: selectedTabIds, sidebarState: sidebarState, tabManager: tabManager,
            statusActions: { .app() },
            statusReorder: { id,target,before,members in tabManager.reorderWorkspaceWithinColorSection(tabId: id,
                targetWorkspaceId: target,insertBefore: before,memberWorkspaceIds: members) },
            currentProjection: { Self.currentStatusGroupProjection(tabs: tabManager.tabs, groups: tabManager.workspaceGroups, storedOrder: sidebarState.statusGroups?.order) },
            currentRenderItems: { Self.statusRenderItemsForSnapshot(tabManager: tabManager, state: sidebarState).items },
            performOrdinary: performOrdinary)
    }

    /// The same guarded app commit path, composed with current per-window values and real mutation closures.
    static func performWorkspaceStatusAwarePlan(_ plan: SidebarWorkspaceReorderDropPlan,
        windowId: UUID, dragState: SidebarDragState, sourceRecorder: SidebarStatusGroupDragSource,
        selectedIds: Set<UUID>, sidebarState: SidebarState, tabManager: TabManager,
        statusActions: () -> WorkspaceStatusActions,
        statusReorder: @escaping (UUID, UUID, Bool, [UUID]) -> Bool,
        currentProjection: @escaping () -> WorkspaceStatusGroupProjection?,
        currentRenderItems: @escaping () -> [SidebarWorkspaceRenderItem],
        performOrdinary: @escaping (SidebarWorkspaceReorderDropPlan) -> Bool) -> Bool {
        let token: UUID
        switch plan.action {
        case .statusGroupDrop(_, let id), .statusAreaBoundaryDrop(_, let id): token = id
        default: return false
        }
        guard let source = sourceRecorder.source(windowId: windowId,
            workspaceId: plan.draggedWorkspaceId, sessionId: token, dragState: dragState) else { return false }
        if workspaceProjectedStatusHeaderIsRefused(draggedId: plan.draggedWorkspaceId, sourceKind: source.kind,
            groups: tabManager.workspaceGroups, projection: currentProjection()) { return false }
        switch plan.action {
        case .statusGroupDrop(let value, _):
            guard let dragged = tabManager.tabs.first(where: { $0.id == plan.draggedWorkspaceId }) else { return false }
            let actions = statusActions()
            if let handled = performWorkspaceProjectedStatusDrop(value, dragged: dragged, sourceKind: source.kind,
                tabManager: tabManager, actions: actions, projection: currentProjection()) { return handled }
            return StatusGroupDropPerformer(statusActions: actions, currentProjection: currentProjection,
                reorder: statusReorder).perform(value, dragged: dragged, sourceKind: source.kind)
        case .statusAreaBoundaryDrop(let value, _):
            let moving = SidebarWorkspaceDragBlockResolver().movingWorkspaceIds(orderedWorkspaceIds: tabManager.tabs.map(\.id),
                selectedIds: selectedIds, draggedId: plan.draggedWorkspaceId,
                anchorIds: Set(tabManager.workspaceGroups.compactMap(\.liveAnchorWorkspaceId)))
            var movingGroups = tabManager.workspaceGroups.filter { group in group.liveAnchorWorkspaceId.map(moving.contains) == true }.map(\.id)
            if case .workspaceGroupHeader(let id) = source.kind, !movingGroups.contains(id) { movingGroups.append(id) }
            var childRoot: WorkspaceStatusChildRootDestination?
            if case .workspaceGroupHeader(let id) = source.kind,
               let group = tabManager.workspaceGroups.first(where: { $0.id == id }),
               group.parentGroupId != nil, !group.isEmpty,
               case .workspaces(_, true, nil) = value.move {
                guard let destination = workspaceStatusChildRootDestination(boundary: value.boundary,
                    draggedId: plan.draggedWorkspaceId, kind: source.kind, tabs: tabManager.tabs,
                    groups: tabManager.workspaceGroups, items: currentRenderItems(), projection: currentProjection(),
                    selectedIds: selectedIds, rootWorkspaceIds: tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: nil, usesTopLevelRows: true)) else { return false }
                childRoot = destination
            }
            return StatusAreaDropPerformer(state: sidebarState, movingGroupIds: movingGroups, movingWorkspaceIds: moving,
                currentTabs: { tabManager.tabs }, currentGroups: { tabManager.workspaceGroups },
                currentProjection: currentProjection,
                currentRenderItems: currentRenderItems,
                performOrdinary: { move in
                    if let childRoot {
                        return performWorkspaceStatusChildRootMove(childRoot, plan: plan, tabManager: tabManager, performOrdinary: performOrdinary)
                    }
                    let action: SidebarWorkspaceReorderDropAction
                    switch move {
                    case .workspaces(let index, let top, let group): action = .reorder(targetIndex: index, usesTopLevelRows: top, explicitGroupId: group)
                    case .group(let index): action = .reorderGroup(targetIndex: index)
                    }
                    return performOrdinary(.init(draggedWorkspaceId: plan.draggedWorkspaceId,
                        indicator: plan.indicator, indicatorScope: plan.indicatorScope, action: action))
                }).perform(value, workspaceId: plan.draggedWorkspaceId, sourceKind: source.kind)
        default: return false
        }
    }
}
