import CmuxBrowser
import CmuxSettings
import Foundation

// cmux-rbf `#cm-73`: a clicked Figma link lands in a Figma pane (`cm-73.8`).

/// What a clicked Figma link reads from the machine: where the read view's page
/// lives, and the defaults that say whether cmux's browser is on. The terminal's
/// witness has a fixed signature and cannot take them as parameters, so it takes
/// them from here; only tests change the values.
struct FigmaClickEnvironment {
    var page: URL = FigmaPaneURL.wrapperFileURL()
    var defaults: UserDefaults = .standard
}

extension Workspace {

    /// Acts on ``FigmaClickRoute`` for a link someone clicked, and answers
    /// whether it took the link. When it says no, the caller opens the link as
    /// it always did.
    ///
    /// - Parameters:
    ///   - sourcePanelId: the panel the link was clicked in; a new Figma tab
    ///     opens where `cmux figma open` puts one, relative to it.
    ///   - page: where the read view's page lives. A parameter so a test never
    ///     touches the real `Application Support` folder.
    ///   - defaults: read for whether cmux's browser is on and for the URL
    ///     policy. A parameter so a test never flips the shared setting.
    func openClickedFigmaLink(
        _ url: URL,
        sourcePanelId: UUID,
        page: URL = FigmaPaneURL.wrapperFileURL(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        // First, before the page is written or an address built: with the
        // browser off, making a pane hands its address to the system browser,
        // and the caller would then open the link a second time.
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }

        let panes = figmaClickPanes()
        switch FigmaClickRoute.answer(for: url, panes: panes, wrapper: page) {
        case .notOurs:
            return false

        case .openNew:
            guard let destination = figmaClickDestination(for: url, node: nil, page: page, defaults: defaults) else {
                return false
            }
            let request = BrowserSplitRequest(
                url: destination.url,
                focus: true,
                preferredProfileID: nil,
                // The two flags that make the pane chrome-free, as `open` sends them.
                chromeVisibility: BrowserChromeVisibility(omnibarVisible: false),
                transparentBackground: true,
                bypassRemoteProxy: false,
                designFocusAsker: .user // cmux-rbf #cm-73.2a
            )
            guard BrowserSplitContainer.workspace(self).openBrowserToRight(
                of: sourcePanelId,
                request: request
            ) != nil else { return false }
            publishSocketReadSnapshotForClick()
            return true

        case .move(let paneId, let node):
            // cmux-rbf #cm-73.2a
            if isDesignFocusActive, let targetPane = self.paneId(forPanelId: paneId) {
                makeDesignFocusFigmaSide(paneId: targetPane)
            }
            guard let address = panes.first(where: { $0.id == paneId })?.address,
                  let document = FigmaPaneURL.documentURL(fromPaneURL: address, wrapper: page),
                  let destination = figmaClickDestination(for: document, node: node, page: page, defaults: defaults)
            else { return false }
            // Showing the pane first makes a restored, not yet shown pane a real
            // `BrowserPanel`; `focusPanel` does that in one synchronous step.
            focusPanel(paneId)
            guard let panel = panels[paneId] as? BrowserPanel else { return false }
            // The pane's own file path plus the clicked link's frame, as `goto` builds it.
            panel.navigate(to: destination.url)
            return true

        case .bringForward(let paneId):
            // cmux-rbf #cm-73.2a
            if isDesignFocusActive, let targetPane = self.paneId(forPanelId: paneId) {
                makeDesignFocusFigmaSide(paneId: targetPane)
            }
            focusPanel(paneId)
            return true
        }
    }

    /// A tab added to an existing pane schedules no refresh of the saved socket
    /// list, so it keeps missing the new pane until the next socket change. The
    /// click publishes, so `surface.list`, which `cmux figma goto` reads for the
    /// list of panes, holds the new pane at once. `.move` and `.bringForward`
    /// add no pane, and `goto` reads addresses live, so a publish there saves
    /// nothing it needs (and before the navigation commits it would save the
    /// old address).
    private func publishSocketReadSnapshotForClick() {
        TerminalController.shared.publishSocketReadSnapshot()
    }

    /// The workspace's browser panes in the order a person reads them: the
    /// split tree left to right and top to bottom, then tab order inside a
    /// pane. `panels` is a dictionary and gives no order.
    ///
    /// A tab restored after a restart and not yet shown is a
    /// `DeferredBrowserPanel`, not a `BrowserPanel`: it counts too, read from the
    /// session snapshot it holds.
    private func figmaClickPanes() -> [FigmaClickRoute.Pane] {
        var found: [FigmaClickRoute.Pane] = []
        for paneId in spatiallyOrderedPaneIds {
            for surfaceId in surfaceIdsInTabOrder(inPaneId: paneId) {
                guard let panelId = panelId(forSurfaceId: surfaceId) else { continue }
                if let panel = panels[panelId] as? BrowserPanel {
                    guard let address = panel.currentURL ?? panel.webView.url else { continue }
                    found.append(FigmaClickRoute.Pane(id: panelId, address: address, showsAddressBar: panel.isOmnibarVisible))
                } else if let browser = (panels[panelId] as? DeferredBrowserPanel)?.sessionPanelSnapshot.browser,
                          let address = browser.urlString.flatMap({ URL(string: $0) }) {
                    found.append(FigmaClickRoute.Pane(
                        id: panelId,
                        address: address,
                        showsAddressBar: (browser.chromeVisibility ?? .visible).isOmnibarVisible
                    ))
                }
            }
        }
        return found
    }

    /// What the pane should load, with the read view's page written. **The click
    /// follows `open` on the write**: a link that names no frame needs no page,
    /// so a failed write is ignored; a link that names a frame cannot open
    /// without it, and the caller opens the link as it did before.
    private func figmaClickDestination(
        for link: URL,
        node: String?,
        page: URL,
        defaults: UserDefaults
    ) -> FigmaPaneURL.Destination? {
        guard let destination = try? FigmaPaneURL.destination(for: link, node: node, wrapper: page) else {
            return nil
        }
        // The pane would refuse this address and still look taken: the policy
        // that `navigate` and the socket's `browser.open_split` ask first.
        guard BrowserURLAllowlistPolicy(defaults: defaults).allowsTrustedInternalURL(destination.url) else {
            return nil
        }
        do {
            try FigmaWrapperPage.install(at: page)
        } catch {
            if case .embed = destination { return nil }
        }
        return destination
    }
}
