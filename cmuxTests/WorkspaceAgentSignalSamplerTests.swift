import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceAgentSignalSamplerTests {
    @Test func monitoringIsSampledWithoutRunningAndCrossesTheControlSocketSeam() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = manager.addWorkspace(select: true)
            defer { manager.closeWorkspace(workspace) }
            let panel = try #require(workspace.focusedPanelId)
            workspace.setAgentLifecycle(key: "claude_code", panelId: panel, lifecycle: .monitoring)
            let signals = workspace.taskStatusSignals(orderedPanelIds: [panel])
            #expect(signals.anyAgentMonitoring)
            #expect(!signals.anyAgentRunning)
            #expect(!signals.anyAgentNeedsInput)

            let controller = TerminalController.shared
            let previous = controller.activeTabManagerForCallerNotification()
            controller.setActiveTabManager(manager)
            defer { controller.setActiveTabManager(previous) }
            let routing = ControlRoutingSelectors(hasWindowIDParam: false, windowID: nil, groupID: nil,
                workspaceID: nil, surfaceID: nil, paneID: nil)
            let result = controller.controlWorkspaceTaskStatus(routing: routing, workspaceID: workspace.id)
            guard case .resolved(_, let snapshot) = result else {
                Issue.record("the monitoring workspace did not resolve: \(result)")
                return
            }
            #expect(snapshot.signals.anyAgentMonitoring)
            #expect(!snapshot.signals.anyAgentRunning)
            workspace.setAgentLifecycle(key: "claude_code", panelId: panel, lifecycle: .running)
            #expect(!workspace.taskStatusSignals().anyAgentMonitoring)
            #expect(workspace.taskStatusSignals().anyAgentRunning)
        }
    }
}
