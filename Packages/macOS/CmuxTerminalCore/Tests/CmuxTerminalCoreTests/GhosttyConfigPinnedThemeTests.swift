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

    @Test func oneSidedThemeIsNotPinnedBecauseTheOtherSideKeepsTheDefault() {
        // Regression, cold review 2026-08-02. This suite previously asserted the
        // opposite, on the reasoning that `resolveThemeName` falls back across
        // sides — but that resolver is not what decides the terminal's colors.
        // `appliedThemeName` is, and it refuses cross-side fallback: `light:X`
        // gives X in light and *ghostty's default* in dark
        // (`GhosttyConfigConditionalThemeApplicationTests.oneSidedLightThemeIsNotAppliedInDarkAppearance`
        // pins that with real background hexes). Two different backgrounds means
        // the terminal *is* following the appearance, so a caveat here would be
        // false twice over — and would name a theme the dark side never loads.
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("light:Catppuccin Latte") == nil)
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("dark:Catppuccin Mocha") == nil)
    }

    @Test func halfFinishedThemesSetCommandDoesNotProduceAFalseCaveat() {
        // The reachable path, and why this rates higher than a parser edge case:
        // `cmux themes set --light X` writes exactly `theme = light:X`
        // (`CLI/CMUXCLI+Themes.swift` encodedThemeValue), into a config the caveat
        // reads. So a user following this feature's own advice half-way would have
        // been told their terminal is stuck on the theme they just set for light.
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("light:GitHub Light Default") == nil)
    }

    @Test func aConditionalSideOverAnUnconditionalBaseIsStillJudgedOnWhatApplies() {
        // `A,light:B` applies B in light and A in dark — different themes, so it
        // follows. The unconditional token is a base, not a pin.
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("3024 Night,light:3024 Day") == nil)
        // ...but when the base is the only thing either side can reach, it pins.
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances("3024 Night") == "3024 Night")
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

    // MARK: - What the input must be

    @Test func absolutePathThemesArePairedLikeAnyOther() {
        // Theme values can be absolute paths, not just names — a real config on a
        // real machine reads:
        //   theme = light:/Users/…/themes/rose-pine-pink-city-dawn,dark:/Users/…/themes/rose-pine-pink-city-moon
        // Two different paths is a genuine pair, so this correctly stays silent.
        // Pinned because the `/` and `.` in a path are exactly the shape most
        // likely to trip a future change to the token split.
        let pathPair =
            "light:/Users/someone/.config/ghostty/themes/rose-pine-pink-city-dawn," +
            "dark:/Users/someone/.config/ghostty/themes/rose-pine-pink-city-moon"
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances(pathPair) == nil)

        // ...and an absolute path used unconditionally still pins, carrying the
        // path through as the name, since that is what the user would recognise.
        let singlePath = "/Users/someone/.config/ghostty/themes/rose-pine-pink-city-dawn"
        #expect(GhosttyConfig.themeNamePinnedAcrossAppearances(singlePath) == singlePath)
    }

    // MARK: - Agreement with the predicate it is built on

    @Test(arguments: [
        "rose-pine-pink-city-dawn",
        "light:3024 Day,dark:3024 Day",
        "light:Catppuccin Latte",
        "dark:Catppuccin Mocha",
        "3024 Night,light:3024 Day",
        "light:rose-pine-pink-city-dawn,dark:rose-pine-pink-city-moon",
        "light:Andromeda,dark:3024 Day",
        "",
    ])
    func agreesWithWhatGhosttyActuallyApplies(rawThemeValue: String) {
        // The binding that matters. This function must be `appliedThemeName`
        // asked twice and compared — never a second opinion — because
        // `appliedThemeName` is what decides the terminal's colors.
        //
        // It deliberately does NOT bind to
        // `themeValueUsesSameResolvedThemeInBothColorSchemes`, which an earlier
        // version of this suite pinned it to. That predicate is built on
        // `resolveThemeName`'s cross-side fallback, and its own consumer
        // (`runtimeColorSchemeForConfigLoad`) only uses it to hold a runtime
        // color scheme steady, where a wrong answer is harmless. Shown to a user
        // as a sentence, the same wrong answer is a false statement.
        let pinnedName = GhosttyConfig.themeNamePinnedAcrossAppearances(rawThemeValue)
        let light = GhosttyConfig.appliedThemeName(from: rawThemeValue, preferredColorScheme: .light)
        let dark = GhosttyConfig.appliedThemeName(from: rawThemeValue, preferredColorScheme: .dark)
        let bothSidesApplyTheSameTheme = light != nil && dark != nil
            && light!.caseInsensitiveCompare(dark!) == .orderedSame
        #expect((pinnedName != nil) == bothSidesApplyTheSameTheme)
    }

    @Test func theNameIsTheThemeGhosttyActuallyApplies() {
        // Whatever name the caveat prints must be the name the terminal really
        // loads, or the message points at a theme the user cannot find.
        let raw = "rose-pine-pink-city-dawn"
        let pinnedName = GhosttyConfig.themeNamePinnedAcrossAppearances(raw)
        #expect(pinnedName == GhosttyConfig.appliedThemeName(from: raw, preferredColorScheme: .light))
        #expect(pinnedName == GhosttyConfig.appliedThemeName(from: raw, preferredColorScheme: .dark))
    }
}
