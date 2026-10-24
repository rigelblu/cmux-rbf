import CmuxNotifications
import CmuxWorkspaces
import SwiftUI

extension VerticalTabsSidebar {
    func sidebarWorkspacesAreaTableConfiguration(renderContext: WorkspaceListRenderContext) -> SidebarWorkspaceTableRowConfiguration {
        let toggle = makeStatusHeaderToggleAction()
        return Self.statusHeaderConfiguration(kind: .workspacesArea, presentation: nil,
            memberCount: renderContext.workspacesSectionMemberIds.count,
            memberIds: renderContext.workspacesSectionMemberIds,
            folds: renderContext.statusGroupFolds, environment: renderContext.environment,
            onToggle: { toggle(.workspacesArea) },
            isBeingDragged: dragState.draggedTabId == SidebarStatusHeaderIdentity.workspacesAreaUUID)
    }

    static func sidebarWorkspacesAreaHeaderRow(folds: WorkspaceStatusGroupsState, memberIds: Set<UUID>,
        unreadSnapshot: SidebarUnreadSnapshot, onToggle: @escaping @MainActor () -> Void) -> SidebarSectionSwiftUIHeader {
        let collapsed = folds.workspacesCollapsed == true
        return SidebarSectionSwiftUIHeader(title: SidebarStatusHeaderText.workspacesAreaTitle,
            label: SidebarStatusHeaderText.workspacesAreaLabel(isCollapsed: collapsed),
            identifier: "sidebarWorkspacesArea", isCollapsed: collapsed,
            unreadCount: collapsed ? memberIds.reduce(0) {
                $0 + unreadSnapshot.unreadCount(forWorkspaceId: $1)
            } : 0, onToggle: onToggle)
    }

    func sidebarPinnedAreaTableConfiguration(renderContext: WorkspaceListRenderContext) -> SidebarWorkspaceTableRowConfiguration { // (#cm-110.5)
        let toggle = makeStatusHeaderToggleAction()
        return Self.statusHeaderConfiguration(kind: .pinnedArea, presentation: nil,
            memberCount: renderContext.pinnedSectionMemberIds.count,
            memberIds: renderContext.pinnedSectionMemberIds,
            folds: renderContext.statusGroupFolds, environment: renderContext.environment,
            onToggle: { toggle(.pinnedArea) },
            isBeingDragged: false)
    }

    static func sidebarPinnedAreaHeaderRow(folds: WorkspaceStatusGroupsState, memberIds: Set<UUID>, // (#cm-110.5)
        unreadSnapshot: SidebarUnreadSnapshot, onToggle: @escaping @MainActor () -> Void) -> SidebarSectionSwiftUIHeader {
        let collapsed = folds.pinnedCollapsed == true
        return SidebarSectionSwiftUIHeader(title: SidebarStatusHeaderText.pinnedAreaTitle,
            label: SidebarStatusHeaderText.pinnedAreaLabel(isCollapsed: collapsed),
            identifier: "sidebarPinnedArea", isCollapsed: collapsed,
            unreadCount: collapsed ? memberIds.reduce(0) {
                $0 + unreadSnapshot.unreadCount(forWorkspaceId: $1)
            } : 0, onToggle: onToggle)
    }
}
