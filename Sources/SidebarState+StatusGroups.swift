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
        selectedWorkspace: Workspace?,
        workspaceGroups: [WorkspaceGroup],
        revealWorkspaces: Bool = true
    ) {
        if statusGroups == nil, list.source != .cmux {
            setStatusGroups(.seeded(list: list, resolvedHexByStatusId: resolvedHexByStatusId,
                                   collapsedColorHexes: statusGroupFoldSeedSource ?? collapsedColorSectionHexes))
        }
        reconcileStatusGroupOrder(list: list)
        if let selectedWorkspace {
            expandColorSection(containing: selectedWorkspace)
            revealStatusGroup(containing: selectedWorkspace, list: list, resolvedHexByStatusId: resolvedHexByStatusId,
                              workspaceGroups: workspaceGroups, revealWorkspaces: revealWorkspaces)
        }
    }

    /// A later revision must preserve a deliberate fold over the selected workspace.
    func prepareStatusGroupsOnListArrival(
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String],
        selectedWorkspace: Workspace?,
        workspaceGroups: [WorkspaceGroup],
        wasUninitialized: Bool? = nil // (#cm-110.4)
    ) {
        reconcileStatusGroupOrder(list: list)
        guard wasUninitialized ?? (statusGroups == nil) else { return } // (#cm-110.4)
        prepareStatusGroupsForSelection(list: list, resolvedHexByStatusId: resolvedHexByStatusId,
                                        selectedWorkspace: selectedWorkspace, workspaceGroups: workspaceGroups)
    }

    func revealStatusGroup(
        containing workspace: Workspace,
        list: WorkspaceStatusList,
        resolvedHexByStatusId: [String: String],
        workspaceGroups: [WorkspaceGroup],
        revealWorkspaces: Bool = true
    ) {
        guard var next = statusGroups else { return }
        // A selected member is a one-row sample; the absent anchor is not evidence that its live group disappeared.
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        let storedGroup = workspaceGroups.first { $0.liveAnchorWorkspaceId == workspace.id }?.id ?? workspace.groupId
        // Restore prepares selection before registering its context; retain the same raw-membership fallback as rendering.
        let groupId = workspaceGroups.isEmpty ? storedGroup : storedGroup.flatMap { groupsById[$0] == nil ? nil : $0 }
        let tree = WorkspaceGroupTree(groups: workspaceGroups)
        let root = groupId.flatMap { groupsById[tree.outermost(of: $0)] }
        let item = VerticalTabsSidebar.statusGroupProjectionItem(workspace, list: list,
            groupId: groupId, isPinned: root?.isPinned ?? workspace.isPinned)
        guard let projection = VerticalTabsSidebar.statusGroupProjection(items: [item],
            list: list, colorHexes: resolvedHexByStatusId, controlsEnabled: true,
            workspaceGroups: workspaceGroups) else { return }
        let statusId = projection.workspaceGroups?.statusIdByWorkspaceId[workspace.id]
            ?? projection.groups.first(where: { $0.memberWorkspaceIds.contains(workspace.id) })?.statusId
        if let statusId { next.reveal(statusId: statusId) }
        else if revealWorkspaces, WorkspaceTodoFeature.isEnabled, next.sectionOrder != nil, !item.isPinned {
            next.revealWorkspaces()
        }
        if next != statusGroups { setStatusGroups(next) }
    }

    func prepareStatusGroupsForSelection(selectedWorkspace: Workspace?, revealWorkspaces: Bool = true) {
        let manager = selectedWorkspace.flatMap { AppDelegate.shared?.tabManagerFor(tabId: $0.id) }
        if let manager { prepareWorkspaceSections(tabManager: manager) }
        let groups = manager?.workspaceGroups ?? []
        prepareStatusGroupsForSelection(list: AppDelegate.statusListInUse,
                                        resolvedHexByStatusId: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
                                        selectedWorkspace: selectedWorkspace, workspaceGroups: groups,
                                        revealWorkspaces: revealWorkspaces)
    }

    func prepareStatusGroupsOnListArrival(selectedWorkspace: Workspace?, tabManager: TabManager? = nil) { // (#cm-110.4)
        let wasUninitialized = statusGroups == nil // (#cm-110.4) capture before migration seeds the record
        let manager = tabManager ?? selectedWorkspace.flatMap { AppDelegate.shared?.tabManagerFor(tabId: $0.id) } // (#cm-110.4)
        if let manager { prepareWorkspaceSections(tabManager: manager) }
        let groups = manager?.workspaceGroups ?? []
        prepareStatusGroupsOnListArrival(list: AppDelegate.statusListInUse,
                                        resolvedHexByStatusId: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
                                        selectedWorkspace: selectedWorkspace, workspaceGroups: groups,
                                        wasUninitialized: wasUninitialized) // (#cm-110.4)
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
