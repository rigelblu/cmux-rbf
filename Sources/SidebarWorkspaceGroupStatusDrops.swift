import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation

extension VerticalTabsSidebar {
    /// Legacy begin callbacks have no row metadata; the model still identifies a projected header by its anchor.
    static func workspaceProjectedStatusHeaderIsRefused(draggedId: UUID,
        sourceKind: SidebarStatusGroupDropRules.SourceKind?, groups: [WorkspaceGroup],
        projection: WorkspaceStatusGroupProjection?) -> Bool {
        let statuses = projection?.workspaceGroups?.statusIdByGroupId ?? [:]
        if case .workspaceGroupHeader(let id)? = sourceKind, statuses[id] != nil { return true }
        return groups.contains { group in
            statuses[group.id] != nil && (group.liveAnchorWorkspaceId == draggedId
                || (group.isEmpty && group.id == draggedId))
        }
    }

    /// Display ownership includes whole group runs; loose mutation membership stays separate.
    static func workspaceStatusDisplayDropMembers(statusId: String, projection: WorkspaceStatusGroupProjection,
        items: [SidebarWorkspaceRenderItem]) -> [UUID] {
        var ids = projection.displayMemberWorkspaceIds(for: statusId)
        for item in items {
            if case .groupHeader(let id, let anchor) = item,
               projection.workspaceGroups?.statusIdByGroupId[id] == statusId { ids.insert(anchor) }
        }
        return ids.sorted { $0.uuidString < $1.uuidString }
    }

    /// Delegate adoption and the horizontal split to cm-106's real planner. Only the enclosing
    /// status's last-row exception and the gap outside a root run override that planner.
    static func workspaceProjectedGroupJoin(point: CGPoint, targets: [SidebarWorkspaceReorderDropOverlay.Target],
        snapshot: WorkspaceStatusDropSnapshot, draggedId: UUID,
        sourceKind: SidebarStatusGroupDropRules.SourceKind?, token: UUID?,
        controlsEnabled: Bool, hasUserStatusList: Bool) -> SidebarStatusHeaderPlanResult? {
        guard let projection = snapshot.statusGroupProjection, let grouped = projection.workspaceGroups else { return nil }
        let typed = workspaceStatusDropTargets(items: snapshot.workspaceRenderItems, measured: targets)
            .filter { $0.frame.width > 0 && $0.frame.height > 0 }.sorted { $0.frame.minY < $1.frame.minY }
        let tree = WorkspaceGroupTree(groups: snapshot.workspaceGroups)
        func group(_ row: SidebarWorkspaceReorderDropTarget) -> UUID? {
            row.groupId.flatMap { grouped.statusIdByGroupId[$0] == nil ? nil : $0 }
        }
        func status(_ row: SidebarWorkspaceReorderDropTarget) -> String? {
            if let id = group(row) { return grouped.statusIdByGroupId[id] }
            guard row.kind == .workspace else { return nil }
            return projection.groups.first { $0.memberWorkspaceIds.contains(row.workspaceId) }?.statusId
        }
        func modelGroup(_ item: SidebarWorkspaceRenderItem) -> UUID? {
            switch item {
            case .groupHeader(let id, _): return id
            case .workspace(let id): return snapshot.tabs.first { $0.id == id }?.groupId
            default: return nil
            }
        }
        func modelStatus(_ item: SidebarWorkspaceRenderItem) -> String? {
            if let id = modelGroup(item) { return grouped.statusIdByGroupId[id] }
            guard case .workspace(let id) = item else { return nil }
            return projection.groups.first { $0.memberWorkspaceIds.contains(id) }?.statusId
        }
        let index: Int
        if let hit = typed.firstIndex(where: { point.y >= $0.frame.minY && point.y <= $0.frame.maxY }) {
            index = hit
            guard let id = group(typed[index]) else { return nil }
            if point.y >= typed[index].frame.midY {
                let root = tree.outermost(of: id)
                // A scrolled-out follower still counts; visible measurements only locate the pointer.
                let model = snapshot.workspaceRenderItems
                let modelIndex = model.firstIndex { $0.headerDropIdentity == typed[index].workspaceId }
                let next = modelIndex.flatMap { $0 + 1 < model.count ? model[$0 + 1] : nil }
                let nextRoot = next.flatMap(modelGroup).map { tree.outermost(of: $0) }
                if nextRoot != root {
                    if next.flatMap(modelStatus) != grouped.statusIdByGroupId[id] { return nil }
                }
            }
        } else if let previous = typed.indices.dropLast().first(where: {
            point.y > typed[$0].frame.maxY && point.y < typed[$0 + 1].frame.minY
        }), let before = group(typed[previous]) {
            let sameRoot = group(typed[previous + 1]).map { tree.outermost(of: before) == tree.outermost(of: $0) } == true
            if !sameRoot {
                guard let statusId = grouped.statusIdByGroupId[before], status(typed[previous + 1]) == statusId else { return nil }
                if point.y >= (typed[previous].frame.maxY + typed[previous + 1].frame.minY) / 2 {
                    guard sourceKind == .workspace, let token, controlsEnabled, hasUserStatusList,
                          snapshot.tabs.contains(where: { $0.id == draggedId }) else { return .refused }
                    // The lower gap is a status landing after this group, rather than a loose-slot permutation before the next row.
                    let indicator = SidebarDropIndicator(tabId: typed[previous].workspaceId, edge: .bottom)
                    let landing = SidebarStatusGroupWorkspaceDropPlan(statusId: statusId,
                        placement: .member(typed[previous].workspaceId, insertBefore: false),
                        setsStatus: projection.group(for: statusId)?.memberWorkspaceIds.contains(draggedId) != true,
                        indicator: indicator)
                    return .plan(.init(draggedWorkspaceId: draggedId, indicator: indicator,
                        indicatorScope: .group(SidebarStatusHeaderIdentity.uuid(forStatusId: statusId)),
                        action: .statusGroupDrop(plan: landing, sessionId: token)))
                }
            }
            index = previous
        } else { return nil }
        guard group(typed[index]) != nil else { return nil }
        guard sourceKind == .workspace, token != nil, controlsEnabled, hasUserStatusList,
              snapshot.tabs.contains(where: { $0.id == draggedId }) else { return .refused }
        guard let base = workspaceLegacyBaseReorderPlan(point: point, targets: targets, snapshot: snapshot,
            draggedTabId: draggedId, foreignDraggedIsPinned: nil),
              case .reorder(_, false, let destination?) = base.action,
              grouped.statusIdByGroupId[destination] != nil else { return nil }
        return .plan(base)
    }

    /// A group-aware status landing uses top-level references, so a whole group between two loose
    /// members is never treated as a hole in a loose-only permutation. The existing model action
    /// also promotes a member out of its former group without changing its siblings.
    static func performWorkspaceProjectedStatusDrop(_ plan: SidebarStatusGroupWorkspaceDropPlan,
        dragged: Workspace, sourceKind: SidebarStatusGroupDropRules.SourceKind, tabManager: TabManager,
        actions: WorkspaceStatusActions, projection: WorkspaceStatusGroupProjection?) -> Bool? {
        guard let projection else { return nil }
        let grouped = projection.workspaceGroups
        let projectedSource = grouped?.statusIdByWorkspaceId[dragged.id] != nil
        let targetInvolvesGroup: Bool
        switch plan.placement {
        case .first:
            let roots = tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: dragged.id, usesTopLevelRows: true)
            let first = roots.first { id in
                id != dragged.id && (projection.group(for: plan.statusId)?.memberWorkspaceIds.contains(id) == true
                    || tabManager.workspaceGroups.contains { group in
                        grouped?.statusIdByGroupId[group.id] == plan.statusId
                            && (group.liveAnchorWorkspaceId ?? group.id) == id
                    })
            }
            targetInvolvesGroup = first.map { id in
                tabManager.workspaceGroups.contains { ($0.liveAnchorWorkspaceId ?? $0.id) == id }
            } ?? false
        case .member(let id, _):
            targetInvolvesGroup = grouped?.statusIdByWorkspaceId[id] != nil
                || grouped?.statusIdByGroupId[id] != nil
        }
        guard projectedSource || targetInvolvesGroup else { return nil }
        guard sourceKind == .workspace, actions.controlsEnabled, actions.list.source != .cmux,
              !actions.list.entries.isEmpty,
              actions.list.entry(id: plan.statusId) != nil,
              let status = projection.group(for: plan.statusId) else { return false }
        let groups = tabManager.workspaceGroups
        guard !groups.contains(where: { $0.liveAnchorWorkspaceId == dragged.id }) else { return false }
        let alreadyMember = status.memberWorkspaceIds.contains(dragged.id)
        guard plan.setsStatus || alreadyMember else { return false }
        let tree = WorkspaceGroupTree(groups: groups)
        let byId = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        func rootReference(forGroup id: UUID) -> UUID? {
            guard let root = byId[tree.outermost(of: id)] else { return nil }
            return root.liveAnchorWorkspaceId ?? root.id
        }
        func memberRootReference(_ id: UUID) -> UUID? {
            if status.memberWorkspaceIds.contains(id) { return id }
            let groupId = tabManager.tabs.first(where: { $0.id == id })?.groupId
                ?? groups.first(where: { $0.liveAnchorWorkspaceId == id || ($0.isEmpty && $0.id == id) })?.id
            guard let groupId, grouped?.statusIdByGroupId[groupId] == plan.statusId else { return nil }
            return rootReference(forGroup: groupId)
        }
        let roots = tabManager.sidebarReorderWorkspaceIds(forDraggedWorkspaceId: dragged.id, usesTopLevelRows: true)
        let remaining = roots.filter { $0 != dragged.id }
        let reference: UUID?, insertBefore: Bool
        switch plan.placement {
        case .first:
            let groupRoots = Set(groups.compactMap { group -> UUID? in
                guard tree.parent(of: group.id) == nil, grouped?.statusIdByGroupId[group.id] == plan.statusId else { return nil }
                return rootReference(forGroup: group.id)
            })
            reference = remaining.first { status.memberWorkspaceIds.contains($0) || groupRoots.contains($0) }
            insertBefore = true
        case .member(let target, let before):
            guard let targetReference = memberRootReference(target) else { return false }
            reference = targetReference; insertBefore = before
        }
        // Preserve cm-110.1's status-only action for pinned and ordinary grouped sources.
        if dragged.isPinned || (dragged.groupId != nil && !projectedSource) {
            return alreadyMember || actions.apply(.status(id: plan.statusId), to: [dragged], requireControls: true) == .set
        }
        guard alreadyMember || actions.apply(.status(id: plan.statusId), to: [dragged], requireControls: true) == .set else { return false }
        guard let current = roots.firstIndex(of: dragged.id) else { return false }
        if reference != dragged.id {
            let destination: Int
            if let reference {
                guard let index = remaining.firstIndex(of: reference) else { return false }
                destination = index + (insertBefore ? 0 : 1)
            } else { destination = current }
            if current != destination || dragged.groupId != nil {
                guard tabManager.reorderSidebarWorkspace(tabId: dragged.id, toIndex: destination,
                    isDragOperation: true, usesTopLevelRows: true, explicitGroupId: nil) else { return false }
            }
        }
        return true
    }

    static func workspaceProjectedStatusDropLineLevel(for plan: SidebarWorkspaceReorderDropPlan,
        depthById: [UUID: Int], projection: WorkspaceStatusGroupProjection?) -> Int? {
        let depths = depthById.merging(projection?.workspaceGroups?.depthById ?? [:]) { _, projected in projected }
        return SidebarNestedDropLine.level(for: plan, depthById: depths)
    }
}
