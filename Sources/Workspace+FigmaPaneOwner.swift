import Foundation

// cmux-rbf #cm-73.45: a Figma pane remembers the terminal that last opened or pointed it.

/// Which entrance wrote a Figma pane's owner. Only the Debug log reads it.
enum FigmaPaneOwnerSource: String {
    case open
    case goto
    case click
}

extension Workspace {

    /// Records `callerPanelId`'s terminal as the owner of the Figma pane
    /// `figmaPanelId`, replacing any earlier owner (the last to point wins).
    /// The one writer: `browser.open_split`, `figma.goto` and a clicked Figma
    /// link all end here.
    ///
    /// Does nothing, and answers `false`, unless the pane is a Figma pane and the
    /// caller is a live terminal. That keeps a markdown view, a closed terminal
    /// and an unknown id from ever becoming an owner. It stores the terminal's
    /// `stableSurfaceId`, never its `id`, which every launch mints again.
    ///
    /// The caller may sit in another workspace than the pane, so it is found
    /// through the app when this workspace does not hold it.
    @discardableResult
    func setFigmaPaneOwner(figmaPanelId: UUID, callerPanelId: UUID, via source: FigmaPaneOwnerSource) -> Bool {
        guard let figma = panels[figmaPanelId] as? BrowserPanel,
              FigmaTabMark.applies(
                  address: figma.currentURL ?? figma.webView.url,
                  showsAddressBar: figma.isOmnibarVisible,
                  wrapper: figma.figmaPageWrapper
              ),
              let terminal = figmaOwnerCandidateTerminal(callerPanelId) else { return false }
        figma.ownerTerminalSurfaceId = terminal.stableSurfaceId
        #if DEBUG
        cmuxDebugLog(
            "figma.owner.set surface=\(figmaPanelId.uuidString) owner=\(terminal.stableSurfaceId.uuidString) via=\(source.rawValue)"
        )
        #endif
        return true
    }

    private func figmaOwnerCandidateTerminal(_ panelId: UUID) -> TerminalPanel? {
        if let terminal = panels[panelId] as? TerminalPanel { return terminal }
        return AppDelegate.shared?.workspaceContainingPanel(panelId: panelId)?
            .workspace.panels[panelId] as? TerminalPanel
    }
}
