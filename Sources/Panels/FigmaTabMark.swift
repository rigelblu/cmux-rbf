import Foundation

/// Figma's own mark on the tab of a Figma pane.
///
/// A browser pane's tab draws the icon its page gave it, and a globe when the
/// page gave none. A Figma pane's page is often one that gives none: cmux's
/// read-view page is a local file, and a fetch never runs for it. So the tab
/// is handed a picture the app ships, through the slot a fetched icon uses
/// (`iconImageData`), which keeps its size and colour in every state.
///
/// **One rule, one choice, both pure.** ``applies(address:showsAddressBar:wrapper:)``
/// says whether a pane is a Figma pane; ``picture(own:address:showsAddressBar:wrapper:)``
/// says what its tab is handed. `Workspace` calls the second where it makes,
/// restores, moves or follows a browser tab. The Dock keeps its own writers, so
/// a Figma tab in the Dock shows a globe in the read view.
enum FigmaTabMark {

    /// Whether a pane's tab gets Figma's mark: the pane shows no address bar,
    /// and its page is cmux's read view or is Figma's own, on `figma.com` or
    /// `www.figma.com` over `https` with no user name and no port. An ordinary
    /// browser tab on a Figma file, with its address bar showing, keeps what
    /// its page gives.
    static func applies(
        address: URL?,
        showsAddressBar: Bool,
        wrapper: URL = FigmaPaneURL.wrapperFileURL()
    ) -> Bool {
        guard !showsAddressBar, let address else { return false }
        return FigmaPaneURL.isWrapperPage(address, wrapper: wrapper)
            || FigmaFileLink.isEditorPage(address)
    }

    /// The picture a tab is handed: the pane's own icon when it has one, else
    /// the shipped mark when the rule holds, else none.
    static func picture(
        own: Data?,
        address: URL?,
        showsAddressBar: Bool,
        wrapper: URL = FigmaPaneURL.wrapperFileURL()
    ) -> Data? {
        if let own { return own }
        return applies(address: address, showsAddressBar: showsAddressBar, wrapper: wrapper)
            ? shippedPicture
            : nil
    }

    /// Figma's `favicon.svg` (`https://static.figma.com/app/icon/1/favicon.svg`,
    /// fetched 2026-10-12) drawn as a 32 by 32 pixel PNG, the size a fetched icon
    /// is redrawn to (`BrowserPanel.makeFaviconPNGData`), so the shipped and the
    /// fetched are equally sharp in the tab's 14 pt slot. Held as text so that no
    /// resource can be missing from a build.
    static let shippedPicture: Data = {
        let text = [
            "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAAB",
            "AAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAIKADAAQAAAABAAAAIAAAAACshmLzAAACYklEQVRYCeVWu24TQRS9",
            "dzaVZdIiCqj4AYTyAZYQNFmXiCoif0BKW0JRGtNh/iARFUKisdNA4w+I4B+AAtFGUSp2hnM3a2W13jOzlk3FNJ6999x7zs7j",
            "eEX+96GpBbjcf5CLk6MgYU9F+038nYdPmiGRIFcIXoj4qU7P5quA24i7na7OLvfvT0A+Q2bQRr5aUUVU+qIyEHWz8OpwQnFI",
            "UAE3b66jWHGnnNNROHqZMywVYMvOitaPO9qLCrA9X5+IVtBeVABtteUEFYBDh1O8tUF7UQHiZbo1elxH1osK2D3/MRcf3rDC",
            "znH0iHkBFWAEu+c/x1iJIaYLHEozl27DjCjIQoIf6rvTcaxoJ5a03Kfed3GZiAY8tPjmwVsto3c//8mzzMExpTzxFiwKLzI9",
            "w4yP6Aq8fxEmWSYzNIOrwd3IuPelAM5Vjil94A07sJjlSFkZpgJOn4ccpEkntDdXuB0jsZxhWJ4KwLJT96o3s2WvP7fNYxgq",
            "AHtO3atOstzzeqw5j2GogGaTf/VMBQS1//P0wIFL4mIYKsAX3ZwQV4263FJ+DEMFHH7UOcwk6YS/n+3MQ8QxLWeYpZjmLxVg",
            "wIMPOi4KGeIQwdXKz6xmffn862kGnK8cU66AN9dcWMxyrUVVENsTH72vJ3lwalet9Zvw+tHrZI8YQ9SKe99OJviuG23EEGNH",
            "jm6BvbmRJ+o3TlMB1bJvTJBqQAWgsJMTpghS+ZiAVC0uxhrfCKRbTEDS4dCzC4ZQ34SpAPUh6XBdMFF2JKmA68fHcELPnRC5",
            "EpNiSOSTV7xuRFWvC3vzbZBbv7/NyLI9HLAZ+AAAAABJRU5ErkJggg=="
        ].joined()
        return Data(base64Encoded: text) ?? Data()
    }()
}
