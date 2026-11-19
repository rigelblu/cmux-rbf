import CmuxControlSocket
import CmuxSettings
import Foundation

// cmux-rbf #cm-126.3: the app's side of `agent_pane.show` and `agent_pane.list`.

/// On the main actor because the check reads, and the apply changes, Bonsplit's
/// layout, which lives there (skill `cmux-socket-policy`). Neither asks for
/// focus or raises a window: the split is made with `focus: false`, and steering
/// selects nothing.
extension TerminalController: ControlAgentPaneContext {

    /// Read-only. In order: the caller's terminal and its workspace, the page
    /// (scheme, Figma address, the URL allowlist, the insecure-HTTP rule), the
    /// browser setting, then Design Focus and the caller's panes. Without the
    /// allowlist and insecure-HTTP checks here, `BrowserPanel.navigate` would stop
    /// a blocked page inside itself and still answer `navigated`, or raise the
    /// insecure-connection sheet on Tom's window.
    func controlAgentPaneCheck(surfaceID: UUID, url: URL, agent: String?) -> ControlAgentPaneCheck {
        controlAgentPaneCheck(surfaceID: surfaceID, url: url, agent: agent, defaults: .standard)
    }

    /// The same, with the defaults the browser settings are read from, so a test
    /// never reads or flips Tom's own.
    func controlAgentPaneCheck(
        surfaceID: UUID, url: URL, agent: String? = nil, defaults: UserDefaults // cmux-rbf #cm-126.15
    ) -> ControlAgentPaneCheck {
        let workspace: Workspace
        let terminal: TerminalPanel
        switch agentPaneCaller(surfaceID: surfaceID) {
        case .refused(let refusal): return .refused(refusal)
        case .found(let foundWorkspace, let foundTerminal): (workspace, terminal) = (foundWorkspace, foundTerminal)
        }
        switch AgentPaneMark.refusal(for: url) {
        case .badScheme: return .refused(.badScheme)
        case .figmaAddress: return .refused(.figmaAddress)
        case nil: break
        }
        let policy = BrowserURLAllowlistPolicy(defaults: defaults)
        let allowed = url.isFileURL ? policy.allowsTrustedInternalURL(url) : policy.allows(url)
        guard allowed else {
            return .refused(.urlBlocked(message: String(
                localized: policy.isManaged
                    ? "cli.browser.error.urlBlockedByPolicy"
                    : "cli.browser.error.urlBlockedByUserPolicy",
                defaultValue: policy.isManaged
                    ? "Blocked by your organization's browser policy"
                    : "Blocked by the embedded-browser URL policy"
            )))
        }
        if browserShouldBlockInsecureHTTPURL(url, defaults: defaults) {
            return .refused(.insecureHTTP(host: url.host ?? ""))
        }
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else {
            return .refused(.browserOff)
        }
        let owner = terminal.stableSurfaceId
        let panes = workspace.agentPanes(ownedBy: owner)
        let action: ControlAgentPanePlan.Action
        if workspace.isDesignFocusActive {
            action = .hold(panelID: panes.first, others: max(panes.count - 1, 0))
        } else {
            switch AgentPaneMark.placement(panes: panes) {
            case .open: action = .open
            case .navigate(let agentPane, let others): action = .navigate(panelID: agentPane, others: others)
            }
        }
        return .ready(ControlAgentPanePlan(
            action: action,
            workspaceID: workspace.id,
            terminalID: terminal.id,
            ownerStableID: owner,
            url: url,
            agent: agent
        ))
    }

    /// The caller's workspace and terminal, or why neither can own an Agent Pane.
    private enum AgentPaneCaller {
        case found(Workspace, TerminalPanel)
        case refused(ControlAgentPaneRefusal)
    }

    private func agentPaneCaller(surfaceID: UUID) -> AgentPaneCaller {
        guard let workspace = agentPaneWorkspace(containing: surfaceID) else {
            return .refused(DockSplitStore.liveStores.contains { $0.containsPanel(surfaceID) }
                ? .inDock
                : .notFound(surfaceID: surfaceID))
        }
        guard let terminal = workspace.panels[surfaceID] as? TerminalPanel else {
            let type = workspace.panels[surfaceID]?.panelType.rawValue ?? "surface"
            return .refused(.notTerminal(surfaceID: surfaceID, type: type))
        }
        return .found(workspace, terminal)
    }

    // MARK: - clear (cm-126.14)

    func controlAgentPaneClearCheck(surfaceID: UUID) -> ControlAgentPaneCheck {
        controlAgentPaneClearCheck(surfaceID: surfaceID, defaults: .standard)
    }

    /// The same, with the defaults the browser settings are read from, so a test never reads or flips Tom's own.
    /// In order: the caller, its first Agent Pane (none: nothing to clear), the same local-file and browser
    /// settings `show` applies to a `file://` page, then Design Focus (hold) or an already-cleared pane (no change).
    func controlAgentPaneClearCheck(surfaceID: UUID, defaults: UserDefaults) -> ControlAgentPaneCheck {
        let workspace: Workspace
        let terminal: TerminalPanel
        switch agentPaneCaller(surfaceID: surfaceID) {
        case .refused(let refusal): return .refused(refusal)
        case .found(let foundWorkspace, let foundTerminal): (workspace, terminal) = (foundWorkspace, foundTerminal)
        }
        let owner = terminal.stableSurfaceId
        let panes = workspace.agentPanes(ownedBy: owner)
        let agentPane = panes.first
        let others = max(panes.count - 1, 0)
        var heldShow = false
        if case .show? = workspace.heldAgentPaneUpdates[owner] { heldShow = true }
        // Nothing to clear without a pane, except a post held for a pane not yet open: the clear retires it (latest wins).
        if agentPane == nil, !heldShow { return .refused(.noAgentPane) }
        guard let folder = workspace.agentPaneClearedFolder else {
            return .refused(.urlBlocked(message: "cmux has no folder to keep the cleared page in"))
        }
        let page = agentPane.map { AgentPaneMark.clearedPageURL(panelID: $0, in: folder) } ?? folder
        let policy = BrowserURLAllowlistPolicy(defaults: defaults)
        guard policy.allowsTrustedInternalURL(page) else {
            return .refused(.urlBlocked(message: String(
                localized: policy.isManaged
                    ? "cli.browser.error.urlBlockedByPolicy"
                    : "cli.browser.error.urlBlockedByUserPolicy",
                defaultValue: policy.isManaged
                    ? "Blocked by your organization's browser policy"
                    : "Blocked by the embedded-browser URL policy"
            )))
        }
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return .refused(.browserOff) }
        let action: ControlAgentPanePlan.Action
        if let agentPane, workspace.agentPaneIsCleared(agentPane), !heldShow {
            // Already cleared, and no held page to retire: a no-op, even under Design Focus.
            action = .alreadyCleared(panelID: agentPane, others: others)
        } else if workspace.isDesignFocusActive {
            action = .holdClear(panelID: agentPane, others: others)
        } else if let agentPane {
            action = .clear(panelID: agentPane, others: others)
        } else {
            return .refused(.noAgentPane)
        }
        return .ready(ControlAgentPanePlan(
            action: action,
            workspaceID: workspace.id,
            terminalID: terminal.id,
            ownerStableID: owner,
            url: page
        ))
    }

    /// The one call that changes anything.
    func controlAgentPaneApply(_ plan: ControlAgentPanePlan) -> ControlAgentPaneApplied? {
        guard let workspace = agentPaneWorkspace(containing: plan.terminalID) else { return nil }
        let agentPane: UUID?
        let others: Int
        let action: ControlAgentPaneApplied.Action
        var appliedURL: URL? = plan.url
        switch plan.action {
        case .open:
            guard let panel = workspace.openAgentPane(
                beside: plan.terminalID, url: plan.url, owner: plan.ownerStableID, agent: plan.agent
            ) else { return nil }
            agentPane = panel.id
            others = 0
            action = .opened
        case .navigate(let agentPaneID, let count):
            guard workspace.navigateAgentPane(agentPaneID, to: plan.url, agent: plan.agent) != nil else { return nil }
            agentPane = agentPaneID
            others = count
            action = .navigated
        case .hold(let agentPaneID, let count):
            workspace.holdAgentPaneUpdate(owner: plan.ownerStableID, url: plan.url, agent: plan.agent)
            agentPane = agentPaneID
            others = count
            action = .heldDesignFocus
        case .clear(let agentPaneID, let count):
            guard workspace.clearAgentPane(agentPaneID) != nil else { return nil }
            agentPane = agentPaneID
            others = count
            action = .cleared
        case .alreadyCleared(let agentPaneID, let count):
            agentPane = agentPaneID
            others = count
            action = .alreadyCleared
        case .holdClear(let agentPaneID, let count):
            workspace.holdAgentPaneClear(owner: plan.ownerStableID)
            if agentPaneID == nil { appliedURL = nil } // no pane yet, so no cleared page to name
            agentPane = agentPaneID
            others = count
            action = .heldDesignFocus
        }
        return ControlAgentPaneApplied(
            action: action,
            surfaceID: agentPane,
            paneID: agentPane.flatMap { workspace.paneId(forPanelId: $0)?.id },
            workspaceID: workspace.id,
            ownerSurfaceID: workspace.agentPaneOwnerTerminal(stableID: plan.ownerStableID)?.id,
            ownerStableID: plan.ownerStableID,
            url: appliedURL,
            others: others
        )
    }

    func controlAgentPaneList(workspaceID: UUID?) -> [ControlAgentPaneSummary]? {
        let workspaces = agentPaneAllWorkspaces()
        let chosen: [Workspace]
        if let workspaceID {
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return nil }
            chosen = [workspace]
        } else {
            chosen = workspaces
        }
        return chosen.flatMap { workspace in
            let candidates = workspace.agentPaneCandidates()
            return candidates.compactMap { candidate -> ControlAgentPaneSummary? in
                guard AgentPaneMark.isAgentPaneKind(owner: candidate.owner, kind: candidate.kind),
                      let owner = candidate.owner else { return nil }
                let url: String?
                if let browser = workspace.panels[candidate.panelID] as? BrowserPanel {
                    url = (browser.currentURL ?? browser.webView.url)?.absoluteString
                } else {
                    url = (workspace.panels[candidate.panelID] as? DeferredBrowserPanel)?
                        .sessionPanelSnapshot.browser?.urlString
                }
                return ControlAgentPaneSummary(
                    surfaceID: candidate.panelID,
                    paneID: workspace.paneId(forPanelId: candidate.panelID)?.id,
                    workspaceID: workspace.id,
                    ownerSurfaceID: workspace.agentPaneOwnerTerminal(stableID: owner)?.id,
                    ownerStableID: owner,
                    url: url,
                    others: max(AgentPaneMark.panes(ownedBy: owner, among: candidates).count - 1, 0)
                )
            }
        }
    }

    // MARK: - Where

    /// Every workspace in every main window, the active tab manager's first.
    private func agentPaneAllWorkspaces() -> [Workspace] {
        var managers: [TabManager] = []
        if let tabManager { managers.append(tabManager) }
        if let app = AppDelegate.shared {
            for summary in app.listMainWindowSummaries() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId),
                      !managers.contains(where: { $0 === manager }) else { continue }
                managers.append(manager)
            }
        }
        return managers.flatMap(\.tabs)
    }

    /// The workspace holding `surfaceID` now; never one passed in, because a
    /// shell's `CMUX_WORKSPACE_ID` goes stale when Tom moves the tab.
    private func agentPaneWorkspace(containing surfaceID: UUID) -> Workspace? {
        agentPaneAllWorkspaces().first { $0.panels[surfaceID] != nil && $0.surfaceIdFromPanelId(surfaceID) != nil }
    }
}
