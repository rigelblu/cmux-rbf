import AppKit
import Testing

@testable import Bonsplit

@Suite
struct SurfaceCaptionChromeTests {
    @Test
    func hostOwnsTabKindToBackgroundMapping() {
        let appearance = BonsplitConfiguration.Appearance(
            surfaceCaptionBackgroundStyle: .transparentOverChrome,
            surfaceCaptionBackgroundStyleOverrides: ["shell": .chrome]
        )

        #expect(appearance.surfaceCaptionBackgroundStyle(forTabKind: "shell") == .chrome)
        #expect(
            appearance.surfaceCaptionBackgroundStyle(forTabKind: "terminal")
                == .transparentOverChrome
        )
        #expect(
            appearance.surfaceCaptionBackgroundStyle(forTabKind: nil)
                == .transparentOverChrome
        )
    }

    @Test
    func chromeStylePaintsAndMeasuresTheSameResolvedSurface() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#1B1E1B")
        )
        let chrome = SurfaceCaptionChrome(style: .chrome, appearance: appearance)

        #expect(chrome.surfaceColor.alphaComponent > 0.99)
        #expect(colorDistance(chrome.surfaceColor, chrome.resolvedBackgroundColor) < 0.0001)
    }

    @Test
    func transparentStyleMeasuresAgainstTheHostChromeItReveals() {
        let appearance = BonsplitConfiguration.Appearance(
            chromeColors: .init(backgroundHex: "#101820")
        )
        let chrome = SurfaceCaptionChrome(
            style: .transparentOverChrome,
            appearance: appearance
        )
        let expectedBackground = NSColor(
            srgbRed: 0x10 / 255,
            green: 0x18 / 255,
            blue: 0x20 / 255,
            alpha: 1
        )
        let resolvedText = NSColor(chrome.activeTextColor)

        #expect(chrome.surfaceColor.alphaComponent == 0)
        #expect(
            colorDistance(chrome.resolvedBackgroundColor, expectedBackground)
                < 0.0001
        )
        #expect(
            TabBarPaneFocusChrome.contrastRatio(
                resolvedText,
                chrome.resolvedBackgroundColor
            ) >= 4.5
        )
        #expect(
            colorDistance(chrome.resolvedBackgroundColor, .windowBackgroundColor)
                > 0.1
        )
    }

    /// cmux's shared-backdrop shape: the tab-bar hex is the `#00000000`
    /// sentinel meaning "no fill", and the real backdrop is the chrome hex,
    /// which carries the terminal's alpha for any `background-opacity < 1`.
    private static func sharedBackdropAppearance(
        terminalHex: String
    ) -> BonsplitConfiguration.Appearance {
        BonsplitConfiguration.Appearance(
            chromeColors: .init(
                backgroundHex: terminalHex,
                tabBarBackgroundHex: "#00000000",
                splitButtonBackdropHex: "#00000000",
                paneBackgroundHex: "#00000000"
            )
        )
    }

    /// Finding 24. The caption and the tab strip render over one backdrop, so
    /// they must pick one text color. Before the fix the caption composited the
    /// chrome hex over `windowBackgroundColor` while tab mode read it raw, and
    /// the two disagreed for every alpha-carrying hex.
    @Test
    func captionAndTabModeAgreeOnAnAlphaCarryingBackdrop() {
        // 0x8C == 0.549 alpha — below the ~0.57 point where the old
        // composite flipped the caption to black on a dark terminal.
        let appearance = Self.sharedBackdropAppearance(terminalHex: "#1B1E1B8C")
        let caption = SurfaceCaptionChrome(
            style: .transparentOverChrome,
            appearance: appearance
        )

        #expect(
            colorDistance(
                NSColor(caption.activeTextColor),
                TabBarColors.nsColorActiveText(for: appearance)
            ) < 0.0001
        )
        #expect(
            colorDistance(
                NSColor(caption.inactiveTextColor),
                TabBarColors.nsColorInactiveText(for: appearance)
            ) < 0.0001
        )
    }

    /// Finding 24, the property worth keeping. Ghostty judges its own text
    /// against `bg.rgb` and never reads `bg.a`, so the caption's text color
    /// must not move when only `background-opacity` moves.
    @Test
    func captionTextColorIsStableAcrossEveryBackgroundOpacity() {
        let opaque = Self.sharedBackdropAppearance(terminalHex: "#1B1E1BFF")
        let reference = NSColor(
            SurfaceCaptionChrome(style: .transparentOverChrome, appearance: opaque)
                .activeTextColor
        )

        // "00" is the boundary case, not a formality: a fully transparent hex
        // still carries the backdrop's real RGB, and an earlier pass of this
        // fix discarded it there. A loop that stops at "0D" cannot express the
        // failure this test is named for.
        for alphaHex in ["BF", "8C", "40", "0D", "00"] {
            let appearance = Self.sharedBackdropAppearance(
                terminalHex: "#1B1E1B\(alphaHex)"
            )
            let caption = SurfaceCaptionChrome(
                style: .transparentOverChrome,
                appearance: appearance
            )

            #expect(
                colorDistance(NSColor(caption.activeTextColor), reference) < 0.0001,
                "alpha \(alphaHex) moved the caption's text color"
            )
            #expect(
                TabBarColors.nsColorResolvedChromeBackground(for: appearance)
                    .alphaComponent == 1,
                "alpha \(alphaHex) survived into the contrast reference"
            )
        }
    }

    /// Finding 24. A dark terminal must keep light text no matter the opacity;
    /// the old composite over a light `windowBackgroundColor` inverted it.
    @Test
    func darkTerminalKeepsLegibleTextAtLowOpacity() {
        let appearance = Self.sharedBackdropAppearance(terminalHex: "#1B1E1B40")
        let caption = SurfaceCaptionChrome(
            style: .transparentOverChrome,
            appearance: appearance
        )
        let terminalRGB = NSColor(
            srgbRed: 0x1B / 255,
            green: 0x1E / 255,
            blue: 0x1B / 255,
            alpha: 1
        )

        #expect(colorDistance(caption.resolvedBackgroundColor, terminalRGB) < 0.0001)
        #expect(
            TabBarPaneFocusChrome.contrastRatio(
                NSColor(caption.activeTextColor),
                terminalRGB
            ) >= 4.5
        )
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let left = lhs.usingColorSpace(.sRGB) ?? lhs
        let right = rhs.usingColorSpace(.sRGB) ?? rhs
        return abs(left.redComponent - right.redComponent)
            + abs(left.greenComponent - right.greenComponent)
            + abs(left.blueComponent - right.blueComponent)
            + abs(left.alphaComponent - right.alphaComponent)
    }
}
