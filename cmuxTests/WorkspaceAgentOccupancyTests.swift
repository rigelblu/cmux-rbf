import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Occupancy decides whether an explicit Codex `/rename` claims the workspace
/// title or only its own tab. One rule serves both launch paths, so a terminal
/// session and an embedded panel can never return opposite verdicts about the
/// same workspace.
struct WorkspaceAgentOccupancyTests {
    /// The whole point of `cm-9`: a lone Codex session renames its workspace.
    ///
    /// `noteHookEvent` creates registry records with `workspaceID: nil`, and the
    /// terminal adapter deliberately admits them. Occupancy must therefore ask
    /// "is anyone else here?", never "am I present and alone?" — a claimant
    /// absent from its own workspace's session list is still the only occupant.
    @MainActor
    @Test func loneTerminalSessionWithUnboundWorkspaceClaimsWorkspace() {
        #expect(
            WorkspaceAgentOccupancy.isSoleAgentSurface(
                .terminalSession(sessionID: "lead"),
                terminalSessionIDs: [],
                embeddedPanelIDs: []
            )
        )
    }

    /// Rename behavior must not depend on launch path. A workspace holding one
    /// terminal Codex surface and one embedded Codex panel holds two agent
    /// surfaces: neither is sole, so neither claims the workspace title.
    @MainActor
    @Test func terminalAndEmbeddedAgreeWhenBothOccupyOneWorkspace() {
        let panelId = UUID()

        let terminalVerdict = WorkspaceAgentOccupancy.isSoleAgentSurface(
            .terminalSession(sessionID: "lead"),
            terminalSessionIDs: ["lead"],
            embeddedPanelIDs: [panelId]
        )
        let embeddedVerdict = WorkspaceAgentOccupancy.isSoleAgentSurface(
            .embeddedPanel(panelId: panelId),
            terminalSessionIDs: ["lead"],
            embeddedPanelIDs: [panelId]
        )

        #expect(terminalVerdict == embeddedVerdict)
        #expect(!terminalVerdict)
    }

    /// Each launch path is sole when it is genuinely the only agent surface.
    @MainActor
    @Test func eitherLaunchPathAloneClaimsWorkspace() {
        let panelId = UUID()

        #expect(
            WorkspaceAgentOccupancy.isSoleAgentSurface(
                .terminalSession(sessionID: "lead"),
                terminalSessionIDs: ["lead"],
                embeddedPanelIDs: []
            )
        )
        #expect(
            WorkspaceAgentOccupancy.isSoleAgentSurface(
                .embeddedPanel(panelId: panelId),
                terminalSessionIDs: [],
                embeddedPanelIDs: [panelId]
            )
        )
    }

    /// A sibling on the same launch path denies the claim, from either side.
    @MainActor
    @Test func siblingOnSameLaunchPathDeniesWorkspaceClaim() {
        let panelId = UUID()
        let siblingPanelId = UUID()

        #expect(
            !WorkspaceAgentOccupancy.isSoleAgentSurface(
                .terminalSession(sessionID: "lead"),
                terminalSessionIDs: ["lead", "sibling"],
                embeddedPanelIDs: []
            )
        )
        #expect(
            !WorkspaceAgentOccupancy.isSoleAgentSurface(
                .embeddedPanel(panelId: panelId),
                terminalSessionIDs: [],
                embeddedPanelIDs: [panelId, siblingPanelId]
            )
        )
    }

    /// Codex hook events identify their terminal surface before they can carry
    /// a workspace binding. Two such sessions in one workspace are still two
    /// occupants: the second rename must stay on its own tab.
    @MainActor
    @Test func unboundSiblingSessionsOnWorkspaceSurfacesDenyWorkspaceClaim() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let leadPanel = try #require(workspace.newTerminalSurface(inPane: pane, focus: true))
        let siblingPanel = try #require(workspace.newTerminalSurface(inPane: pane, focus: false))
        let registry = AgentChatSessionRegistry()

        registry.noteHookEvent(WorkstreamEvent(
            sessionId: "lead",
            hookEventName: .userPromptSubmit,
            source: "codex",
            surfaceId: leadPanel.id.uuidString
        ))
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: "sibling",
            hookEventName: .userPromptSubmit,
            source: "codex",
            surfaceId: siblingPanel.id.uuidString
        ))

        #expect(
            !WorkspaceAgentOccupancy.isSoleAgentSurface(
                .terminalSession(sessionID: "lead"),
                in: workspace,
                registry: registry
            )
        )
    }

    /// Session ids reach the two adapters from different sources — a registry
    /// record on one side, a Codex thread id on the other — and the terminal
    /// handler already folds case when matching them. Occupancy folds it too,
    /// so a claimant is never mistaken for its own sibling.
    @MainActor
    @Test func claimantMatchesItsOwnSessionIDRegardlessOfCase() {
        #expect(
            WorkspaceAgentOccupancy.isSoleAgentSurface(
                .terminalSession(sessionID: "LEAD"),
                terminalSessionIDs: ["lead"],
                embeddedPanelIDs: []
            )
        )
    }
}
