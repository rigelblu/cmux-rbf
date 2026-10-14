import CmuxControlSocket
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// What a cmux status set by hand does around an agent's wait and around the socket's read of it (#cm-109.2).
@MainActor
@Suite("Workspace status, the end of a wait and the status read", .serialized)
struct WorkspaceStatusWriteTests {
    private let key = "claude_code"
    private let routing = ControlRoutingSelectors(
        hasWindowIDParam: false, windowID: nil, groupID: nil, workspaceID: nil, surfaceID: nil, paneID: nil
    )

    /// Test 10. A cmux status set during a wait goes when the wait ends, so the next wait starts with the detected
    /// status. `end` ends the wait, one way for each caller. It never calls `reconcileExpiredTaskStatusOverride()`
    /// and the test never reads the status over the socket between the waits: on code without the change of
    /// test 12 either would remove a lapsed status and let a build that does nothing for the end of a wait pass.
    private func aStatusSetDuringAWaitDoesNotSurviveItsEnd(
        waitPanelId: ((Workspace) throws -> UUID)? = nil,
        secondWaitPanelId: ((Workspace) throws -> UUID)? = nil,
        end: (Workspace, UUID) -> Void
    ) throws {
        let workspace = Workspace()
        let first = try waitPanelId?(workspace) ?? #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: key, panelId: first, lifecycle: .needsInput)
        #expect(workspace.effectiveTaskStatus == .needsAttention)
        workspace.setTaskStatusOverride(.review)
        #expect(workspace.effectiveTaskStatus == .review)

        end(workspace, first)
        #expect(
            workspace.todoState.statusOverride == nil,
            "the status is still stored after the wait ended: \(String(describing: workspace.todoState.statusOverride))"
        )

        let second = try secondWaitPanelId?(workspace) ?? #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: key, panelId: second, lifecycle: .needsInput)
        #expect(workspace.effectiveTaskStatus == .needsAttention)
    }

    @Test func theAgentGoingToRunningEndsTheWait() throws {
        try aStatusSetDuringAWaitDoesNotSurviveItsEnd { workspace, panelId in
            workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        }
    }

    @Test func theAgentGoingIdleEndsTheWait() throws {
        try aStatusSetDuringAWaitDoesNotSurviveItsEnd { workspace, panelId in
            workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .idle)
        }
    }

    @Test func clearingTheAgentStateEndsTheWait() throws {
        try aStatusSetDuringAWaitDoesNotSurviveItsEnd { workspace, panelId in
            #expect(workspace.clearAgentLifecycle(key: key, panelId: panelId))
        }
    }

    @Test func closingThePanelEndsTheWait() throws {
        var leftPanelId: UUID?
        try aStatusSetDuringAWaitDoesNotSurviveItsEnd(
            waitPanelId: { workspace in
                // The wait is on the second panel, which closes; the first stays for the second wait.
                let first = try #require(workspace.focusedPanelId)
                let second = try #require(
                    workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: false)
                )
                leftPanelId = first
                return second.id
            },
            secondWaitPanelId: { _ in try #require(leftPanelId) },
            end: { workspace, panelId in
                #expect(workspace.closePanel(panelId, force: true))
            }
        )
    }

    @Test func clearingEveryAgentStateEndsTheWait() throws {
        try aStatusSetDuringAWaitDoesNotSurviveItsEnd { workspace, _ in
            workspace.clearAllAgentLifecycleStates()
        }
    }

    /// Test 12. Reading a lapsed cmux status over the socket changes nothing the workspace holds, and the status
    /// is in effect again when detection returns.
    @Test func readingALapsedStatusKeepsItAndItIsInEffectWhenDetectionReturns() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)

        workspace.setTaskStatusOverride(.done)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        #expect(workspace.effectiveTaskStatus == .working)

        let previous = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        let resolution = TerminalController.shared.controlWorkspaceTaskStatus(
            routing: routing, workspaceID: workspace.id
        )
        TerminalController.shared.setActiveTabManager(previous)

        guard case .resolved(_, let status) = resolution else {
            Issue.record("the read did not resolve the workspace: \(resolution)")
            return
        }
        // True today and must stay true: the answer does not report a lapsed status as in effect.
        #expect(status.overrideStatus == nil)
        #expect(status.effective == "working")
        #expect(status.statusID == nil, "the answer reports the lapsed status's id: \(String(describing: status.statusID))")
        // Fails today: the read removed the status.
        #expect(
            workspace.todoState.statusOverride != nil,
            "the read removed the status the workspace held"
        )

        #expect(workspace.clearAgentLifecycle(key: key, panelId: panelId))
        #expect(
            workspace.effectiveTaskStatus == .done,
            "detection returned and the status is not in effect: \(workspace.effectiveTaskStatus)"
        )
    }
}
