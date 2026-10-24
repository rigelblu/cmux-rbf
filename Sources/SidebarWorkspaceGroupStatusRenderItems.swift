import CmuxWorkspaces
import Foundation

/// Moves visible group subtrees as blocks while leaving model order, numbering and inner folds untouched.
@MainActor
struct SidebarWorkspaceGroupStatusRenderItems {
    func resolve(
        colorSections: SidebarWorkspaceColorSectionProjection,
        base: [SidebarWorkspaceRenderItem],
        projection: WorkspaceStatusGroupProjection?,
        folds: WorkspaceStatusGroupsState,
        tabs: [Workspace],
        groups: [WorkspaceGroup]
    ) -> SidebarStatusRenderItemsResolution {
        let numbering = SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(from: base)
        guard let projection else {
            return .init(items: colorSections.applying(to: base), numberedWorkspaceIndexById: numbering)
        }
        var looseStatuses: [UUID: String] = [:]
        for status in projection.groups {
            for id in status.memberWorkspaceIds { looseStatuses[id] = status.statusId }
        }
        let groupStatuses = projection.workspaceGroups?.statusIdByGroupId ?? [:]
        let containedStatuses = projection.workspaceGroups?.statusIdByWorkspaceId ?? [:]
        var normal: [SidebarWorkspaceRenderItem] = []
        var rowsByStatus: [String: [SidebarWorkspaceRenderItem]] = [:]
        for item in base {
            let status: String?
            switch item {
            case .groupHeader(let id, _): status = groupStatuses[id]
            case .workspace(let id): status = containedStatuses[id] ?? looseStatuses[id]
            default: status = nil
            }
            if let status, projection.statusGroupStatusIds.contains(status) {
                rowsByStatus[status, default: []].append(item)
            } else { normal.append(item) }
        }
        var area: [SidebarWorkspaceRenderItem] = [.statusesHeader]
        for status in projection.groups where !folds.areaCollapsed {
            area.append(.statusGroupHeader(statusId: status.statusId))
            guard !folds.collapsedStatusIds.contains(status.statusId) else { continue }
            var rows = rowsByStatus[status.statusId] ?? []
            // Keep the loose projection's existing ability to supply a missing base row. Group members
            // come only from the visible base run: rebuilding them would unfold a folded group.
            let present = Set(rows.map(\.id))
            for id in status.memberWorkspaceIds where !present.contains(.workspace(id)) && containedStatuses[id] == nil {
                rows.append(.workspace(workspaceId: id))
            }
            area.append(contentsOf: rows)
        }
        let normalItems = colorSections.applying(to: normal)
        let layout = SidebarStatusAreaLayout(items: normalItems, tabs: tabs, groups: groups, statusProjection: projection)
        let order = folds.sectionOrder ?? layout.legacySectionOrder(state: folds)
        let pins = Array(normalItems.prefix(layout.pinnedBoundary))
        let ordinary = Array(normalItems.dropFirst(layout.pinnedBoundary))
        let pinnedSection: [SidebarWorkspaceRenderItem]
        if !pins.isEmpty {
            pinnedSection = folds.pinnedCollapsed == true ? [.pinnedHeader] : [.pinnedHeader] + pins
        } else {
            pinnedSection = []
        }
        let workspaces: [SidebarWorkspaceRenderItem] = [.workspacesHeader]
            + (folds.workspacesCollapsed == true ? [] : ordinary)
        let sections = order == .statusesFirst ? area + workspaces : workspaces + area
        return .init(items: pinnedSection + sections, numberedWorkspaceIndexById: numbering,
            workspacesSectionMemberIds: layout.workspacesSectionMemberIds,
            pinnedSectionMemberIds: layout.pinnedSectionMemberIds)
    }
}
