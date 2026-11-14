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
        var numbering = SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(from: base)
        guard let projection else {
            return .init(items: colorSections.applying(to: base), numberedWorkspaceIndexById: numbering)
        }
        let groupsById = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let separatePins = tabs.filter { WorkspaceGroupWorkspaceItem($0).sidebarPin(in: groupsById, sectionsShown: true).isOutsideGroup }
        let separatePinIds = Set(separatePins.map(\.id))
        if !separatePinIds.isEmpty {
            // A model fold can omit a pin from base. Count every visible row in its original tab slot.
            let visibleIds = Set(numbering.keys).union(separatePinIds)
            numbering = SidebarWorkspaceRenderItem.numberedWorkspaceIndexById(from: tabs.compactMap { tab in
                visibleIds.contains(tab.id) ? .workspace(workspaceId: tab.id) : nil
            })
        }
        let pinnedRoots = Set(groups.filter { group in
            group.parentGroupId != nil && group.sidebarPin(in: groupsById, sectionsShown: true).pinRootGroupId == group.id
        }.map(\.id))
        var displayBase = base
        if !pinnedRoots.isEmpty {
            // Draw the same tree with its pinned roots at the top, never writing those view-only parents or memberships.
            let displayGroups = groups.map { group -> WorkspaceGroup in
                var display = group
                if pinnedRoots.contains(group.id) { display.parentGroupId = nil }
                return display
            }
            let membership = SidebarWorkspaceRenderItem.effectiveGroupIdByWorkspaceId(tabs: tabs, groupsById: groupsById)
            let displayWorkspaces = tabs.map { tab in
                WorkspaceGroupWorkspaceItem(id: tab.id, groupId: separatePinIds.contains(tab.id) ? nil : (membership[tab.id] ?? nil), isPinned: tab.isPinned)
            }
            displayBase = WorkspaceGroupRowWalk.rows(groups: displayGroups, workspaces: displayWorkspaces,
                groupsShownUnderAStatus: projection.workspaceGroups?.nestedRootGroupIds ?? []).compactMap { row in
                    switch row.kind {
                    case .header(let id):
                        return groupsById[id].map { .groupHeader(groupId: id, anchorWorkspaceId: $0.anchorWorkspaceId) }
                    case .workspace(let id): return .workspace(workspaceId: id)
                    }
                }
        }
        var looseStatuses: [UUID: String] = [:]
        for status in projection.groups {
            for id in status.memberWorkspaceIds { looseStatuses[id] = status.statusId }
        }
        let groupStatuses = projection.workspaceGroups?.statusIdByGroupId ?? [:]
        let containedStatuses = projection.workspaceGroups?.statusIdByWorkspaceId ?? [:]
        var normal: [SidebarWorkspaceRenderItem] = []
        var rowsByStatus: [String: [SidebarWorkspaceRenderItem]] = [:]
        for item in displayBase {
            if pinnedRoots.isEmpty, case .workspace(let id) = item, separatePinIds.contains(id) { continue }
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
        // A view only: supply pins even when their model parent is folded, after the existing pinned run, in tab order.
        if pinnedRoots.isEmpty {
            let pinBoundary = SidebarStatusAreaLayout(items: normal, tabs: tabs, groups: groups, statusProjection: projection).pinnedBoundary
            normal.insert(contentsOf: separatePins.map { .workspace(workspaceId: $0.id) }, at: pinBoundary)
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
