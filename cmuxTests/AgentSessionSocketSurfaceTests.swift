import Bonsplit
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AgentSessionSocketSurfaceTests {
    @Test
    func testPanelTypeParserAcceptsAgentSessionSpellings() {
        let controller = TerminalController.shared

        for rawValue in [
            "agentSession", "agent-session", "agent_session", "agent session", "agentsession",
        ] {
            expectEqual(
                controller.v2PanelType(["type": rawValue], "type"),
                .agentSession,
                "Expected \(rawValue) to parse as an agent session surface"
            )
        }
    }

    @Test
    func testWorkspaceCreatesAgentSessionSurfaceWithProviderAndRenderer() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .opencode,
                rendererKind: .solid,
                workingDirectory: "/tmp",
                focus: true
            )
        )

        expectEqual(panel.panelType, .agentSession)
        expectEqual(panel.initialProviderID, .opencode)
        expectEqual(panel.rendererKind, .solid)
        expectEqual(panel.workingDirectory, "/tmp")
        expectEqual(workspace.panelDirectories[panel.id], "/tmp")
        expectEqual(workspace.focusedPanelId, panel.id)
    }

    @Test
    func testMovedAgentSessionRebindsTerminalCommandRoutingToDestinationWorkspace() throws {
        let source = Workspace()
        let destination = Workspace()
        let sourcePane = try #require(source.bonsplitController.focusedPaneId)
        let destinationPane = try #require(destination.bonsplitController.focusedPaneId)
        let panel = try #require(
            source.newAgentSessionSurface(
                inPane: sourcePane,
                rendererKind: .react,
                workingDirectory: "/tmp",
                focus: false
            )
        )

        #expect(panel.onRunCommand != nil)
        let detached = try #require(source.detachSurface(panelId: panel.id))
        #expect(panel.onRunCommand == nil)

        #expect(
            destination.attachDetachedSurface(
                detached,
                inPane: destinationPane,
                focus: false
            ) == panel.id
        )
        #expect(panel.workspaceId == destination.id)
        #expect(panel.onRunCommand != nil)

        let result = try #require(try panel.onRunCommand?("pwd"))
        let terminalPanelID = try #require(
            (result["terminalPanelId"] as? String).flatMap(UUID.init(uuidString:))
        )
        #expect(destination.terminalPanel(for: terminalPanelID) != nil)
        #expect(source.terminalPanel(for: terminalPanelID) == nil)
    }

    @Test
    func testAgentSessionCommandTerminalDoesNotArmDeferredFocusRepair() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)
        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                rendererKind: .react,
                workingDirectory: "/tmp",
                focus: true
            )
        )

        let result = try #require(try panel.onRunCommand?("pwd"))
        let terminalPanelID = try #require(
            (result["terminalPanelId"] as? String).flatMap(UUID.init(uuidString:))
        )
        let terminalTabID = try #require(workspace.surfaceIdFromPanelId(terminalPanelID))

        #expect(workspace.focusedPanelId == panel.id)
        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id != terminalTabID)

        // Simulate a later Bonsplit selection after the background terminal was
        // created. The agent-command path must leave no queued focus repair that
        // can overwrite this newer selection on subsequent main-queue turns.
        workspace.bonsplitController.selectTab(terminalTabID)
        await Task.yield()
        await Task.yield()

        #expect(workspace.bonsplitController.selectedTab(inPane: paneId)?.id == terminalTabID)
        #expect(workspace.focusedPanelId == terminalPanelID)
    }

    @Test
    func testWorkspaceSessionSnapshotPersistsAgentSessionWorkingDirectory() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let paneId = try #require(workspace.bonsplitController.focusedPaneId)

        let panel = try #require(
            workspace.newAgentSessionSurface(
                inPane: paneId,
                providerID: .codex,
                rendererKind: .react,
                workingDirectory: "/tmp/cmux-agent-session-cwd",
                focus: true
            )
        )

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let panelSnapshot = try #require(snapshot.panels.first { $0.id == panel.id })
        expectEqual(panelSnapshot.directory, "/tmp/cmux-agent-session-cwd")
        expectEqual(panelSnapshot.agentSession?.workingDirectory, "/tmp/cmux-agent-session-cwd")
    }

    /// `surface.split` hands CLI callers the terminal-surface UUID (the panel
    /// id), and the Codex Teams bridge forwards exactly that id into
    /// `agent.session_title.seed`. The seed must therefore accept a panel id,
    /// not only a bonsplit tab id.
    @Test
    func testSeedResolvesTerminalSurfaceUUIDToItsPanel() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        let panel = try #require(workspace.focusedTerminalPanel)
        // Fixture invariants: the id under test is a genuine panel id and is
        // NOT a key of the bonsplit surface-id map, so the only way the seed
        // can resolve it is by treating it as a panel id.
        try #require(workspace.panels[panel.id] != nil)
        try #require(workspace.panelIdFromSurfaceId(TabID(uuid: panel.id)) == nil)

        // Control: seeding with the bonsplit tab id succeeds on any build,
        // proving workspace routing, method dispatch, and the title write
        // path all work — so a failure below can only be the id-space bug.
        let tabId = try #require(workspace.surfaceIdFromPanelId(panel.id))
        let controlResponse = try handleV2Request(
            method: "agent.session_title.seed",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": tabId.uuid.uuidString,
                "title": "control seed",
            ]
        )
        try #require(
            controlResponse["ok"] as? Bool == true,
            "control seed via bonsplit tab id failed — fixture broken: \(controlResponse)"
        )
        try #require(workspace.panelCustomTitles[panel.id] == "control seed")

        // Target: the same request carrying the terminal-surface UUID that
        // `surface.split` returned.
        let response = try handleV2Request(
            method: "agent.session_title.seed",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
                "title": "panel-id seed",
            ]
        )
        #expect(
            response["ok"] as? Bool == true,
            "seed rejected the terminal-surface UUID surface.split returns: \(response)"
        )
        let result = try #require(
            response["result"] as? [String: Any],
            "expected a result envelope, got: \(response)"
        )
        #expect(result["panel_applied"] as? Bool == true)
        #expect(workspace.panelCustomTitles[panel.id] == "panel-id seed")
    }

    private func handleV2Request(
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let line = try #require(String(data: data, encoding: .utf8))
        let responseLine = TerminalController.shared.handleSocketLine(line)
        let responseData = try #require(responseLine.data(using: .utf8))
        return try #require(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }
}
