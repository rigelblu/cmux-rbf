public import CoreGraphics

/// Combines a surface's own zoom with the app-wide magnification.
///
/// cmux zooms on two independent axes: each surface keeps a *base* the user sets
/// for that surface alone, and ``GlobalFontMagnification`` applies one *scale*
/// across the app. What a surface renders at is always the product.
///
/// The arithmetic lives here, apart from any surface, because the failure it
/// prevents is invisible at a call site. A surface that stores only its rendered
/// zoom has no way to tell the base apart from the scale, so any code that reads
/// the rendered value back and stores it as a base folds the scale in a second
/// time. Repeated across a web view reload, a crash recovery, or a profile
/// switch, that compounds — a pane at 130% creeps larger on every replacement.
/// Deriving from a durable base makes the scale apply exactly once, however many
/// times the underlying view is rebuilt.
public enum GlobalZoomComposition {
    /// The value a surface should render at.
    ///
    /// - Parameters:
    ///   - base: The surface's own zoom, independent of the app-wide scale.
    ///   - scale: The app-wide multiplier, as from ``GlobalFontMagnification/scale``.
    ///   - minimum: Lower bound for the rendered value.
    ///   - maximum: Upper bound for the rendered value.
    /// - Returns: `base * scale`, clamped to the given bounds.
    public static func effective(
        base: CGFloat,
        scale: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard base.isFinite, scale.isFinite else { return minimum }
        return Swift.max(minimum, Swift.min(maximum, base * scale))
    }

    /// Recovers the base that renders at `rendered` under `scale`.
    ///
    /// Use when a caller states an intent in *rendered* terms — the browser
    /// automation and socket viewport verbs mean "make the page render at this
    /// factor" — so the stated factor survives round-tripping through
    /// ``effective(base:scale:minimum:maximum:)``.
    ///
    /// - Parameters:
    ///   - rendered: The desired rendered value.
    ///   - scale: The app-wide multiplier currently in effect.
    /// - Returns: The base to store; falls back to `rendered` for a
    ///   non-positive or non-finite scale rather than dividing by it.
    public static func base(forRendered rendered: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return rendered }
        return rendered / scale
    }
}
