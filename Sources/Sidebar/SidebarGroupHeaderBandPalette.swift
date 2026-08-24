import AppKit
import SwiftUI

/// Resolves the band drawn behind a workspace **group header** row.
///
/// A group header is a container, and until `#cm-49` it did not render like
/// one: its background was `Color.clear` at rest, while every coloured member
/// row beneath it carried a leading strip at
/// `SidebarWorkspaceRowVisualPalette.accentStripOpacity` over a wash. The
/// container read quieter than its contents.
///
/// The band fixes that by taking a channel the member rows do not use — the
/// row's **full-width fill**, where a member's identity lives on its **leading
/// edge**. Header and member therefore differentiate in different channels and
/// cannot be mistaken for one another. Giving the header a thicker strip
/// instead was rejected for exactly this reason: same channel, so the header
/// could only ever read as a louder row.
///
/// Like `SidebarWorkspaceRowVisualPalette`, this exists so the AppKit and
/// SwiftUI header renderers cannot drift. Both previously decided the header's
/// background independently — `SidebarWorkspaceGroupHeaderView`'s `.background`
/// and `SidebarGroupHeaderRowView.headerBackgroundColor(for:)` — which is the
/// same hazard `accentStripOpacity` was pulled out of two files to close.
/// Resolve here; do not re-inline a rung at a call site.
struct SidebarGroupHeaderBandPalette: Equatable {
    /// The band's colour before `bandOpacity` is applied.
    let bandColor: NSColor

    /// The rung this header sits on.
    let bandOpacity: CGFloat

    /// Foreground for the header's name, derived against the composited band.
    let primaryTextColor: NSColor

    /// Resting rung for a group that has a colour.
    ///
    /// Settled at 0.18 against a rendered four-candidate board (0.10 / 0.14 /
    /// 0.18 / 0.24), each shown beside a member row at
    /// `SidebarWorkspaceRowVisualPalette.restingWashOpacity`.
    ///
    /// **0.14 was rejected on provenance, not appearance.** It is the exact
    /// value `#cm-20` deliberately lowered the member wash *away* from, and
    /// reusing it on a different element risks re-importing the wall-of-fill
    /// problem that decision solved. 0.10 was rejected as merely twice a
    /// whisper. 0.18 is the loudest rung that does not approach `#cm-20`'s wall,
    /// and it is the one that still separates in dark appearance, where the
    /// 0.05 member wash all but vanishes into the sidebar base.
    static let restingBandOpacity: CGFloat = 0.18

    /// Rung for a header whose anchor workspace is active.
    ///
    /// Replaces a neutral `labelColor` at 0.08 — the header was the only row in
    /// the sidebar that said "active" in grey while every workspace row said it
    /// in its own hue. Not yet settled by eye; tune during dogfood.
    ///
    /// This sits deliberately *below* a member row's active fill (opaque
    /// `darkenedForWhiteText`). Only one workspace is active app-wide, so the
    /// two never appear together — the gap exists to keep an active header
    /// still reading as a header, not to tell the two apart on screen.
    static let activeBandOpacity: CGFloat = 0.55

    /// Resting rung for a group with **no** colour.
    ///
    /// Every group gets a band, so that the band means *container* on its own
    /// and its hue only adds *which* container. Banding just the coloured
    /// groups would leave the original defect intact for every group that was
    /// never given a colour.
    static let neutralRestingBandOpacity: CGFloat = 0.06

    /// Active rung for a group with no colour.
    static let neutralActiveBandOpacity: CGFloat = 0.18

    /// Material used when a group has no colour, or its colour cannot be parsed.
    static let neutralBandColor: NSColor = .labelColor

    /// - Parameters:
    ///   - tintHex: the group's colour, as `customColor ?? resolvedConfig?.color`.
    ///     A nil or unparseable value resolves to the neutral band — a group
    ///     whose colour did not parse is a normal group, not an error state.
    ///   - base: what the band composites over, used only to derive a readable
    ///     foreground. This is a **proxy**: the sidebar composites against a
    ///     material, and a material's resolved pixels cannot be sampled from
    ///     here, so `windowBackgroundColor` stands in for it. It tracks the
    ///     appearance, which is what the contrast derivation actually needs.
    ///     Reduce Transparency changes the real material and is a named dogfood
    ///     check for exactly this reason.
    init(
        tintHex: String?,
        isAnchorActive: Bool,
        isMultiSelected: Bool,
        multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle,
        base: NSColor = .windowBackgroundColor
    ) {
        let identity = tintHex.flatMap { NSColor(hex: $0) }

        if isMultiSelected, !isAnchorActive, let style = multiSelectionBackgroundStyle.color {
            // Multi-selection keeps its existing treatment and sits on top of
            // the band rather than beside it on the ladder.
            bandColor = style
            bandOpacity = style.alphaComponent * multiSelectionBackgroundStyle.opacity
        } else if let identity {
            bandColor = identity
            bandOpacity = isAnchorActive ? Self.activeBandOpacity : Self.restingBandOpacity
        } else {
            bandColor = Self.neutralBandColor
            bandOpacity = isAnchorActive
                ? Self.neutralActiveBandOpacity
                : Self.neutralRestingBandOpacity
        }

        let composited = cmuxCompositedNSColor(
            bandColor.withAlphaComponent(bandOpacity),
            over: base
        )
        // The header's name was a fixed `Color.primary` while its background
        // was clear. Once the band can carry a saturated config-supplied colour
        // that is no longer safe, so the foreground is derived — the same
        // contrast path the workspace rows already use.
        primaryTextColor = cmuxReadableForegroundNSColor(
            preferred: .labelColor,
            on: composited
        )
    }
}
