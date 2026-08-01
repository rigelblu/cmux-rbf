import CoreGraphics
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``GlobalZoomComposition``, the two-axis arithmetic behind
/// per-surface zoom and the app-wide scale.
@Suite struct GlobalZoomCompositionTests {
    private let minimum: CGFloat = 0.25
    private let maximum: CGFloat = 5.0

    private func effective(_ base: CGFloat, _ scale: CGFloat) -> CGFloat {
        GlobalZoomComposition.effective(base: base, scale: scale, minimum: minimum, maximum: maximum)
    }

    @Test func aDefaultScaleLeavesTheBaseAlone() {
        #expect(effective(1.0, 1.0) == 1.0)
        #expect(effective(1.5, 1.0) == 1.5)
    }

    @Test func theScaleMultipliesTheBase() {
        #expect(abs(effective(1.0, 1.3) - 1.3) < 0.0001)
        #expect(abs(effective(1.5, 2.0) - 3.0) < 0.0001)
    }

    @Test func theProductIsClampedToTheBounds() {
        #expect(effective(4.0, 2.0) == maximum)
        #expect(effective(0.3, 0.5) == minimum)
    }

    /// The regression this whole file exists for.
    ///
    /// A web view reload, crash recovery, or profile switch rebuilds the view
    /// and has to restore zoom. Reading the *rendered* value back and storing it
    /// as the next base folds the app-wide scale in again each time, so a pane
    /// grows on every replacement. Deriving from a durable base does not.
    @Test func replacementDerivedFromTheBaseDoesNotCompound() {
        let scale: CGFloat = 1.3
        let base: CGFloat = 1.0

        var derived = effective(base, scale)
        for _ in 0..<10 {
            // What every replacement site must do: recompute from the stored
            // base, never from the outgoing view's rendered value.
            derived = effective(base, scale)
        }

        #expect(abs(derived - 1.3) < 0.0001)
    }

    /// Pins the pre-fix behavior so the test above cannot quietly stop meaning
    /// anything: feeding the rendered value back in as the base *does* run away.
    @Test func feedingTheRenderedValueBackInCompounds() {
        let scale: CGFloat = 1.3
        var rendered = effective(1.0, scale)
        for _ in 0..<10 {
            rendered = effective(rendered, scale)
        }

        // 1.3^11 far exceeds the ceiling, so the runaway pins to the maximum —
        // which is exactly the "pane keeps growing on every reload" symptom.
        #expect(rendered == maximum)
        #expect(rendered > 1.3)
    }

    @Test func renderedValuesRoundTripThroughABase() {
        let scale: CGFloat = 1.3
        let requested: CGFloat = 1.5
        let base = GlobalZoomComposition.base(forRendered: requested, scale: scale)
        #expect(abs(effective(base, scale) - requested) < 0.0001)
    }

    @Test func roundTrippingHoldsAtTheDefaultScale() {
        let base = GlobalZoomComposition.base(forRendered: 2.0, scale: 1.0)
        #expect(base == 2.0)
        #expect(effective(base, 1.0) == 2.0)
    }

    @Test func aNonPositiveScaleFallsBackInsteadOfDividingByIt() {
        #expect(GlobalZoomComposition.base(forRendered: 1.5, scale: 0) == 1.5)
        #expect(GlobalZoomComposition.base(forRendered: 1.5, scale: -1) == 1.5)
    }

    @Test func nonFiniteInputsResolveToTheMinimumRatherThanPropagating() {
        #expect(effective(.nan, 1.0) == minimum)
        #expect(effective(1.0, .infinity) == minimum)
        #expect(GlobalZoomComposition.base(forRendered: 1.5, scale: .nan) == 1.5)
    }

    /// A surface the user sized by hand keeps its size *relative* to everything
    /// else when the app-wide scale moves.
    @Test func aHandSizedSurfaceKeepsItsRelativeSize() {
        let handSized: CGFloat = 1.5
        let ordinary: CGFloat = 1.0

        let ratioAtDefault = effective(handSized, 1.0) / effective(ordinary, 1.0)
        let ratioScaled = effective(handSized, 1.4) / effective(ordinary, 1.4)

        #expect(abs(ratioAtDefault - ratioScaled) < 0.0001)
    }
}
