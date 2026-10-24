import CmuxFoundation
import CmuxWorkspaces

@MainActor
extension SidebarState {
    /// Shared commit for native, SwiftUI and DEBUG header drops. Workspace state is deliberately not an input.
    func commitStatusHeaderDrop(source: SidebarStatusHeaderKind, plan: SidebarStatusHeaderDropPlan,
                                list: WorkspaceStatusList, controlsEnabled: Bool,
                                validTopLevelRowIds: Set<String> = []) -> Bool {
        guard controlsEnabled, list.source != .cmux, !list.entries.isEmpty,
              var next = statusGroups else { return false }
        switch (source, plan.action) {
        case (.statusGroup(let id), .statusGroup(let target, let before)):
            let fileIds = list.entries.map(\.id)
            guard id != target, fileIds.contains(id), fileIds.contains(target) else { return false }
            let adopted = WorkspaceStatusGroupOrder.adopting(fileIds: fileIds, storedOrder: next.order ?? fileIds)
            next.order = WorkspaceStatusGroupOrder.moving(id, relativeTo: target, insertBefore: before,
                fileIds: fileIds, storedOrder: adopted) ?? adopted
        case (.statusesArea, .area(let above, let below, let last)),
             (.workspacesArea, .area(let above, let below, let last)):
            if next.sectionOrder != nil {
                guard above == "top", below == nil else { return false }
                next.placeSections(last ? .workspacesFirst : .statusesFirst)
                break
            }
            guard source == .statusesArea else { return false }
            guard (above == "top" || validTopLevelRowIds.contains(above)),
                  below.map(validTopLevelRowIds.contains) ?? true,
                  last || below != nil else { return false }
            next.aboveRow = above
            next.belowRow = last ? nil : below
            next.last = last
        default: return false
        }
        if next != statusGroups { setStatusGroups(next) }
        return true
    }
}
