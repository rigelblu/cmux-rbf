import AppKit
import CmuxSettings
import SwiftUI
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@MainActor
@Suite("Workspace Accent Strip palette")
struct SidebarWorkspaceAccentStripPaletteTests {
    @Test
    func customColorStateMatrixUsesOneIdentityAndStateWeightedFill() throws {
        let resting = palette(isHovered: false)
        let hovered = palette(isHovered: true)
        let multiSelected = palette(isMultiSelected: true)
        let active = palette(isActive: true)

        #expect(resting.identityColor?.hexString() == "#006B6B")
        #expect(resting.stripColor?.hexString() == "#006B6B")
        #expect(resting.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(resting.backgroundStyle.opacity == 0.14)

        #expect(hovered.identityColor?.hexString() == "#006B6B")
        #expect(hovered.stripColor?.hexString() == "#006B6B")
        #expect(hovered.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(hovered.backgroundStyle.opacity == 0.24)

        #expect(multiSelected.identityColor?.hexString() == "#006B6B")
        #expect(multiSelected.stripColor?.hexString() == "#006B6B")
        #expect(multiSelected.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(multiSelected.backgroundStyle.opacity == 0.35)

        let activeFill = try #require(active.backgroundStyle.color)
        let activeStrip = try #require(active.stripColor)
        #expect(active.identityColor?.hexString() == "#006B6B")
        #expect(active.backgroundStyle.opacity == 1)
        #expect(active.primaryTextColor.hexString() == "#FFFFFF")
        #expect(cmuxContrastRatio(foreground: .white, background: activeFill) >= 4.5)
        #expect(cmuxContrastRatio(foreground: activeStrip, background: activeFill) >= 3)
        // The active strip now wears the row's resting tint rather than a flat
        // inverse edge. Pinning "neither black nor white" is the point: the old
        // behaviour gave every selected row an identical strip, so a selected
        // row could not be identified by its strip at all.
        #expect(activeStrip.hexString() != NSColor.black.hexString())
        #expect(activeStrip.hexString() != NSColor.white.hexString())
    }

    @Test
    func activeStripWearsTheSameTintTwoDifferentWorkspacesDoNotShare() throws {
        // The regression this guards: two selected workspaces used to render
        // the same strip colour, so the strip stopped naming the workspace at
        // exactly the moment it mattered most.
        let teal = try #require(
            SidebarWorkspaceRowVisualPalette(
                isActive: true,
                isMultiSelected: false,
                isHovered: false,
                isEditing: false,
                customColorHex: "#1ABC9C",
                colorScheme: .light,
                selectionColorHex: nil,
                notificationBadgeColorHex: nil
            ).stripColor
        )
        let red = try #require(
            SidebarWorkspaceRowVisualPalette(
                isActive: true,
                isMultiSelected: false,
                isHovered: false,
                isEditing: false,
                customColorHex: "#C0392B",
                colorScheme: .light,
                selectionColorHex: nil,
                notificationBadgeColorHex: nil
            ).stripColor
        )
        #expect(teal.hexString() != red.hexString())

        // Hex inequality alone is too weak: at restingWashOpacity = 0.01 every
        // tint is a near-identical off-white and this still passed. Require a
        // gap wide enough to actually see.
        func channels(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
            let s = c.usingColorSpace(.sRGB) ?? c
            return (s.redComponent, s.greenComponent, s.blueComponent)
        }
        let (tr, tg, tb) = channels(teal)
        let (rr, rg, rb) = channels(red)
        let widestChannelGap = max(abs(tr - rr), max(abs(tg - rg), abs(tb - rb)))
        #expect(widestChannelGap >= 0.03, "tints are too close to tell apart: \(widestChannelGap)")
    }

    @Test
    func brightIdentityDarkensOnlyTheActiveFill() throws {
        let palette = SidebarWorkspaceRowVisualPalette(
            isActive: true,
            isMultiSelected: false,
            isHovered: false,
            isEditing: false,
            customColorHex: "#FFF200",
            colorScheme: .light,
            selectionColorHex: nil,
            notificationBadgeColorHex: nil
        )

        let fill = try #require(palette.backgroundStyle.color)
        #expect(palette.identityColor?.hexString() == "#FFF200")
        #expect(fill.hexString() != palette.identityColor?.hexString())
        #expect(cmuxContrastRatio(foreground: .white, background: fill) >= 4.5)
    }

    @Test
    func renameUsesGlobalSelectionSurfaceButKeepsCustomIdentityStrip() {
        let palette = SidebarWorkspaceRowVisualPalette(
            isActive: true,
            isMultiSelected: false,
            isHovered: false,
            isEditing: true,
            customColorHex: "#006B6B",
            colorScheme: .light,
            selectionColorHex: "#123456",
            notificationBadgeColorHex: nil
        )

        #expect(palette.backgroundStyle.color?.hexString() == "#123456")
        #expect(palette.backgroundStyle.opacity == 1)
        #expect(palette.identityColor?.hexString() == "#006B6B")
        #expect(palette.stripColor?.hexString() == "#006B6B")
        #expect(
            cmuxContrastRatio(
                foreground: palette.primaryTextColor,
                background: palette.backgroundStyle.color ?? .clear
            ) >= 4.5
        )
    }

    @Test
    func uncoloredAccentStripKeepsExistingFallbackSelection() {
        let palette = SidebarWorkspaceRowVisualPalette(
            isActive: true,
            isMultiSelected: false,
            isHovered: true,
            isEditing: false,
            customColorHex: nil,
            colorScheme: .light,
            selectionColorHex: "#123456",
            notificationBadgeColorHex: nil
        )

        #expect(palette.identityColor == nil)
        #expect(palette.stripColor == nil)
        #expect(palette.backgroundStyle.color?.hexString() == "#123456")
        #expect(palette.backgroundStyle.opacity == 1)
    }

    // MARK: - Strip silhouette
    //
    // The trailing corners are inverse (concave): the strip widens to
    // bodyWidth + flare at the extreme top and bottom and curves inward to
    // bodyWidth. A `cornerRadius` cannot express this — it only ever subtracts
    // material — so the shape is a path, and these tests pin the path rather
    // than a radius.

    @Test
    func stripBodyStaysNarrowWhileTheEndsFlareOutward() {
        let height: CGFloat = 48
        let body = SidebarWorkspaceRowVisualPalette.accentStripWidth
        let flare = SidebarWorkspaceRowVisualPalette.accentStripFlareRadius
        let rect = CGRect(
            x: 0,
            y: 0,
            width: SidebarWorkspaceRowVisualPalette.accentStripLayerWidth,
            height: height
        )
        let path = SidebarWorkspaceRowVisualPalette.accentStripPath(
            in: rect,
            bodyWidth: body,
            flare: flare
        )

        // Mid-height is body width only.
        #expect(path.contains(CGPoint(x: body - 0.5, y: height / 2)))
        #expect(!path.contains(CGPoint(x: body + 0.5, y: height / 2)))

        // Both ends reach past the body at the same x that is outside at
        // mid-height. That pair is the inversion: a convex trailing radius is
        // *narrower* at the ends, so it fails both of these.
        //
        // Deliberately sampled 1pt past the body rather than at the full
        // body + flare. The nominal width exists only on the y == 0 line — the
        // arc pulls in immediately, reaching ~9.3pt by y == 0.25 — so probing
        // the extreme corner tests the rasteriser, not the shape.
        #expect(path.contains(CGPoint(x: body + 1, y: 0.25)))
        #expect(path.contains(CGPoint(x: body + 1, y: height - 0.25)))

        #expect(path.boundingBox.width == body + flare)
        #expect(path.boundingBox.height == height)
    }

    @Test
    func theLayerCanHoldTheWholePathSoTheFlareIsNeverClippedMidArc() {
        // The invariant that matters is containment, not the arithmetic that
        // happens to satisfy it: the mask layer must be wide enough for the
        // full silhouette, or the flare gets cut off mid-curve.
        let rect = CGRect(
            x: 0,
            y: 0,
            width: SidebarWorkspaceRowVisualPalette.accentStripLayerWidth,
            height: 48
        )
        let path = SidebarWorkspaceRowVisualPalette.accentStripPath(
            in: rect,
            bodyWidth: SidebarWorkspaceRowVisualPalette.accentStripWidth,
            flare: SidebarWorkspaceRowVisualPalette.accentStripFlareRadius
        )
        #expect(rect.contains(path.boundingBox))
        // …and the flare must actually use the extra width, not waste it.
        #expect(path.boundingBox.width > SidebarWorkspaceRowVisualPalette.accentStripWidth)
    }

    @Test
    func flareClampsSoTheTwoEndsCannotCollideOnAShortRow() {
        // Two flares share the vertical axis, so each may claim at most half
        // the height: on a 6pt row a 6pt flare must resolve to 3pt.
        let path = SidebarWorkspaceRowVisualPalette.accentStripPath(
            in: CGRect(x: 0, y: 0, width: 11, height: 6),
            bodyWidth: 5,
            flare: 6
        )
        #expect(path.boundingBox.width == 8)
    }

    @Test
    func flareClampsToTheWidthAvailableBesideTheBody() {
        // More flare than the layer can hold must shrink the curve rather than
        // clip it mid-arc.
        let path = SidebarWorkspaceRowVisualPalette.accentStripPath(
            in: CGRect(x: 0, y: 0, width: 7, height: 48),
            bodyWidth: 5,
            flare: 6
        )
        #expect(path.boundingBox.width == 7)
    }

    @Test
    func zeroFlareFallsBackToAPlainBodyWidthBar() {
        let path = SidebarWorkspaceRowVisualPalette.accentStripPath(
            in: CGRect(x: 0, y: 0, width: 11, height: 48),
            bodyWidth: 5,
            flare: 0
        )
        #expect(path.boundingBox.width == 5)
        #expect(!path.contains(CGPoint(x: 5.5, y: 0.25)))
    }

    @Test
    func bothRenderersDeriveTheSameSilhouette() {
        // The SwiftUI row must not re-derive the curve; it wraps the same
        // function the AppKit mask uses.
        let rect = CGRect(
            x: 0,
            y: 0,
            width: SidebarWorkspaceRowVisualPalette.accentStripLayerWidth,
            height: 44
        )
        let appKit = SidebarWorkspaceRowVisualPalette.accentStripPath(
            in: rect,
            bodyWidth: SidebarWorkspaceRowVisualPalette.accentStripWidth,
            flare: SidebarWorkspaceRowVisualPalette.accentStripFlareRadius
        )
        let swiftUI = SidebarAccentStripShape().path(in: rect)
        #expect(swiftUI.boundingRect == appKit.boundingBox)
        // Bounding boxes alone would pass for a plain Rectangle(). Sample the
        // interior too: the concave notch must be absent from BOTH shapes at
        // mid-height and present in BOTH near the ends.
        let body = SidebarWorkspaceRowVisualPalette.accentStripWidth
        for point in [
            CGPoint(x: body + 1, y: rect.height / 2),   // outside both
            CGPoint(x: body + 1, y: 0.25),              // inside both
            CGPoint(x: body + 1, y: rect.height - 0.25),
            CGPoint(x: body - 0.5, y: rect.height / 2), // inside both
        ] {
            #expect(
                appKit.contains(point) == swiftUI.contains(point),
                "renderers disagree at \(point)"
            )
        }
    }

    private func palette(
        isActive: Bool = false,
        isMultiSelected: Bool = false,
        isHovered: Bool = false
    ) -> SidebarWorkspaceRowVisualPalette {
        SidebarWorkspaceRowVisualPalette(
            isActive: isActive,
            isMultiSelected: isMultiSelected,
            isHovered: isHovered,
            isEditing: false,
            customColorHex: "#006B6B",
            colorScheme: .light,
            selectionColorHex: nil,
            notificationBadgeColorHex: nil
        )
    }
}
