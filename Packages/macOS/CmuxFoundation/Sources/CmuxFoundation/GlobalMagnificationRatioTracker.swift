public import Foundation

/// Turns successive app-wide magnification percents into the *ratio* between
/// them, which is what surfaces that opt out of config reload must be scaled by.
///
/// This exists as its own type because every bug in this feature has lived in
/// exactly this state, never in the arithmetic it feeds:
///
/// - The scale was first applied by recovering a per-surface base and
///   multiplying by the new percent. That is an identity — the base is derived
///   by dividing the live size by that same percent — so the font pinned in
///   place while every intermediate value looked plausible.
/// - The replacement tracked the previous percent but never seeded it, so the
///   first change of a session measured against 100% instead of the percent
///   actually on screen. At 200% a first zoom-*out* grew the font by 90%, and a
///   first reset from 150% was a silent no-op.
///
/// Both were invisible to tests that computed the ratio in the test body and
/// checked the pure scaling helper. Keeping the baseline here makes the part
/// that actually broke twice directly testable.
public struct GlobalMagnificationRatioTracker: Sendable {
    private var lastAppliedPercent: Int

    /// Creates a tracker anchored to the percent already in effect.
    ///
    /// - Important: Seed this from the *stored* percent when the observer is
    ///   installed, not lazily on first use. Resolving the baseline when the
    ///   first change arrives reads it after the new value is written, which
    ///   yields a ratio of 1 and swallows the first zoom entirely.
    /// - Parameter percent: The magnification percent currently on screen.
    public init(startingAt percent: Int) {
        lastAppliedPercent = GlobalFontMagnification.clamp(percent)
    }

    /// The percent this tracker will measure the next change against.
    public var baseline: Int { lastAppliedPercent }

    /// Records a new percent and returns the ratio to scale surfaces by.
    ///
    /// - Parameter percent: The magnification percent now in effect.
    /// - Returns: `newPercent / previousPercent`, or `nil` when the percent did
    ///   not move and nothing should be rescaled.
    public mutating func consume(percent: Int) -> Double? {
        let clamped = GlobalFontMagnification.clamp(percent)
        let previous = lastAppliedPercent
        lastAppliedPercent = clamped
        guard clamped != previous, previous > 0 else { return nil }
        return Double(clamped) / Double(previous)
    }
}
