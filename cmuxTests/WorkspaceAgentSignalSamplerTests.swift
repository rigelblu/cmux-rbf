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

    /// cm-128.5 (Scenario 72): a pane at `.error` reaches the socket as `any_agent_error`, and an idle one does not.
    @Test func anErroredPaneCrossesTheControlSocketSeamAsAnyAgentError() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let workspace = manager.addWorkspace(select: true)
            defer { manager.closeWorkspace(workspace) }
            let panel = try #require(workspace.focusedPanelId)
            let controller = TerminalController.shared
            let previous = controller.activeTabManagerForCallerNotification()
            controller.setActiveTabManager(manager)
            defer { controller.setActiveTabManager(previous) }
            let routing = ControlRoutingSelectors(hasWindowIDParam: false, windowID: nil, groupID: nil,
                workspaceID: nil, surfaceID: nil, paneID: nil)
            @MainActor func sampled() -> Bool? {
                guard case .resolved(_, let snapshot) = controller.controlWorkspaceTaskStatus(routing: routing, workspaceID: workspace.id) else { return nil }
                return snapshot.signals.anyAgentError
            }
            workspace.setAgentLifecycle(key: "claude_code", panelId: panel, lifecycle: .idle)
            #expect(sampled() == false, "control: an idle pane is not an error")
            workspace.setAgentLifecycle(key: "claude_code", panelId: panel, lifecycle: .error)
            #expect(workspace.taskStatusSignals(orderedPanelIds: [panel]).anyAgentError, "the sampler reads the error")
            #expect(sampled() == true, "the error did not cross the socket seam")
        }
    }
}
