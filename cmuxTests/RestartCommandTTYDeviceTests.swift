// cmux-rbf #cm-137.1
import CmuxRestartCommands
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A restart-command scan may read a pane's TTY only from evidence of this launch.
/// A name restored from the previous launch points at whatever another pane runs on that
/// TTY number now, and bound a pane to an app it never ran.
@Suite("RestartCommandTTYDevice")
struct RestartCommandTTYDeviceTests {
    @Test func liveTerminalPTYWinsOverAReportedTTY() {
        #expect(Workspace.restartCommandTTYDevice(liveDevice: 7, currentRuntimeReportedDevice: 9) == 7)
    }

    @Test func aTTYTheShellReportedThisLaunchIsUsedWhenThePTYIsNotKnownYet() {
        #expect(Workspace.restartCommandTTYDevice(liveDevice: nil, currentRuntimeReportedDevice: 9) == 9)
    }

    @Test func aPaneWhoseTerminalHasNotStartedHasNoTTY() {
        #expect(Workspace.restartCommandTTYDevice(liveDevice: nil, currentRuntimeReportedDevice: nil) == nil)
    }

    /// The call site: a TTY name restore loaded from the last launch is not a pane's TTY.
    @MainActor
    @Test func aRestoredTTYNameDoesNotGiveAPaneARestartCommandTTY() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.panelDirectories[panel] = NSTemporaryDirectory()
        workspace.restorePersistedSurfaceTTYName("/dev/null", panelId: panel)
        #expect(CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: "/dev/null") != nil)
        #expect(workspace.restartCommandPanelTTYDevices().isEmpty)
    }

    /// The call site: a TTY the pane's own shell reported this launch still counts.
    @MainActor
    @Test func aTTYReportedThisLaunchGivesThePaneItsRestartCommandTTY() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.panelDirectories[panel] = NSTemporaryDirectory()
        workspace.registerReportedSurfaceTTYName("/dev/null", panelId: panel)
        let device = try #require(CmuxTopProcessSnapshot.deviceIdentifier(forTTYName: "/dev/null"))
        #expect(
            workspace.restartCommandPanelTTYDevices()
                == [RestartCommandPanelKey(workspaceID: workspace.id, panelID: panel): device]
        )
    }
}
