import AppKit

struct TabBarPaneFocusChrome {
    static let lineWidth: CGFloat = 2
    static let minimumContrastRatio: CGFloat = 3

    let color: NSColor?

    var isVisible: Bool {
        color != nil
    }

    init(
        isEnabled: Bool,
        presentation: PaneHeaderPresentation,
        isFocused: Bool,
        paneCount: Int,
        surfaceCount: Int,
        isWindowKey: Bool,
        isAnyPaneZoomed: Bool,
        resolvedBackgroundColor: NSColor,
        accentColor: NSColor = .controlAccentColor
    ) {
        // A non-key window draws no rule, the way AppKit's own focus rings
        // vanish on resign-key. Restyling it instead cannot work: any base
        // color that already clears the minimum ratio passes through
        // `contrastAdjustedColor` untouched, so key and non-key converge —
        // exactly the chroma-only, luminance-preserving cue this type exists
        // to replace. Presence is the one difference the normalizer cannot
        // erase.
        // Zoom collapses the workspace to one visible pane, so the rule has
        // nothing to distinguish this pane from — the same reason it is
        // suppressed in a solo-pane workspace. `paneCount` counts the layout's
        // panes, including the ones zoom is hiding, so it cannot answer this
        // on its own.
        guard isEnabled,
              presentation == .caption,
              isFocused,
              isWindowKey,
              paneCount > 1,
              !isAnyPaneZoomed,
              surfaceCount == 1 else {
            color = nil
            return
        }

        color = Self.contrastAdjustedColor(
            accentColor,
            against: resolvedBackgroundColor
        )
    }

    static func contrastAdjustedColor(
        _ foreground: NSColor,
        against background: NSColor,
        minimumRatio: CGFloat = minimumContrastRatio
    ) -> NSColor {
        let resolvedBackground = opaqueColor(background)
        let resolvedForeground = opaqueColor(foreground, over: resolvedBackground)
        guard contrastRatio(resolvedForeground, resolvedBackground) < minimumRatio else {
            return resolvedForeground
        }

        let lighter = minimumPassingBlend(
            from: resolvedForeground,
            toward: .white,
            against: resolvedBackground,
            minimumRatio: minimumRatio
        )
        let darker = minimumPassingBlend(
            from: resolvedForeground,
            toward: .black,
            against: resolvedBackground,
            minimumRatio: minimumRatio
        )

        switch (lighter, darker) {
        case let (.some(light), .some(dark)):
            return light.amount <= dark.amount ? light.color : dark.color
        case let (.some(light), .none):
            return light.color
        case let (.none, .some(dark)):
            return dark.color
        case (.none, .none):
            let whiteContrast = contrastRatio(.white, resolvedBackground)
            let blackContrast = contrastRatio(.black, resolvedBackground)
            return whiteContrast >= blackContrast ? .white : .black
        }
    }

    static func contrastRatio(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
        let foregroundLuminance = relativeLuminance(opaqueColor(foreground))
        let backgroundLuminance = relativeLuminance(opaqueColor(background))
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func minimumPassingBlend(
        from foreground: NSColor,
        toward endpoint: NSColor,
        against background: NSColor,
        minimumRatio: CGFloat
    ) -> (color: NSColor, amount: CGFloat)? {
        let resolvedEndpoint = opaqueColor(endpoint)
        guard contrastRatio(resolvedEndpoint, background) >= minimumRatio else {
            return nil
        }

        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<24 {
            let midpoint = (lower + upper) / 2
            let candidate = blend(foreground, toward: resolvedEndpoint, amount: midpoint)
            if contrastRatio(candidate, background) >= minimumRatio {
                upper = midpoint
            } else {
                lower = midpoint
            }
        }

        return (
            color: blend(foreground, toward: resolvedEndpoint, amount: upper),
            amount: upper
        )
    }

    private static func blend(
        _ color: NSColor,
        toward endpoint: NSColor,
        amount: CGFloat
    ) -> NSColor {
        let source = opaqueColor(color)
        let target = opaqueColor(endpoint)
        let clampedAmount = min(max(amount, 0), 1)
        let inverse = 1 - clampedAmount
        return NSColor(
            srgbRed: source.redComponent * inverse + target.redComponent * clampedAmount,
            green: source.greenComponent * inverse + target.greenComponent * clampedAmount,
            blue: source.blueComponent * inverse + target.blueComponent * clampedAmount,
            alpha: 1
        )
    }

    /// Drops alpha and keeps RGB — the same call `TabBarColors.contrastReference`
    /// makes, for the same reason. This rule sits over the terminal backdrop,
    /// so compositing over `windowBackgroundColor` would guess at pixels the
    /// view cannot see, and would move the rule's color with `background-opacity`.
    private static func opaqueColor(_ color: NSColor) -> NSColor {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return NSColor(
            srgbRed: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: 1
        )
    }

    /// Composites a translucent foreground over a backdrop the caller knows.
    private static func opaqueColor(
        _ color: NSColor,
        over background: NSColor
    ) -> NSColor {
        let foreground = color.usingColorSpace(.sRGB) ?? color
        let backdrop = background.usingColorSpace(.sRGB) ?? background
        let alpha = min(max(foreground.alphaComponent, 0), 1)
        let inverse = 1 - alpha
        return NSColor(
            srgbRed: foreground.redComponent * alpha + backdrop.redComponent * inverse,
            green: foreground.greenComponent * alpha + backdrop.greenComponent * inverse,
            blue: foreground.blueComponent * alpha + backdrop.blueComponent * inverse,
            alpha: 1
        )
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let resolved = opaqueColor(color)
        return 0.2126 * linearized(resolved.redComponent)
            + 0.7152 * linearized(resolved.greenComponent)
            + 0.0722 * linearized(resolved.blueComponent)
    }

    private static func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }
}
