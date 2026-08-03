import AppKit
import CmuxSettings
import CmuxWorkspaces
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
                notificationBadgeColorHex: nil,
                attentionTaskStatus: nil
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
                notificationBadgeColorHex: nil,
                attentionTaskStatus: nil
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
            notificationBadgeColorHex: nil,
            attentionTaskStatus: nil
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
                notificationBadgeColorHex: nil,
                attentionTaskStatus: nil
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
            notificationBadgeColorHex: nil,
            attentionTaskStatus: nil
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
            notificationBadgeColorHex: nil,
            attentionTaskStatus: nil
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
            notificationBadgeColorHex: nil,
            attentionTaskStatus: nil
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
            notificationBadgeColorHex: nil,
            attentionTaskStatus: nil
        )
    }
}

/// `#cm-22` — a workspace that is not in play should stop wearing the sidebar's
/// loudest element.
///
/// Two lanes suppress: `.todo` (not started) and `.done` (finished). The three
/// between them mean work is in play and keep the strip. Named without "todo"
/// because `.done` joined on 2026-08-03 and `-only-testing:` takes this type
/// name — a suite called `Todo` hides half of what it covers.
///
/// The strip is full-hue at `accentStripOpacity`; the wash is
/// `restingWashOpacity`. Suppressing the loud one and keeping the faint one is
/// what makes a suppressed row read as quiet rather than as absent, so these
/// tests pin **both halves** — a strip that goes away *and* a wash that stays.
/// A test that only checked the strip would let a future change take the wash
/// with it and still pass.
@MainActor
@Suite("Workspace strip suppression")
struct SidebarWorkspaceStripSuppressionTests {
    @Test
    func todoRowDropsItsStripAndKeepsItsWash() throws {
        let todo = palette(attentionTaskStatus: .todo)

        #expect(todo.stripColor == nil)
        // The wash is the trace that survives suppression. If this ever goes
        // nil the row has become colourless, which is a different feature.
        #expect(todo.backgroundStyle.color?.hexString() == "#006B6B")
        // `#expect(Double == CGFloat)` fails in this toolchain, so the
        // `Double(...)` wrapper is required.
        #expect(
            todo.backgroundStyle.opacity
                == Double(SidebarWorkspaceRowVisualPalette.restingWashOpacity)
        )
        // The workspace's colour assignment is untouched — suppression is
        // presentation only, so the identity is still resolvable.
        #expect(todo.identityColor?.hexString() == "#006B6B")
    }

    @Test
    func doneRowDropsItsStripAndKeepsItsWash() throws {
        // `.done` suppresses for the same reason `.todo` does: neither lane is in
        // play. Tom, 2026-08-03, on being shown that `.done` kept a full-strength
        // strip while dimming its own title WHEREVER THE STATUS WAS VISIBLE:
        // "yes, done would suppress".
        //
        // That qualifier is load-bearing and the first version of this comment
        // omitted it. The dim fires only when `taskStatus == .done`, which is
        // gated on `statusHidden` — and `statusHidden` defaults to TRUE. So in
        // the default state a done row wore the strip and did NOT dim.
        //
        // The dimming stays a separate mechanism: `doneRowContentAlpha` dims a
        // done row's CONTENT and reads `taskStatus`, while suppression reads
        // `attentionTaskStatus`. They deliberately do not share a trigger.
        let done = palette(attentionTaskStatus: .done)

        #expect(done.stripColor == nil)
        #expect(done.backgroundStyle.color?.hexString() == "#006B6B")
        // `#expect(Double == CGFloat)` fails in this toolchain, so the
        // `Double(...)` wrapper is required here too.
        #expect(
            done.backgroundStyle.opacity
                == Double(SidebarWorkspaceRowVisualPalette.restingWashOpacity)
        )
        #expect(done.identityColor?.hexString() == "#006B6B")
    }

    @Test
    func onlyADoneRowDimsItsContent() throws {
        // Finding 7 of the cold review: `doneRowContentAlpha` had ZERO assertions
        // in either renderer, so the "separate mechanism" half of this feature's
        // central claim was documented in three places and tested nowhere.
        let suppressing: Set<WorkspaceTaskStatus> = [.done]

        for status in WorkspaceTaskStatus.allCases {
            let alpha = SidebarWorkspaceRowVisualPalette.contentAlpha(taskStatus: status)
            let expected = suppressing.contains(status)
                ? SidebarWorkspaceRowVisualPalette.doneRowContentAlpha
                : 1
            #expect(alpha == expected, "\(status.rawValue) dimmed to \(alpha)")
        }
    }

    @Test
    func theDimAndTheStripSuppressionReadDifferentFieldsOnPurpose() throws {
        // The asymmetry this feature is most likely to be "tidied" away by
        // someone who reads the two rules as one. They are gated on different
        // snapshot fields, and the whole `statusHidden` defect came from
        // conflating exactly this pair.
        //
        // A workspace that was never labelled has `taskStatus == nil` (gated on
        // statusHidden) while its `attentionTaskStatus` still resolves a lane.
        // So a finished-but-never-labelled row loses its strip and keeps its
        // content at full strength — half the done treatment, deliberately.
        #expect(SidebarWorkspaceRowVisualPalette.contentAlpha(taskStatus: nil) == 1)
        #expect(SidebarWorkspaceRowVisualPalette.suppressesAccentStrip(attentionTaskStatus: .done))

        // And the converse: unify them and this pair stops disagreeing.
        #expect(
            SidebarWorkspaceRowVisualPalette.contentAlpha(taskStatus: .done)
                == SidebarWorkspaceRowVisualPalette.doneRowContentAlpha
        )
    }

    @Test
    func onlyTheLanesAtTheEndsOfTheLifecycleSuppress() throws {
        // Guards the half of the rule that is easy to over-apply: the three
        // middle lanes mean work is in play and must keep the strip, and
        // widening suppression to any of them would empty the sidebar of
        // identity.
        //
        // Stated as an explicit PARTITION over every lane rather than as a
        // filtered loop. The filtered form (`where status != .todo && ...`) is
        // weakened by appending one term to its `where` clause, and a diff of
        // that shape reads as "I filtered the loop" rather than "I changed the
        // expected behaviour" — which is exactly how `.done` was added. This
        // form makes the same edit a visible change to the expected set, and it
        // covers every case rather than only the non-suppressing ones.
        let suppressing: Set<WorkspaceTaskStatus> = [.todo, .done]

        for status in WorkspaceTaskStatus.allCases {
            let lane = palette(attentionTaskStatus: status)
            let isSuppressed = lane.stripColor == nil
            #expect(
                isSuppressed == suppressing.contains(status),
                "\(status.rawValue): suppressed=\(isSuppressed), expected=\(suppressing.contains(status))"
            )
        }
    }

    @Test
    func aParkedRowAndAFinishedRowAreDeliberatelyIndistinguishable() throws {
        // Finding 1 of the cold review of this change, recorded as INTENDED
        // rather than left implicit — which is the only thing the reviewer held
        // the verdict open for.
        //
        // The rule is binary: in play, or not. `.todo` and `.done` are both
        // "not in play", so they resolve to the SAME row treatment — same
        // absent strip, same wash, same weight. That is the rule working.
        //
        // What makes it worth pinning is the default state. `statusHidden`
        // defaults to true, so `taskStatus` is nil and neither the status glyph
        // nor `doneRowContentAlpha`'s dim fires — the two things that would
        // otherwise tell a finished row from a not-started one. A workspace
        // whose lane is INFERRED `.done` (all pull requests merged or closed)
        // therefore looks exactly like a parked one, and nobody has to touch the
        // status UI to reach that state.
        //
        // Before `.done` joined, those two rows were tellable apart, because
        // done kept its strip. If that distinction is ever wanted back, the fix
        // is to gate the dim on `attentionTaskStatus` as well — not to give
        // `.done` its strip back.
        let todo = palette(attentionTaskStatus: .todo)
        let done = palette(attentionTaskStatus: .done)

        #expect(todo.stripColor == nil)
        #expect(done.stripColor == nil)
        #expect(todo.backgroundStyle.color?.hexString() == done.backgroundStyle.color?.hexString())
        #expect(todo.backgroundStyle.opacity == done.backgroundStyle.opacity)
        #expect(todo.identityColor?.hexString() == done.identityColor?.hexString())
    }

    @Test
    func theFeatureGateBeingOffLeavesEveryRowExactlyAsBefore() throws {
        // nil is "the todo feature is off". #cm-22 must be entirely dormant
        // there: the gate defaults to OFF, so suppressing would silently revert
        // #cm-10 for everyone who never opted in.
        let ungated = palette(attentionTaskStatus: nil)

        #expect(ungated.stripColor?.hexString() == "#006B6B")
        #expect(ungated.backgroundStyle.opacity == 0.05)
    }

    @Test
    func hoveredAndMultiSelectedTodoRowsDropTheStripAndKeepTheirLadder() throws {
        let hovered = palette(attentionTaskStatus: .todo, isHovered: true)
        let multiSelected = palette(attentionTaskStatus: .todo, isMultiSelected: true)

        #expect(hovered.stripColor == nil)
        #expect(multiSelected.stripColor == nil)
        // Suppression must not flatten the resting → hover → multi ladder that
        // `#cm-20` scaled deliberately; the wash is doing all the work now that
        // the strip is gone, so a flat ladder here is a dead row.
        let resting = palette(attentionTaskStatus: .todo)
        #expect(resting.backgroundStyle.opacity < hovered.backgroundStyle.opacity)
        #expect(hovered.backgroundStyle.opacity < multiSelected.backgroundStyle.opacity)
    }

    @Test
    func theActiveRowKeepsItsFullColourEvenWhenTodo() throws {
        // Decision 3, 2026-08-03: the active row's job is "you are here", and
        // you can be inside a workspace you have not started work in. It keeps
        // `#cm-10`'s contrast-corrected fill and its tinted strip.
        let active = palette(attentionTaskStatus: .todo, isActive: true)

        let fill = try #require(active.backgroundStyle.color)
        let strip = try #require(active.stripColor)
        #expect(active.backgroundStyle.opacity == 1)
        #expect(active.primaryTextColor.hexString() == "#FFFFFF")
        #expect(cmuxContrastRatio(foreground: .white, background: fill) >= 4.5)
        #expect(cmuxContrastRatio(foreground: strip, background: fill) >= 3)
    }

    @Test
    func anUncolouredRowStillGetsItsMultiSelectAccent() throws {
        // With no workspace colour there is no strip to suppress; this guards
        // against a wrong suppression implementation reaching the uncoloured
        // branch and knocking out the multi-select accent wash. It does not
        // discriminate present-vs-reverted #cm-22, and nothing needs it to.
        let uncoloured = SidebarWorkspaceRowVisualPalette(
            isActive: false,
            isMultiSelected: true,
            isHovered: false,
            isEditing: false,
            customColorHex: nil,
            colorScheme: .light,
            selectionColorHex: nil,
            notificationBadgeColorHex: nil,
            attentionTaskStatus: .todo
        )

        #expect(uncoloured.stripColor == nil)
        #expect(uncoloured.backgroundStyle.color != nil)
        #expect(uncoloured.backgroundStyle.opacity == 0.25)
    }

    private func palette(
        attentionTaskStatus: WorkspaceTaskStatus?,
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
            notificationBadgeColorHex: nil,
            attentionTaskStatus: attentionTaskStatus
        )
    }
}

/// `#cm-22` — the factory decision, which is where the shipped regression lived
/// and which had no test at all: every palette test hand-feeds the value this
/// code is responsible for *producing*.
@MainActor
@Suite("Workspace attention lane source")
struct SidebarWorkspaceAttentionLaneSourceTests {
    @Test
    func aHiddenStatusStillReportsALaneForSuppression() throws {
        // The two fields MUST diverge here, and that divergence is the fix.
        // `statusHidden` defaults to true, so this is the default state of every
        // workspace: `taskStatus` (what the status glyph reads) is gated and goes
        // nil, while `attentionTaskStatus` (what suppression reads) is not and
        // still resolves a lane. The shipped defect was these two agreeing, which
        // made a never-labelled workspace look idle even with an agent running.
        let workspace = Workspace()
        workspace.todoState.statusHidden = true

        let snapshot = Self.makeSnapshot(workspace: workspace, todoControlsEnabled: true)

        #expect(snapshot.taskStatus == nil)
        #expect(snapshot.attentionTaskStatus != nil)
    }

    @Test
    func theFeatureBeingOffErasesTheLaneSoNoRowIsEverSuppressed() throws {
        // Previously reachable ONLY by a human turning the beta flag off and
        // relaunching (`test-suite/review.md` Scenario 11), because the factory
        // read the flag from a singleton. Its failure mode is silent: every row
        // would lose its strip for anyone who never opted in, reverting `#cm-10`
        // for them, with nothing to signal it.
        let workspace = Workspace()

        let snapshot = Self.makeSnapshot(workspace: workspace, todoControlsEnabled: false)

        #expect(snapshot.attentionTaskStatus == nil)
    }

    private static func makeSnapshot(
        workspace: Workspace,
        todoControlsEnabled: Bool
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(
                defaults: UserDefaults(suiteName: UUID().uuidString)!
            ),
            showsAgentActivity: false,
            todoControlsEnabled: todoControlsEnabled
        ).makeSnapshot()
    }
}
