import Bonsplit
import CmuxBrowser
import Foundation

// cmux-rbf #cm-126.3: the Agent Pane, a browser pane one agent's terminal owns.

/// What a held update will do when Design Focus ends: show a page, or clear (cmux-rbf #cm-126.14).
enum HeldAgentPaneUpdate: Equatable {
    case show(URL, agent: String?) // cmux-rbf #cm-126.15: the held page keeps the agent its show sent
    case clear
}

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
    func openAgentPane(beside terminalID: UUID, url: URL, owner: UUID, agent: String? = nil) -> BrowserPanel? {
        guard let browser = newBrowserSplit(
            from: terminalID,
            orientation: .horizontal,
            url: url,
            focus: false,
            creationPolicy: .automationPreload,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
            // cmux-rbf #cm-126.15: the agent is on the pane before its first caption, so a new Agent Pane opens with its name.
            owner: BrowserPaneOwner(
                terminalStableID: owner,
                kind: .agentPane,
                agent: agentPaneAgentToRecord(sent: agent, saved: nil, terminalPanelId: terminalID)
            )
        ) else { return nil }
        browser.agentPaneLastPostURL = url
        agentPaneClearedFlags[browser.id] = false
        return browser
    }

    /// Shows `url` in the Agent Pane `panelId`, materializing a restore placeholder
    /// first. Selects nothing and moves no focus.
    @discardableResult
    func navigateAgentPane(
        _ panelId: UUID,
        to url: URL,
        isClear: Bool = false,
        agent: String? = nil
    ) -> BrowserPanel? {
        let browser: BrowserPanel?
        if let deferred = panels[panelId] as? DeferredBrowserPanel {
            browser = materializeDeferredBrowserPanel(deferred)
        } else {
            browser = panels[panelId] as? BrowserPanel
        }
        guard let browser else { return nil }
        let before = browser.webView.url // cmux-rbf (#cm-126.3, #cm-142.1)
        browser.navigate(to: url)
        // cmux-rbf (#cm-142.1): upstream's #18318 moved the web view's URL observer onto a later main-actor turn. The
        // Agent Pane's own steer publishes the address WebKit took at once, as that observer did before, so a clear, a
        // move or the next show in the same turn reads the page it steered to (#cm-126.3, #cm-126.14). Only a change is
        // published, as that observer fired only on a change: a navigate that loads nothing (a remote workspace's queue,
        // a cloud address) leaves the web view on the old page, and the address those paths set stands. Known gap: a
        // steer to the address the web view already took earlier in the same turn, by a load nothing published,
        // publishes nothing, so the pane's address trails until the load commits.
        if !browser.isMainFrameProvisionalNavigationActive, let taken = browser.webView.url, taken != before {
            browser.publishObservedDocumentURL(taken)
        }
        if !isClear { browser.agentPaneLastPostURL = url }
        agentPaneClearedFlags[browser.id] = isClear
        // cmux-rbf #cm-126.15: a show records its agent and then refreshes the caption, which names the pane for it; a clear
        // touches neither.
        if !isClear, let owner = browser.ownerTerminalSurfaceId {
            browser.ownerAgent = agentPaneAgentToRecord(
                sent: agent, saved: browser.ownerAgent, terminalPanelId: agentPaneOwnerTerminal(stableID: owner)?.id
            )
            refreshAgentPaneCaption(panelId: browser.id)
        }
        return browser
    }

    /// Sets a moved or restored Agent Pane's cleared flag from the page it shows (in the cleared folder: cleared), then
    /// refreshes its caption, which a restore or a move into this workspace has not set yet (cmux-rbf #cm-126.14; the
    /// workspace a pane came from dropped its flag).
    func deriveAgentPaneCleared(panelId: UUID) {
        guard let candidate = agentPaneCandidates().first(where: { $0.panelID == panelId }),
              AgentPaneMark.isAgentPaneKind(owner: candidate.owner, kind: candidate.kind) else { return }
        agentPaneClearedFlags[panelId] = agentPaneClearedFolder.map {
            AgentPaneMark.isCleared(url: agentPaneShownURL(panelId), clearedFolderURL: $0)
        } ?? false
        refreshAgentPaneCaption(panelId: panelId)
    }

    // MARK: - Cleared (cm-126.14)

    static func agentPaneClearedFolderURL(
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBundleId = (trimmed?.isEmpty == false ? trimmed : nil) ?? "com.cmuxterm.app"
        return appSupport
            .appendingPathComponent(resolvedBundleId, isDirectory: true)
            .appendingPathComponent(AgentPaneMark.clearedPagesSubfolder, isDirectory: true)
    }

    /// Where this workspace writes cleared pages: a test's own folder when set, else the app's.
    var agentPaneClearedFolder: URL? {
        agentPaneClearedFolderOverride ?? Self.agentPaneClearedFolderURL()
    }

    /// The page the Agent Pane shows now, or what a restore placeholder will show; `nil` when none.
    func agentPaneShownURL(_ panelId: UUID) -> URL? {
        if let browser = panels[panelId] as? BrowserPanel {
            return browser.currentURL ?? browser.webView.url
        }
        return (panels[panelId] as? DeferredBrowserPanel)?
            .sessionPanelSnapshot.browser?.urlString.flatMap(URL.init(string:))
    }

    /// Clears an Agent Pane: writes its cleared page (one file named by the pane's id, overwritten each
    /// time, with a link to the page shown until now) and takes `show`'s steer path to it. A pane that is
    /// already cleared stays as it is, so its link still points at the post. `nil` when the page can't be
    /// written or the pane isn't there. cmux-rbf #cm-126.14.
    @discardableResult
    func clearAgentPane(_ panelId: UUID) -> BrowserPanel? {
        if agentPaneIsCleared(panelId) {
            return panels[panelId] as? BrowserPanel
        }
        guard let folder = agentPaneClearedFolder else { return nil }
        let page = AgentPaneMark.clearedPageURL(panelID: panelId, in: folder)
        let html = AgentPaneMark.clearedPageHTML(
            title: String(localized: "agentPane.cleared.title", defaultValue: "Nothing to answer right now"),
            linkText: String(localized: "agentPane.cleared.link", defaultValue: "The last post"),
            previousURL: AgentPaneMark.linkTarget(
                shown: agentPaneShownURL(panelId),
                recordedPost: (panels[panelId] as? BrowserPanel)?.agentPaneLastPostURL,
                pageLink: { AgentPaneMark.clearedPageLink(at: self.agentPaneShownURL(panelId)) },
                clearedFolderURL: folder
            )
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(html.utf8).write(to: page, options: .atomic)
        } catch {
            return nil
        }
        return navigateAgentPane(panelId, to: page, isClear: true)
    }

    /// Deletes a closed Agent Pane's cleared page when Tom closed it (see
    /// ``AgentPaneMark/removesClearedPage(origin:closePanel:appIsTerminating:)``).
    func removeClearedPageIfClosedByTom(
        panelId: UUID,
        origin: String,
        closePanel: Bool,
        appIsTerminating: Bool? = nil
    ) {
        guard AgentPaneMark.removesClearedPage(
            origin: origin, closePanel: closePanel,
            appIsTerminating: appIsTerminating ?? (AppDelegate.shared?.isTerminatingApp == true)
        ), let folder = agentPaneClearedFolder else { return }
        try? FileManager.default.removeItem(at: AgentPaneMark.clearedPageURL(panelID: panelId, in: folder))
    }

    /// Whether the Agent Pane shows its cleared page: a clear sets it, a show unsets it, a restore or a move derives it
    /// from the page. A pane with no flag is not cleared.
    func agentPaneIsCleared(_ panelId: UUID) -> Bool {
        agentPaneClearedFlags[panelId] ?? false
    }

    // MARK: - The caption (cm-126.15)

    /// What a `show` records as the pane's agent: ``AgentPaneMark/agent(sent:saved:liveAgentKeys:)`` over the keys the terminal
    /// `terminalPanelId` shows now (none when the terminal is gone), a manual loader's left out. A key whose state is `.unknown`
    /// is no live agent: Clear Agent State leaves a cleared agent's key at `.unknown` rather than removing it, so counting it
    /// would stop the one agent that still runs from being the only one.
    private func agentPaneAgentToRecord(sent: String?, saved: String?, terminalPanelId: UUID?) -> String? {
        let liveKeys = terminalPanelId.map { id in
            agentPaneStates(panelIds: [id]).entries.filter { $0.state != .unknown }.map(\.agentKey)
        } ?? []
        return AgentPaneMark.agent(sent: sent, saved: saved, liveAgentKeys: liveKeys)
    }

    /// The one writer of an Agent Pane's caption (cmux-rbf #cm-126.15), so the seven places that title a pane agree: the
    /// browser subscription, the workspace-context reset, the restore placeholder, `applySessionPanelMetadata`,
    /// `newBrowserSplit`, the Figma setting's re-title and ``refreshAgentPaneCaption(panelId:)``. It takes what the pane
    /// holds rather than looking the pane up by id, because `newBrowserSplit` asks before `panels[id]` is set and a
    /// restore placeholder has only its snapshot. The caption is the name from ``AgentPaneNameSetting`` for the pane's agent;
    /// a plain pane keeps `own`. Rename Tab still wins afterwards, through `resolvedPanelTitle`.
    func agentPaneCaption(owner: UUID?, kind: BrowserOwnedKind?, agent: String?, own: String) -> String {
        let isAgentPane = AgentPaneMark.isAgentPaneKind(owner: owner, kind: kind)
        return AgentPaneMark.title(
            isAgentPaneKind: isAgentPane,
            own: own,
            name: isAgentPane ? AgentPaneMark.name(agent: agent, names: AgentPaneNameSetting.current.names) : nil
        )
    }

    /// ``agentPaneCaption(owner:kind:agent:own:)`` for a live browser panel, which may not be in `panels` yet.
    func agentPaneCaption(for browser: BrowserPanel) -> String {
        agentPaneCaption(
            owner: browser.ownerTerminalSurfaceId, kind: browser.ownedKind, agent: browser.ownerAgent, own: browser.displayTitle
        )
    }

    /// The same for a saved record: a restore placeholder, or a snapshot applied to a panel.
    func agentPaneCaption(snapshot: SessionPanelSnapshot, own: String) -> String {
        agentPaneCaption(
            owner: snapshot.browser?.ownerTerminalSurfaceId,
            kind: snapshot.browser?.ownedKind.flatMap(BrowserOwnedKind.init(rawValue:)),
            agent: snapshot.browser?.ownerAgent,
            own: own
        )
    }

    /// Refreshes the caption (`panelTitles`, `resolvedPanelTitle`, and the Bonsplit tab title)
    /// for an Agent Pane, including a restore placeholder (`DeferredBrowserPanel`).
    func refreshAgentPaneCaption(panelId: UUID) {
        let nextTitle: String
        if let browserPanel = panels[panelId] as? BrowserPanel {
            nextTitle = agentPaneCaption(for: browserPanel) // (cm-126.15)
        } else if let deferred = panels[panelId] as? DeferredBrowserPanel {
            nextTitle = agentPaneCaption( // (cm-126.15)
                snapshot: deferred.sessionPanelSnapshot,
                own: deferred.sessionPanelSnapshot.title ?? deferred.displayTitle
            )
        } else {
            return
        }
        if panelTitles[panelId] != nextTitle {
            panelTitles[panelId] = nextTitle
        }
        guard let tabId = surfaceIdFromPanelId(panelId),
              let existing = bonsplitController.tab(tabId) else {
            return
        }
        let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: nextTitle)
        guard existing.title != resolvedTitle else { return }
        bonsplitController.updateTab(tabId, title: resolvedTitle)
    }

    /// Re-titles every Agent Pane in this workspace, live or still a restore placeholder, when `agentPane.names` changes
    /// (cmux-rbf #cm-126.15). Only Agent Panes: a plain pane's title is its page's.
    func refreshAgentPaneCaptions() {
        for candidate in agentPaneCandidates() where AgentPaneMark.isAgentPaneKind(owner: candidate.owner, kind: candidate.kind) {
            refreshAgentPaneCaption(panelId: candidate.panelID)
        }
    }

    // MARK: - Held while Design Focus is on

    /// Keeps `url` as the latest page for the terminal `owner`, to show when
    /// Design Focus ends. In memory only; latest wins.
    func holdAgentPaneUpdate(owner: UUID, url: URL, agent: String? = nil) {
        heldAgentPaneUpdates[owner] = .show(url, agent: agent)
    }

    /// Keeps a clear for the terminal `owner`, to apply when Design Focus ends; replaces any held
    /// page and is replaced by a later one (cmux-rbf #cm-126.14).
    func holdAgentPaneClear(owner: UUID) {
        heldAgentPaneUpdates[owner] = .clear
    }

    /// Runs each held update, then empties the store: a held page takes the same open-or-steer path a `show` takes;
    /// a held clear only steers its pane, and is dropped when that pane has closed. An app quit drops them all, so
    /// nothing opens while the app quits; an update whose terminal left this workspace is dropped.
    func applyHeldAgentPaneUpdates(reason: String) {
        let held = heldAgentPaneUpdates
        heldAgentPaneUpdates = [:]
        guard reason != "appQuit" else { return }
        for (owner, update) in held {
            guard let terminal = agentPaneOwnerTerminal(stableID: owner) else { continue }
            switch update {
            case .show(let url, let agent):
                switch AgentPaneMark.placement(panes: agentPanes(ownedBy: owner)) {
                case .open:
                    openAgentPane(beside: terminal.id, url: url, owner: owner, agent: agent)
                case .navigate(let agentPane, _):
                    navigateAgentPane(agentPane, to: url, agent: agent)
                }
            case .clear:
                // A held clear never opens a pane: when its pane closed meanwhile, it is dropped.
                guard let agentPane = agentPanes(ownedBy: owner).first else { continue }
                clearAgentPane(agentPane)
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

extension AppDelegate {
    /// Re-titles every Agent Pane across every window's workspaces when `agentPane.names` changes (cmux-rbf #cm-126.15). The Dock
    /// has no Agent Pane rule, so it is not visited.
    func refreshAgentPaneCaptions() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs {
                workspace.refreshAgentPaneCaptions()
            }
        }
        // As for the Figma re-title: `cmux tree` reads a copy that only refreshes on its own events.
        TerminalController.shared.scheduleSocketReadSnapshotRefresh()
    }
}
