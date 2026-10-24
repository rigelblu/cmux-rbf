import CmuxWorkspaces
import Foundation

// What `cmux sidebar rows` reports: the rows each window's sidebar built, not a second projection of the model. (#cm-110.1)

/// One row of the sidebar as the debug helper reports it.
struct SidebarDebugRow: Equatable {
    let kind: String
    let id: String
    let title: String
    /// The header the row sits under, or `nil` for a top-level row.
    let header: String?
    let folded: Bool
    /// The group's own stored status; independent of the header it sits under.
    var statusId: String? = nil

    /// Reads the rows off the items the sidebar built, in order.
    static func rows(
        from items: [SidebarWorkspaceRenderItem],
        workspaceTitle: (UUID) -> String,
        groupName: (UUID) -> String,
        groupIsFolded: (UUID) -> Bool,
        groupIdOfWorkspace: (UUID) -> UUID?,
        statusName: (String) -> String,
        statusGroups: WorkspaceStatusGroupsState = WorkspaceStatusGroupsState(),
        statusIdByWorkspaceId: [UUID: String]? = nil,
        groupStatusId: (UUID) -> String? = { _ in nil },
        parentGroupId: (UUID) -> UUID? = { _ in nil },
        statusIdByGroupId: [UUID: String] = [:]
    ) -> [SidebarDebugRow] {
        var rows: [SidebarDebugRow] = []
        var insideStatusArea = false
        var currentStatusId: String?
        for item in items {
            switch item {
            case .groupHeader(let groupId, _):
                let parent = parentGroupId(groupId)
                let containingStatus = insideStatusArea && currentStatusId == statusIdByGroupId[groupId]
                    ? currentStatusId : nil
                if parent == nil && containingStatus == nil {
                    insideStatusArea = false
                    currentStatusId = nil
                }
                rows.append(SidebarDebugRow(
                    kind: "groupHeader", id: groupId.uuidString, title: groupName(groupId),
                    header: parent?.uuidString ?? containingStatus,
                    folded: groupIsFolded(groupId), statusId: groupStatusId(groupId)
                ))
            case .colorSectionHeader(let section):
                insideStatusArea = false
                currentStatusId = nil
                rows.append(SidebarDebugRow(
                    kind: "colorSectionHeader", id: section.id.normalizedHex, title: section.title, header: nil,
                    folded: section.isCollapsed
                ))
            case .statusesHeader:
                insideStatusArea = true
                rows.append(SidebarDebugRow(
                    kind: "statusesHeader", id: SidebarStatusHeaderIdentity.statusesAreaUUID.uuidString,
                    title: SidebarStatusHeaderText.statusesAreaTitle, header: nil, folded: statusGroups.areaCollapsed
                ))
            case .pinnedHeader: // (#cm-110.5)
                insideStatusArea = false
                currentStatusId = nil
                rows.append(SidebarDebugRow(kind: "pinnedHeader", id: SidebarStatusHeaderIdentity.pinnedAreaUUID.uuidString,
                    title: SidebarStatusHeaderText.pinnedAreaTitle, header: nil, folded: statusGroups.pinnedCollapsed == true))
            case .workspacesHeader:
                insideStatusArea = false
                currentStatusId = nil
                rows.append(SidebarDebugRow(kind: "workspacesHeader", id: SidebarStatusHeaderIdentity.workspacesAreaUUID.uuidString,
                    title: SidebarStatusHeaderText.workspacesAreaTitle, header: nil, folded: statusGroups.workspacesCollapsed == true))
            case .statusGroupHeader(let statusId):
                currentStatusId = statusId
                rows.append(SidebarDebugRow(
                    kind: "statusGroupHeader", id: statusId, title: statusName(statusId), header: "statusesArea", folded: statusGroups.collapsedStatusIds.contains(statusId)
                ))
            case .workspace(let workspaceId):
                var headerUnder: String?
                if let statusIdByWorkspaceId {
                    headerUnder = statusIdByWorkspaceId[workspaceId]
                    if headerUnder == nil {
                        headerUnder = colorSection(containing: workspaceId, in: items)?.id.normalizedHex
                            ?? groupIdOfWorkspace(workspaceId)?.uuidString
                    }
                } else if insideStatusArea {
                    headerUnder = currentStatusId
                } else if let section = colorSection(containing: workspaceId, in: items) {
                    headerUnder = section.id.normalizedHex
                } else if let groupId = groupIdOfWorkspace(workspaceId) {
                    headerUnder = groupId.uuidString
                }
                rows.append(SidebarDebugRow(
                    kind: "workspace", id: workspaceId.uuidString, title: workspaceTitle(workspaceId), header: headerUnder,
                    folded: false
                ))
            }
        }
        return rows
    }

    private static func colorSection(containing workspaceId: UUID, in items: [SidebarWorkspaceRenderItem]) -> SidebarWorkspaceColorSection? {
        for item in items {
            if case .colorSectionHeader(let section) = item, section.memberWorkspaceIds.contains(workspaceId) { return section }
        }
        return nil
    }
}

#if DEBUG
/// The render items each window's sidebar last built, written from the sidebar's body (a plain store: nothing
/// observes it, so writing it invalidates no view).
@MainActor
enum SidebarDebugRowSnapshots {
    private static var itemsByWindowId: [UUID: [SidebarWorkspaceRenderItem]] = [:]

    /// Records the window's items, and forgets every window that has since closed.
    static func record(windowId: UUID, items: [SidebarWorkspaceRenderItem]) {
        store(windowId: windowId, items: items)
        if let app = AppDelegate.shared {
            let live = Set(app.mainWindowContexts.values.map(\.windowId))
            prune(keepingWindowIds: live.union([windowId]))
        }
    }

    static func store(windowId: UUID, items: [SidebarWorkspaceRenderItem]) {
        itemsByWindowId[windowId] = items
    }

    static func prune(keepingWindowIds live: Set<UUID>) {
        itemsByWindowId = itemsByWindowId.filter { live.contains($0.key) }
    }

    static func items(windowId: UUID) -> [SidebarWorkspaceRenderItem]? {
        itemsByWindowId[windowId]
    }
}
#endif
