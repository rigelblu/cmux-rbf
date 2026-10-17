import CmuxBrowser
import Foundation

/// Browser creation options shared by main-workspace and Dock split hosts.
struct BrowserSplitRequest: Sendable {
    let url: URL?
    let focus: Bool
    let preferredProfileID: UUID?
    let chromeVisibility: BrowserChromeVisibility
    let transparentBackground: Bool
    let bypassRemoteProxy: Bool
    // cmux-rbf #cm-73.2a
    let designFocusAsker: DesignFocusRouting.Asker?

    init(
        url: URL?,
        focus: Bool,
        preferredProfileID: UUID?,
        chromeVisibility: BrowserChromeVisibility,
        transparentBackground: Bool,
        bypassRemoteProxy: Bool,
        designFocusAsker: DesignFocusRouting.Asker? = nil
    ) {
        self.url = url
        self.focus = focus
        self.preferredProfileID = preferredProfileID
        self.chromeVisibility = chromeVisibility
        self.transparentBackground = transparentBackground
        self.bypassRemoteProxy = bypassRemoteProxy
        self.designFocusAsker = designFocusAsker
    }
}
