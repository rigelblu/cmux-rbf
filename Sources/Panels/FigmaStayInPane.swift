import Foundation

/// Whether a link that asks for a new tab loads in the pane that asked instead.
///
/// **Tom's rule (2026-09-07): nothing inside the Figma pane may eject you to a
/// new tab.** Figma's own *Open in Figma* mark, clicked in the read view, asks
/// for a new tab. In a pane with no address bar, showing cmux's read view, a
/// Figma file link loads in that pane, and the panel collapse then runs because
/// the pane now shows the editor.
///
/// **One check, two callers.** cmux chooses a new tab in
/// `BrowserNavigationDelegate` (a link with no target frame) and in
/// `BrowserUIDelegate.createWebViewWith` (a scripted open). Both ask this.
/// ⌘-click and middle-click take their own branch ahead of both: that is a
/// person asking for a new tab, and they get one.
enum FigmaStayInPane {

    /// - Parameters:
    ///   - paneURL: the address of the pane that asked.
    ///   - isOmnibarVisible: whether that pane shows its address bar.
    ///   - target: where the link points.
    ///   - wrapper: cmux's own read-view page.
    static func shouldLoadInThisPane(
        paneURL: URL?,
        isOmnibarVisible: Bool,
        target: URL?,
        wrapper: URL = FigmaPaneURL.wrapperFileURL()
    ) -> Bool {
        guard !isOmnibarVisible, let paneURL, let target else { return false }
        guard FigmaPaneURL.isWrapperPage(paneURL, wrapper: wrapper) else { return false }
        // The editor's hosts only: the pane has to show the editor afterwards,
        // so that the panel collapse runs. The read view's own host is not one.
        return FigmaFileLink.isEditorLink(target)
    }
}
