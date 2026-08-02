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
        #expect(resting.backgroundStyle.opacity == 0.05)

        #expect(hovered.identityColor?.hexString() == "#006B6B")
        #expect(hovered.stripColor?.hexString() == "#006B6B")
        #expect(hovered.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(hovered.backgroundStyle.opacity == 0.09)

        #expect(multiSelected.identityColor?.hexString() == "#006B6B")
        #expect(multiSelected.stripColor?.hexString() == "#006B6B")
        #expect(multiSelected.backgroundStyle.color?.hexString() == "#006B6B")
        #expect(multiSelected.backgroundStyle.opacity == 0.13)

        // The ladder must stay strictly increasing whatever the literals become:
        // a hover that does not visibly lift off resting, or a multi-selected row
        // that reads no heavier than a hovered one, is the failure mode that
        // lowering the resting wash invites.
        #expect(resting.backgroundStyle.opacity < hovered.backgroundStyle.opacity)
        #expect(hovered.backgroundStyle.opacity < multiSelected.backgroundStyle.opacity)

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

        // Hex inequality alone is too weak: at a tint fraction of 0.01 every
        // tint is a near-identical off-white and this still passed. Require a
        // gap wide enough to actually see. (That fraction was restingWashOpacity
        // when this was written; #cm-20 split it out as activeStripTintFraction,
        // which is the constant this test is now sensitive to.)
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
    func activeStripTintDoesNotFollowTheRestingWash() throws {
        // These two weights were one constant. Quieting the resting wash pulled
        // the active strip toward white with it — bleaching the one strip whose
        // job is to name the workspace on the selected row. They are separate
        // now, and this is the assertion that keeps a future "tidy up the
        // duplicate constant" from silently re-merging them.
        #expect(
            SidebarWorkspaceRowVisualPalette.activeStripTintFraction
                > SidebarWorkspaceRowVisualPalette.restingWashOpacity
        )

        let active = SidebarWorkspaceRowVisualPalette(
            isActive: true,
            isMultiSelected: false,
            isHovered: false,
            isEditing: false,
            customColorHex: "#1ABC9C",
            colorScheme: .light,
            selectionColorHex: nil,
            notificationBadgeColorHex: nil
        )
        let strip = try #require(active.stripColor)
        let identity = try #require(active.identityColor?.usingColorSpace(.sRGB))
        let bleached = try #require(
            NSColor.white.blended(
                withFraction: SidebarWorkspaceRowVisualPalette.restingWashOpacity,
                of: identity
            )?.usingColorSpace(.sRGB)
        )
        let actual = try #require(strip.usingColorSpace(.sRGB))
        // The shipped strip must carry more of the workspace hue than the resting
        // weight would give it — i.e. it is further from white.
        //
        // `greenComponent > 0` used to sit here and could not fail: the tint is
        // at least (1 - activeStripTintFraction) white, so every channel is
        // >= 0.86 for any identity and any fraction <= 1. Pin the actual
        // fraction instead, which discriminates the near misses the redComponent
        // check alone lets through — re-pointing this at multiSelectWashOpacity
        // (0.13) passes that check and fails this one.
        let expected = try #require(
            NSColor.white.blended(
                withFraction: SidebarWorkspaceRowVisualPalette.activeStripTintFraction,
                of: identity
            )?.usingColorSpace(.sRGB)
        )
        #expect(abs(actual.redComponent - expected.redComponent) < 0.001)
        #expect(abs(actual.greenComponent - expected.greenComponent) < 0.001)
        #expect(abs(actual.blueComponent - expected.blueComponent) < 0.001)
        #expect(actual.redComponent < bleached.redComponent)
    }

    @Test
    func theStripStaysStrongerThanAnyWash() throws {
        // The strip's opacity was a bare 0.95 written out twice — once in the
        // AppKit cell, once in the SwiftUI row. Geometry was already unified
        // through accentStripPath precisely so the two renderers could not
        // drift; opacity was left behind. It is one named constant now, and
        // both call sites read it — that part is enforced by there being no
        // literal left to drift, not by this test.
        //
        // What this test does hold is the relationship that makes the strip
        // worth having: with the wash this quiet, the strip is what tells two
        // nearby workspace colours apart, so it must out-weigh every wash
        // state. Lower it past multi-select and the row's own background
        // out-shouts the element carrying its identity.
        let strip = SidebarWorkspaceRowVisualPalette.accentStripOpacity
        #expect(strip > SidebarWorkspaceRowVisualPalette.multiSelectWashOpacity)
        #expect(strip > SidebarWorkspaceRowVisualPalette.hoverWashOpacity)
        #expect(strip > SidebarWorkspaceRowVisualPalette.restingWashOpacity)
    }

    @Test
    func theStripClearsThreeToOneAsItIsActuallyRendered() throws {
        // The strip is never drawn opaque. Both renderers set it at
        // accentStripOpacity over the active fill — SidebarWorkspaceRowCellView
        // via CALayer.backgroundColor, ContentView via Color.opacity — so the
        // colour that reaches the eye is strictly closer to the fill than the
        // opaque tint activeStripColor's own 3:1 guard measures.
        //
        // Swept 2197 colours (a 13³ sRGB grid) through the real palette on
        // 2026-08-02: the floor holds everywhere, but only just. Worst case is
        // pure #FF0000 at 3.047:1 rendered, where the guard sees 3.714:1 on the
        // opaque tint. So 0.85 is inside the floor by 1.6%, and the guard is
        // measuring a number 22% higher than the one that reaches the eye.
        //
        // Do not model this arithmetic outside Swift. NSColor.blended does not
        // lerp sRGB components — an sRGB-lerp model of this same path predicted
        // 2.76:1 for near-red and "floor breached", which is wrong; the real
        // fill for #F40000 is #E82100, carrying a green channel a plain blend
        // toward black cannot produce. Both a review agent and I reached the
        // same wrong number from the same wrong model, and only running it
        // through the real palette settled it.
        //
        // Asserting on the composite rather than on the tint is the point. The
        // pre-existing floor assertion reads palette.stripColor directly, which
        // makes it independent of accentStripOpacity: set that constant to 0 and
        // the strip vanishes while every other test here stays green. This one
        // fails, which is what makes lowering the strip again a caught mistake
        // rather than a silent one.
        for hex in ["#FF0000", "#F40000", "#006B6B", "#C0392B", "#FFF200"] {
            let palette = SidebarWorkspaceRowVisualPalette(
                isActive: true,
                isMultiSelected: false,
                isHovered: false,
                isEditing: false,
                customColorHex: hex,
                colorScheme: .light,
                selectionColorHex: nil,
                notificationBadgeColorHex: nil
            )
            let fill = try #require(palette.backgroundStyle.color?.usingColorSpace(.sRGB))
            let strip = try #require(palette.stripColor?.usingColorSpace(.sRGB))
            let rendered = try #require(
                fill.blended(
                    withFraction: SidebarWorkspaceRowVisualPalette.accentStripOpacity,
                    of: strip
                )
            )
            let ratio = cmuxContrastRatio(foreground: rendered, background: fill)
            #expect(ratio >= 3, "\(hex): strip renders at \(ratio):1 against its own fill")
        }
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
