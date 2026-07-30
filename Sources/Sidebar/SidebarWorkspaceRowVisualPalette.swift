import AppKit
import CmuxSettings
import SwiftUI

/// Resolves every color used by a workspace row from one immutable snapshot.
///
/// Keeping foreground and chrome decisions together prevents the AppKit and
/// SwiftUI row renderers from drifting when a workspace changes state.
struct SidebarWorkspaceRowVisualPalette {
    let colorScheme: ColorScheme
    let isActive: Bool
    let backgroundStyle: SidebarWorkspaceRowBackgroundStyle
    let identityColor: NSColor?
    let stripColor: NSColor?
    let primaryTextColor: NSColor
    let badgeFillColor: NSColor
    let badgeTextColor: NSColor
    let progressTrackColor: NSColor
    let progressFillColor: NSColor

    /// Width of the leading identity strip's body. The strip runs the row's
    /// full height, flush to the leading edge. Both row renderers read this one
    /// value.
    static let accentStripWidth: CGFloat = 5

    /// Radius of the strip's **inverse** (concave) trailing corners. The path
    /// widens to `accentStripWidth + accentStripFlareRadius` at its very top and
    /// bottom and curves inward to `accentStripWidth`, so it flares into the row
    /// rather than tapering to a rounded tip.
    ///
    /// What the user sees is narrower than that. This radius equals the row
    /// background's own corner radius, and the background clips the strip, so
    /// the two arcs cancel: the visible result is a constant-width band that
    /// follows the row's corner. Changing this without changing the row's
    /// corner radius breaks that cancellation and the band stops being even.
    ///
    /// This is deliberately not a `cornerRadius`. A corner radius can only
    /// subtract material, so it can only ever produce a convex tip — no value of
    /// it expresses this curve. The shape is stated as a path instead. Matches
    /// the row's own 6pt corner so the flare reads as part of the row's edge.
    static let accentStripFlareRadius: CGFloat = 6

    /// Total width the strip's layer must occupy to contain the flare. The
    /// visible body stays `accentStripWidth`; only the extreme top and bottom
    /// reach this far.
    static let accentStripLayerWidth: CGFloat = accentStripWidth + accentStripFlareRadius

    /// Breathing room between the strip's trailing edge and row content. Set so
    /// a 5pt strip needs no content shift at all — 5pt strip + 5pt gap is
    /// exactly the row's existing 10pt content padding.
    static let accentStripContentGap: CGFloat = 5

    /// Weight of the workspace colour in a resting row's wash, applied as a
    /// layer *alpha* over whatever the sidebar material composites against.
    ///
    /// The active strip's tint reuses this number as a *blend fraction against
    /// white* — deliberately the same weight, but not the same operation. The
    /// two agree in light appearance and diverge in dark, where a resting wash
    /// composites dark while the active tint stays a light pastel. Do not read
    /// this as "the strip wears the row's resting colour".
    static let restingWashOpacity: CGFloat = 0.14

    /// Extra leading inset row content needs so the title clears the strip.
    /// Resolves to 0 at the shipped 5pt width (5 + 5 gap == the row's 10pt
    /// content padding); it only becomes non-zero if the strip is widened.
    static func accentStripContentInset(contentPadding: CGFloat) -> CGFloat {
        // Measured against the strip's body width, not the flare: the flare only
        // reaches its full width at the extreme top and bottom of the row, well
        // clear of the vertically-centred content.
        max(0, accentStripWidth + accentStripContentGap - contentPadding)
    }

    /// Silhouette of the Accent Strip: a `bodyWidth` bar whose trailing corners
    /// are **inverse** (concave). It reaches `bodyWidth + flare` at the top and
    /// bottom edges and curves inward to `bodyWidth`, with each arc's centre
    /// outside the shape.
    ///
    /// Both row renderers build their geometry from this one function — the
    /// AppKit cell as a `CAShapeLayer` mask, the SwiftUI row through
    /// ``SidebarAccentStripShape`` — so the two cannot drift. The curve is
    /// vertically symmetric, so it renders identically in AppKit's y-up layer
    /// space and SwiftUI's y-down space.
    static func accentStripPath(in rect: CGRect, bodyWidth: CGFloat, flare: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let body = max(0, min(bodyWidth, rect.width))
        let bodyX = rect.minX + body
        // Two flares share the vertical axis, so each may claim at most half the
        // height; the layer must also be wide enough to hold the flare.
        let r = max(0, min(flare, rect.height / 2, rect.width - body))
        guard r > 0, rect.height > 0 else {
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: body, height: rect.height))
            return path
        }
        let flaredX = bodyX + r
        // Circular-arc approximation constant for a quarter turn.
        let k = 0.5523 * r

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: flaredX, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: bodyX, y: rect.minY + r),
            control1: CGPoint(x: flaredX - k, y: rect.minY),
            control2: CGPoint(x: bodyX, y: rect.minY + r - k)
        )
        path.addLine(to: CGPoint(x: bodyX, y: rect.maxY - r))
        path.addCurve(
            to: CGPoint(x: flaredX, y: rect.maxY),
            control1: CGPoint(x: bodyX, y: rect.maxY - r + k),
            control2: CGPoint(x: flaredX - k, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    private let secondaryBaseColor: NSColor

    init(
        isActive: Bool,
        isMultiSelected: Bool,
        isHovered: Bool,
        isEditing: Bool,
        customColorHex: String?,
        colorScheme: ColorScheme,
        selectionColorHex: String?,
        notificationBadgeColorHex: String?
    ) {
        self.colorScheme = colorScheme
        self.isActive = isActive

        let selectedBackground = sidebarSelectedWorkspaceBackgroundNSColor(
            for: colorScheme,
            sidebarSelectionColorHex: selectionColorHex
        )
        let accentBackground = cmuxAccentNSColor(for: colorScheme)
        // `forceBright` existed only to give Left Rail's bare rail extra punch
        // against an unfilled row. This treatment always pairs the strip with a
        // wash of the same colour, so the display colour stands on its own.
        let identityColor = customColorHex.flatMap {
            WorkspaceTabColorSettings.displayNSColor(
                hex: $0,
                colorScheme: colorScheme,
                forceBright: false
            )
        }
        self.identityColor = identityColor

        let resolvedBackground: SidebarWorkspaceRowBackgroundStyle
        let resolvedStrip: NSColor?
        let resolvedPrimary: NSColor

        if isEditing {
            resolvedBackground = .init(color: selectedBackground, opacity: 1)
            resolvedStrip = identityColor
            resolvedPrimary = cmuxReadableForegroundNSColor(
                on: selectedBackground,
                opacity: 1
            )
        } else if isActive, let identityColor {
            let activeFill = Self.darkenedForWhiteText(identityColor)
            resolvedBackground = .init(color: activeFill, opacity: 1)
            resolvedStrip = Self.activeStripColor(identity: identityColor, on: activeFill)
            resolvedPrimary = .white
        } else if isActive {
            resolvedBackground = .init(color: selectedBackground, opacity: 1)
            resolvedStrip = nil
            resolvedPrimary = sidebarSelectedWorkspaceForegroundNSColor(
                on: selectedBackground,
                opacity: 1
            )
        } else if let identityColor {
            resolvedBackground = .init(
                color: identityColor,
                opacity: isMultiSelected ? 0.35 : (isHovered ? 0.24 : Self.restingWashOpacity)
            )
            resolvedStrip = identityColor
            resolvedPrimary = .labelColor
        } else if isMultiSelected {
            resolvedBackground = .init(color: accentBackground, opacity: 0.25)
            resolvedStrip = nil
            resolvedPrimary = .labelColor
        } else {
            resolvedBackground = .clear
            resolvedStrip = nil
            resolvedPrimary = .labelColor
        }

        backgroundStyle = resolvedBackground
        stripColor = resolvedStrip
        primaryTextColor = resolvedPrimary
        secondaryBaseColor = isActive
            ? resolvedPrimary
            : .secondaryLabelColor

        if let notificationBadgeColorHex,
           let notificationBadgeColor = NSColor(hex: notificationBadgeColorHex) {
            badgeFillColor = notificationBadgeColor
        } else {
            badgeFillColor = isActive
                ? resolvedPrimary.withAlphaComponent(0.25)
                : accentBackground
        }
        badgeTextColor = isActive ? resolvedPrimary : .white
        progressTrackColor = isActive
            ? resolvedPrimary.withAlphaComponent(0.15)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.2)
        progressFillColor = isActive
            ? resolvedPrimary.withAlphaComponent(0.8)
            : accentBackground
    }

    /// On an active row the foreground is derived from the fill, so the caller's
    /// opacity is applied to it. On every other row the system token already
    /// encodes the intended de-emphasis (~0.5 alpha) — multiplying it by the
    /// caller's opacity a second time silently darkened subtitle, description,
    /// metadata, log, progress and branch text on every unselected row.
    func secondaryTextColor(opacity: CGFloat = 0.75) -> NSColor {
        guard isActive else { return secondaryBaseColor }
        return secondaryBaseColor.withAlphaComponent(max(0, min(opacity, 1)))
    }

    private static func darkenedForWhiteText(_ identityColor: NSColor) -> NSColor {
        let opaqueIdentity = (identityColor.usingColorSpace(.sRGB) ?? identityColor)
            .withAlphaComponent(1)
        guard cmuxContrastRatio(foreground: .white, background: opaqueIdentity) < 4.5 else {
            return opaqueIdentity
        }

        var lowerBound: CGFloat = 0
        var upperBound: CGFloat = 1
        for _ in 0..<24 {
            let fraction = (lowerBound + upperBound) / 2
            let candidate = opaqueIdentity.blended(withFraction: fraction, of: .black) ?? .black
            if cmuxContrastRatio(foreground: .white, background: candidate) >= 4.5 {
                upperBound = fraction
            } else {
                lowerBound = fraction
            }
        }
        return (opaqueIdentity.blended(withFraction: upperBound, of: .black) ?? .black)
            .withAlphaComponent(1)
    }

    /// Strip colour for an active row: the same pale tint of the workspace
    /// colour that an *unselected* row wears as its resting wash, rather than
    /// flat black or white.
    ///
    /// This keeps hue on the strip in the one state where it used to vanish.
    /// The previous inverse edge made every selected row's strip identical, so
    /// a selected row announced that it was selected but not which workspace it
    /// was — the fill alone carried identity. A tint reads as "this row's own
    /// resting colour", and still separates cleanly from the fill because the
    /// fill is darkened until white clears 4.5:1.
    ///
    /// The 3:1 guard below is defensive, not load-bearing: because
    /// `darkenedForWhiteText` already forces the fill to clear 4.5:1 against
    /// white, and the tint is 86% white, the ratio cannot currently drop below
    /// ~3.7 for any sRGB input. It is kept so that changing `restingWashOpacity`
    /// or the darkening rule cannot silently breach the floor — but no test can
    /// exercise the fallback today, and an assertion on it would be vacuous.
    private static func activeStripColor(identity: NSColor, on fill: NSColor) -> NSColor {
        let opaqueIdentity = (identity.usingColorSpace(.sRGB) ?? identity).withAlphaComponent(1)
        let tint = (NSColor.white.blended(withFraction: restingWashOpacity, of: opaqueIdentity)
            ?? .white).withAlphaComponent(1)
        guard cmuxContrastRatio(foreground: tint, background: fill) >= 3 else {
            return highestContrastEdgeColor(on: fill)
        }
        return tint
    }

    private static func highestContrastEdgeColor(on backgroundColor: NSColor) -> NSColor {
        cmuxContrastRatio(foreground: .black, background: backgroundColor)
            >= cmuxContrastRatio(foreground: .white, background: backgroundColor)
            ? .black
            : .white
    }
}

/// SwiftUI face of ``SidebarWorkspaceRowVisualPalette/accentStripPath(in:bodyWidth:flare:)``.
/// Exists so the SwiftUI row draws the identical silhouette to the AppKit cell
/// rather than re-deriving it.
struct SidebarAccentStripShape: Shape {
    var bodyWidth: CGFloat = SidebarWorkspaceRowVisualPalette.accentStripWidth
    var flare: CGFloat = SidebarWorkspaceRowVisualPalette.accentStripFlareRadius

    func path(in rect: CGRect) -> Path {
        Path(
            SidebarWorkspaceRowVisualPalette.accentStripPath(
                in: rect,
                bodyWidth: bodyWidth,
                flare: flare
            )
        )
    }
}
