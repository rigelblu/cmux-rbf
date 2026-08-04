import AppKit
import CmuxSettings
import CmuxWorkspaces
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
    /// Lowered from 0.14, first to 0.09, then 0.07, then 0.05 across three dogfood passes. At 0.14 a
    /// sidebar of coloured workspaces read as a stack of filled swatches rather
    /// than as rows carrying a hint of identity. Hue still has to survive — two
    /// workspaces with nearby colours must stay tellable apart at rest — so this
    /// is a reduction, not a removal, and there is a floor somewhere below here.
    ///
    /// `hoverWashOpacity` and `multiSelectWashOpacity` are scaled from the same
    /// change so the resting → hover → multi-select ladder keeps its shape.
    ///
    /// This is *not* the active strip's tint weight; see
    /// `activeStripTintFraction`, which is a blend fraction against white and is
    /// deliberately pinned. Do not re-merge the two.
    static let restingWashOpacity: CGFloat = 0.05

    /// Wash weight while the pointer is over a resting row.
    static let hoverWashOpacity: CGFloat = 0.09

    /// Wash weight for a row in a multi-selection.
    static let multiSelectWashOpacity: CGFloat = 0.13

    /// Opacity the Accent Strip is drawn at, in **both** renderers.
    ///
    /// Lowered from 0.95 on dogfood: as the wash got quieter the strip stopped
    /// reading as part of the row and started reading as a bar stuck to it. It
    /// stays the strongest colour on a resting row on purpose — with the wash at
    /// `restingWashOpacity` the strip is what actually distinguishes two
    /// workspaces with nearby colours, so this can be softened but not much
    /// further without taking identity with it.
    ///
    /// **This existed as a bare `0.95` in two places** — the AppKit cell and the
    /// SwiftUI row — which is the same renderer-drift hazard `accentStripPath`
    /// was written to close for the strip's geometry, left open for its opacity.
    /// Both now read this. Do not re-inline it.
    static let accentStripOpacity: CGFloat = 0.85

    /// Whether a row's lane suppresses its leading Accent Strip.
    ///
    /// **The two lanes at the ends of the lifecycle suppress: not started, and
    /// finished.** The three between them — `.working`, `.needsAttention`,
    /// `.review` — mean work is in play and keep the strip. The strip is the
    /// loudest element on a resting row, drawn at `accentStripOpacity`, so it is
    /// what a workspace gives up when it is not in play; the same-colour wash
    /// stays as the trace of identity.
    ///
    /// This reads the **effective** lane, so a manual override outranks live
    /// activity, and `.todo` therefore means either "nothing is happening" or
    /// "the user parked it by hand".
    ///
    /// `.done` joined `.todo` on 2026-08-03. It previously kept a full-strength
    /// strip on the argument that it de-emphasises by dimming content instead —
    /// but that left the most finished state in the sidebar wearing the loudest
    /// element while dimming its own title **wherever the status was visible**.
    /// That qualifier matters: the dim is gated on `taskStatus`, which respects
    /// `statusHidden`, and `statusHidden` defaults to `true` — so in the default
    /// state a done row wore the strip and did not dim at all. Suppression is
    /// gated on `attentionTaskStatus`, which does not respect `statusHidden`, so
    /// the two rules deliberately do not share a trigger.
    ///
    /// **The consequence, intended and pinned by
    /// `aParkedRowAndAFinishedRowAreDeliberatelyIndistinguishable`:** in that
    /// default state a row whose lane is *inferred* `.done` (all pull requests
    /// merged or closed) is identical to a `.todo` one — same absent strip, same
    /// wash, and neither the glyph nor the dim to separate them, because both
    /// are gated off. The rule is binary, in play or not, so two "not in play"
    /// lanes looking alike is the rule working. It does widen an already-shipped
    /// limitation ("an absent strip has several causes you cannot tell apart"),
    /// and it is reachable without ever touching the status UI. If the
    /// distinction is ever wanted back, gate the dim on `attentionTaskStatus`
    /// too — do not give `.done` its strip back.
    ///
    /// `nil` means the todo feature is off; nothing suppresses.
    static func suppressesAccentStrip(attentionTaskStatus: WorkspaceTaskStatus?) -> Bool {
        attentionTaskStatus == .todo || attentionTaskStatus == .done
    }


    /// Alpha applied to a `.done` row's CONTENT (never its background, strip, or
    /// drop chrome) so a finished row reads as settled.
    ///
    /// Named here because `#cm-22` adds a second "status modulates row weight"
    /// rule; leaving its only neighbour inlined in two renderers would give one
    /// concept two homes — the same drift hazard `#cm-20` closed for
    /// `accentStripOpacity`.
    static let doneRowContentAlpha: CGFloat = 0.6

    /// Alpha for a row's content, given the lane the **status glyph** reads.
    ///
    /// The sibling of ``suppressesAccentStrip(attentionTaskStatus:)``, and the
    /// two are deliberately gated on different fields — this one on `taskStatus`,
    /// which respects `statusHidden`, and suppression on `attentionTaskStatus`,
    /// which does not. Since `statusHidden` defaults to `true`, this dim almost
    /// never fires while suppression always does. **Do not unify them.**
    ///
    /// Extracted from two inlined ternaries (the AppKit cell and the SwiftUI
    /// row) so the decision has one home and a seam a test can reach. A cold
    /// review found the rule had **zero assertions in either renderer**, which
    /// left the "separate mechanism" half of `#cm-22`'s central claim entirely
    /// unpinned — the claim was documented in three places and tested nowhere.
    /// Asserting it inside a renderer was not available: both apply it to a
    /// `private` content container, which is the wrong seam. This is the right
    /// one.
    static func contentAlpha(taskStatus: WorkspaceTaskStatus?) -> CGFloat {
        taskStatus == .done ? doneRowContentAlpha : 1
    }

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

    /// - Parameters:
    ///   - attentionTaskStatus: The workspace's attention lane, or `nil` when
    ///     the todo feature is off for it — see
    ///     `SidebarWorkspaceSnapshotFactory.attentionTaskStatus`. Deliberately
    ///     **not** defaulted: both row renderers build this palette
    ///     (`SidebarRowPalette.init`, `ContentView.rowVisualPalette`), and a
    ///     default would let one of them silently keep the old treatment — the
    ///     shared-behavior policy enforced by a reviewer instead of by the
    ///     compiler.
    init(
        isActive: Bool,
        isMultiSelected: Bool,
        isHovered: Bool,
        isEditing: Bool,
        customColorHex: String?,
        colorScheme: ColorScheme,
        selectionColorHex: String?,
        notificationBadgeColorHex: String?,
        attentionTaskStatus: WorkspaceTaskStatus?
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
                opacity: isMultiSelected
                    ? Self.multiSelectWashOpacity
                    : (isHovered ? Self.hoverWashOpacity : Self.restingWashOpacity)
            )
            resolvedStrip = Self.suppressesAccentStrip(attentionTaskStatus: attentionTaskStatus)
                ? nil
                : identityColor
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

    /// Weight of the workspace colour in the active row's strip tint, as a
    /// blend fraction against white.
    ///
    /// Pinned at the value `restingWashOpacity` used to carry. Lowering the
    /// resting wash is about quieting *unselected* rows; letting this follow
    /// would bleach the one strip whose whole job is to say which workspace the
    /// active row belongs to — the identity loss the inverse-edge strip had.
    static let activeStripTintFraction: CGFloat = 0.14

    /// Strip colour for an active row: a pale tint of the workspace colour,
    /// rather than flat black or white.
    ///
    /// This keeps hue on the strip in the one state where it used to vanish.
    /// The previous inverse edge made every selected row's strip identical, so
    /// a selected row announced that it was selected but not which workspace it
    /// was — the fill alone carried identity. A tint reads as "this row's own
    /// resting colour", and still separates cleanly from the fill because the
    /// fill is darkened until white clears 4.5:1.
    ///
    /// The 3:1 guard below measures the strip **as it is rendered**, not the
    /// opaque tint. Neither renderer draws the strip opaque — both set it at
    /// `accentStripOpacity` over this same fill — so the colour that reaches
    /// the eye sits between the tint and the fill, and is always the lower
    /// contrast of the two. Measuring the tint overstates it by ~22%.
    ///
    /// That gap was harmless while the strip was near-opaque and is not now.
    /// Swept across a 13³ sRGB grid on 2026-08-02: at `accentStripOpacity`
    /// 0.85 the worst case is pure red, 3.714:1 opaque against 3.047:1
    /// rendered. Nothing breaches the floor today — the margin is 1.6%, and
    /// the previous version of this guard could not see it shrink.
    ///
    /// So the guard is load-bearing now rather than defensive: lower
    /// `accentStripOpacity` or `activeStripTintFraction` far enough and it
    /// fires, swapping the tint for the inverse edge instead of silently
    /// shipping an unreadable strip.
    private static func activeStripColor(identity: NSColor, on fill: NSColor) -> NSColor {
        let opaqueIdentity = (identity.usingColorSpace(.sRGB) ?? identity).withAlphaComponent(1)
        let tint = (NSColor.white.blended(withFraction: activeStripTintFraction, of: opaqueIdentity)
            ?? .white).withAlphaComponent(1)
        let rendered = fill.blended(withFraction: accentStripOpacity, of: tint) ?? tint
        guard cmuxContrastRatio(foreground: rendered, background: fill) >= 3 else {
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
