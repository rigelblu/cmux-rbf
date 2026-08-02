import CmuxSettings
import Foundation

/// Decides whether the Theme picker owes the reader a caveat, and what it says.
///
/// Split out of ``ThemePickerRow`` as a pure function so the *decision* is
/// testable without a view: the interesting behavior is not how the line looks
/// but the three cases where it must stay silent.
enum ThemePickerCaveat {
    /// The caveat to show under the "Theme" title, or `nil` when the row should
    /// say nothing.
    ///
    /// - Parameters:
    ///   - selectedMode: The appearance mode the picker currently shows selected.
    ///   - pinnedThemeName: The theme name pinned across both appearances, or
    ///     `nil` when the terminal theme follows the appearance.
    ///
    /// Silent unless the selected mode is ``AppearanceMode/system``. Under an
    /// explicit Light or Dark there is nothing for the terminal to follow, so a
    /// pinned theme is exactly what the user asked for and saying so would be
    /// noise — this is the case most likely to be got wrong, because the
    /// underlying config is *identically* pinned in all three modes and only the
    /// promise differs.
    static func subtitle(
        selectedMode: AppearanceMode,
        pinnedThemeName: String?
    ) -> String? {
        guard selectedMode == .system else { return nil }
        guard let pinnedThemeName, !pinnedThemeName.isEmpty else { return nil }
        return String(
            localized: "settings.app.theme.pinnedAcrossAppearances",
            defaultValue: "Terminal keeps “\(pinnedThemeName)” in both appearances. Set separate light and dark themes for it to follow System."
        )
    }
}
