import Foundation

/// The surface asking to claim its workspace's title on an explicit agent
/// rename.
///
/// Terminal Codex sessions are tracked in `AgentChatSessionRegistry`; embedded
/// Codex panels are not tracked there at all. Naming both identities in one
/// type lets a single occupancy rule serve both launch paths, so rename
/// behavior never depends on how the session was started.
enum AgentRenameClaimant: Equatable {
    /// A Codex session tracked in `AgentChatSessionRegistry`.
    case terminalSession(sessionID: String)
    /// An embedded agent-session panel, untracked by the registry.
    case embeddedPanel(panelId: UUID)
}

/// Decides whether a renaming agent surface is alone in its workspace, and so
/// may claim the workspace title rather than only its own tab.
@MainActor
enum WorkspaceAgentOccupancy {
    /// Whether `claimant` is the only agent surface occupying its workspace.
    ///
    /// - Parameters:
    ///   - claimant: Identity of the surface asking to claim the title.
    ///   - terminalSessionIDs: Session ids of live registry-tracked agent
    ///     sessions bound to the workspace.
    ///   - embeddedPanelIDs: Panel ids of agent-session panels in the workspace.
    /// - Returns: `true` when nothing else in the workspace could claim it.
    ///
    /// The question is deliberately "is anyone *else* here?", never "am I here
    /// and alone?". A renaming terminal session whose registry record carries no
    /// workspace binding — every record `noteHookEvent` creates — is absent from
    /// `terminalSessionIDs` while still being the workspace's only occupant, and
    /// must still rename it. Requiring the claimant to prove its own presence
    /// denied exactly the case `cm-9` exists to fix.
    static func isSoleAgentSurface(
        _ claimant: AgentRenameClaimant,
        terminalSessionIDs: [String],
        embeddedPanelIDs: [UUID]
    ) -> Bool {
        let hasOtherTerminalSession = terminalSessionIDs.contains { sessionID in
            guard case .terminalSession(let ownSessionID) = claimant else { return true }
            return ownSessionID.caseInsensitiveCompare(sessionID) != .orderedSame
        }
        if hasOtherTerminalSession { return false }
        return !embeddedPanelIDs.contains { panelID in
            guard case .embeddedPanel(let ownPanelID) = claimant else { return true }
            return ownPanelID != panelID
        }
    }

    /// Reads `workspace`'s occupancy from the places that know it — live
    /// registry sessions bound either to the workspace or one of its terminal
    /// surfaces, plus its embedded agent-session panels — and decides whether
    /// `claimant` is alone. Surface binding matters because Codex hook events
    /// identify their terminal before workspace backfill completes. Both
    /// adapters call this, each passing only its own identity, so neither can
    /// invent its own rule.
    ///
    /// - Parameters:
    ///   - claimant: Identity of the surface asking to claim the title.
    ///   - workspace: Workspace whose title is being claimed.
    ///   - registry: Agent session registry, or `nil` when unavailable.
    /// - Returns: `true` when nothing else in the workspace could claim it.
    static func isSoleAgentSurface(
        _ claimant: AgentRenameClaimant,
        in workspace: Workspace,
        registry: AgentChatSessionRegistry?
    ) -> Bool {
        var terminalSessionIDs = Set(
            registry?.liveSessionIDs(workspaceID: workspace.id.uuidString) ?? []
        )
        if let registry {
            for (panelID, panel) in workspace.panels where panel is TerminalPanel {
                if let session = registry.liveSession(surfaceID: panelID.uuidString) {
                    terminalSessionIDs.insert(session.sessionID)
                }
            }
        }

        return isSoleAgentSurface(
            claimant,
            terminalSessionIDs: Array(terminalSessionIDs),
            embeddedPanelIDs: workspace.panels.compactMap { id, panel in
                panel is AgentSessionPanel ? id : nil
            }
        )
    }
}
