import Foundation
import Testing
@testable import CmuxTerminalCore

/// Unit coverage for ``GhosttyConfig/themeNamePinnedAcrossAppearances(_:)`` —
/// the question "can this terminal theme follow the system appearance at all?",
/// answered with the theme's name so a caveat can say something actionable.
///
/// The behavior under test is mostly about *silence*: a `nil` result means the
/// theme follows the appearance and nothing should be said. Every case that
/// wrongly returns a name is a caveat shown to someone who does not have the
/// problem, which is the failure mode that teaches readers to ignore the row.
@Suite struct GhosttyConfigPinnedThemeTests {
    // MARK: - Pinned: the caveat is owed

    @Test func unconditionalThemeIsPinnedAndCarriesItsName() {
        // The reported case (#cm-21): one theme, no light:/dark: token, so
        // `resolveThemeName` returns it for both sides via `fallbackTheme`.
        #expect(
            GhosttyConfig.themeNamePinnedAcrossAppearances("rose-pine-pink-city-dawn")
                == "rose-pine-pink-city-dawn"
        )
    }

    @Test func sameThemeOnBothSidesIsPinned() {
        #expect(
            GhosttyConfig.themeNamePinnedAcrossAppearances("light:3024 Day,dark:3024 Day") == "3024 Day"
        )
    }

    @Test func oneSidedThemeIsPinnedBecauseTheResolverFallsBackAcrossSides() {
        // `light:X` with no dark token resolves X for dark too
        // (GhosttyConfig.resolveThemeName's fallback ladder), so the terminal
        // still cannot follow — the caveat is owed even though the raw value
        // *looks* conditional.
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("light:Catppuccin Latte") == "Catppuccin Latte")
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("dark:Catppuccin Mocha") == "Catppuccin Mocha")
    }

    @Test func caseAndWhitespaceDifferencesAreStillTheSameTheme() {
        // Matching `themeValueUsesSameResolvedThemeInBothColorSchemes`, which
        // compares case-insensitively: two spellings of one theme are one theme,
        // and claiming otherwise would silence a caveat that is owed.
        #expect(
            GhosttyConfig.themeNamePinnedAcrossAppearances("light: 3024 Day , dark:3024 DAY") == "3024 Day"
        )
    }

    // MARK: - Not pinned: silence

    @Test func distinctLightAndDarkThemesAreNotPinned() {
        // The fix Tom applied to his own config.
        #expect(
            GhosttyConfig.themeNamePinnedAcrossAppearances(
                "light:rose-pine-pink-city-dawn,dark:rose-pine-pink-city-moon"
            ) == nil
        )
    }

    @Test func noThemeDirectiveIsNotPinned() {
        // No `theme` at all means cmux's managed default appearance applies, and
        // that one does follow — so there is nothing to warn about.
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances(nil) == nil)
    }

    @Test func emptyAndWhitespaceOnlyValuesAreNotPinned() {
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("") == nil)
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("   ") == nil)
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("\n\t ") == nil)
    }

    // MARK: - Agreement with the predicate it is built on

    @Test(arguments: [
        "rose-pine-pink-city-dawn",
        "light:3024 Day,dark:3024 Day",
        "light:Catppuccin Latte",
        "light:rose-pine-pink-city-dawn,dark:rose-pine-pink-city-moon",
        "light:Andromeda,dark:3024 Day",
        "",
    ])
    func neverDisagreesWithTheExistingPredicate(rawThemeValue: String) {
        // The name-carrying function must be the predicate plus a name, never a
        // second opinion: a drift between these two would put the caveat's text
        // and the terminal's actual color decision on different parsers.
        let pinnedName = GhosttyConfig.themeNamePinnedAcrossAppearances(rawThemeValue)
        let predicate = GhosttyConfig.themeValueUsesSameResolvedThemeInBothColorSchemes(rawThemeValue)
        #expect((pinnedName != nil) == predicate)
    }

    @Test func theNameIsTheThemeThatActuallyResolves() {
        // Whatever name the caveat prints must be the name the resolver hands the
        // terminal, or the message points at a theme the user cannot find.
        let raw = "light:Catppuccin Latte"
        let pinnedName = GhosttyConfig.themeNamePinnedAcrossAppearances(raw)
        #expect(pinnedName == GhosttyConfig.resolveThemeName(from: raw, preferredColorScheme: .light))
        #expect(pinnedName == GhosttyConfig.resolveThemeName(from: raw, preferredColorScheme: .dark))
    }
}
