import Bonsplit
import CoreGraphics
import Foundation
import Testing
@testable import CmuxPanes

@Suite("SplitGeometry")
struct SplitGeometryTests {
    private func pane(_ id: String, x: Double = 0, y: Double = 0, width: Double = 100, height: Double = 100) -> ExternalTreeNode {
        .pane(ExternalPaneNode(
            id: id,
            frame: PixelRect(x: x, y: y, width: width, height: height),
            tabs: [],
            selectedTabId: nil
        ))
    }

    private func split(
        _ id: UUID,
        orientation: String,
        dividerPosition: Double = 0.5,
        first: ExternalTreeNode,
        second: ExternalTreeNode
    ) -> ExternalTreeNode {
        .split(ExternalSplitNode(
            id: id.uuidString,
            orientation: orientation,
            dividerPosition: dividerPosition,
            first: first,
            second: second
        ))
    }

    // MARK: Equalize planning

    @Test func equalizeWeightsNestedSameOrientationSpans() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            dividerPosition: 0.8,
            first: pane("a"),
            second: split(
                innerId,
                orientation: "horizontal",
                dividerPosition: 0.2,
                first: pane("b"),
                second: pane("c")
            )
        )

        let plan = tree.equalizeDividerPlan()

        #expect(plan.foundSplit)
        #expect(!plan.hadInvalidSplitIds)
        // Children are planned before their parent (legacy post-order).
        #expect(plan.adjustments.map(\.splitId) == [innerId, outerId])
        // Inner split divides its two leaves evenly; the outer divider gives
        // its first child 1 of 3 same-orientation spans.
        #expect(plan.adjustments[0].position == 0.5)
        #expect(abs(plan.adjustments[1].position - (1.0 / 3.0)) < 0.0001)
    }

    @Test func equalizeTreatsCrossOrientationSubtreeAsOneSpan() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            first: pane("a"),
            second: split(
                innerId,
                orientation: "vertical",
                first: pane("b"),
                second: pane("c")
            )
        )

        let plan = tree.equalizeDividerPlan()

        // The vertical subtree counts as a single horizontal span, so the
        // outer divider lands at 1/2.
        #expect(plan.adjustments.first { $0.splitId == outerId }?.position == 0.5)
        #expect(plan.adjustments.first { $0.splitId == innerId }?.position == 0.5)
    }

    @Test func equalizeOrientationFilterSkipsOtherOrientations() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            first: pane("a"),
            second: split(
                innerId,
                orientation: "vertical",
                first: pane("b"),
                second: pane("c")
            )
        )

        let plan = tree.equalizeDividerPlan(orientationFilter: "vertical")

        #expect(plan.foundSplit)
        #expect(plan.adjustments.map(\.splitId) == [innerId])

        let noMatch = pane("solo").equalizeDividerPlan(orientationFilter: "vertical")
        #expect(!noMatch.foundSplit)
        #expect(noMatch.adjustments.isEmpty)
    }

    @Test func equalizeFlagsUnparseableSplitIds() {
        let tree = ExternalTreeNode.split(ExternalSplitNode(
            id: "not-a-uuid",
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: pane("a"),
            second: pane("b")
        ))

        let plan = tree.equalizeDividerPlan()

        #expect(plan.foundSplit)
        #expect(plan.hadInvalidSplitIds)
        #expect(plan.adjustments.isEmpty)
    }

    // MARK: Ratio planning

    @Test func ratioPlanWeightsRightLeaningThreeColumnRun() {
        let outerId = UUID()
        let innerId = UUID()
        // a | (b | c) — a right-leaning run reads a, b, c left-to-right.
        let tree = split(
            outerId,
            orientation: "horizontal",
            dividerPosition: 0.8,
            first: pane("a"),
            second: split(
                innerId,
                orientation: "horizontal",
                dividerPosition: 0.2,
                first: pane("b"),
                second: pane("c")
            )
        )

        let plan = tree.ratioDividerPlan(ratios: [1, 1, 0.5], orientation: "horizontal")

        #expect(plan != nil)
        #expect(plan?.foundSplit == true)
        #expect(plan?.hadInvalidSplitIds == false)
        // Children before parent, matching the equalize application order.
        #expect(plan?.adjustments.map(\.splitId) == [innerId, outerId])
        // a gets 1/2.5 = 0.4 of the outer axis; within (b|c), b gets 1/1.5.
        #expect(plan.map { abs($0.adjustments[0].position - (1.0 / 1.5)) < 0.0001 } == true)
        #expect(plan.map { abs($0.adjustments[1].position - 0.4) < 0.0001 } == true)
    }

    @Test func ratioPlanWeightsLeftLeaningThreeColumnRun() {
        // (a | b) | c — the same three spans nested the other way. The weight
        // rule reads spans in spatial order, so a:b:c = 1:1:0.5 must land the
        // same 40/40/20 however the binary tree leans.
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            dividerPosition: 0.2,
            first: split(
                innerId,
                orientation: "horizontal",
                dividerPosition: 0.8,
                first: pane("a"),
                second: pane("b")
            ),
            second: pane("c")
        )

        let plan = tree.ratioDividerPlan(ratios: [1, 1, 0.5], orientation: "horizontal")

        #expect(plan?.adjustments.map(\.splitId) == [innerId, outerId])
        // Within (a|b), a gets 1/2; (a|b) as a whole gets 2/2.5 = 0.8 of the outer axis.
        #expect(plan.map { abs($0.adjustments[0].position - 0.5) < 0.0001 } == true)
        #expect(plan.map { abs($0.adjustments[1].position - 0.8) < 0.0001 } == true)
    }

    @Test func ratioPlanWeightsMainLastAndMinorFirstShapes() {
        // The Main Last and Minor First weight vectors on a | (b | c): the
        // heavy or light span sits where the nesting is deepest or shallowest.
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            first: pane("a"),
            second: split(
                innerId,
                orientation: "horizontal",
                first: pane("b"),
                second: pane("c")
            )
        )

        // Main Last, 1:1:2 — within (b|c), b gets 1/3; a gets 1/4 of the outer axis.
        let mainLast = tree.ratioDividerPlan(ratios: [1, 1, 2], orientation: "horizontal")
        #expect(mainLast?.adjustments.map(\.splitId) == [innerId, outerId])
        #expect(mainLast.map { abs($0.adjustments[0].position - (1.0 / 3.0)) < 0.0001 } == true)
        #expect(mainLast.map { abs($0.adjustments[1].position - 0.25) < 0.0001 } == true)

        // Minor First, 0.5:1:1 — within (b|c), b gets 1/2; a gets 0.5/2.5 = 0.2.
        let minorFirst = tree.ratioDividerPlan(ratios: [0.5, 1, 1], orientation: "horizontal")
        #expect(minorFirst.map { abs($0.adjustments[0].position - 0.5) < 0.0001 } == true)
        #expect(minorFirst.map { abs($0.adjustments[1].position - 0.2) < 0.0001 } == true)
    }

    @Test func ratioPlanLeavesCrossOrientationSubtreeAlone() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            first: pane("a"),
            second: split(
                innerId,
                orientation: "vertical",
                dividerPosition: 0.3,
                first: pane("b"),
                second: pane("c")
            )
        )

        // The vertical pair is one horizontal span: 2 spans fit a 2-ratio preset.
        let plan = tree.ratioDividerPlan(ratios: [2, 1], orientation: "horizontal")

        #expect(plan?.adjustments.map(\.splitId) == [outerId])
        #expect(plan.map { abs($0.adjustments[0].position - (2.0 / 3.0)) < 0.0001 } == true)
    }

    @Test func ratioPlanRejectsCountMismatchAndBadRatios() {
        let tree = split(
            UUID(),
            orientation: "horizontal",
            first: pane("a"),
            second: pane("b")
        )

        // 3 ratios over 2 spans does not fit.
        #expect(tree.ratioDividerPlan(ratios: [1, 1, 0.5], orientation: "horizontal") == nil)
        // A lone pane has 1 span; nothing fits a multi-weight vector.
        #expect(pane("solo").ratioDividerPlan(ratios: [1, 1], orientation: "horizontal") == nil)
        // Empty and non-positive ratios are invalid.
        #expect(tree.ratioDividerPlan(ratios: [], orientation: "horizontal") == nil)
        #expect(tree.ratioDividerPlan(ratios: [1, 0], orientation: "horizontal") == nil)
        // A non-finite weight would put NaN into a divider position.
        #expect(tree.ratioDividerPlan(ratios: [1, .infinity], orientation: "horizontal") == nil)
    }

    @Test func ratioPlanEqualWeightsMatchesEqualizePlan() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            dividerPosition: 0.8,
            first: pane("a"),
            second: split(
                innerId,
                orientation: "horizontal",
                dividerPosition: 0.2,
                first: pane("b"),
                second: pane("c")
            )
        )

        let ratioPlan = tree.ratioDividerPlan(ratios: [1, 1, 1], orientation: "horizontal")
        let equalizePlan = tree.equalizeDividerPlan(orientationFilter: "horizontal")

        #expect(ratioPlan?.adjustments.map(\.splitId) == equalizePlan.adjustments.map(\.splitId))
        for (ratioAdjustment, equalizeAdjustment) in zip(ratioPlan?.adjustments ?? [], equalizePlan.adjustments) {
            #expect(abs(ratioAdjustment.position - equalizeAdjustment.position) < 0.0001)
        }
    }

    // MARK: Resize planning

    @Test func resizeMovesControllingDividerByPixelDelta() {
        let splitId = UUID()
        let tree = split(
            splitId,
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: pane("a", x: 0, y: 0, width: 300, height: 400),
            second: pane("b", x: 300, y: 0, width: 300, height: 400)
        )

        // Target the second child; .left controls a divider whose target sits
        // in the second child and moves it toward the first child.
        let adjustment = tree.resizeDividerAdjustment(targetPaneId: "b", direction: .left, amountPixels: 60)

        #expect(adjustment?.splitId == splitId)
        // 60px over a 600px axis = 0.1 delta, signed negative for .left.
        #expect(adjustment.map { abs($0.position - 0.4) < 0.0001 } == true)
    }

    @Test func resizeRequiresMatchingChildSide() {
        let splitId = UUID()
        let tree = split(
            splitId,
            orientation: "horizontal",
            first: pane("a", width: 300),
            second: pane("b", x: 300, width: 300)
        )

        // .right requires the target in the first child; "b" is the second.
        #expect(tree.resizeDividerAdjustment(targetPaneId: "b", direction: .right, amountPixels: 10) == nil)
        // Vertical resize has no vertical split to control.
        #expect(tree.resizeDividerAdjustment(targetPaneId: "b", direction: .up, amountPixels: 10) == nil)
        // Unknown pane plans nothing.
        #expect(tree.resizeDividerAdjustment(targetPaneId: "zz", direction: .left, amountPixels: 10) == nil)
    }

    @Test func resizePrefersInnermostEnclosingSplit() {
        let outerId = UUID()
        let innerId = UUID()
        let tree = split(
            outerId,
            orientation: "horizontal",
            dividerPosition: 0.5,
            first: pane("a", width: 300, height: 400),
            second: split(
                innerId,
                orientation: "horizontal",
                dividerPosition: 0.5,
                first: pane("b", x: 300, width: 150, height: 400),
                second: pane("c", x: 450, width: 150, height: 400)
            )
        )

        // "c" sits in the second child of BOTH splits; the innermost
        // (closest enclosing) candidate wins, matching the legacy order.
        let adjustment = tree.resizeDividerAdjustment(targetPaneId: "c", direction: .left, amountPixels: 30)
        #expect(adjustment?.splitId == innerId)
    }

    @Test func resizeClampsDividerToLegacyBounds() {
        let splitId = UUID()
        let tree = split(
            splitId,
            orientation: "vertical",
            dividerPosition: 0.85,
            first: pane("a", width: 600, height: 200),
            second: pane("b", y: 200, width: 600, height: 200)
        )

        // A huge downward move from 0.85 clamps to 0.9.
        let adjustment = tree.resizeDividerAdjustment(targetPaneId: "a", direction: .down, amountPixels: 400)
        #expect(adjustment?.position == 0.9)
    }

    // MARK: Direction values

    @Test func splitDirectionMapsOrientationAndInsertionSide() {
        #expect(SplitDirection.left.isHorizontal)
        #expect(SplitDirection.right.isHorizontal)
        #expect(!SplitDirection.up.isHorizontal)
        #expect(SplitDirection.left.orientation == .horizontal)
        #expect(SplitDirection.down.orientation == .vertical)
        #expect(SplitDirection.left.insertFirst)
        #expect(SplitDirection.up.insertFirst)
        #expect(!SplitDirection.right.insertFirst)
        #expect(!SplitDirection.down.insertFirst)
    }

    @Test func resizeDirectionMapsSplitAxisAndSign() {
        #expect(ResizeDirection.left.splitOrientation == "horizontal")
        #expect(ResizeDirection.down.splitOrientation == "vertical")
        #expect(ResizeDirection.right.requiresPaneInFirstChild)
        #expect(ResizeDirection.down.requiresPaneInFirstChild)
        #expect(!ResizeDirection.left.requiresPaneInFirstChild)
        #expect(ResizeDirection.right.dividerDeltaSign == 1)
        #expect(ResizeDirection.up.dividerDeltaSign == -1)
    }
}
