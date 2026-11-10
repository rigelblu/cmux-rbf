import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.1` Scenario 4 (Q3, R4): the toolbar sits above the selection's
/// first row, else below its last, held inside the pane, and absent from a
/// pane narrower than itself. Space is points from the pane's top-left.
@Suite
struct ReplyInlinePlacementTests {
    /// 28 pt tall, 3 pt gap: it needs 31 pt above the first row.
    private let bounds = CGSize(width: 800, height: 600)

    private func place(
        rowTop: Double, rowBottom: Double, anchorX: Double = 100, bounds: CGSize? = nil
    ) -> ReplyInlinePlacement.Result? {
        ReplyInlinePlacement.frame(
            rowTop: rowTop, rowBottom: rowBottom, anchorX: anchorX, bounds: bounds ?? self.bounds
        )
    }

    @Test("Above: its bottom edge sits 3 pt over the first row, never on it")
    func aboveTheFirstRow() {
        let result = place(rowTop: 38, rowBottom: 89)
        #expect(result?.edge == .above)
        #expect(result?.frame == CGRect(x: 100, y: 38 - 3 - 28, width: ReplyInlinePlacement.toolbarSize.width, height: 28))
        #expect(result.map { $0.frame.maxY + 3 } == 38)
    }

    @Test("Exactly 31 pt of room above is enough")
    func thresholdIsInclusive() {
        #expect(place(rowTop: 31, rowBottom: 80)?.edge == .above)
        #expect(place(rowTop: 30.9, rowBottom: 80)?.edge == .below)
    }

    @Test("Below when the selection starts on the pane's top row")
    func topRowPlacesBelow() {
        // Row 0 with paddingTop 4 and 17 pt rows: rowTop 4, rowBottom 21.
        let result = place(rowTop: 4, rowBottom: 21)
        #expect(result?.edge == .below)
        #expect(result?.frame.minY == CGFloat(24))
    }

    @Test("Below on the second row too: 21 pt of room is less than 31")
    func secondRowPlacesBelow() {
        let result = place(rowTop: 21, rowBottom: 38)
        #expect(result?.edge == .below)
        #expect(result?.frame.minY == CGFloat(41))
    }

    @Test("A selection filling the pane puts the toolbar at the pane's top edge")
    func noRoomEitherWayIsThePaneTop() {
        let result = place(rowTop: 4, rowBottom: 596)
        #expect(result?.edge == .paneTop)
        #expect(result?.frame.minY == 0)
    }

    @Test("Below needs the whole toolbar to fit under the last row")
    func belowMustFitInside() {
        // 600 - (rowBottom + 3) must be >= 28: rowBottom 569 fits, 570 doesn't.
        #expect(place(rowTop: 4, rowBottom: 569)?.edge == .below)
        #expect(place(rowTop: 4, rowBottom: 570)?.edge == .paneTop)
    }

    @Test("It slides left at the right edge and right at the left edge")
    func slidesToStayInside() {
        let width = ReplyInlinePlacement.toolbarSize.width
        #expect(place(rowTop: 100, rowBottom: 117, anchorX: 790)?.frame.maxX == 800)
        #expect(place(rowTop: 100, rowBottom: 117, anchorX: 790)?.frame.minX == 800 - width)
        #expect(place(rowTop: 100, rowBottom: 117, anchorX: -12)?.frame.minX == 0)
    }

    @Test("A pane narrower than the toolbar gets no toolbar")
    func narrowPaneHasNone() {
        let width = ReplyInlinePlacement.toolbarSize.width
        #expect(place(rowTop: 100, rowBottom: 117, bounds: CGSize(width: width - 1, height: 600)) == nil)
        #expect(place(rowTop: 100, rowBottom: 117, bounds: CGSize(width: width, height: 600)) != nil)
    }

    @Test("The size is the same at every pane width")
    func sizeDoesNotFollowThePane() {
        let narrow = place(rowTop: 100, rowBottom: 117, bounds: CGSize(width: 90, height: 600))
        let wide = place(rowTop: 100, rowBottom: 117, bounds: CGSize(width: 2400, height: 600))
        #expect(narrow?.frame.size == wide?.frame.size)
        #expect(narrow?.frame.size == ReplyInlinePlacement.toolbarSize)
    }

    @Test("Never over the selection's own rows unless nothing else fits")
    func clearOfTheRows() {
        for (top, bottom) in [(38.0, 89.0), (4.0, 21.0), (21.0, 38.0), (300.0, 500.0)] {
            guard let result = place(rowTop: top, rowBottom: bottom), result.edge != .paneTop else {
                Issue.record("expected a placement clear of the rows for \(top)...\(bottom)"); continue
            }
            #expect(result.frame.maxY <= top || result.frame.minY >= bottom, "overlaps rows \(top)...\(bottom)")
        }
    }
}
