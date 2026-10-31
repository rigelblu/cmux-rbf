import AppKit
import CmuxWorkspaces
import Foundation
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Each way in reaches the one shared action (cm-128.2, Scenarios 55 and 56's unit halves): the AppKit row menu, the SwiftUI
/// row menu's enabled check, and the socket method behind `cmux clear-agent-state`. The palette entry is covered live.
@MainActor
@Suite("Clear Agent State entrances", .serialized)
struct ClearAgentStateEntranceTests {
    private func commands(for workspace: Workspace, in manager: TabManager, targets: [UUID],
                          store: TerminalNotificationStore) -> SidebarWorkspaceRowCommands {
        SidebarWorkspaceRowCommands(
            tab: workspace, tabManager: manager, notificationStore: store, index: 0,
            contextMenuWorkspaceIds: targets, remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false, allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil, workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            colorScheme: .dark, refreshSnapshot: {}, readSelectedTabIds: { [] }, writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil }, writeLastSelectionIndex: { _ in }, setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
    }

    private func menu(for workspace: Workspace, in manager: TabManager, targets: [UUID]? = nil,
                      store: TerminalNotificationStore) -> NSMenu {
        let row = commands(for: workspace, in: manager, targets: targets ?? [workspace.id], store: store)
        return SidebarWorkspaceRowMenuBuilder(commands: row).build(onOpen: {}, onClose: {})
    }

    private func wire(_ workspace: Workspace, key: String = "claude_code", _ state: AgentHibernationLifecycleState = .needsInput) throws {
        workspace.agentLifecycleStatesByPanelId = [try #require(workspace.focusedPanelId): [key: state]]
    }

    // MARK: - AppKit row menu

    @Test func theAppKitMenuHoldsTheItemAfterClearLatestAndEnablesItOnlyWithState() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let store = TerminalNotificationStore.shared
        var built = menu(for: workspace, in: manager, store: store)
        let titles = built.items.map(\.title)
        let clear = try #require(titles.firstIndex(of: "Clear Agent State"), "the menu has no Clear Agent State: \(titles)")
        #expect(titles[clear - 1] == "Clear Latest Notification")
        #expect(titles[clear + 1] == "Notifications")
        #expect(!built.items[clear].isEnabled, "disabled with nothing to clear, not hidden")
        try wire(workspace)
        built = menu(for: workspace, in: manager, store: store)
        #expect(built.items[clear].isEnabled)
    }

    @Test func theAppKitItemClearsEachSelectedWorkspace() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let first = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: false)
        let quiet = manager.addWorkspace(select: false)
        try wire(first)
        try wire(second, key: "codex", .running)
        let store = TerminalNotificationStore.shared
        let built = menu(for: first, in: manager, targets: [first.id, second.id, quiet.id], store: store)
        let index = try #require(built.items.firstIndex { $0.title == "Clear Agent State" })
        #expect(built.items[index].isEnabled)
        built.performActionForItem(at: index)
        for workspace in [first, second] {
            let states = workspace.agentLifecycleStatesByPanelId.values.flatMap(\.values)
            #expect(!states.contains(.needsInput) && !states.contains(.running), "a selected row kept its mark")
            #expect(!workspace.hasClearableAgentState)
        }
    }

    // MARK: - SwiftUI row menu

    @Test func theSwiftUIMenuReadsTheLiveEnabledCheckWhenItIsPresented() throws {
        var asked: [[UUID]] = []
        let target = UUID()
        let actions = SidebarWorkspaceContextMenuWindowTargetsTests.actions(
            canClearAgentState: { ids in asked.append(ids); return true })
        let row = TabItemView(snapshot: try SidebarWorkspaceContextMenuWindowTargetsTests.rowSnapshot(workspaceId: target),
            actions: actions)
        _ = row.body
        #expect(asked.isEmpty, "rendering the row must not read agent state")
        _ = TabItemWorkspaceContextMenuContent(row: row).body
        #expect(asked.count == 1, "the presented menu never asked the shared check")
    }

    // MARK: - Socket

    private func call(_ params: [String: Any]) throws -> [String: Any] {
        let request: [String: Any] = ["id": "clear", "method": "workspace.clear_agent_state", "params": params]
        let line = try #require(String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8))
        let data = try #require(TerminalController.shared.handleSocketLine(line).data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theSocketMethodRunsTheSharedActionAndAnEmptyWorkspaceChangesNothing() async throws {
        try await ClearAgentStateHarness.run { harness in
            // The socket resolves workspaces through `AppDelegate.shared`, so this one test registers its window there too.
            let shared = try #require(AppDelegate.shared)
            let sharedWindow = shared.registerMainWindowContextForTesting(tabManager: harness.tabManager)
            defer {
                shared.unregisterMainWindowContextForTesting(windowId: sharedWindow)
                shared.forgetRecoverableMainWindowRoute(windowId: sharedWindow)
            }
            let store = TerminalNotificationStore.shared
            let note = TerminalNotification(id: UUID(), tabId: harness.workspace.id, surfaceId: harness.panel,
                correlationKey: "k", title: "t", subtitle: "", body: "b", createdAt: Date(), isRead: false)
            store.replaceNotificationsForTesting([note])
            defer { store.replaceNotificationsForTesting([]) }

            var response = try call(["workspace_id": harness.workspace.id.uuidString])
            var result = try #require(response["result"] as? [String: Any], "\(response)")
            #expect(result["cleared"] as? Bool == false)
            #expect(store.notifications.first?.isRead == false, "a clear with nothing to clear marked a notification read")

            harness.workspace.setAgentLifecycle(key: "codex", panelId: harness.panel, lifecycle: .needsInput)
            response = try call(["workspace_id": harness.workspace.id.uuidString])
            result = try #require(response["result"] as? [String: Any], "\(response)")
            #expect(result["cleared"] as? Bool == true)
            #expect(harness.marks["codex"] == .unknown, "the socket method did not reach the shared action")
            #expect(store.notifications.first?.isRead == true)

            response = try call(["workspace_id": UUID().uuidString])
            // A suite outside the gate can leave the controller with no window to search at this instant: still an error.
            let code = (response["error"] as? [String: Any])?["code"] as? String
            #expect(code == "not_found" || code == "unavailable", "an unknown workspace must be an error, not a clear")
        }
    }
}
