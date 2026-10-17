import CmuxWorkspaces
import Foundation

/// Window-owned fold changes happen at restore, list arrival, selection, or an action, never while drawing a row.
@MainActor
extension SidebarState {
    func reconcileStatusGroupOrder(list: WorkspaceStatusList) {
        guard list.source != .cmux, !list.entries.isEmpty,
              var next = statusGroups, let order = next.order else { return }
        next.order = WorkspaceStatusGroupOrder.adopting(fileIds: list.entries.map(\.id), storedOrder: order)
        if next != statusGroups { setStatusGroups(next) }
    }

    func toggleStatusGroup(id: String) {
        guard var next = statusGroups else { return }
        next.toggleStatus(id: id)
        setStatusGroups(next)
    }

    func toggleStatusesArea() {
        guard var next = statusGroups else { return }
        next.toggleArea()
        setStatusGroups(next)
    }

    /// Copy before opening the selected color; opening its status group follows the copy.
    func prepareStatusGroupsForSelection(
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String],
        selectedWorkspace: Workspace?
    ) {
        if statusGroups == nil, list.source != .cmux {
            setStatusGroups(.seeded(list: list, resolvedHexByStatusId: resolvedHexByStatusId,
                                   collapsedColorHexes: statusGroupFoldSeedSource ?? collapsedColorSectionHexes))
        }
        reconcileStatusGroupOrder(list: list)
        if let selectedWorkspace {
            expandColorSection(containing: selectedWorkspace)
            revealStatusGroup(containing: selectedWorkspace, list: list, resolvedHexByStatusId: resolvedHexByStatusId)
        }
    }

    /// A later revision must preserve a deliberate fold over the selected workspace.
    func prepareStatusGroupsOnListArrival(
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String],
        selectedWorkspace: Workspace?
    ) {
        reconcileStatusGroupOrder(list: list)
        guard statusGroups == nil else { return }
        prepareStatusGroupsForSelection(list: list, resolvedHexByStatusId: resolvedHexByStatusId,
                                        selectedWorkspace: selectedWorkspace)
    }

    func revealStatusGroup(
        containing workspace: Workspace,
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String]
    ) {
        guard var next = statusGroups,
              let projection = WorkspaceStatusGroupProjection.project(
                workspaces: VerticalTabsSidebar.statusGroupProjectionItems(tabs: [workspace], list: list),
                list: list, resolvedHexByStatusId: resolvedHexByStatusId, storedOrder: nil
              ),
              let group = projection.groups.first(where: { $0.memberWorkspaceIds.contains(workspace.id) }) else { return }
        next.reveal(statusId: group.statusId)
        if next != statusGroups { setStatusGroups(next) }
    }

    func prepareStatusGroupsForSelection(selectedWorkspace: Workspace?) {
        prepareStatusGroupsForSelection(list: AppDelegate.statusListInUse,
                                        resolvedHexByStatusId: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
                                        selectedWorkspace: selectedWorkspace)
    }

    func prepareStatusGroupsOnListArrival(selectedWorkspace: Workspace?) {
        prepareStatusGroupsOnListArrival(list: AppDelegate.statusListInUse,
                                        resolvedHexByStatusId: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
                                        selectedWorkspace: selectedWorkspace)
    }
}

// These hooks run only from SidebarState's existing initialization/restore/record/color-toggle paths.
// Automatic color reveal intentionally does not call them.
extension SidebarState {
    func statusGroupRecordDidChange() {
        statusGroupFoldSeedSource = statusGroups == nil ? collapsedColorSectionHexes : nil
    }

    func statusGroupColorFoldWasToggled(hex: String) {
        guard statusGroups == nil else { return }
        var source = statusGroupFoldSeedSource ?? collapsedColorSectionHexes
        if collapsedColorSectionHexes.contains(hex) { source.insert(hex) }
        else { source.remove(hex) }
        statusGroupFoldSeedSource = source
    }
}
