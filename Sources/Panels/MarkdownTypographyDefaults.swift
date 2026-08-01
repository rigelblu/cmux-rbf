import Foundation

/// Writes the markdown viewer defaults (size, font, width, and page canvas).
///
/// Writing the keys triggers `UserDefaults.didChangeNotification`, which open
/// viewers observe: those still on the previous default adopt the new one, while
/// individually customized viewers keep their settings. The same path applies a
/// `markdown.*` change from `cmux.json` (the config file store writes the managed
/// values to `UserDefaults.standard`), so `cmux reload-config` refreshes open
/// viewers too.
enum MarkdownTypographyDefaults {
    static func setDefault(
        fontSize: Double,
        fontFamily: String,
        maxContentWidth: Double,
        background: MarkdownBackgroundStyle,
        defaults: UserDefaults = .standard
    ) {
        MarkdownFontSizeSettings.setDefault(fontSize, defaults: defaults)
        MarkdownFontFamily.setDefault(fontFamily, defaults: defaults)
        MarkdownMaxWidthSettings.setDefault(maxContentWidth, defaults: defaults)
        MarkdownBackgroundSettings.setDefault(background, defaults: defaults)
    }

    static func resetToBuiltInDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: MarkdownFontSizeSettings.key)
        MarkdownFontFamily.setDefault(MarkdownFontFamily.systemDefault, defaults: defaults)
        MarkdownMaxWidthSettings.resetDefault(defaults: defaults)
        MarkdownBackgroundSettings.resetDefault(defaults: defaults)
    }
}
