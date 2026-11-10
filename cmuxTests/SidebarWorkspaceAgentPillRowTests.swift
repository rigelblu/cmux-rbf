import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-128.6 (Scenario 90, Tom's item 10): cmux's own agent pills leave the row, his `set-status` pills stay, and every other
/// reader of the pills still sees all of them.
@MainActor
@Suite(.serialized)
struct SidebarWorkspaceAgentPillRowTests {
    private func pill(_ key: String, _ value: String) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value)
    }

    /// The four entries of Scenario 90. `claude_code` is an allowed agent key, which upstream shows only while its PID has
    /// a live pane, so the workspace registers one; `codex.s1` and the Feed slot sit outside that set and always pass it.
    private func workspaceWithTheFourPills() throws -> Workspace {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.agentPIDPanelIdsByKey["claude_code"] = panelId
        workspace.statusEntries = [
            "claude_code": pill("claude_code", "Running"),
            "codex.s1": pill("codex.s1", "Needs input"),
            "cmux.feed.attention:claude_code": pill("cmux.feed.attention:claude_code", "Needs input"),
            "deploy": pill("deploy", "green"),
        ]
        return workspace
    }

    private func rowSnapshot(_ workspace: Workspace) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let suite = "SidebarWorkspaceAgentPillRowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: true,
            todoControlsEnabled: true, statusList: WorkspaceStatusEntrancesTests.hisList, statusColorHexes: [:]
        ).makeSnapshot()
    }

    @Test func theRowDropsCmuxAgentPillsAndKeepsHis() throws {
        let workspace = try workspaceWithTheFourPills()
        let keys = rowSnapshot(workspace).metadataEntries.map(\.key)
        #expect(keys == ["deploy"], "the row's lines under the title: \(keys)")
    }

    /// The filter sits at the snapshot factory only: the store and its other readers (socket `list_status`, `sidebar_state`,
    /// `cmux top`, `list-status`, the automations' `workspace.tag`) all read this function.
    @Test func theStoreAndEveryOtherReaderStillSeeAllFourPills() throws {
        let workspace = try workspaceWithTheFourPills()
        _ = rowSnapshot(workspace)
        let keys = Set(workspace.sidebarStatusEntriesInDisplayOrder().map(\.key))
        #expect(keys == ["claude_code", "codex.s1", "cmux.feed.attention:claude_code", "deploy"], "\(keys)")
        #expect(workspace.statusEntries.count == 4)
    }

    /// The check reads the part of a key before its first dot, so a pill of his under `pi.x` or `amp.x` leaves too; one that
    /// merely contains an agent's name does not.
    @Test func aKeyIsToldFromHisByItsHead() throws {
        let workspace = Workspace()
        workspace.statusEntries = [
            "pi.x": pill("pi.x", "a"), "amp.build": pill("amp.build", "b"),
            "deploy.claude_code": pill("deploy.claude_code", "c"), "deploy": pill("deploy", "d"),
        ]
        let keys = rowSnapshot(workspace).metadataEntries.map(\.key)
        // The row's order is behaviour: the filter keeps the display order, which the base gave as
        // ["deploy", "amp.build", "pi.x", "deploy.claude_code"].
        #expect(keys == ["deploy", "deploy.claude_code"], "\(keys)")
    }
}
