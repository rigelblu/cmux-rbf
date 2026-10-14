import Foundation

/// Figma's outline icon, the image on the header's Figma button.
///
/// The app ships one file, `FigmaOutlineIcon.svg` in its Resources: Figma's own
/// path, its path data unchanged, with `fill="currentColor"` where Figma's file
/// has `fill="black"` and the canvas cut to the icon's bounds. The header tints
/// image data that is SVG text holding `currentColor` in its first 4,096 bytes,
/// so the icon takes the colour of the buttons beside it.
///
/// It reaches the header as the built-in's default icon, through the `imagePath`
/// icon a config file can already name (``CmuxSurfaceTabBarBuiltInAction/defaultButtonIcon``).
enum FigmaButtonIcon {

    static let resourceName = "FigmaOutlineIcon"
    static let resourceExtension = "svg"

    /// Where the shipped file is in the running app, standardized, or `nil` when
    /// it is not there. Looked up once, so every question about "the shipped
    /// path" is put to the same answer.
    static let shippedPath: String? = Bundle.main
        .path(forResource: resourceName, ofType: resourceExtension)
        .map { ($0 as NSString).standardizingPath }

    /// Whether `path` is the shipped file, by exact equality with ``shippedPath``
    /// once standardized. The icon-path check refuses an absolute path from a
    /// project's own `cmux.json`; the app's own image is not the project's to
    /// refuse, so it passes the check whichever file listed the button.
    static func isShipped(path: String) -> Bool {
        guard let shipped = shippedPath else { return false }
        return (path as NSString).standardizingPath == shipped
    }

    /// The header's whole test for tinting an image: SVG text holding `currentColor`
    /// in its first 4,096 bytes. A menu row asks the same, so it tints as the header does.
    ///
    /// **A copy, on purpose.** The original is `TabBarStyling.imageDataShouldRenderAsTemplate(_:)` in
    /// `Packages/macOS/Bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift`, an internal function of a
    /// shared package. The fork does not change Bonsplit's tint rule; it copies it here, because a menu row in
    /// the app cannot call it. The two must stay equal: when that function changes on an upstream sync, change
    /// this one to match.
    static func drawsAsTemplate(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        return text.contains("<svg") && text.contains("currentcolor")
    }
}

extension CmuxSurfaceTabBarBuiltInAction {

    /// The icon the header draws for this built-in when `cmux.json` names none:
    /// Figma's outline image for the Figma button, a symbol for the rest. The
    /// symbol stays `defaultIcon` for the Figma button too, and is what is drawn
    /// where only a symbol can be, or if the shipped file is not in the app.
    var defaultButtonIcon: CmuxButtonIcon {
        if self == .newFigma, let path = FigmaButtonIcon.shippedPath {
            return .imagePath(path)
        }
        return .symbol(defaultIcon)
    }
}
