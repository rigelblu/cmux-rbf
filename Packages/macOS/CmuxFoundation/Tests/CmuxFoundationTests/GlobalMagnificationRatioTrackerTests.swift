import Testing

@testable import CmuxFoundation

/// Regression coverage for the state that has broken this feature twice.
///
/// Both prior defects lived here, not in the scaling arithmetic:
/// the font pinned in place (a base recovered and re-multiplied by the same
/// percent is an identity), and then the first change of a session measuring
/// against 100% instead of the percent actually on screen.
///
/// Earlier tests computed the ratio in the test body and checked the pure
/// scaling helper, so they stayed green through both. These drive the baseline
/// itself.
@Suite struct GlobalMagnificationRatioTrackerTests {
    // MARK: - The seeding defect

    /// The defect: a session that starts at 150% and steps to 160% must scale by
    /// 1.067, not by 1.6. Unseeded, this returned 1.6 and grew a hand-sized pane
    /// by 50% on one keystroke.
    @Test func aTrackerSeededAboveDefaultScalesFromTheSeedNotFromOneHundred() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 150)

        let ratio = tracker.consume(percent: 160)

        #expect(ratio != nil)
        #expect(abs((ratio ?? 0) - (160.0 / 150.0)) < 0.0001)
        #expect(abs((ratio ?? 0) - 1.6) > 0.1, "must not measure against 100%")
    }

    /// Zooming OUT must shrink. Unseeded at 200%, the first ⇧⌘- produced
    /// 190/100 = 1.9 and grew the pane the user asked to shrink.
    @Test func theFirstZoomOutOfASessionShrinks() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 200)

        let ratio = tracker.consume(percent: 190)

        #expect((ratio ?? 0) < 1.0, "zoom out must not enlarge")
        #expect(abs((ratio ?? 0) - 0.95) < 0.0001)
    }

    /// "Actual Size" from 150% must actually resize. Unseeded, baseline and new
    /// percent were both 100, so the change was swallowed and hand-sized panes
    /// stayed at 150%-relative size while the rest of the app dropped.
    @Test func resettingToDefaultFromANonDefaultSeedIsNotSwallowed() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 150)

        let ratio = tracker.consume(percent: 100)

        #expect(ratio != nil, "reset must produce a rescale")
        #expect(abs((ratio ?? 0) - (100.0 / 150.0)) < 0.0001)
    }

    // MARK: - Sequencing

    @Test func successiveChangesEachMeasureAgainstThePreviousPercent() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 100)

        #expect(abs((tracker.consume(percent: 110) ?? 0) - 110.0 / 100.0) < 0.0001)
        #expect(abs((tracker.consume(percent: 120) ?? 0) - 120.0 / 110.0) < 0.0001)
        #expect(abs((tracker.consume(percent: 130) ?? 0) - 130.0 / 120.0) < 0.0001)
    }

    /// Compounding the successive ratios must reproduce the end-to-end scale, so
    /// stepping up N times and back down N times returns a surface to its size.
    @Test func compoundedRatiosRoundTripToOne() {
        var up = GlobalMagnificationRatioTracker(startingAt: 100)
        var product = 1.0
        for percent in [110, 120, 130, 140] {
            product *= up.consume(percent: percent) ?? 1
        }
        for percent in [130, 120, 110, 100] {
            product *= up.consume(percent: percent) ?? 1
        }
        #expect(abs(product - 1.0) < 0.0001)
    }

    @Test func anUnchangedPercentRescalesNothing() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 130)
        #expect(tracker.consume(percent: 130) == nil)
    }

    /// Key-repeat at a bound: the percent stops moving, so nothing is rescaled
    /// however many times the notification arrives.
    @Test func repeatedConsumesAtABoundRescaleNothingAfterTheFirst() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 190)
        #expect(tracker.consume(percent: 200) != nil)
        for _ in 0..<10 {
            #expect(tracker.consume(percent: 200) == nil)
        }
    }

    // MARK: - Normalisation

    @Test func theSeedIsClampedSoAnOutOfRangeStoredValueCannotSkewTheFirstRatio() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 5_000)
        #expect(tracker.baseline == GlobalFontMagnification.maximumPercent)
        #expect(tracker.consume(percent: GlobalFontMagnification.maximumPercent) == nil)
    }

    @Test func baselineAdvancesToTheClampedValueNotTheRequestedOne() {
        var tracker = GlobalMagnificationRatioTracker(startingAt: 100)
        _ = tracker.consume(percent: 10_000)
        #expect(tracker.baseline == GlobalFontMagnification.maximumPercent)
    }
}
