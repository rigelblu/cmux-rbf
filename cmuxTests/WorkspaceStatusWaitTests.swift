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
@Suite("Workspace status and the end of a wait", .serialized)
struct WorkspaceStatusWaitTests {
    private typealias A = WorkspaceStatusActionsTests
    private let key = "claude_code"
    private struct NoDefaultsSuite: Error {}

    /// Runs `body` with `AppDelegate.shared` holding a store that has loaded his list.
    private func underHisList(_ body: () throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStatusWaitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cmux.json")
        let hisText = """
        { "workspaceStatuses": [
          { "id": "doing", "name": "Doing", "extends": "working", "color": "#112233" },
          { "id": "parked", "name": "Parked", "extends": "todo", "color": "#445566" },
          { "id": "review", "name": "Review", "color": "#333333" },
          { "id": "done", "name": "Done", "color": "#778899" }
        ] }
        """
        try hisText.write(to: file, atomically: true, encoding: .utf8)
        let suite = "WorkspaceStatusWaitTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw NoDefaultsSuite() }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WorkspaceStatusListStore(
            fileURL: file,
            defaults: defaults,
            resolveColor: { _ in nil },
            paletteFingerprint: { "fixed" },
            clock: ContinuousClock()
        )
        store.load()
        let previous = AppDelegate.shared
        let delegate = AppDelegate()
        delegate.workspaceStatusListStore = store
        AppDelegate.shared = delegate
        defer { AppDelegate.shared = previous }
        try body()
    }

    private func panel(_ workspace: Workspace) throws -> UUID {
        try #require(workspace.focusedPanelId)
    }

    @Test func aCmuxStatusSetDuringAWaitIsRemovedWhenItEndsAndWritesNoColor() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        let writes = A.Writes()
        let cmuxList = WorkspaceStatusList(entries: A.hisEntries, source: .cmux)
        A.actions(cmuxList, writes: writes).apply(.done, to: [workspace], requireControls: false)
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

    /// With a list in use, one of his own picked during a wait is kept through it and stays in effect after it,
    /// and stays in effect at the next wait (11_expected-results.md:67, 71, 19_technical-system.md:435).
    @Test func oneOfHisOwnPickedDuringAWaitStaysAfterItAndStaysInEffectAtTheNext() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        let list = A.hisList
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        #expect(workspace.todoState.ownStatus == WorkspaceOwnStatus(id: "parked"))
        let held = workspace.statusResolution(list: list)
        #expect(held.held == .inEffect)
        #expect(held.effective == .todo)

        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        #expect(workspace.todoState.ownStatus == WorkspaceOwnStatus(id: "parked"))
        #expect(workspace.statusResolution(list: list).held == .inEffect)

        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        let next = workspace.statusResolution(list: list)
        #expect(next.held == .inEffect, "with his list, detection without states is .todo so it stays in effect")
        #expect(next.effective == .todo)
    }

    /// With a list in use, one picked while idle is kept and stays in effect in the next wait because detection without states is .todo (11_expected-results.md:67, 71, 19_technical-system.md:435).
    @Test func oneOfHisOwnPickedWhileIdleStaysInEffectInTheNextWait() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        #expect(workspace.todoState.ownStatus == WorkspaceOwnStatus(id: "parked"))
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        #expect(workspace.statusResolution(list: A.hisList).held == .inEffect)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        #expect(workspace.statusResolution(list: A.hisList).held == .inEffect)
        #expect(workspace.todoState.ownStatus?.id == "parked")
    }

    /// Under his list, Review set by hand during a wait records detection without states (.todo) and stays in effect in that wait.
    @Test func aCmuxStatusSetDuringAWaitIsInEffectInThatWait() throws {
        try underHisList {
            let workspace = Workspace()
            let panelId = try panel(workspace)
            workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
            let actions = A.actions()
            actions.apply(.status(id: "review"), to: [workspace], requireControls: false)
            #expect(workspace.todoState.statusOverride?.status == .review)
            #expect(workspace.todoState.statusOverride?.inferredAtOverride == .todo)
            #expect(workspace.statusResolution(list: A.hisList).effective == .review)
        }
    }

    /// In a bare test host with no list loaded in AppDelegate, applying a cmux status through actions with his list
    /// passes the actions' list to setTaskStatusOverride, recording detection without states (.todo).
    @Test func actionsPassesItsListToSetTaskStatusOverrideInBareHost() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        let actions = A.actions()
        actions.apply(.status(id: "review"), to: [workspace], requireControls: false)
        #expect(workspace.todoState.statusOverride?.status == .review)
        #expect(workspace.todoState.statusOverride?.inferredAtOverride == .todo)
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

    /// The table after the end of a wait.
    @Test func theTableHoldsAfterTheEndOfAWait() throws {
        let workspace = Workspace()
        let panelId = try panel(workspace)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        let cmuxList = WorkspaceStatusList(entries: A.hisEntries, source: .cmux)
        A.actions(cmuxList).apply(.done, to: [workspace], requireControls: false)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .idle)
        A.expectHolds(workspace, override: nil, own: nil, hidden: false, "the end of a wait")
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .needsInput)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .idle)
        A.expectHolds(workspace, override: nil, own: "parked", hidden: false, "the end of a wait with his own")
    }
}
