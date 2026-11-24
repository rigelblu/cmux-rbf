import AppKit
import Bonsplit
import CmuxBrowser // cmux-rbf #cm-73.15
import CmuxNotifications // (cm-128.13)
import CmuxSettings
import Foundation

enum DockBatchCloseConfirmationPolicy: Sendable {
    case tabsRequiringConfirmation
    case allTabs
}

// cmux-rbf #cm-73.15: Figma is a context-menu creation kind, not a new persisted surface kind.
enum DockContextSurfaceKind {
    case terminal
    case browser
    case figma
}

extension DockSplitStore {
    func splitTabBar(
        _ controller: BonsplitController,
        didRequestTabContextAction action: TabContextAction,
        for tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) {
        guard controller === bonsplitController,
              let panelId = surfaceIdToPanelId[tab.id],
              panels[panelId] != nil else {
            return
        }

        switch action {
        case .rename:
            _ = requestPaletteRenameDockSurface(
                tabId: tab.id,
                presentingWindow: dockContextMenuWindow
            )
        case .clearName:
            _ = setDockPanelCustomTitle(panelId: panelId, title: nil)
        case .copyIdentifiers:
            copyDockIdentifiers(panelId: panelId, paneId: pane)
        case .close:
            guard controller.configuration.allowCloseTabs, !tab.isPinned else { return }
            _ = closePanel(panelId, force: false)
        case .closeToLeft:
            guard controller.configuration.allowCloseTabs else { return }
            _ = closeDockTabs(
                dockTabIds(toLeftOf: tab.id, inPane: pane),
                inPane: pane,
                confirmationPolicy: .tabsRequiringConfirmation
            )
        case .closeToRight:
            guard controller.configuration.allowCloseTabs else { return }
            _ = closeDockTabs(
                dockTabIds(toRightOf: tab.id, inPane: pane),
                inPane: pane,
                confirmationPolicy: .tabsRequiringConfirmation
            )
        case .closeOthers:
            guard controller.configuration.allowCloseTabs else { return }
            _ = closeDockTabs(
                controller.tabs(inPane: pane).lazy
                    .filter { $0.id != tab.id }
                    .map(\.id),
                inPane: pane,
                confirmationPolicy: .tabsRequiringConfirmation
            )
        case .move:
            if let destination = dockTabMoveDestinations(
                for: tab.id
            ).first {
                splitTabBar(
                    controller,
                    didRequestTabMoveToDestination: destination.id,
                    for: tab,
                    inPane: pane
                )
            }
        case .moveToNewWorkspace:
            _ = AppDelegate.shared?.moveDockSurfaceToNewWorkspace(
                sourceDock: self,
                panelId: panelId,
                focus: true,
                focusWindow: false
            )
        case .moveToLeftPane:
            moveDockContextTab(
                panelId: panelId,
                movement: .left
            )
        case .moveToRightPane:
            moveDockContextTab(
                panelId: panelId,
                movement: .right
            )
        case .newTerminalToRight:
            createDockContextSurfaceToRight(
                kind: .terminal,
                anchorTabId: tab.id,
                paneId: pane
            )
        case .newFigmaToRight: // cmux-rbf #cm-73.15
            createDockContextSurfaceToRight(kind: .figma, anchorTabId: tab.id, paneId: pane)
        case .newBrowserToRight:
            createDockContextSurfaceToRight(
                kind: .browser,
                anchorTabId: tab.id,
                paneId: pane
            )
        case .reload:
            browserPanel(for: panelId)?.reload()
        case .toggleAudioMute:
            toggleDockBrowserMute(panelId: panelId, tabId: tab.id)
        case .duplicate:
            _ = duplicateBrowserToRight(panelId: panelId)
        case .togglePin:
            setDockTabPinned(tabId: tab.id, pinned: !tab.isPinned)
        case .markAsRead:
            setDockTabUnread(panelId: panelId, tabId: tab.id, unread: false)
        case .markAsUnread:
            putDockTabBackUnread(panelId: panelId, tabId: tab.id) // (cm-128.13)
        case .sendToBack:
            sendDockTabToBack(panelId: panelId, tabId: tab.id) // (cm-128.13)
        case .toggleZoom:
            _ = toggleDockPaneZoom(inPane: pane)
        case .toggleFullWidthTab:
            _ = toggleDockFullWidthTab(panelId: panelId)
        case .disconnectRemote,
             .forkConversation,
             .forkConversationRight,
             .forkConversationLeft,
             .forkConversationTop,
             .forkConversationBottom,
             .forkConversationNewTab,
             .forkConversationNewWorkspace,
             // Dock terminals are local and never carry shared-terminal
             // presence, so the sizing accessory never offers these.
             .sizeToMyWindow,
             .sizeModeLatest,
             .sizeModeSmallest,
             .sizeModeLargest,
             .sizeModePriority,
             .sizeModeFixed,
             .toggleSizePanel,
             .disconnectOtherClients:
            break
        @unknown default:
            break
        }
    }

    @discardableResult
    func closeDockTabs<S: Sequence>(
        _ tabIds: S,
        inPane paneId: PaneID,
        confirmationPolicy: DockBatchCloseConfirmationPolicy
    ) -> Bool where S.Element == TabID {
        let candidates = tabIds.compactMap { tabId -> (
            tabId: TabID,
            panelId: UUID,
            title: String,
            needsConfirmation: Bool
        )? in
            guard let tab = bonsplitController.tab(tabId),
                  !tab.isPinned,
                  let panelId = surfaceIdToPanelId[tabId],
                  let panel = panels[panelId] else {
                return nil
            }
            return (
                tabId,
                panelId,
                CloseOtherTabsConfirmationPrompt.displayTitle(
                    tab.title
                ),
                dockPanelNeedsConfirmClose(panel)
            )
        }
        guard !candidates.isEmpty else { return true }

        let manager = dockCloseConfirmationManager()
        guard manager?.isCloseConfirmationInFlight != true else {
            return true
        }
        let needsConfirmation: Bool
        switch confirmationPolicy {
        case .tabsRequiringConfirmation:
            needsConfirmation = candidates.contains {
                $0.needsConfirmation
            }
        case .allTabs:
            needsConfirmation = true
        }
        let warningStore = CloseTabWarningStore(
            defaults: manager?.closeTabWarningDefaults ?? .standard
        )
        let hasActiveProcess = candidates.contains { $0.needsConfirmation }
        var warningKinds = warningStore.warningKinds(
            requiresConfirmation: needsConfirmation,
            source: .shortcut
        )
        if hasActiveProcess {
            warningKinds.insert(.safety)
        }
        if !warningKinds.isEmpty {
            guard let manager else { return false }
            let prompt = CloseOtherTabsConfirmationPrompt(
                titles: candidates.map(\.title)
            )
            guard manager.confirmClose(
                title: prompt.title,
                message: prompt.message,
                scrollableDetails: prompt.details,
                acceptCmdD: false,
                dontAskAgain: warningKinds
            ) else {
                return true
            }
        }

        stageDockClosedPanelHistory(
            tabIds: Set(candidates.map(\.tabId)),
            inPane: paneId
        )
        for candidate in candidates {
            if !closePanel(
                candidate.panelId,
                force: needsConfirmation
            ) {
                discardDockClosedPanelHistory(tabId: candidate.tabId)
            }
        }
        return true
    }

    private var dockContextMenuWindow: NSWindow? {
        guard let app = AppDelegate.shared,
              let manager = app.dockReferenceTabManager(for: self),
              let windowId = app.windowId(for: manager) else {
            return NSApp.keyWindow ?? NSApp.mainWindow
        }
        return app.mainWindow(for: windowId)
    }

    private func copyDockIdentifiers(
        panelId: UUID,
        paneId: PaneID
    ) {
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText
                .makeWorkspacePaneSurfaceIdentifiers(
                    workspaceId: workspaceId,
                    paneId: paneId.id,
                    surfaceId: panelId,
                    includeRefs: true
                )
        )
    }

    private func dockTabIds(
        toLeftOf anchorTabId: TabID,
        inPane paneId: PaneID
    ) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }) else {
            return []
        }
        return tabs[..<index].map(\.id)
    }

    private func dockTabIds(
        toRightOf anchorTabId: TabID,
        inPane paneId: PaneID
    ) -> [TabID] {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let index = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }), index + 1 < tabs.count else {
            return []
        }
        return tabs[(index + 1)...].map(\.id)
    }

    private func moveDockContextTab(
        panelId: UUID,
        movement: SurfacePaneMovement
    ) {
        focusPanelFromDockInteraction(
            panelId,
            window: dockContextMenuWindow
        )
        _ = performShortcutCommand(
            .moveSurfaceToPane(
                movement,
                allowMissingDestinationSplit: false
            )
        )
    }

    // cmux-rbf #cm-73.15: Figma shares the Dock's neighbour insertion and focus path.
    func createDockContextSurfaceToRight(
        kind: DockContextSurfaceKind,
        anchorTabId: TabID,
        paneId: PaneID,
        defaults: UserDefaults = .standard,
        openExternally: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: {
            $0.id == anchorTabId
        }) else {
            return
        }
        let sourcePanelId = surfaceIdToPanelId[anchorTabId]
        let sourceBrowser = sourcePanelId.flatMap {
            browserPanel(for: $0)
        }
        // cmux-rbf #cm-73.15: browser-off wins over the allowlist, as newFigmaSurface does.
        let isFigma = kind == .figma
        if isFigma {
            guard isBrowserAvailable(), BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return }
            guard BrowserURLAllowlistPolicy(defaults: defaults).allowsTrustedInternalURL(Workspace.figmaRecentFilesURL) else {
                openExternally(Workspace.figmaRecentFilesURL)
                return
            }
        }
        noteKeyboardFocusIntent(window: dockContextMenuWindow)
        guard let panelId = newSurface(
            kind: kind == .terminal ? .terminal : .browser,
            inPane: paneId,
            url: isFigma ? Workspace.figmaRecentFilesURL : nil,
            sourcePanelId: sourcePanelId,
            focus: false,
            // cmux-rbf #cm-73.15: Figma passes no explicit profile/private store, as newFigmaSurface does.
            preferredProfileID: isFigma ? nil : sourceBrowser?.profileID,
            // cmux-rbf #cm-73.15: the same chrome and transparency as newFigmaSurface.
            chromeVisibility: isFigma ? BrowserChromeVisibility(omnibarVisible: false) : .visible,
            transparentBackground: isFigma,
            allowsExternalBrowserFallback: !isFigma,
            websiteDataStore: isFigma ? nil : sourceBrowser?.explicitEphemeralWebsiteDataStoreForSibling
        ),
        let newTabId = surfaceId(forPanelId: panelId) else {
            return
        }
        _ = bonsplitController.reorderTab(
            newTabId,
            toIndex: anchorIndex + 1
        )
        // cmux-rbf #cm-73.15: publish the new neighbour before returning, as newFigmaSurface does.
        if isFigma {
            TerminalController.shared.publishSocketReadSnapshot()
        }
        focusPanelFromDockInteraction(
            panelId,
            window: dockContextMenuWindow
        )
        // cmux-rbf #cm-73.15: a Figma tab has no address bar to focus.
        if !isFigma, let browser = browserPanel(for: panelId) {
            _ = AppDelegate.shared?.focusBrowserAddressBar(in: browser)
        }
    }

    private func toggleDockBrowserMute(
        panelId: UUID,
        tabId: TabID
    ) {
        guard let browser = browserPanel(for: panelId),
              browser.toggleMute() else {
            NSSound.beep()
            return
        }
        bonsplitController.updateTab(
            tabId,
            isAudioMuted: browser.isMuted
        )
    }

    private func setDockTabPinned(
        tabId: TabID,
        pinned: Bool
    ) {
        guard let paneId = paneId(forTabId: tabId) else { return }
        bonsplitController.updateTab(tabId, isPinned: pinned)
        let tabs = bonsplitController.tabs(
            inPane: paneId
        )
        let ordered = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        for (index, tab) in ordered.enumerated() {
            _ = bonsplitController.reorderTab(tab.id, toIndex: index)
        }
    }

    @discardableResult
    func setDockPanelPinned(
        panelId: UUID,
        pinned: Bool
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else {
            return false
        }
        setDockTabPinned(tabId: tabId, pinned: pinned)
        return true
    }

    private func paneId(forTabId tabId: TabID) -> PaneID? {
        bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains {
                $0.id == tabId
            }
        }
    }

    @discardableResult
    func toggleDockFullWidthTab(panelId: UUID) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId),
              let paneId = paneId(forTabId: tabId) else {
            return false
        }
        return bonsplitController.requestTabFullWidthToggle(
            for: tabId,
            inPane: paneId
        )
    }

    func panelIsUnread(_ panelId: UUID) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId),
              let tab = bonsplitController.tab(tabId) else {
            return false
        }
        let notificationStore = resolvedNotificationStore()
        return tab.showsNotificationBadge ||
            manualUnreadPanelIds.contains(panelId) ||
            notificationStore?.hasManualUnread(
                forTabId: workspaceId,
                surfaceId: panelId
            ) == true ||
            notificationStore?.hasUnreadNotification(
                forTabId: workspaceId,
                surfaceId: panelId
            ) == true
    }

    @discardableResult
    func togglePanelUnread(_ panelId: UUID) -> Bool {
        // (cm-128.13) The palette's Mark Tab as Unread puts the notification back where it was (an entrance, with the tab menu's
        // item); Mark Tab as Read stays as it was.
        if !panelIsUnread(panelId) {
            guard let tabId = surfaceId(forPanelId: panelId) else { return false }
            putDockTabBackUnread(panelId: panelId, tabId: tabId)
            return true
        }
        return setDockPanelUnread(panelId: panelId, unread: false)
    }

    /// (cm-128.13) A user Mark as Unread on a Dock tab, the one path for its two entrances, the tab menu's item and the palette's
    /// Dock toggle: the Dock surface's newest notification goes back where it was, as his mark, else a Dock mark (MISS1: the tab's
    /// badge is set whichever happened). A Dock with no window-Dock target (a non-global scope) keeps today's local mark. The system
    /// paths stay plain marks and don't come through here: the Dock's bell calls `markWindowDockSurfaceUnread` and its restore calls
    /// `adoptManualUnreadState`. `setDockTabUnread` is as upstream wrote it (the design's own rule, `14_technical-system.md:478`; step 4b R5).
    func putDockTabBackUnread(panelId: UUID, tabId: TabID) {
        guard scope == .global, let notificationStore = resolvedNotificationStore() else {
            setDockTabUnread(panelId: panelId, tabId: tabId, unread: true)
            return
        }
        manualUnreadPanelIds.remove(panelId)
        _ = notificationStore.markUnreadAtFormerPlace([.windowDock(WindowDockUnreadTarget(windowId: workspaceId, surfaceId: panelId))])
        bonsplitController.updateTab(tabId, showsNotificationBadge: true)
    }

    /// (cm-128.13) Send to Back from a window-Dock tab's menu (MISS1): the Dock surface's notifications go to the back of the
    /// unread queue. The tab's badge is set only when the send turned a READ notification unread (MISS1's case): a tab already
    /// unread looks as it should (Q111: nothing new on screen), so the send adds no dot there (step 9 R2). A Dock with no
    /// window-Dock target (a non-global scope) sends nothing, and a surface with no notification has nothing to move: nothing is
    /// marked (the lead, 2026-11-17).
    private func sendDockTabToBack(panelId: UUID, tabId: TabID) {
        guard scope == .global, let notificationStore = resolvedNotificationStore() else { return }
        let target = UnreadQueueTarget.windowDock(WindowDockUnreadTarget(windowId: workspaceId, surfaceId: panelId))
        guard notificationStore.canSendToBack([target]) else { return }
        let wasUnread = notificationStore.notifications.contains { !$0.isRead && $0.matches(tabId: workspaceId, surfaceId: panelId) }
        manualUnreadPanelIds.remove(panelId)
        notificationStore.sendToBack([target])
        if !wasUnread { // (cm-128.13, step 9 R2) a read notification came back unread: the tab shows it now
            bonsplitController.updateTab(tabId, showsNotificationBadge: true)
        }
    }

    /// (cm-128.13) A window Dock's tab dots clear-only follow the notification store (Tom, 2026-11-18): when this Dock's surfaces
    /// change in the store, a tab whose dot is on, and whose surface holds neither an unread notification nor a Dock mark, loses it.
    /// Nothing here ever turns a dot on: news doesn't add one, and the sites that do are unchanged (`putDockTabBackUnread`,
    /// `sendDockTabToBack`, `setDockTabUnread`, and the tab's creation by session restore, `DockSplitStore+SessionRestore.swift`,
    /// and by surface transfer, `DockSplitStore+SurfaceTransfer.swift`, which both put the Dock mark in the store too). A local Dock (a non-global scope) has no window-Dock target
    /// and is left alone. The store's per-owner surface channel fires only for this window's changes, never per keystroke.
    func installUnreadBadgeClearing() {
        unreadBadgeClearingObservation?.cancel()
        unreadBadgeClearingObservation = nil
        guard scope == .global, let notificationStore else { return }
        unreadBadgeClearingObservation = notificationStore.sidebarUnread.observeSurfaceChanges(
            forOwnerId: workspaceId,
            owner: self
        ) { dock, _ in
            dock.clearDockTabBadgesWithNothingUnread()
        }
    }

    private func clearDockTabBadgesWithNothingUnread() { // only `installUnreadBadgeClearing`, which subscribes global Docks only, calls this
        guard let notificationStore = resolvedNotificationStore() else { return }
        for tabId in bonsplitController.allTabIds {
            guard bonsplitController.tab(tabId)?.showsNotificationBadge == true,
                  let panelId = surfaceIdToPanelId[tabId],
                  !notificationStore.hasUnreadNotification(forTabId: workspaceId, surfaceId: panelId),
                  !notificationStore.hasManualUnread(forTabId: workspaceId, surfaceId: panelId) else { continue }
            bonsplitController.updateTab(tabId, showsNotificationBadge: false)
        }
    }

    private func setDockTabUnread(
        panelId: UUID,
        tabId: TabID,
        unread: Bool
    ) {
        adoptManualUnreadState(unread, panelId: panelId)
        let notificationStore = resolvedNotificationStore()
        if !unread {
            notificationStore?.markRead(
                forTabId: workspaceId,
                surfaceId: panelId
            )
            notificationStore?.clearFocusedReadIndicator(
                forTabId: workspaceId,
                surfaceId: panelId
            )
        }
        bonsplitController.updateTab(
            tabId,
            showsNotificationBadge: unread
        )
    }

    @discardableResult
    func setDockPanelUnread(
        panelId: UUID,
        unread: Bool
    ) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId) else {
            return false
        }
        setDockTabUnread(
            panelId: panelId,
            tabId: tabId,
            unread: unread
        )
        return true
    }

    /// Adopts durable unread state through the authority for this Dock scope.
    /// Window Docks use their injected notification store; legacy workspace
    /// Docks retain local state because they do not have a window-Dock target.
    func adoptManualUnreadState(
        _ unread: Bool,
        panelId: UUID
    ) {
        if scope == .global {
            manualUnreadPanelIds.remove(panelId)
            applyWindowDockUnreadState(unread, panelId: panelId)
            return
        }
        if unread {
            manualUnreadPanelIds.insert(panelId)
        } else {
            manualUnreadPanelIds.remove(panelId)
        }
    }
}
