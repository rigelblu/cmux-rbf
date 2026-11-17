import AppKit
import CmuxBrowser
import Foundation
import Observation

/// Lightweight browser surface used while a session restore is assembling its topology.
///
/// A deferred panel keeps the persisted browser metadata and tab identity, but does not
/// construct a ``WKWebView`` until the pane is actually visible. This is intentionally a
/// ``Panel`` rather than a Bonsplit-only placeholder so the restored layout remains fully
/// navigable (and serializable) while WebKit work is kept out of the launch burst.
@MainActor
@Observable
final class DeferredBrowserPanel: Panel {
    let id: UUID
    private(set) var workspaceId: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .browser

    /// The complete persisted panel record used to materialize the real browser later.
    let sessionPanelSnapshot: SessionPanelSnapshot

    /// cmux-rbf #cm-73.43: the name the panel's workspace knows for the file its saved address names,
    /// set and cleared by the workspace as for a live ``BrowserPanel``.
    var figmaKnownFileName: (key: String, name: String)?

    /// cmux-rbf #cm-73.43: the saved address, read as a live panel would read it.
    var figmaSavedAddress: URL? { sessionPanelSnapshot.browser?.urlString.flatMap { URL(string: $0) } }

    /// cmux-rbf #cm-73.43: whether the saved address bar was showing, read the way
    /// `Workspace.restoredBrowserTabPicture` reads it: `chromeVisibility`, else `omnibarVisible`, else shown.
    var figmaSavedShowsAddressBar: Bool {
        guard let browser = sessionPanelSnapshot.browser else { return true }
        return (browser.chromeVisibility ?? BrowserChromeVisibility(omnibarVisible: browser.omnibarVisible ?? true))
            .isOmnibarVisible
    }

    /// cmux-rbf #cm-73.43: an Agent Pane by its snapshot, since a placeholder has neither owner nor kind itself.
    var isAgentPaneBySnapshot: Bool {
        AgentPaneMark.isAgentPaneKind(
            owner: sessionPanelSnapshot.browser?.ownerTerminalSurfaceId,
            kind: sessionPanelSnapshot.browser?.ownedKind.flatMap(BrowserOwnedKind.init(rawValue:))
        )
    }

    /// cmux-rbf #cm-73.43: `Figma (<name>)` for a Figma pane on a file, from the saved address alone.
    /// A saved title is never read as a page name: a saved `Figma (X)` carries no Figma suffix.
    private var figmaTabTitle: String? {
        let address = figmaSavedAddress
        let key = address.flatMap { FigmaPaneURL.fileKey(fromPaneURL: $0) }
        let knownName = key != nil && figmaKnownFileName?.key == key ? figmaKnownFileName?.name : nil
        return FigmaTabTitle.title(
            address: address,
            showsAddressBar: figmaSavedShowsAddressBar,
            isAgentPane: isAgentPaneBySnapshot,
            pageName: nil,
            knownName: knownName,
            showsFileName: FigmaTabTitleSetting.current.showsFileName
        )
    }

    /// cmux-rbf #cm-73.43: the title with no Rename Tab name in it: the rule, then the saved title. This
    /// is what the workspace keeps in `panelTitles`, the fallback a cleared rename falls back to; the
    /// rename itself lives in `panelCustomTitles` and `resolvedPanelTitle` applies it.
    var titleWithoutRename: String {
        if let figma = figmaTabTitle { return figma }
        return sessionPanelSnapshot.title
            ?? sessionPanelSnapshot.browser?.urlString
            ?? String(localized: "browser.newTab", defaultValue: "New tab")
    }

    var displayTitle: String {
        // cmux-rbf #cm-73.43: Rename Tab's name first, then the rule, then the saved title.
        sessionPanelSnapshot.customTitle ?? titleWithoutRename
    }

    var displayIcon: String? { "globe" }

    init(
        id: UUID,
        workspaceId: UUID,
        snapshot: SessionPanelSnapshot
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.sessionPanelSnapshot = snapshot
    }

    /// Updates the owning workspace after a cross-workspace panel transfer.
    func updateWorkspaceId(_ workspaceId: UUID) {
        self.workspaceId = workspaceId
    }

    func close() {
        // The owning Workspace or DockSplitStore removes the placeholder from its registry.
        // There are no native resources to release before that removal.
    }

    // Materialization is owned by Workspace or DockSplitStore; a placeholder
    // must not mutate its registry from a generic Panel focus callback.
    func focus() {}
    func unfocus() {}
    func triggerFlash(reason: WorkspaceAttentionFlashReason) {}

    deinit {}
}
