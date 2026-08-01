import Foundation

/// Persistent default for what the markdown viewer paints its page on
/// (`markdown.background`).
///
/// Shape mirrors ``MarkdownMaxWidthSettings`` so the four `markdown.*` keys read
/// the same way: a key, a resolved default, a setter, and a reset.
///
/// The distinction this controls is legibility, not decoration. Under
/// ``MarkdownBackgroundStyle/terminal`` the page canvas is transparent and the
/// terminal's own background shows through, so nothing the viewer draws has a
/// knowable contrast ratio — it depends on a theme this code cannot see, and the
/// only oracle is a human looking at it. Under ``MarkdownBackgroundStyle/solid``
/// the canvas is the one `github-markdown.css` was designed against, so every
/// ratio is fixed and checkable.
enum MarkdownBackgroundSettings {
    /// UserDefaults / cmux.json key (`markdown.background`).
    static let key = "markdown.background"

    /// The pre-existing behaviour, and the default: an upgrade must not repaint
    /// anyone's panel.
    static let defaultStyle: MarkdownBackgroundStyle = .terminal

    /// Reads the persisted default, falling back to ``defaultStyle``.
    ///
    /// An unrecognised string resolves to `terminal` rather than throwing or
    /// picking `solid`: a typo in `cmux.json` must leave the panel as it was.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> MarkdownBackgroundStyle {
        MarkdownBackgroundStyle(rawValueOrTerminal: defaults.string(forKey: key))
    }

    static func setDefault(_ style: MarkdownBackgroundStyle, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: key)
    }

    static func resetDefault(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
