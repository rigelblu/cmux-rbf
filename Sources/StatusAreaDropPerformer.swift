import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// Reconciles an explicit outer-area drop through the existing per-window place; it never writes status/color.
@MainActor
struct StatusAreaDropPerformer {
    let state: SidebarState
    let movingGroupIds: [UUID]
    var movingWorkspaceIds: [UUID] = []
    let currentTabs: () -> [Workspace]
    let currentGroups: () -> [WorkspaceGroup]
    let currentProjection: () -> WorkspaceStatusGroupProjection?
    let currentRenderItems: () -> [SidebarWorkspaceRenderItem]
    let performOrdinary: (SidebarStatusAreaBoundaryDropPlan.Move) -> Bool

    func perform(_ plan: SidebarStatusAreaBoundaryDropPlan, workspaceId: UUID,
                 sourceKind: SidebarStatusGroupDropRules.SourceKind) -> Bool {
        let tabs = currentTabs(), groups = currentGroups(), items = currentRenderItems()
        guard let projection = currentProjection(), var next = state.statusGroups,
              let areaIndex = items.firstIndex(where: { $0.id == .statusesArea() }) else { return false }
        let layout = SidebarStatusAreaLayout(items: items, tabs: tabs, groups: groups, statusProjection: projection)
        let moving: Set<String>
        let groupIds: [UUID]
        switch sourceKind {
        case .workspace:
            guard plan.boundary == .belowAll, let source = tabs.first(where: { $0.id == workspaceId }),
                  !source.isPinned, !projection.contains(workspaceId: workspaceId) else { return false }
            if source.groupId == nil,
               layout.owner(of: .workspace(workspaceId)) != "workspace:\(workspaceId.uuidString)" { return false }
            moving = Set((movingWorkspaceIds.isEmpty ? [workspaceId] : movingWorkspaceIds).map { "workspace:\($0.uuidString)" }); groupIds = []
        case .workspaceGroupHeader(let id):
            guard let group = groups.first(where: { $0.id == id }),
                  (group.isEmpty ? group.id : group.anchorWorkspaceId) == workspaceId else { return false }
            groupIds = movingGroupIds.isEmpty ? [id] : movingGroupIds
            guard groupIds.contains(id), groupIds.allSatisfy({ wanted in groups.contains { $0.id == wanted } }) else { return false }
            moving = Set(groupIds.map { "group:\($0.uuidString)" })
            guard !moving.isEmpty else { return false }
        case .unknown: return false
        }
        let validBefore = layout.topLevelRowIds
        let above = items[..<areaIndex].reversed().compactMap { layout.owner(of: $0.id) }
            .first { validBefore.contains($0) && !moving.contains($0) }
        let below = items.dropFirst(areaIndex + 1).compactMap { layout.owner(of: $0.id) }
            .first { validBefore.contains($0) && !moving.contains($0) }
        let requiresChildRoot: Bool
        if case .workspaceGroupHeader(let id) = sourceKind,
           let child = groups.first(where: { $0.id == id }), !child.isEmpty, child.parentGroupId != nil,
           case .workspaces(_, true, nil) = plan.move { requiresChildRoot = true }
        else { requiresChildRoot = false }
        let didMove = performOrdinary(plan.move)
        if requiresChildRoot, case .workspaceGroupHeader(let id) = sourceKind {
            guard didMove, let child = currentGroups().first(where: { $0.id == id }), child.parentGroupId == nil else { return false }
        }
        let freshTabs = currentTabs(), freshGroups = currentGroups(), freshItems = currentRenderItems()
        let freshProjection = currentProjection()
        let freshLayout = SidebarStatusAreaLayout(items: freshItems, tabs: freshTabs, groups: freshGroups,
            statusProjection: freshProjection)
        if sourceKind == .workspace {
            guard let source = freshTabs.first(where: { $0.id == workspaceId }), source.groupId == nil else { return didMove }
            // An existing status/color projects the detached member into its generated section; keep the area's place.
            if freshProjection?.contains(workspaceId: workspaceId) == true
                || freshLayout.owner(of: .workspace(workspaceId)) != "workspace:\(workspaceId.uuidString)" { return true }
        }
        let freshMoving = groupIds.isEmpty ? moving : Set(groupIds.compactMap { freshLayout.owner(of: .group($0)) })
        let validAfter = freshLayout.topLevelRowIds
        var ordered: [String] = []
        for item in freshItems {
            if let owner = freshLayout.owner(of: item.id), freshMoving.contains(owner),
               validAfter.contains(owner), !ordered.contains(owner) { ordered.append(owner) }
        }
        guard let first = ordered.first, let last = ordered.last else { return didMove }
        switch plan.boundary {
        case .belowAll:
            // Rebind BOTH anchors: a saved last=true record can still have aboveRow equal to the moved source.
            next.aboveRow = above.flatMap { validAfter.contains($0) ? $0 : nil } ?? "top"
            next.belowRow = below.flatMap { validAfter.contains($0) ? $0 : nil } ?? first
            next.last = false
        case .aboveArea:
            let lastIndex = freshItems.lastIndex { freshLayout.owner(of: $0.id) == last }
            let following = lastIndex.flatMap { index in
                freshItems.dropFirst(index + 1).compactMap { freshLayout.owner(of: $0.id) }
                    .first { validAfter.contains($0) && !freshMoving.contains($0) }
            }
            next.aboveRow = last; next.belowRow = following; next.last = following == nil
        }
        if next != state.statusGroups { state.setStatusGroups(next) }
        return true
    }
}
