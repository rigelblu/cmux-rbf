import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
struct ControlExtensionSidebarBadgeTests {
    @Test(arguments: [false, true], [0, 2])
    func socketSerializesNewsAndMarkSeparately(_ marked: Bool, _ news: Int) throws {
        let context = BadgeSidebarControlContext()
        let workspace = UUID()
        context.snapshot = ControlExtensionSidebarSnapshot(sequence: 1, windowID: nil,
            selectedWorkspaceID: workspace, workspaces: [ControlExtensionSidebarWorkspace(
                workspaceID: workspace, index: 0, title: "Workspace", description: nil,
                isSelected: true, isPinned: false, rootPath: nil, projectRootPath: nil,
                branchSummary: nil, remoteDisplayTarget: nil, remoteConnectionStateRawValue: "connected",
                remotePayload: .object([:]), currentDirectory: "/tmp", customColor: nil,
                unreadCount: news, markedUnread: marked, latestNotificationText: nil,
                latestConversationMessage: nil, latestSubmittedMessage: nil, latestSubmittedAtISO: nil,
                listeningPorts: [], pullRequestURLs: [], panelDirectories: [], gitBranches: [])])
        let coordinator = ControlCommandCoordinator(context: context)
        let result = try #require(coordinator.handle(ControlRequest(id: .int(1), method: "extension.sidebar.snapshot", params: [:])))
        guard case .ok(.object(let payload)) = result,
              case .array(let rows) = payload["workspaces"],
              case .object(let row) = rows.first else {
            Issue.record("Expected the sidebar's workspace payload")
            return
        }
        #expect(row["unread_count"] == .int(Int64(news)))
        #expect(row["marked_unread"] == .bool(marked))
    }
}
