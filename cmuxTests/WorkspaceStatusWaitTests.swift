import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// What the end of an agent's wait does to a workspace's status (#cm-109.2), beside the five short cases of
/// `WorkspaceStatusWriteTests`. A status of his is asserted through `statusResolution(list:)` with a list passed in,
/// never through `effectiveTaskStatus` in a bare test host, where it reads Needs Attention in both waits whether the
/// hold works or not.
@MainActor
@Suite("Workspace status and the end of a wait")
struct WorkspaceStatusWaitTests {
    private typealias A = WorkspaceStatusActionsTests
    private let key = "claude_code"

    private func panel(_ workspace: Workspace) throws -> UUID {
        try #require(workspace.focusedPanelId)
    }

    @Test func aCmuxStatusSetDuringAWaitIsRemovedWhenItEndsAndWritesNoColor() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        let writes = A.Writes()
        A.actions(writes: writes).apply(.done, to: [workspace], requireControls: false)
        #expect(workspace.todoState.statusOverride?.status == .done)
        #expect(workspace.customColor == "#222222")
        #expect(writes.all.count == 1)

        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        #expect(workspace.todoState.statusOverride == nil, "the status set during the wait is still stored")
        #expect(workspace.customColor == "#222222")
        // Whether the removal writes a color through the app's own writer is checked in WorkspaceStatusHandOverTests,
        // on a workspace a TabManager holds: a counter on this test's writer cannot see it.
    }

    /// The control: a cmux status set while idle is not removed by a wait that came and went, even though it
    /// lapsed in between, and is in effect again when detection returns.
    @Test func aCmuxStatusSetWhileIdleSurvivesAWaitThatCameAndWent() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        workspace.setTaskStatusOverride(.done)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        #expect(workspace.todoState.statusOverride != nil)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        #expect(workspace.todoState.statusOverride != nil, "a lapsed status was removed when the wait ended")
        #expect(workspace.clearAgentLifecycle(key: key, panelId: panelId))
        #expect(workspace.todoState.statusOverride != nil)
        #expect(workspace.statusResolution(list: .cmuxFive).effective == .done)
    }

    /// One of his own picked during a wait is held through it, stays after it, and shows Needs Attention at the next.
    @Test func oneOfHisOwnPickedDuringAWaitStaysAfterItAndShowsNeedsAttentionAtTheNext() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        let list = A.hisList
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        #expect(workspace.todoState.ownStatus == WorkspaceOwnStatus(id: "parked", heldThroughWait: true))
        let held = workspace.statusResolution(list: list)
        #expect(held.held == .inEffect)
        #expect(held.effective == .todo)

        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        #expect(workspace.todoState.ownStatus == WorkspaceOwnStatus(id: "parked", heldThroughWait: false))
        #expect(workspace.statusResolution(list: list).held == .inEffect)

        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        let next = workspace.statusResolution(list: list)
        #expect(next.held == .waiting, "the status held through the first wait also held through the second")
        #expect(next.effective == .needsAttention)
    }

    /// The control: one picked while idle is never held, so it shows Needs Attention in the wait that follows.
    @Test func oneOfHisOwnPickedWhileIdleShowsNeedsAttentionInTheNextWait() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        #expect(workspace.todoState.ownStatus == WorkspaceOwnStatus(id: "parked", heldThroughWait: false))
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        #expect(workspace.statusResolution(list: A.hisList).held == .waiting)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        #expect(workspace.statusResolution(list: A.hisList).held == .inEffect)
        #expect(workspace.todoState.ownStatus?.id == "parked")
    }

    /// A cmux status set during a wait stays in effect in that wait.
    @Test func aCmuxStatusSetDuringAWaitIsInEffectInThatWait() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        workspace.setTaskStatusOverride(.review)
        #expect(workspace.statusResolution(list: A.hisList).effective == .review)
    }

    /// Two agents wait; the wait ends only when the second stops.
    @Test func aWaitWithTwoAgentsEndsOnlyWhenTheSecondStops() throws {
        let workspace = Workspace()
        let first = try panel(workspace)
        let second = try #require(workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: false)).id
        workspace.setAgentLifecycle(key: key, panelId: first, lifecycle: .needsInput)
        workspace.setAgentLifecycle(key: key, panelId: second, lifecycle: .needsInput)
        workspace.setTaskStatusOverride(.review)

        workspace.setAgentLifecycle(key: key, panelId: first, lifecycle: .running)
        #expect(workspace.todoState.statusOverride != nil, "the wait ended while a second agent still waited")
        workspace.setAgentLifecycle(key: key, panelId: second, lifecycle: .idle)
        #expect(workspace.todoState.statusOverride == nil)
    }

    @Test func theFlagOfOneOfHisOwnClearsOnlyWhenTheLastAgentStopsWaiting() throws {
        let workspace = Workspace()
        let first = try panel(workspace)
        let second = try #require(workspace.newTerminalSplit(from: first, orientation: .horizontal, focus: false)).id
        workspace.setAgentLifecycle(key: key, panelId: first, lifecycle: .needsInput)
        workspace.setAgentLifecycle(key: key, panelId: second, lifecycle: .needsInput)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        workspace.setAgentLifecycle(key: key, panelId: first, lifecycle: .running)
        #expect(workspace.todoState.ownStatus?.heldThroughWait == true)
        workspace.setAgentLifecycle(key: key, panelId: second, lifecycle: .running)
        #expect(workspace.todoState.ownStatus == WorkspaceOwnStatus(id: "parked", heldThroughWait: false))
    }

    /// The table after the end of a wait.
    @Test func theTableHoldsAfterTheEndOfAWait() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        A.actions().apply(.done, to: [workspace], requireControls: false)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .idle)
        A.expectHolds(workspace, override: nil, own: nil, hidden: false, "the end of a wait")
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .idle)
        A.expectHolds(workspace, override: nil, own: "parked", hidden: false, "the end of a wait with his own")
    }
}
