import CmuxSettings
import Foundation
import Testing
@testable import CmuxSettingsUI

/// Unit coverage for ``ThemePickerCaveat/subtitle(selectedMode:pinnedThemeName:)``.
///
/// The Theme picker's System tile is a split light/dark thumbnail — a picture of
/// the app switching. This decides when that picture is a half-truth and the row
/// owes the reader a caveat.
///
/// Note what makes the mode gate non-obvious: the *config* is identically pinned
/// in all three modes. Only the promise differs, so a test that varies the theme
/// value while holding the mode at `.system` would pass with the gate deleted.
@MainActor
@Suite struct ThemePickerCaveatTests {
    private let pinned = "rose-pine-pink-city-dawn"

    @Test func systemModeWithAPinnedThemeGetsTheCaveat() {
        let subtitle = ThemePickerCaveat.subtitle(selectedMode: .system, pinnedThemeName: pinned)
        #expect(subtitle != nil)
    }

    @Test func theCaveatNamesTheThemeThatIsPinned() {
        // "Your theme is pinned" is not actionable; the theme's own name is what
        // lets the reader find and change it.
        let subtitle = ThemePickerCaveat.subtitle(selectedMode: .system, pinnedThemeName: pinned)
        #expect(subtitle?.contains(pinned) == true)
    }

    @Test func systemModeWithAFollowingThemeStaysSilent() {
        #expect(ThemePickerCaveat.subtitle(selectedMode: .system, pinnedThemeName: nil) == nil)
    }

    // MARK: - The mode gate

    @Test(arguments: [AppearanceMode.light, AppearanceMode.dark])
    func explicitModesStaySilentEvenWhenTheThemeIsPinned(mode: AppearanceMode) {
        // Under an explicit Light or Dark there is nothing for the terminal to
        // follow, so a pinned theme is exactly what was asked for. This is the
        // case most likely to be got wrong: the pinned-theme input is identical
        // to the passing case above and only the mode changed.
        #expect(ThemePickerCaveat.subtitle(selectedMode: mode, pinnedThemeName: pinned) == nil)
    }

    // MARK: - Degenerate input

    @Test func anEmptyThemeNameIsTreatedAsNotPinned() {
        // A caveat naming no theme would be worse than none: it states a problem
        // and withholds the one fact that makes it fixable.
        #expect(ThemePickerCaveat.subtitle(selectedMode: .system, pinnedThemeName: "") == nil)
    }
}
