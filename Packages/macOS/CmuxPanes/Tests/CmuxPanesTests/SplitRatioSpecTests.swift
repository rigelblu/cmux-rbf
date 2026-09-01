import Bonsplit
import CoreGraphics
import Foundation
import Testing
@testable import CmuxPanes

@Suite("SplitRatioSpec")
struct SplitRatioSpecTests {
    // MARK: - Parsing

    @Test
    func parsesTheMenuHintNotation() {
        #expect(SplitRatioSpec("1:1:0.5")?.weights == [1, 1, 0.5])
        #expect(SplitRatioSpec("2:1")?.weights == [2, 1])
        #expect(SplitRatioSpec(" 2 : 1 : 1 ")?.weights == [2, 1, 1])
    }

    @Test
    func rejectsVectorsWithNoUsableGeometry() {
        // Fewer than two weights: nothing to divide.
        #expect(SplitRatioSpec("1") == nil)
        #expect(SplitRatioSpec("") == nil)
        // A zero or negative share has no width to occupy.
        #expect(SplitRatioSpec("1:0") == nil)
        #expect(SplitRatioSpec("1:-2") == nil)
        // Non-finite weights produce a NaN divider position downstream.
        #expect(SplitRatioSpec("1:inf") == nil)
        #expect(SplitRatioSpec("1:nan") == nil)
        // Non-numeric fields.
        #expect(SplitRatioSpec("1:wide") == nil)
        // An empty field fails rather than being skipped: skipping would apply
        // a vector the user did not write.
        #expect(SplitRatioSpec("1::2") == nil)
        #expect(SplitRatioSpec("1:1:") == nil)
    }

    @Test
    func rejectsBadWeightsThroughTheDirectInitializerToo() {
        #expect(SplitRatioSpec(weights: [1]) == nil)
        #expect(SplitRatioSpec(weights: []) == nil)
        #expect(SplitRatioSpec(weights: [1, 0]) == nil)
        #expect(SplitRatioSpec(weights: [1, .infinity]) == nil)
        #expect(SplitRatioSpec(weights: [1, 1, 0.5])?.weights == [1, 1, 0.5])
    }

    // MARK: - Span adaptation

    @Test
    func writtenCountReturnsExactlyWhatWasWritten() {
        // The identity case is the one users check first, and the rule that
        // repeats `weights[1]` in place is what preserves it at every length.
        #expect(SplitRatioSpec("2:1")?.ratios(forSpanCount: 2) == [2, 1])
        #expect(SplitRatioSpec("1:1:0.5")?.ratios(forSpanCount: 3) == [1, 1, 0.5])
        #expect(SplitRatioSpec("2:3:1:0.5")?.ratios(forSpanCount: 4) == [2, 3, 1, 0.5])
    }

    @Test
    func moreSpansRepeatTheSecondWeightAndKeepEveryOther() {
        #expect(SplitRatioSpec("2:1")?.ratios(forSpanCount: 3) == [2, 1, 1])
        #expect(SplitRatioSpec("2:1")?.ratios(forSpanCount: 5) == [2, 1, 1, 1, 1])
        #expect(SplitRatioSpec("1:1:0.5")?.ratios(forSpanCount: 5) == [1, 1, 1, 1, 0.5])
        // The weight that discriminates this rule from head/filler/tail: a
        // head/filler/tail rule would give [2, 3, 3, 1, 0.5] -> [2, 3, 3, 3, 0.5]
        // and drop the written `1` entirely.
        #expect(SplitRatioSpec("2:3:1:0.5")?.ratios(forSpanCount: 6) == [2, 3, 3, 3, 1, 0.5])
    }

    @Test
    func fewerSpansKeepTheHeadAndTail() {
        #expect(SplitRatioSpec("1:1:0.5")?.ratios(forSpanCount: 2) == [1, 0.5])
        #expect(SplitRatioSpec("2:3:1:0.5")?.ratios(forSpanCount: 3) == [2, 1, 0.5])
        #expect(SplitRatioSpec("2:3:1:0.5")?.ratios(forSpanCount: 2) == [2, 0.5])
    }

    @Test
    func belowTwoSpansThereIsNothingToArrange() {
        #expect(SplitRatioSpec("1:1:0.5")?.ratios(forSpanCount: 1) == nil)
        #expect(SplitRatioSpec("1:1:0.5")?.ratios(forSpanCount: 0) == nil)
        #expect(SplitRatioSpec("1:1:0.5")?.ratios(forSpanCount: -1) == nil)
    }

    // MARK: - The built-ins are specs

    /// The four built-in patterns are `SplitRatioSpec`s, not a parallel rule.
    /// This pins that equivalence across every span count the menu can reach,
    /// so the `#cm-67.1` unification stays behaviour-preserving for `#cm-67`.
    @Test
    func builtInPatternsMatchTheirPreUnificationVectors() {
        func preUnification(_ kind: String, _ spanCount: Int) -> [CGFloat] {
            var ratios = [CGFloat](repeating: 1, count: spanCount)
            switch kind {
            case "mainFirst": ratios[0] = 2
            case "mainLast": ratios[spanCount - 1] = 2
            case "minorFirst": ratios[0] = 0.5
            default: ratios[spanCount - 1] = 0.5
            }
            return ratios
        }

        let specs = [
            "mainFirst": "2:1",
            "mainLast": "1:1:2",
            "minorFirst": "0.5:1",
            "minorLast": "1:1:0.5",
        ]
        for (kind, text) in specs {
            let spec = SplitRatioSpec(text)
            #expect(spec != nil, "\(kind) spec \(text) failed to parse")
            for spanCount in 2...12 {
                #expect(
                    spec?.ratios(forSpanCount: spanCount) == preUnification(kind, spanCount),
                    "\(kind) diverged at \(spanCount) spans"
                )
            }
        }
    }

    /// A spec feeds `ratioDividerPlan` directly — the geometry layer has no
    /// notion of built-in versus custom.
    @Test
    func specWeightsDriveTheDividerPlan() {
        func pane(_ id: String) -> ExternalTreeNode {
            .pane(ExternalPaneNode(
                id: id,
                frame: PixelRect(x: 0, y: 0, width: 100, height: 100),
                tabs: [],
                selectedTabId: nil
            ))
        }

        let tree = ExternalTreeNode.split(ExternalSplitNode(
            id: UUID().uuidString,
            orientation: "horizontal",
            dividerPosition: 0.8,
            first: pane("a"),
            second: pane("b")
        ))

        let spec = SplitRatioSpec("2:1")
        let ratios = spec?.ratios(forSpanCount: tree.spanCount(along: "horizontal"))
        #expect(ratios == [2, 1])

        let plan = tree.ratioDividerPlan(ratios: ratios ?? [], orientation: "horizontal")
        #expect(plan?.adjustments.count == 1)
        #expect(plan?.adjustments.first?.position == 2.0 / 3.0)
    }
}
