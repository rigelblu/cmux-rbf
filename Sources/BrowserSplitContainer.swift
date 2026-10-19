import Bonsplit
import CmuxBrowser
import CmuxAgentChat
import CmuxPanes
import Foundation

/// Adapts the main workspace and Dock split trees to one browser-placement path.
@MainActor
enum BrowserSplitContainer {
    case workspace(Workspace)
    case dock(DockSplitStore)

    var host: PanelHost {
        switch self {
        case .workspace(let workspace):
            return .workspace(workspace.id)
        case .dock(let dock):
            switch dock.scope {
            case .workspace:
                return .workspaceDock(dock.workspaceId)
            case .global:
                return .windowDock(dock.workspaceId)
            }
        }
    }

    var ownerID: UUID {
        host.ownerID
    }

    var isRemoteWorkspace: Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.isRemoteWorkspace
        case .dock(let dock):
            return dock.currentRemoteBrowserSettings().isRemoteWorkspace
        }
    }

    /// Resolves an explicit surface or pane selection, then falls back to focus.
    func sourcePanelID(
        requestedSurfaceID: UUID?,
        requestedPaneID: UUID?
    ) -> UUID? {
        if let requestedSurfaceID {
            return containsPanel(requestedSurfaceID)
                ? requestedSurfaceID
                : nil
        }
        if let requestedPaneID {
            return selectedPanelID(inPane: requestedPaneID)
        }
        switch self {
        case .workspace(let workspace):
            return workspace.focusedPanelId
        case .dock(let dock):
            return dock.focusedPanelId
        }
    }

    func containsPanel(_ panelID: UUID) -> Bool {
        switch self {
        case .workspace(let workspace):
            return workspace.panels[panelID] != nil
        case .dock(let dock):
            return dock.containsPanel(panelID)
        }
    }

    func paneID(forPanelID panelID: UUID) -> PaneID? {
        switch self {
        case .workspace(let workspace):
            return workspace.paneId(forPanelId: panelID)
        case .dock(let dock):
            return dock.paneId(forPanelId: panelID)
        }
    }

    /// Reuses the right pane, otherwise splits Figma by the source pane shape.
    func openBrowserToRight(
        of sourcePanelID: UUID,
        request: BrowserSplitRequest,
        registry: AgentChatSessionRegistry? = nil
    ) -> BrowserSplitPlacement? {
        guard containsPanel(sourcePanelID),
              let sourcePane = paneID(forPanelID: sourcePanelID) else {
            return nil
        }

        if let targetPane = preferredRightSidePane(from: sourcePane) {
            return createBrowserSurface(
                in: targetPane,
                request: request
            ).map {
                placement(panel: $0, sourcePanelID: sourcePanelID, request: request, createdSplit: false, registry: registry)
            }
        }

        let direction = splitOrientation(from: sourcePanelID, request: request)
        return createBrowserSplit(
            from: sourcePanelID,
            request: request,
            orientation: direction
        ).map {
            placement(panel: $0, sourcePanelID: sourcePanelID, request: request,
                      createdSplit: true, splitDirection: direction, registry: registry)
        }
    }

    private func placement(panel: BrowserPanel, sourcePanelID: UUID, request: BrowserSplitRequest,
                           createdSplit: Bool, splitDirection: SplitOrientation? = nil,
                           registry: AgentChatSessionRegistry?) -> BrowserSplitPlacement {
        var orientation: BoardLayoutOrientation?
        if case .workspace(let workspace) = self,
           FigmaTabMark.applies(address: request.url, showsAddressBar: request.chromeVisibility.isOmnibarVisible),
           let landedPane = paneID(forPanelID: panel.id) {
            let size: CGSize?
            if workspace.isDesignFocusActive, workspace.bonsplitController.pairZoomPanes?.second == landedPane {
                size = workspace.bonsplitController.pairSecondPaneSize
            } else {
                size = paneSize(landedPane, in: workspace)
            }
            if let size, size.width > 0, size.height > 0 {
                let landed = BoardLayoutOrientation(size: size)
                orientation = landed
                // Clicks by the person share placement, but do not claim that an agent opened the file.
                if request.designFocusAsker != .user {
                    workspace.recordFigmaBoardOpen(panel: panel, sourcePanelID: sourcePanelID,
                                                  url: request.url, orientation: landed, registry: registry)
                }
            }
        }
        return BrowserSplitPlacement(panel: panel, createdSplit: createdSplit, orientation: orientation, splitDirection: splitDirection)
    }

    private func paneSize(_ pane: PaneID, in workspace: Workspace) -> CGSize? {
        guard let frame = workspace.bonsplitController.layoutSnapshot().panes.first(where: {
            $0.paneId == pane.id.uuidString
        })?.frame else { return nil }
        return CGSize(width: frame.width, height: frame.height)
    }

    private func splitOrientation(from sourcePanelID: UUID, request: BrowserSplitRequest) -> SplitOrientation {
        guard case .workspace(let workspace) = self,
              FigmaTabMark.applies(address: request.url, showsAddressBar: request.chromeVisibility.isOmnibarVisible),
              let pane = paneID(forPanelID: sourcePanelID), let size = paneSize(pane, in: workspace) else { return .horizontal }
        return DesignFocusPair.orientation(areaSize: size) == .beside ? .horizontal : .vertical
    }

    private func selectedPanelID(inPane requestedPaneID: UUID) -> UUID? {
        switch self {
        case .workspace(let workspace):
            guard let pane = workspace.bonsplitController.allPaneIds.first(
                where: { $0.id == requestedPaneID }
            ), let tabID = workspace.bonsplitController.selectedTab(
                inPane: pane
            )?.id else {
                return nil
            }
            return workspace.panelIdFromSurfaceId(tabID)
        case .dock(let dock):
            guard let pane = dock.bonsplitController.allPaneIds.first(
                where: { $0.id == requestedPaneID }
            ), let tabID = dock.bonsplitController.selectedTab(
                inPane: pane
            )?.id else {
                return nil
            }
            return dock.panel(for: tabID)?.id
        }
    }

    private func preferredRightSidePane(from sourcePane: PaneID) -> PaneID? {
        switch self {
        case .workspace(let workspace):
            return BrowserRightSidePaneResolver().preferredPane(
                from: sourcePane,
                in: workspace.bonsplitController
            )
        case .dock(let dock):
            return BrowserRightSidePaneResolver().preferredPane(
                from: sourcePane,
                in: dock.bonsplitController
            )
        }
    }

    private func createBrowserSurface(
        in paneID: PaneID,
        request: BrowserSplitRequest
    ) -> BrowserPanel? {
        switch self {
        case .workspace(let workspace):
            return workspace.newBrowserSurface(
                inPane: paneID,
                url: request.url,
                focus: request.focus,
                selectWhenNotFocused: true,
                preferredProfileID: request.preferredProfileID,
                creationPolicy: .automationPreload,
                chromeVisibility: request.chromeVisibility,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy,
                // cmux-rbf #cm-73.2a
                designFocusAsker: request.designFocusAsker
            )
        case .dock(let dock):
            guard let panelID = dock.newSurface(
                kind: .browser,
                inPane: paneID,
                url: request.url,
                focus: false,
                preferredProfileID: request.preferredProfileID,
                chromeVisibility: request.chromeVisibility,
                preloadInitialNavigationInBackground: true,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy
            ) else {
                return nil
            }
            if request.focus {
                dock.focusPanelFromDockInteraction(panelID, window: nil)
            }
            return dock.browserPanel(for: panelID)
        }
    }

    private func createBrowserSplit(
        from sourcePanelID: UUID,
        request: BrowserSplitRequest,
        orientation: SplitOrientation
    ) -> BrowserPanel? {
        switch self {
        case .workspace(let workspace):
            return workspace.newBrowserSplit(
                from: sourcePanelID,
                orientation: orientation,
                url: request.url,
                preferredProfileID: request.preferredProfileID,
                focus: request.focus,
                creationPolicy: .automationPreload,
                chromeVisibility: request.chromeVisibility,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy,
                // cmux-rbf #cm-73.2a
                designFocusAsker: request.designFocusAsker
            )
        case .dock(let dock):
            guard let panelID = dock.newSplit(
                kind: .browser,
                orientation: .horizontal,
                insertFirst: false,
                sourcePanelId: sourcePanelID,
                url: request.url,
                preferredProfileID: request.preferredProfileID,
                chromeVisibility: request.chromeVisibility,
                preloadInitialNavigationInBackground: true,
                transparentBackground: request.transparentBackground,
                bypassRemoteProxy: request.bypassRemoteProxy,
                focus: false
            ) else {
                return nil
            }
            if request.focus {
                dock.focusPanelFromDockInteraction(panelID, window: nil)
            }
            return dock.browserPanel(for: panelID)
        }
    }
}
