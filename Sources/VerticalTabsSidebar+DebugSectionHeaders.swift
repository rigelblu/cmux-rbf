import SwiftUI

#if DEBUG
extension VerticalTabsSidebar {
    func makeSidebarDebugSectionHeaderActions(renderContext: WorkspaceListRenderContext) -> [SidebarDebugActions.Action] {
        let state = sidebarState
        let toggle = makeStatusHeaderToggleAction()
        guard renderContext.statusGroupProjection != nil else { return [] }
        return [.init(header: .statuses, isCollapsed: { state.statusGroups?.areaCollapsed ?? false },
            toggle: { toggle(.statusesArea) }),
            .init(header: .workspaces, isCollapsed: { state.statusGroups?.workspacesCollapsed == true },
                toggle: { toggle(.workspacesArea) })]
    }
}
#endif
