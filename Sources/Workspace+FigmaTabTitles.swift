import Foundation

// cmux-rbf #cm-73.43: a Figma pane's header names its file, and the workspace is what knows the
// name the Figma button's menu holds for it.
extension Workspace {

    /// The name this workspace's file list holds for `address`'s file, for a header: a name from Figma's
    /// title, or the link's own name part. `nil` when the row holds only the menu's "Untitled"
    /// placeholder (no title name, no link name part), the one place the header and the menu differ.
    private func figmaKnownName(forAddress address: URL?) -> (key: String, name: String)? {
        guard let key = address.flatMap({ FigmaPaneURL.fileKey(fromPaneURL: $0) }),
              let entry = figmaFiles.entries.first(where: {
                  $0.key == key && ($0.nameFromTitle || FigmaFileList.linkName($0.link) != nil)
              }) else { return nil }
        return (key: key, name: entry.name)
    }

    /// Hands a panel the name this workspace's file list holds for the file its address names, or
    /// clears it when the list holds none. The panel reads it only while its address still names
    /// that file (`BrowserPanel.figmaKnownFileName`), so a name never outlives a move to another file.
    func syncFigmaKnownFileName(_ panel: BrowserPanel) {
        panel.figmaKnownFileName = figmaKnownName(forAddress: panel.currentURL)
    }

    /// The same for a restored tab not shown yet, from its saved address.
    func syncFigmaKnownFileName(_ panel: DeferredBrowserPanel) {
        panel.figmaKnownFileName = figmaKnownName(forAddress: panel.figmaSavedAddress)
    }

    /// The title Figma's editor gave a file, as a tab of this workspace kept it, for the list's
    /// showing to take: this panel's own, when its key is `key`; else, only when the list holds no
    /// name from a title for `key`, another panel's. `nil` for a panel this workspace doesn't hold.
    func keptFigmaTitle(forPanel panelId: UUID, key: String) -> String? {
        if let own = (panels[panelId] as? BrowserPanel)?.figmaPageTitle, own.key == key {
            return own.title
        }
        if figmaFiles.entries.first(where: { $0.key == key })?.nameFromTitle == true { return nil }
        for (otherId, other) in panels where otherId != panelId {
            if let kept = (other as? BrowserPanel)?.figmaPageTitle, kept.key == key { return kept.title }
        }
        return nil
    }

    /// Re-titles every Figma tab of this workspace on `key` (every Figma tab when `key` is `nil`), live
    /// or a restored one not shown yet: sets the tab's known name, then writes `panelTitles` and the
    /// Bonsplit tab the way the browser subscription does, with a Rename Tab name still winning and an
    /// Agent Pane's caption kept (`AgentPaneMark.title`), so a re-title never replaces it with a page's
    /// title. A restored tab has no owner or kind of its own: its snapshot is the only source.
    func refreshFigmaTabTitles(key: String? = nil) {
        for (panelId, panel) in panels {
            let address: URL?
            let showsAddressBar: Bool
            let next: String // cmux-rbf #cm-126.15: the one caption writer, so a Figma setting flip keeps the name
            if let browser = panel as? BrowserPanel {
                address = browser.currentURL
                showsAddressBar = browser.isOmnibarVisible
                guard FigmaTabMark.applies(address: address, showsAddressBar: showsAddressBar) else { continue }
                if let key, address.flatMap({ FigmaPaneURL.fileKey(fromPaneURL: $0) }) != key { continue }
                syncFigmaKnownFileName(browser)
                next = agentPaneCaption(for: browser) // (cm-126.15)
            } else if let deferred = panel as? DeferredBrowserPanel {
                address = deferred.figmaSavedAddress
                showsAddressBar = deferred.figmaSavedShowsAddressBar
                guard FigmaTabMark.applies(address: address, showsAddressBar: showsAddressBar) else { continue }
                if let key, address.flatMap({ FigmaPaneURL.fileKey(fromPaneURL: $0) }) != key { continue }
                syncFigmaKnownFileName(deferred)
                next = agentPaneCaption(snapshot: deferred.sessionPanelSnapshot, own: deferred.titleWithoutRename) // (cm-126.15)
            } else {
                continue
            }
            guard let tabId = surfaceIdFromPanelId(panelId) else { continue }
            if panelTitles[panelId] != next { panelTitles[panelId] = next }
            let resolved = resolvedPanelTitle(panelId: panelId, fallback: next)
            guard let existing = bonsplitController.tab(tabId), existing.title != resolved else { continue }
            bonsplitController.updateTab(tabId, title: resolved, hasCustomTitle: panelCustomTitles[panelId] != nil)
        }
    }
}

extension AppDelegate {
    /// Re-titles every Figma tab across every window's workspaces and Docks
    /// when `figma.showFileNameInHeader` changes.
    func refreshFigmaTabTitles() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs {
                workspace.refreshFigmaTabTitles()
                if let dock = workspace._dockSplit {
                    dock.refreshFigmaTabTitles()
                }
            }
            for dock in manager.liveWindowDockStores {
                dock.refreshFigmaTabTitles()
            }
        }
        // A tab title change publishes nothing by itself: `cmux tree` reads a copy that refreshes on
        // its own events, so without this it keeps the old names until one comes along.
        TerminalController.shared.scheduleSocketReadSnapshotRefresh()
    }
}

extension DockSplitStore {
    /// Re-titles every Figma tab in this Dock, live or a restored one not shown yet, from the panel's
    /// own `displayTitle`, **unwrapped**: Tom's kept exception, the Dock has no Agent Pane rule
    /// (`AgentPaneMark.title` is a workspace writer's), so an Agent Pane here reads its page's title as
    /// it did before. The Dock holds no file list, so a preview reads its link's name. A tab with a
    /// Rename Tab name keeps it. Called when the setting flips (`AppDelegate.refreshFigmaTabTitles()`)
    /// and after a session restore, whose tabs are created with the title they were saved with.
    func refreshFigmaTabTitles() {
        for (panelId, panel) in panels {
            let address: URL?
            let showsAddressBar: Bool
            let displayTitle: String
            if let browser = panel as? BrowserPanel {
                address = browser.currentURL
                showsAddressBar = browser.isOmnibarVisible
                displayTitle = browser.displayTitle
            } else if let deferred = panel as? DeferredBrowserPanel {
                address = deferred.figmaSavedAddress
                showsAddressBar = deferred.figmaSavedShowsAddressBar
                displayTitle = deferred.displayTitle
            } else {
                continue
            }
            guard FigmaTabMark.applies(address: address, showsAddressBar: showsAddressBar),
                  let tabId = surfaceId(forPanelId: panelId),
                  let existing = bonsplitController.tab(tabId),
                  !existing.hasCustomTitle,
                  existing.title != displayTitle else { continue }
            bonsplitController.updateTab(tabId, title: displayTitle)
        }
    }
}
