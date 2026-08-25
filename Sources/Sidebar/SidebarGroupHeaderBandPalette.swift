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
    ///
    /// **Raised from 0.06 after dogfood: at 0.06 the container was fainter than
    /// its own contents.** Measured on a warm sidebar, 0.06 moves the row by 15
    /// of 243 (~6%) — a smudge, not structure — while a *member* row's
    /// `restingWashOpacity` wash moves a coloured row by ~19. So an uncoloured
    /// group re-created the exact inversion this feature exists to remove. At
    /// the accepted 0.40 rung the move is 107, enough to read as structure;
    /// the resulting tight active range is tracked by `#cm-52`.
    ///
    /// This was mistaken for a hue problem first; it was always amplitude.
    static let neutralRestingBandOpacity: CGFloat = 0.40

    /// Active rung for a group with no colour.
    ///
    /// **Raised to 0.85 after dogfood reported the active header as "too faint".**
    /// The step matters, not the value: at 0.60 the move from resting was 51,
    /// against a 107 move from the sidebar to the resting band — so the eye
    /// absorbed a big jump and then a half-sized one, and read the second as no
    /// change. At 0.85 the step is 118, proportionate to the 107 below it.
    ///
    /// **The range here is structurally tight, and that is worth knowing before
    /// moving either number.** The band tops out at the tint itself, so the whole
    /// ladder spans about 265 on a light sidebar. `neutralRestingBandOpacity`
    /// spends 107 of that to read as a hue at all, which leaves at most 158 for
    /// active. Making resting louder — the change that made it stop looking grey
    /// — permanently compresses active. That trade is `#cm-52`'s to resolve.
    ///
    /// **This used to equal `restingBandOpacity` at 0.18**, and that collision
    /// was documented as a deliberate exception to the ladder's rule that
    /// intensity carries attention. Raising the neutral rungs removes the
    /// crossing, so the rule now holds without an exception and there is no
    /// longer a hazard to warn about.
    static let neutralActiveBandOpacity: CGFloat = 0.85

    /// Colour used when a group has no colour of its own.
    ///
    /// **Accepted after dogfood, 2026-08-24 — with a real cost, see below.** This
    /// paints the configured *sidebar tint* rather than darkening whatever is
    /// behind the band. It was chosen because a faithful darkening looks grey on a
    /// low-saturation sidebar: measured on a live sidebar at 6.2% saturation,
    /// the band came out at 6.1% — hue perfectly preserved, and perfectly grey,
    /// because there was almost no hue there to preserve.
    ///
    /// **The cost is an inversion of the ladder.** The tint only reads as purple
    /// once it out-weighs the base's own warmth, which on that sidebar needs
    /// opacity above 0.375. At 0.40 an *uncoloured* group moves the row by 107,
    /// where a *coloured* group at `restingBandOpacity` moves it by about 67 — so
    /// "no colour assigned" becomes the loudest thing in the sidebar, and the
    /// hue layer stops meaning "which container".
    ///
    /// It also reads the configured tint, which is **not** always what is on
    /// screen: with `sidebarMatchTerminalBackground` on, the sidebar shows the
    /// terminal background instead, and this paints a colour the user cannot see
    /// anywhere else.
    ///
    /// Dogfood accepted the result despite both costs. Reconsidering that trade
    /// belongs to `#cm-52`, rather than silently reverting to `.labelColor`.
    /// **`let`, not `var`, and that is load-bearing.** As a computed property this
    /// minted a *fresh* dynamic `NSColor` on every call, each with its own UUID,
    /// so two of them were never `==` even when they resolved to the identical
    /// pixel. That silently broke this type's `Equatable` conformance for the
    /// whole uncoloured path — `bandResolutionIsPureAcrossEveryState` caught it.
    ///
    /// Purity is the property the single-source contract rests on: state the band
    /// once, consume it twice, and know both renderers agree. A value type that
    /// returns something different each call cannot carry that. Resolved once
    /// here, the instance is shared and the dynamic lookup still runs per draw.
    static let neutralBandColor = makeNeutralBandColor()

    static func makeNeutralBandColor(defaults: UserDefaults = .standard) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let specific = defaults.string(forKey: isDark ? "sidebarTintHexDark" : "sidebarTintHexLight")
            let hex = specific ?? defaults.string(forKey: "sidebarTintHex")
            return hex.flatMap { NSColor(hex: $0) } ?? .labelColor
        }
    }

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
