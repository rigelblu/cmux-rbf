import Bonsplit
import CmuxBrowser
import Foundation

// cmux-rbf #cm-126.3: the Agent Pane, a browser pane one agent's terminal owns.

/// What a held update will do when Design Focus ends: show a page, or clear (cmux-rbf #cm-126.14).
enum HeldAgentPaneUpdate: Equatable {
    case show(URL)
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
    func openAgentPane(beside terminalID: UUID, url: URL, owner: UUID) -> BrowserPanel? {
        guard let browser = newBrowserSplit(
            from: terminalID,
            orientation: .horizontal,
            url: url,
            focus: false,
            creationPolicy: .automationPreload,
            allowsExternalBrowserFallback: false,
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
            owner: BrowserPaneOwner(terminalStableID: owner, kind: .agentPane)
        ) else { return nil }
        browser.agentPaneLastPostURL = url
        transitionAgentPaneState(panelId: browser.id, event: .show)
        return browser
    }

    /// Shows `url` in the Agent Pane `panelId`, materializing a restore placeholder
    /// first. Selects nothing and moves no focus.
    @discardableResult
    func navigateAgentPane(
        _ panelId: UUID,
        to url: URL,
        stateEvent: AgentPaneAnswerState.Event = .show
    ) -> BrowserPanel? {
        let browser: BrowserPanel?
        if let deferred = panels[panelId] as? DeferredBrowserPanel {
            browser = materializeDeferredBrowserPanel(deferred)
        } else {
            browser = panels[panelId] as? BrowserPanel
        }
        guard let browser else { return nil }
        browser.navigate(to: url)
        if stateEvent == .show { browser.agentPaneLastPostURL = url }
        transitionAgentPaneState(panelId: browser.id, event: stateEvent)
        return browser
    }

    /// Sets a moved or restored Agent Pane's state from the page it shows: in the cleared folder, cleared; else a post
    /// (cmux-rbf #cm-126.14; what a restore does, and what a pane moved into this workspace needs, since the workspace it came from
    /// dropped its state).
    func deriveAgentPaneAnswerState(panelId: UUID) {
        guard let candidate = agentPaneCandidates().first(where: { $0.panelID == panelId }),
              AgentPaneMark.isAgentPaneKind(owner: candidate.owner, kind: candidate.kind) else { return }
        let isCleared = agentPaneClearedFolder.map {
            AgentPaneMark.restoredState(url: agentPaneShownURL(panelId), clearedFolderURL: $0) == .cleared
        } ?? false
        transitionAgentPaneState(panelId: panelId, event: isCleared ? .clear : .show)
    }

    // MARK: - Answer state (cm-126.14)

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
        if agentPaneAnswerState(for: panelId).isCleared {
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
        return navigateAgentPane(panelId, to: page, stateEvent: .clear)
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

    func agentPaneAnswerState(for panelId: UUID) -> AgentPaneAnswerState {
        agentPaneAnswerStates[panelId] ?? .post
    }

    /// The one transition function for an Agent Pane's answer state.
    ///
    /// Also sets the owning terminal's typing-path flag (`awaitsAgentPaneAnswer`, true only in `.post`)
    /// and refreshes the pane's caption.
    @discardableResult
    func transitionAgentPaneState(panelId: UUID, event: AgentPaneAnswerState.Event) -> AgentPaneAnswerState {
        let current = agentPaneAnswerStates[panelId] ?? .post
        let next = AgentPaneAnswerState.next(state: current, event: event)
        applyAgentPaneAnswerState(panelId: panelId, state: next)
        return next
    }

    /// Stores a pane's state, then syncs its terminal's typing-path flag and the caption: the one place a state is written.
    private func applyAgentPaneAnswerState(panelId: UUID, state next: AgentPaneAnswerState) {
        agentPaneAnswerStates[panelId] = next

        if let candidate = agentPaneCandidates().first(where: { $0.panelID == panelId }),
           let owner = candidate.owner,
           let terminal = agentPaneOwnerTerminal(stableID: owner) {
            syncTerminalAgentPaneAnswerFlag(for: terminal)
        }

        refreshAgentPaneCaption(panelId: panelId)
    }

    /// A pane moved into this workspace: the state it carried, else one derived from its page (Agent Pane kind only).
    func adoptDetachedAgentPaneAnswerState(panelId: UUID, carried: AgentPaneAnswerState?) {
        guard let carried else {
            deriveAgentPaneAnswerState(panelId: panelId)
            return
        }
        guard let candidate = agentPaneCandidates().first(where: { $0.panelID == panelId }),
              AgentPaneMark.isAgentPaneKind(owner: candidate.owner, kind: candidate.kind) else { return }
        applyAgentPaneAnswerState(panelId: panelId, state: carried)
    }

    /// Syncs a terminal's typing-path flag from its first owned Agent Pane's current state.
    /// Called both when an Agent Pane transitions and when a terminal joins (or adopts its stable id in) a workspace.
    func syncTerminalAgentPaneAnswerFlag(for terminal: TerminalPanel) {
        if let firstPane = agentPanes(ownedBy: terminal.stableSurfaceId).first {
            terminal.surface.awaitsAgentPaneAnswer = (agentPaneAnswerState(for: firstPane) == .post)
        } else {
            terminal.surface.awaitsAgentPaneAnswer = false
        }
    }

    /// Marks the first Agent Pane owned by `terminalStableId` as written to by Tom.
    @discardableResult
    func noteTomWroteToTerminal(stableID terminalStableId: UUID, at date: Date = Date()) -> AgentPaneAnswerState? {
        guard let firstPane = agentPanes(ownedBy: terminalStableId).first else { return nil }
        return transitionAgentPaneState(panelId: firstPane, event: .tomWrote(at: date))
    }

    /// Refreshes the caption (`panelTitles`, `resolvedPanelTitle`, and the Bonsplit tab title)
    /// for an Agent Pane, including a restore placeholder (`DeferredBrowserPanel`).
    func refreshAgentPaneCaption(panelId: UUID) {
        let isAgentPaneKind: Bool
        let ownTitle: String
        if let browserPanel = panels[panelId] as? BrowserPanel {
            isAgentPaneKind = AgentPaneMark.isAgentPaneKind(
                owner: browserPanel.ownerTerminalSurfaceId,
                kind: browserPanel.ownedKind
            )
            ownTitle = browserPanel.displayTitle
        } else if let deferred = panels[panelId] as? DeferredBrowserPanel {
            let browserSnapshot = deferred.sessionPanelSnapshot.browser
            isAgentPaneKind = AgentPaneMark.isAgentPaneKind(
                owner: browserSnapshot?.ownerTerminalSurfaceId,
                kind: browserSnapshot?.ownedKind.flatMap(BrowserOwnedKind.init(rawValue:))
            )
            ownTitle = deferred.sessionPanelSnapshot.title ?? deferred.displayTitle
        } else {
            return
        }

        let wroteAt = agentPaneAnswerState(for: panelId).wroteAt
        let nextTitle = AgentPaneMark.title(
            isAgentPaneKind: isAgentPaneKind,
            own: ownTitle,
            wroteAt: wroteAt
        )
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

    // MARK: - Held while Design Focus is on

    /// Keeps `url` as the latest page for the terminal `owner`, to show when
    /// Design Focus ends. In memory only; latest wins.
    func holdAgentPaneUpdate(owner: UUID, url: URL) {
        heldAgentPaneUpdates[owner] = .show(url)
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
            case .show(let url):
                switch AgentPaneMark.placement(panes: agentPanes(ownedBy: owner)) {
                case .open:
                    openAgentPane(beside: terminal.id, url: url, owner: owner)
                case .navigate(let agentPane, _):
                    navigateAgentPane(agentPane, to: url)
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
