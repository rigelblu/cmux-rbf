import AppKit
import Bonsplit
import CmuxBrowser
import CmuxSettings
import Foundation

// cmux-rbf `#cm-73.9`: the Figma button in a pane's header, and the other two ways in (`cm-73.9`).

extension Workspace {

    /// Where the button's tab starts: Figma's recent files. Signed in, Figma
    /// sends this on to the signed-in person's own list; signed out, it shows
    /// Figma's sign-in page.
    static let figmaRecentFilesURL = URL(string: "https://www.figma.com/files/recent")!

    /// Adds a Figma tab to `paneId`, showing the requested address, with no
    /// address bar and the see-through background a Figma pane has. Every click
    /// adds one: a second Figma tab is wanted (Tom, 2026-10-12, Q15).
    ///
    /// Asks, in this order and before it makes anything: whether cmux's browser
    /// is on (with it off, nothing opens, the system browser included); then
    /// whether the URL allowlist lets Figma through (when it does not, the
    /// address goes to the system browser and no tab is made).
    ///
    /// - Parameters:
    ///   - focus: `nil` focuses the tab only when its pane was the focused one,
    ///     as the browser button does.
    ///   - insertAtEnd: put the tab last in the pane, as the browser's palette
    ///     row and shortcut do.
    ///   - defaults: read for the browser setting and the allowlist. A parameter
    ///     so a test never flips Tom's shared setting.
    ///   - openExternally: the hand-off to the system browser. A parameter so a
    ///     test records it and opens nothing.
    /// - Returns: the new pane, or `nil` when no tab was made.
    @discardableResult
    func newFigmaSurface(
        inPane paneId: PaneID,
        address: URL = Workspace.figmaRecentFilesURL, // cmux-rbf #cm-73.16
        focus: Bool? = nil,
        insertAtEnd: Bool = false,
        defaults: UserDefaults = .standard,
        openExternally: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) -> BrowserPanel? {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return nil }
        guard BrowserURLAllowlistPolicy(defaults: defaults).allowsTrustedInternalURL(address) else {
            openExternally(address)
            return nil
        }
        guard let panel = newBrowserSurface(
            inPane: paneId,
            url: address,
            focus: focus,
            insertAtEnd: insertAtEnd,
            // The browser setting was asked above; the hand-off is `openExternally`'s.
            allowsExternalBrowserFallback: false,
            // The two flags that make a Figma pane, as the click on a Figma link sends them.
            chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
            transparentBackground: true
        ) else { return nil }
        // A tab added to an existing pane schedules no refresh of the saved
        // socket list. Publishing here lets `surface.list` hold the new tab at
        // once, so `cmux figma goto` finds the pane as soon as a file is open in it.
        TerminalController.shared.publishSocketReadSnapshot()
        return panel
    }

    /// The Figma tab for a way in that points at no pane: the palette's row and
    /// a `cmux.json` action or shortcut that names `cmux.newFigma`. It goes last
    /// in the focused pane and takes focus, as the browser's does.
    @discardableResult
    func openFigmaTabInFocusedPane(
        defaults: UserDefaults = .standard,
        openExternally: (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) -> BrowserPanel? {
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return nil
        }
        return newFigmaSurface(
            inPane: paneId,
            focus: true,
            insertAtEnd: true,
            defaults: defaults,
            openExternally: openExternally
        )
    }
}
