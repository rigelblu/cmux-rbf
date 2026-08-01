/// A terminal font size together with whether it is a surface-local override.
///
/// Keeping provenance beside the point size lets inherited and restored
/// surfaces preserve explicit zoom while terminals at the config default keep
/// following later config changes.
public struct TerminalFontSizeLineage: Equatable, Sendable {
    /// The unscaled font size in points at 100% global magnification.
    public var basePoints: Float32

    /// Whether the size came from an explicit surface-local zoom.
    public var isExplicitOverride: Bool

    /// Creates font-size lineage for a terminal surface.
    ///
    /// - Parameters:
    ///   - basePoints: The unscaled font size in points.
    ///   - isExplicitOverride: Whether the surface owns this size instead of
    ///     following the current terminal config.
    public init(basePoints: Float32, isExplicitOverride: Bool) {
        self.basePoints = basePoints
        self.isExplicitOverride = isExplicitOverride
    }

}

extension CmuxSurfaceConfigTemplate {
    /// Scales a surface's live runtime font size by a magnification *ratio*.
    ///
    /// Used when the app-wide magnification moves and a surface must be resized
    /// directly, because Ghostty sets `font_size_adjusted` on any manual font
    /// change and then skips that surface on config reload — deliberately,
    /// "since we assume the user wants a specific size" (`Surface.zig`).
    ///
    /// **Why a ratio and not a base.** The obvious alternative — recover the
    /// surface's unscaled base and multiply it by the new percent — is a fixed
    /// point in this position. ``TerminalFontSizeLineage`` derives its base by
    /// dividing the *live* size by the *current* percent, so once the percent
    /// has already moved, that base multiplies straight back to the size the
    /// surface already had. Every intermediate value looks reasonable and the
    /// font never moves; dogfood on 2026-07-31 caught it pinned at 13.0pt across
    /// 170%, 180%, and 190%. A ratio never reconstructs a base, so it cannot
    /// cancel itself out.
    ///
    /// - Parameters:
    ///   - current: The surface's live runtime point size.
    ///   - ratio: New magnification percent divided by the previous one.
    /// - Returns: The clamped size to apply, or `nil` when there is nothing
    ///   meaningful to change.
    public static func runtimePointsScaled(current: Float32, byMagnificationRatio ratio: Double) -> Float32? {
        guard current.isFinite, current > 0 else { return nil }
        guard ratio.isFinite, ratio > 0, abs(ratio - 1) > 0.0001 else { return nil }
        let scaled = TerminalFontSizePolicy().clampedRuntimePoints(current * Float32(ratio))
        guard scaled.isFinite, scaled > 0, abs(scaled - current) > 0.01 else { return nil }
        return scaled
    }
}
