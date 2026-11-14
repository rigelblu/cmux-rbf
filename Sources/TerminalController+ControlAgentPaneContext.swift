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
    func controlAgentPaneCheck(surfaceID: UUID, url: URL) -> ControlAgentPaneCheck {
        controlAgentPaneCheck(surfaceID: surfaceID, url: url, defaults: .standard)
    }

    /// The same, with the defaults the browser settings are read from, so a test
    /// never reads or flips Tom's own.
    func controlAgentPaneCheck(surfaceID: UUID, url: URL, defaults: UserDefaults) -> ControlAgentPaneCheck {
        guard let workspace = agentPaneWorkspace(containing: surfaceID) else {
            return .refused(DockSplitStore.liveStores.contains { $0.containsPanel(surfaceID) }
                ? .inDock
                : .notFound(surfaceID: surfaceID))
        }
        guard let terminal = workspace.panels[surfaceID] as? TerminalPanel else {
            let type = workspace.panels[surfaceID]?.panelType.rawValue ?? "surface"
            return .refused(.notTerminal(surfaceID: surfaceID, type: type))
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
            url: url
        ))
    }

    /// The one call that changes anything.
    func controlAgentPaneApply(_ plan: ControlAgentPanePlan) -> ControlAgentPaneApplied? {
        guard let workspace = agentPaneWorkspace(containing: plan.terminalID) else { return nil }
        let agentPane: UUID?
        let others: Int
        let action: ControlAgentPaneApplied.Action
        switch plan.action {
        case .open:
            guard let panel = workspace.openAgentPane(
                beside: plan.terminalID, url: plan.url, owner: plan.ownerStableID
            ) else { return nil }
            agentPane = panel.id
            others = 0
            action = .opened
        case .navigate(let agentPaneID, let count):
            guard workspace.navigateAgentPane(agentPaneID, to: plan.url) != nil else { return nil }
            agentPane = agentPaneID
            others = count
            action = .navigated
        case .hold(let agentPaneID, let count):
            workspace.holdAgentPaneUpdate(owner: plan.ownerStableID, url: plan.url)
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
            url: plan.url,
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
