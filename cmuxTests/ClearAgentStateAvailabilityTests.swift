import CmuxSidebar
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The one check that enables Clear Agent State in the menu (both builders) and the palette (cm-128.2, Scenario 53).
@MainActor
struct ClearAgentStateAvailabilityTests {
    private func pill(_ key: String) -> SidebarStatusEntry { SidebarStatusEntry(key: key, value: "x") }

    @Test func anyAgentMarkOrAgentPillEnablesIt() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        #expect(!workspace.hasClearableAgentState, "a quiet workspace has nothing to clear")
        for (key, state) in [("claude_code", AgentHibernationLifecycleState.needsInput), ("codex", .running),
                             ("claude_code", .monitoring),
                             ("cmux.feed.attention:claude_code", .needsInput)] {
            workspace.agentLifecycleStatesByPanelId = [panel: [key: state]]
            #expect(workspace.hasClearableAgentState, "\(key) \(state) must enable it")
        }
        workspace.agentLifecycleStatesByPanelId = [:]
        for key in ["claude_code", "codex.session-1", "cmux.feed.attention:codex"] {
            workspace.statusEntries = [key: pill(key)]
            #expect(workspace.hasClearableAgentState, "an agent pill \(key) alone must enable it")
        }
    }

    @Test func nothingWorthClearingLeavesItDisabled() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId = [panel: ["claude_code": .unknown]]
        #expect(!workspace.hasClearableAgentState, "unknown, which a clear leaves, must not count as a mark")
        workspace.agentLifecycleStatesByPanelId = [panel: ["claude_code": .idle]]
        #expect(!workspace.hasClearableAgentState)
        workspace.agentLifecycleStatesByPanelId = [panel: ["manual": .running, "manual:build": .running]]
        #expect(!workspace.hasClearableAgentState, "a manual loading key is not agent state")
        workspace.agentLifecycleStatesByPanelId = [UUID(): ["claude_code": .needsInput]]
        #expect(!workspace.hasClearableAgentState, "state on a pane that is not the workspace's own (a Dock pane) draws nothing")
        workspace.agentLifecycleStatesByPanelId = [:]
        workspace.statusEntries = ["build": pill("build"), "remote.error": pill("remote.error")]
        #expect(!workspace.hasClearableAgentState, "his own set-status pills are not agent pills")
    }

    @Test func theTabManagerCheckOverASelectionIsTrueWhenAnyTargetHasState() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let quiet = manager.addWorkspace(select: false)
        let busy = manager.addWorkspace(select: false)
        let panel = try #require(busy.focusedPanelId)
        busy.agentLifecycleStatesByPanelId = [panel: ["claude_code": .running]]
        #expect(!manager.canClearAgentState(workspaceIds: [quiet.id]))
        #expect(manager.canClearAgentState(workspaceIds: [quiet.id, busy.id]))
        #expect(!manager.canClearAgentState(workspaceIds: [UUID()]))
    }

    // MARK: cm-128.6, Scenario 96: a Vault agent is clearable, a loader never

    private func rowSnapshot(_ workspace: Workspace) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let suite = "ClearAgentStateAvailabilityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: true,
            todoControlsEnabled: true, statusList: .cmuxFive, statusColorHexes: [:]
        ).makeSnapshot()
    }

    @Test func clearAgentStateTakesAVaultAgentAndKeepsALoader() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = ["my-vault-agent": .running, "manual:build": .running]
            #expect(harness.workspace.hasClearableAgentState, "a Vault agent's running mark can be cleared")
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            #expect(harness.marks["my-vault-agent"] == .unknown)
            #expect(harness.marks["manual:build"] == .running, "a loader is not agent state")
            #expect(rowSnapshot(harness.workspace).activeCodingAgentCount == 1, "only the loader still spins")
        }
    }

    @Test func aLoaderAloneIsNothingToClear() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["manual:build": .running]
        #expect(!workspace.hasClearableAgentState)
    }
}
