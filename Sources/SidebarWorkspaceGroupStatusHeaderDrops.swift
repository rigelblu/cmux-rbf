import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// Adapts header provenance and complete model runs to the shared, pure status-placement plan.
@MainActor
struct SidebarWorkspaceGroupStatusHeaderDrops {
    let snapshot: VerticalTabsSidebar.WorkspaceStatusDropSnapshot

    func route(decision: SidebarStatusGroupDropRules.Decision, source: SidebarStatusGroupDropRules.Source,
               token: UUID?) -> SidebarStatusHeaderPlanResult? {
        guard case .workspaceGroupHeader(let groupId) = source.kind else { return nil }
        switch decision {
        case .statusGroup(let requested):
            guard let token, let group = snapshot.workspaceGroups.first(where: { $0.id == groupId }),
                  !group.isEmpty, group.liveAnchorWorkspaceId == source.workspaceId,
                  snapshot.tabs.contains(where: { $0.id == source.workspaceId && $0.groupId == groupId }),
                  let result = placement(groupId: groupId, statusId: requested.statusId, target: requested.placement)
            else { return .refused }
            let value = SidebarStatusGroupWorkspaceDropPlan(statusId: requested.statusId, placement: requested.placement,
                setsStatus: group.statusId != requested.statusId, indicator: result.indicator, headerPlacement: result)
            return .plan(.init(draggedWorkspaceId: source.workspaceId, indicator: result.indicator,
                indicatorScope: .group(SidebarStatusHeaderIdentity.uuid(forStatusId: requested.statusId)),
                action: .statusGroupDrop(plan: value, sessionId: token)))
        case .refused: return .refused
        case .unrelated, .areaBoundary: return nil
        }
    }

    /// Also used at commit: rebuild from authoritative membership, not a cached list of stored statuses.
    func placement(groupId: UUID, statusId: String, target: SidebarStatusGroupWorkspaceDropPlan.Placement)
        -> SidebarStatusGroupHeaderPlacementPlan? {
        guard let projection = snapshot.statusGroupProjection,
              let status = projection.group(for: statusId),
              let sourceGroup = snapshot.workspaceGroups.first(where: { $0.id == groupId }),
              !sourceGroup.isEmpty else { return nil }
        let tree = WorkspaceGroupTree(groups: snapshot.workspaceGroups)
        let roots = snapshot.workspaceGroups.filter { tree.parent(of: $0.id) == nil }
        let rootByReference = Dictionary(roots.map { ($0.liveAnchorWorkspaceId ?? $0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
        guard !snapshot.rootWorkspaceIds.isEmpty else { return nil }
        let rootIds = snapshot.rootWorkspaceIds
        var positions: [UUID: Int] = [:]
        let stride = snapshot.tabs.count + 1
        for (index, id) in rootIds.enumerated() {
            let base = index * stride
            positions[id] = base
            guard let root = rootByReference[id] else { continue }
            let descendants = Set([root.id] + tree.descendants(of: root.id))
            let members = snapshot.tabs.filter { $0.groupId.map(descendants.contains) == true }
            for (offset, member) in members.enumerated() { positions[member.id] = base + offset }
        }
        func run(_ group: WorkspaceGroup) -> SidebarStatusGroupHeaderPlacementPlan.Row? {
            let reference = group.liveAnchorWorkspaceId ?? group.id
            guard let order = positions[reference] else { return nil }
            let descendants = Set([group.id] + tree.descendants(of: group.id))
            let members = snapshot.tabs.filter { $0.groupId.map(descendants.contains) == true }.map(\.id)
            let visible = snapshot.workspaceRenderItems.compactMap { item -> UUID? in
                switch item {
                case .groupHeader(let id, let anchor) where descendants.contains(id): return anchor
                case .workspace(let id) where members.contains(id): return id
                default: return nil
                }
            }
            return .init(referenceId: reference, workspaceIds: members, isGroup: true, order: order,
                         lastVisibleRowId: visible.last ?? reference)
        }
        guard let source = run(sourceGroup), source.workspaceIds.first == sourceGroup.liveAnchorWorkspaceId else { return nil }
        var rows: [SidebarStatusGroupHeaderPlacementPlan.Row] = []
        for id in status.memberWorkspaceIds {
            guard let order = positions[id], let tab = snapshot.tabs.first(where: { $0.id == id }),
                  tab.groupId == nil, !tab.isPinned else { return nil }
            rows.append(.init(referenceId: id, workspaceIds: [id], isGroup: false, order: order))
        }
        for group in roots where projection.workspaceGroups?.statusIdByGroupId[group.id] == statusId {
            guard let row = run(group) else { return nil }
            rows.append(row)
        }
        return .init(rows: rows, source: source, placement: target,
            statusHeaderId: SidebarStatusHeaderIdentity.uuid(forStatusId: statusId),
            isFolded: snapshot.statusGroupFolds.collapsedStatusIds.contains(statusId),
            movesSource: tree.parent(of: groupId) == nil && !sourceGroup.isPinned)
    }
}

#if DEBUG
extension VerticalTabsSidebar {
    /// DEBUG pointer calibration is shared with the real drop route, retaining raw targets for ordinary drags.
    static func workspaceStatusDebugPointFrames(sourceId: UUID, sourceRowId: SidebarWorkspaceRenderItemID?,
        targetId: UUID, targetRowId: SidebarWorkspaceRenderItemID?, items: [SidebarWorkspaceRenderItem],
        projection: WorkspaceStatusGroupProjection?, targets: [SidebarWorkspaceReorderDropOverlay.Target]) -> [UUID: CGRect]? {
        guard sourceRowId == .workspace(sourceId) || sourceRowId?.groupId != nil, let projection else { return nil }
        let typed = workspaceStatusDropTargets(items: items, measured: targets)
        let usesStatusFrames: Bool
        switch typed.first(where: { $0.workspaceId == targetId })?.kind {
        case .some(.statusesArea), .some(.statusGroupHeader(_)): usesStatusFrames = true
        case .some(.workspace):
            usesStatusFrames = projection.allDisplayMemberWorkspaceIds.contains(targetId)
                || targetRowId?.groupId.flatMap { projection.workspaceGroups?.statusIdByGroupId[$0] } != nil
        default: usesStatusFrames = false
        }
        return usesStatusFrames ? Dictionary(uniqueKeysWithValues: typed.map { ($0.workspaceId, $0.frame) }) : nil
    }
}
#endif
