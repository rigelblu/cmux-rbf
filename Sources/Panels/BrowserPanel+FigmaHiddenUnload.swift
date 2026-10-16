import Foundation

extension BrowserPanel {
    /// Whether this pane is a Figma pane to the hidden-pane timer: no address bar showing, and its page is cmux's read view or a page on Figma's site (`FigmaTabMark.applies`). `hiddenWebViewDiscardKeepLoaded` keeps such a pane as it keeps a Keep Page Loaded pane. The pane's own `keepLoaded` is never written, because the session saves it. Memory pressure still unloads it.
    var isFigmaPaneForHiddenUnload: Bool {
        FigmaTabMark.applies(address: currentURL, showsAddressBar: isOmnibarVisible)
    }
}
