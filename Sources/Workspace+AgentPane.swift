import Bonsplit
import CmuxBrowser
import Foundation

// cmux-rbf #cm-126.3: the Agent Pane, a browser pane one agent's terminal owns.

extension Workspace {

    // MARK: - Finding panes

    /// Every browser pane in this workspace, live or still a restore
    /// placeholder, in Bonsplit's pane order, as the Agent Pane rules read it. A
    /// placeholder carries its whole saved record, so its owner and kind are read
    /// from there, as `designFocusCandidatePanes` reads the owner.
    func agentPaneCandidates(inPane onlyPane: PaneID? = nil) -> [AgentPaneMark.Candidate] {
        let paneIds = onlyPane.map { [$0] } ?? bonsplitController.allPaneIds
        var candidates: [AgentPaneMark.Candidate] = []
        for paneId in paneIds {
            for tab in bonsplitController.tabs(inPane: paneId) {
                guard let panelId = panelIdFromSurfaceId(tab.id) else { continue }
                if let browser = panels[panelId] as? BrowserPanel {
                    candidates.append(.init(panelID: panelId, owner: browser.ownerTerminalSurfaceId, kind: browser.ownedKind))
                } else if let record = (panels[panelId] as? DeferredBrowserPanel)?.sessionPanelSnapshot.browser {
                    candidates.append(.init(
                        panelID: panelId,
                        owner: record.ownerTerminalSurfaceId,
                        kind: record.ownedKind.flatMap(BrowserOwnedKind.init(rawValue:))
                    ))
                }
            }
        }
        return candidates
    }

    /// The panes the terminal whose stable id is `owner` owns in this
    /// workspace, in pane order. A Figma pane the same terminal owns through
    /// `cm-73.45` has no kind, so it is never one.
    func agentPanes(ownedBy owner: UUID) -> [UUID] {
        AgentPaneMark.panes(ownedBy: owner, among: agentPaneCandidates())
    }

    /// The live terminal in this workspace whose stable id is `stableID`, or
    /// `nil` when it closed or moved to another workspace.
    func agentPaneOwnerTerminal(stableID: UUID) -> TerminalPanel? {
        panels.values.lazy.compactMap { $0 as? TerminalPanel }.first { $0.stableSurfaceId == stableID }
    }

    // MARK: - The one action path

    /// Opens the terminal's Agent Pane as a new split of its own pane, showing `url`,
    /// without focus or a hand-off to the system browser. The owner and kind go
    /// in through `newBrowserSplit(owner:)`, so the tab is made with the mark.
    @discardableResult
    func openAgentPane(beside terminalID: UUID, url: URL, owner: UUID) -> BrowserPanel? {
        newBrowserSplit(
            from: terminalID,
            orientation: .horizontal,
            url: url,
            focus: false,
            creationPolicy: .automationPreload,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
            owner: BrowserPaneOwner(terminalStableID: owner, kind: .agentPane)
        )
    }

    /// Shows `url` in the Agent Pane `panelId`, materializing a restore placeholder
    /// first. Selects nothing and moves no focus.
    @discardableResult
    func navigateAgentPane(_ panelId: UUID, to url: URL) -> BrowserPanel? {
        let browser: BrowserPanel?
        if let deferred = panels[panelId] as? DeferredBrowserPanel {
            browser = materializeDeferredBrowserPanel(deferred)
        } else {
            browser = panels[panelId] as? BrowserPanel
        }
        guard let browser else { return nil }
        browser.navigate(to: url)
        return browser
    }

    // MARK: - Held while Design Focus is on

    /// Keeps `url` as the latest page for the terminal `owner`, to show when
    /// Design Focus ends. In memory only; latest wins.
    func holdAgentPaneUpdate(owner: UUID, url: URL) {
        heldAgentPaneUpdates[owner] = url
    }

    /// Runs each held page through the same open-or-steer path a `show` takes,
    /// then empties the store. An app quit drops them all, so nothing opens while
    /// the app quits; a page whose terminal left this workspace is dropped.
    func applyHeldAgentPaneUpdates(reason: String) {
        let held = heldAgentPaneUpdates
        heldAgentPaneUpdates = [:]
        guard reason != "appQuit" else { return }
        for (owner, url) in held {
            guard let terminal = agentPaneOwnerTerminal(stableID: owner) else { continue }
            switch AgentPaneMark.placement(panes: agentPanes(ownedBy: owner)) {
            case .open:
                openAgentPane(beside: terminal.id, url: url, owner: owner)
            case .navigate(let agentPane, _):
                navigateAgentPane(agentPane, to: url)
            }
        }
    }

    // MARK: - Never covered

    /// `nil` when `pane` holds an Agent Pane, else `pane`: the one check every
    /// entrance that would add a tab to "the pane on the right" calls, so it
    /// splits instead and the Agent Pane stays in front, alone in its pane.
    func agentPaneFreePane(_ pane: PaneID?) -> PaneID? {
        guard let pane else { return nil }
        return AgentPaneMark.paneHoldsAgentPane(agentPaneCandidates(inPane: pane)) ? nil : pane
    }
}
