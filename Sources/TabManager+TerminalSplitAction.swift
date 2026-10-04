import Bonsplit
import CmuxPanes
import Foundation

/// Preserves asynchronous acceptance through the shared terminal split action.
@MainActor
extension TabManager {
    func createSplitOutcome(direction: SplitDirection) -> TerminalPanelCreationOutcome {
        guard let selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedTabId }),
              let panelID = workspace.focusedPanelId else { return .failed }
        return createSplitOutcome(tabId: selectedTabId, surfaceId: panelID, direction: direction)
    }

    /// Create a new split from an explicit source panel, preserving whether the
    /// mutation was made locally or routed to a remote tmux mirror.
    ///
    /// A mirror workspace returns `.routedToRemote` with no local panel — the
    /// pane arrives via `%layout-change`. Reporting that as failure is what
    /// makes a caller retry and duplicate the remote pane.
    @discardableResult
    func createSplitOutcome(
        tabId: UUID,
        surfaceId: UUID,
        direction: SplitDirection,
        focus: Bool = true
    ) -> TerminalPanelCreationOutcome {
        guard let workspace = tabs.first(where: { $0.id == tabId }),
              workspace.panels[surfaceId] != nil else { return .failed }
        workspace.clearSplitZoom()
        sentryBreadcrumb("split.create", data: ["direction": String(describing: direction)])
        return workspace.newTerminalSplitOutcome(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            focus: focus
        )
    }
}
