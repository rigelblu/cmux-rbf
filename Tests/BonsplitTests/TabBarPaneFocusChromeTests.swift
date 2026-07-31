import AppKit
import Testing

@testable import Bonsplit

@Suite
struct TabBarPaneFocusChromeTests {
    @Test
    func visibleOnlyForFocusedSingleSurfacePaneInOptedInMultiPaneLayout() {
        #expect(chrome(enabled: true, presentation: .caption, focused: true, paneCount: 2).isVisible)
        #expect(!chrome(enabled: true, presentation: .tabs, focused: true, paneCount: 2).isVisible)
        #expect(!chrome(enabled: true, presentation: .caption, focused: false, paneCount: 2).isVisible)
        #expect(!chrome(enabled: true, presentation: .caption, focused: true, paneCount: 1).isVisible)
        #expect(!chrome(enabled: true, presentation: .caption, focused: true, paneCount: 2, surfaceCount: 0).isVisible)
        #expect(!chrome(enabled: true, presentation: .caption, focused: true, paneCount: 2, surfaceCount: 2).isVisible)
        #expect(!chrome(enabled: false, presentation: .caption, focused: true, paneCount: 2).isVisible)
    }

    /// Finding 43. `paneCount` counts the layout's panes, including the ones
    /// zoom is hiding, so a zoomed one-surface caption drew the multi-pane
    /// focus rule with only one pane on screen and nothing to contrast against.
    @Test
    func zoomSuppressesTheRuleEvenWhenTheLayoutHasSeveralPanes() {
        #expect(
            chrome(
                enabled: true,
                presentation: .caption,
                focused: true,
                paneCount: 3,
                isAnyPaneZoomed: true
            ).color == nil
        )
        // The same layout unzoomed still draws it.
        #expect(
            chrome(
                enabled: true,
                presentation: .caption,
                focused: true,
                paneCount: 3,
                isAnyPaneZoomed: false
            ).isVisible
        )
    }

    @Test
    func passingAccentRemainsUnchanged() {
        let foreground = rgb(0x6E, 0xD1, 0xC0)
        let background = rgb(0x1B, 0x1E, 0x1B)

        let adjusted = TabBarPaneFocusChrome.contrastAdjustedColor(
            foreground,
            against: background
        )

        #expect(colorDistance(adjusted, foreground) < 0.0001)
        #expect(
            TabBarPaneFocusChrome.contrastRatio(adjusted, background)
                >= TabBarPaneFocusChrome.minimumContrastRatio
        )
    }

    @Test
    func lowContrastAccentMovesToNearestPassingLuminance() {
        let foreground = rgb(0x74, 0x74, 0x74)
        let background = rgb(0x77, 0x77, 0x77)

        let adjusted = TabBarPaneFocusChrome.contrastAdjustedColor(
            foreground,
            against: background
        )
        let ratio = TabBarPaneFocusChrome.contrastRatio(adjusted, background)

        #expect(ratio >= TabBarPaneFocusChrome.minimumContrastRatio)
        #expect(ratio < TabBarPaneFocusChrome.minimumContrastRatio + 0.001)
    }

    /// Finding 26. The superseded test asserted the inactive color was
    /// achromatic and cleared 3:1 — both of which the defective code satisfied,
    /// so it could not fail. What it never checked is the only thing that
    /// matters: that a non-key window looks different from a key one.
    ///
    /// Graphite is the input that breaks every color-derivation approach,
    /// because an achromatic accent survives any luma-preserving transform.
    @Test
    func nonKeyWindowDrawsNoRuleForEveryAccentIncludingGraphite() {
        let graphite = rgb(0x98, 0x98, 0x98)
        let chromatic = rgb(0x35, 0xC7, 0x9A)

        for accent in [graphite, chromatic] {
            #expect(keyed(false, accent: accent).color == nil)
            #expect(keyed(true, accent: accent).isVisible)
        }
    }

    /// Finding 26's regression guard. Presence is the cue, so key and non-key
    /// can never render the same pixels no matter what the accent is.
    @Test
    func keyAndNonKeyNeverRenderTheSameRule() {
        for accent in [rgb(0x98, 0x98, 0x98), rgb(0x35, 0xC7, 0x9A), rgb(0, 0, 0)] {
            #expect(keyed(true, accent: accent).color != keyed(false, accent: accent).color)
        }
    }

    private func keyed(_ isWindowKey: Bool, accent: NSColor) -> TabBarPaneFocusChrome {
        TabBarPaneFocusChrome(
            isEnabled: true,
            presentation: .caption,
            isFocused: true,
            paneCount: 2,
            surfaceCount: 1,
            isWindowKey: isWindowKey,
            isAnyPaneZoomed: false,
            resolvedBackgroundColor: rgb(0x1B, 0x1E, 0x1B),
            accentColor: accent
        )
    }

    private func chrome(
        enabled: Bool,
        presentation: PaneHeaderPresentation,
        focused: Bool,
        paneCount: Int,
        surfaceCount: Int = 1,
        isAnyPaneZoomed: Bool = false
    ) -> TabBarPaneFocusChrome {
        TabBarPaneFocusChrome(
            isEnabled: enabled,
            presentation: presentation,
            isFocused: focused,
            paneCount: paneCount,
            surfaceCount: surfaceCount,
            isWindowKey: true,
            isAnyPaneZoomed: isAnyPaneZoomed,
            resolvedBackgroundColor: rgb(0x1B, 0x1E, 0x1B)
        )
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.usingColorSpace(.sRGB) ?? lhs
        let right = rhs.usingColorSpace(.sRGB) ?? rhs
        return abs(left.redComponent - right.redComponent)
            + abs(left.greenComponent - right.greenComponent)
            + abs(left.blueComponent - right.blueComponent)
    }

    private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }
}
