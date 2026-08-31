public import Bonsplit
public import CoreGraphics

/// Applies pure split-geometry plans (see `ExternalTreeNode` extensions in
/// `Geometry/`) to a live `BonsplitController`, preserving the legacy
/// divider-mutation order exactly: equalize applies children before their
/// parent, and a resize issues a single divider move.
///
/// `@MainActor` because `BonsplitController` is MainActor-isolated; the
/// service holds no state and is owned as a plain value by its callers.
@MainActor
public struct PaneLayoutService {
    /// Creates the stateless service.
    public init() {}

    /// Equalizes every split matching `orientationFilter` (all splits when
    /// `nil`) in the snapshot, applying the planned divider positions to
    /// `controller`. Lifted from the app-side `SplitEqualizer.equalize`.
    @discardableResult
    public func equalizeSplits(
        in node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String? = nil
    ) -> SplitEqualizeResult {
        let plan = node.equalizeDividerPlan(orientationFilter: orientationFilter)
        var allSucceeded = !plan.hadInvalidSplitIds
        for adjustment in plan.adjustments {
            if !controller.setDividerPosition(adjustment.position, forSplit: adjustment.splitId, fromExternal: true) {
                allSucceeded = false
            }
        }
        return SplitEqualizeResult(foundSplit: plan.foundSplit, allSucceeded: allSucceeded)
    }

    /// Arranges the same-orientation spans along `orientation` into the
    /// proportions in `ratios` (see `ExternalTreeNode.ratioDividerPlan`),
    /// applying the planned divider positions to `controller` children-first
    /// like the equalize pass. Returns `nil` when the weights do not fit the
    /// tree (span-count mismatch or invalid ratios).
    @discardableResult
    public func arrangeSplits(
        ratios: [CGFloat],
        in node: ExternalTreeNode,
        controller: BonsplitController,
        orientation: String
    ) -> SplitEqualizeResult? {
        guard let plan = node.ratioDividerPlan(ratios: ratios, orientation: orientation) else {
            return nil
        }
        var allSucceeded = !plan.hadInvalidSplitIds
        for adjustment in plan.adjustments {
            if !controller.setDividerPosition(adjustment.position, forSplit: adjustment.splitId, fromExternal: true) {
                allSucceeded = false
            }
        }
        return SplitEqualizeResult(foundSplit: plan.foundSplit, allSucceeded: allSucceeded)
    }

    /// Resizes the pane's controlling divider by `amountPixels` in
    /// `direction`, applying the planned clamped position to `controller`.
    /// Returns whether a divider was found and the move was accepted.
    /// Lifted from the divider math of the app-side `TabManager.resizeSplit`.
    public func resizeSplit(
        in node: ExternalTreeNode,
        targetPaneId: String,
        direction: ResizeDirection,
        amountPixels: UInt16,
        controller: BonsplitController
    ) -> Bool {
        guard let adjustment = node.resizeDividerAdjustment(
            targetPaneId: targetPaneId,
            direction: direction,
            amountPixels: amountPixels
        ) else {
            return false
        }
        return controller.setDividerPosition(adjustment.position, forSplit: adjustment.splitId, fromExternal: true)
    }
}
