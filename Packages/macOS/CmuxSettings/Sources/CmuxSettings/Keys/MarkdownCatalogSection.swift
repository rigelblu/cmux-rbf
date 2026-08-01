import Foundation

/// Settings under the dotted-id prefix `markdown.*`.
///
/// Controls the built-in markdown viewer that `cmux markdown open` and the file
/// explorer use. The viewer renders into a WKWebView and scales with
/// `WKWebView.pageZoom`, so ``fontSize`` is the body font size in points.
/// ``fontFamily`` optionally overrides the prose font stack, and
/// ``maxWidth`` caps the reading column width.
public struct MarkdownCatalogSection: SettingCatalogSection {
    /// Default body font size, in points, for newly opened markdown viewers.
    ///
    /// Each viewer can still be zoomed live with the Markdown Viewer zoom
    /// shortcuts; this is the size every new viewer starts at and the size that
    /// "Actual Size" resets to. Per-invocation overrides come from
    /// `cmux markdown open --font-size <points>`.
    public let fontSize = DefaultsKey<Int>(
        id: "markdown.fontSize",
        defaultValue: 15,
        userDefaultsKey: "markdown.fontSize"
    )

    /// Default body prose font family for newly opened markdown viewers.
    ///
    /// Empty means the System/GitHub markdown stack. Code blocks continue to use
    /// the viewer's monospace stack.
    public let fontFamily = DefaultsKey<String>(
        id: "markdown.fontFamily",
        defaultValue: "",
        userDefaultsKey: "markdown.fontFamily"
    )

    /// Default maximum reading column width, in CSS pixels, for newly opened
    /// markdown viewers.
    public let maxWidth = DefaultsKey<Int>(
        id: "markdown.maxWidth",
        defaultValue: 980,
        userDefaultsKey: "markdown.maxWidth"
    )

    /// What the viewer paints its page on: `terminal` or `solid`.
    ///
    /// `terminal` — the default, and the only behaviour before this key existed
    /// — leaves the page canvas transparent so the terminal's own background
    /// shows through and the panel matches whatever theme is set. `solid` paints
    /// the canvas github-markdown.css was designed against: `#ffffff` in light
    /// and `#0d1117` in dark.
    ///
    /// This is a legibility control, not decoration. Under `terminal` the page's
    /// contrast is a function of the terminal theme, so nothing the viewer draws
    /// has a knowable contrast ratio — a colour that reads well on one theme can
    /// be unreadable on another, and the only oracle is a human looking at it.
    /// Under `solid` every ratio is fixed and checkable.
    ///
    /// Defaults to `terminal` so an upgrade changes nothing for anyone.
    public let background = DefaultsKey<String>(
        id: "markdown.background",
        defaultValue: "terminal",
        userDefaultsKey: "markdown.background"
    )

    /// Creates the markdown settings section with its default keys.
    public init() {}
}
