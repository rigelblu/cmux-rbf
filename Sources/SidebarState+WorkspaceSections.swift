import CmuxWorkspaces
import Foundation

@MainActor
extension SidebarState {
    /// Resolves this window before selection, a header action or snapshot can replace the legacy record.
    /// The render resolver reads the old placement without writing; an inactive projection leaves it pending.
    @discardableResult
    func prepareWorkspaceSections(tabManager: TabManager) -> Bool {
        prepareWorkspaceSections(renderItems: {
            VerticalTabsSidebar.statusRenderItemsForSnapshot(tabManager: tabManager, state: self).items
        })
    }

    @discardableResult
    func prepareWorkspaceSections(renderItems: () -> [SidebarWorkspaceRenderItem]) -> Bool {
        if let current = statusGroups, current.sectionOrder != nil {
            let next = current.canonicalizingSectionOrder()
            if next != current { setStatusGroups(next) }
            return true
        }
        let items = renderItems()
        guard let workspaces = items.firstIndex(where: { $0.id == .workspacesArea() }),
              let statuses = items.firstIndex(where: { $0.id == .statusesArea() }) else { return false }
        var next = statusGroups ?? .seeded(list: AppDelegate.statusListInUse,
            resolvedHexByStatusId: AppDelegate.shared?.workspaceStatusListStore.colorHexes ?? [:],
            collapsedColorHexes: statusGroupFoldSeedSource ?? collapsedColorSectionHexes)
        next.placeSections(statuses < workspaces ? .statusesFirst : .workspacesFirst)
        setStatusGroups(next)
        return true
    }

    func toggleWorkspacesArea() {
        guard var next = statusGroups else { return }
        next.toggleWorkspaces()
        setStatusGroups(next)
    }
}
