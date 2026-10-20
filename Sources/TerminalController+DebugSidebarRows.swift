import CmuxWorkspaces
import Foundation

#if DEBUG
// `debug.sidebar.rows`: the rows a window's sidebar built, from what the sidebar recorded. (#cm-110.1)
extension TerminalController {
    nonisolated func v2DebugSidebarRows(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let app = AppDelegate.shared else {
                return .err(code: "internal_error", message: "AppDelegate not available", data: nil)
            }
            let tabManager: TabManager?
            if let windowId = v2UUID(params, "window_id") {
                tabManager = app.tabManagerFor(windowId: windowId)
            } else {
                tabManager = self.tabManager
            }
            guard let tabManager, let windowId = app.windowId(for: tabManager) else {
                return .err(code: "not_found", message: "TabManager not found", data: nil)
            }
            guard let items = SidebarDebugRowSnapshots.items(windowId: windowId) else {
                return .err(
                    code: "not_found",
                    message: "The sidebar has not built rows for this window yet (is it visible?)",
                    data: nil
                )
            }
            let groupsById = Dictionary(uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0) })
            let tabsById = Dictionary(uniqueKeysWithValues: tabManager.tabs.map { ($0.id, $0) })
            let statusList = AppDelegate.statusListInUse
            let statusGroups = app.mainWindowContexts.values.first { $0.windowId == windowId }?.sidebarState.statusGroups ?? .init()
            let projection = VerticalTabsSidebar.currentStatusGroupProjection(tabs: tabManager.tabs, groups: tabManager.workspaceGroups, storedOrder: statusGroups.order)
            var statusIdByWorkspaceId: [UUID: String] = [:]
            for group in projection?.groups ?? [] {
                for id in group.memberWorkspaceIds { statusIdByWorkspaceId[id] = group.statusId }
            }
            let rows = SidebarDebugRow.rows(
                from: items,
                workspaceTitle: { tabsById[$0]?.title ?? "" },
                groupName: { groupsById[$0]?.name ?? "" },
                groupIsFolded: { groupsById[$0]?.isCollapsed ?? false },
                groupIdOfWorkspace: { tabsById[$0]?.groupId },
                statusName: { statusId in
                    SidebarStatusGroupPresentation.resolve(
                        statusId: statusId,
                        list: statusList,
                        colorHexes: [:]
                    ).name
                },
                statusGroups: statusGroups, statusIdByWorkspaceId: statusIdByWorkspaceId,
                groupStatusId: { groupsById[$0]?.statusId },
                parentGroupId: { groupsById[$0]?.parentGroupId },
                statusIdByGroupId: projection?.workspaceGroups?.statusIdByGroupId ?? [:]
            )
            let rowsData: [[String: Any]] = rows.map { row in
                [
                    "kind": row.kind,
                    "id": row.id,
                    "title": row.title,
                    "header": row.header.map { $0 as Any } ?? NSNull(),
                    "folded": row.folded,
                    "status_id": row.statusId.map { $0 as Any } ?? NSNull(),
                ]
            }
            return .ok([
                "rows": rowsData,
                "session_file_path": app.sessionSnapshotStore.defaultSnapshotFileURL()?.path ?? "",
            ])
        }
    }
}
#endif
