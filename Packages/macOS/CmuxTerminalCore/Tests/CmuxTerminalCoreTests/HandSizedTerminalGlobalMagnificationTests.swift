import Testing
import CmuxTerminalCore

/// Regression coverage for two defects dogfood caught on 2026-07-31, both in
/// how a hand-sized terminal follows the app-wide magnification.
///
/// **First:** every pane scaled except the one the user had sized by hand.
/// Ghostty sets `font_size_adjusted` on any manual font change and then skips
/// that surface on config reload — by design, "since we assume the user wants a
/// specific size" (`Surface.zig`). cmux drove the app-wide scale purely through
/// config reload, so exactly the panes carrying user intent were left frozen.
///
/// **Second, and self-inflicted:** the repair recovered the surface's unscaled
/// base and multiplied it by the new percent. That is a *fixed point* in this
/// position — the base is itself derived by dividing the live size by the
/// current percent, so it multiplies straight back to the size already on
/// screen. The instrumented build showed the font pinned at 13.0pt across 170%,
/// 180%, and 190% while every intermediate value looked reasonable.
///
/// The repair scales by the ratio between the old and new percent instead.
@Suite struct HandSizedTerminalGlobalMagnificationTests {
    // MARK: - The ratio actually moves the font

    @Test func scalingUpGrowsTheFont() {
        let scaled = CmuxSurfaceConfigTemplate.runtimePointsScaled(current: 13, byMagnificationRatio: 1.5)
        #expect(scaled != nil)
        #expect((scaled ?? 0) > 13)
    }

    @Test func scalingDownShrinksTheFont() {
        let scaled = CmuxSurfaceConfigTemplate.runtimePointsScaled(current: 20, byMagnificationRatio: 0.5)
        #expect(scaled != nil)
        #expect((scaled ?? 0) < 20)
    }

    /// The exact defect: stepping the magnification repeatedly must keep moving
    /// the font, not settle on one value. This is the shape the instrumented
    /// log showed — 13.0, 13.0, 13.0 across three different percentages.
    @Test func steppingRepeatedlyKeepsMovingInsteadOfPinning() {
        var size: Float32 = 13
        var seen: [Float32] = [size]

        // 100 → 110 → 120 → 130, each a ratio against the previous percent.
        for (from, to) in [(100, 110), (110, 120), (120, 130)] {
            let ratio = Double(to) / Double(from)
            guard let next = CmuxSurfaceConfigTemplate.runtimePointsScaled(
                current: size,
                byMagnificationRatio: ratio
            ) else {
                Issue.record("ratio \(from)->\(to) produced no change from \(size)")
                continue
            }
            #expect(next > size)
            size = next
            seen.append(size)
        }

        #expect(Set(seen).count == seen.count, "font pinned — saw repeats in \(seen)")
    }

    /// Round-tripping the magnification returns the font to where it started,
    /// so zooming in and back out is not lossy.
    @Test func zoomingUpThenBackDownReturnsToTheStartingSize() {
        let start: Float32 = 13
        let up = CmuxSurfaceConfigTemplate.runtimePointsScaled(current: start, byMagnificationRatio: 1.6)
        #expect(up != nil)
        let back = CmuxSurfaceConfigTemplate.runtimePointsScaled(
            current: up ?? start,
            byMagnificationRatio: 1 / 1.6
        )
        #expect(abs((back ?? 0) - start) < 0.05)
    }

    // MARK: - The trap, pinned so it cannot return

    /// Pins *why* the base approach was abandoned. `basePoints` is derived by
    /// dividing the live size by the current percent; re-multiplying by that
    /// same percent is the identity. A future refactor that "simplifies" the
    /// ratio back into a base recreates the frozen-font defect, and this test
    /// is the thing that should stop it.
    @Test func rebuildingABaseFromTheLiveSizeIsAFixedPointAndChangesNothing() {
        let live: Float32 = 13
        for percent in [110, 150, 170, 190] {
            let derivedBase = CmuxSurfaceConfigTemplate.baseFontSize(
                fromRuntimePoints: live,
                percent: percent
            )
            let rebuilt = CmuxSurfaceConfigTemplate.runtimeFontSize(
                fromBasePoints: derivedBase,
                percent: percent
            )
            #expect(
                abs(rebuilt - live) < 0.01,
                "base round-trip should be the identity at \(percent)% — that is the trap"
            )
        }
    }

    // MARK: - Guards

    @Test func aRatioOfOneChangesNothing() {
        #expect(CmuxSurfaceConfigTemplate.runtimePointsScaled(current: 13, byMagnificationRatio: 1) == nil)
    }

    @Test func degenerateInputsScaleNothingRatherThanZeroingTheFont() {
        #expect(CmuxSurfaceConfigTemplate.runtimePointsScaled(current: 0, byMagnificationRatio: 1.5) == nil)
        #expect(CmuxSurfaceConfigTemplate.runtimePointsScaled(current: -3, byMagnificationRatio: 1.5) == nil)
        #expect(CmuxSurfaceConfigTemplate.runtimePointsScaled(current: 13, byMagnificationRatio: 0) == nil)
        #expect(CmuxSurfaceConfigTemplate.runtimePointsScaled(current: 13, byMagnificationRatio: -1) == nil)
        #expect(CmuxSurfaceConfigTemplate.runtimePointsScaled(current: 13, byMagnificationRatio: .nan) == nil)
    }

    @Test func aHandSetSizeStillRecordsAnExplicitOverride() {
        var template = CmuxSurfaceConfigTemplate()
        template.fontSize = 17

        #expect(template.fontSizeLineage?.isExplicitOverride == true)
        #expect(template.fontSizeLineage?.basePoints == 17)
    }
}
