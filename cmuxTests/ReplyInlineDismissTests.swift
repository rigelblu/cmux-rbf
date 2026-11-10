import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cm-136.1` Scenario 13's decisions (Q4, R1, R2): what takes a showing
/// toolbar away, and why. The monitor's install and removal are wired in the
/// shell and tested there.
@Suite
struct ReplyInlineDismissTests {
    private static let passage = ReplyInlinePassage(
        rawText: "origin-checked open tab",
        sourcePanelID: UUID(),
        topRow: 2, bottomRow: 4, rowTop: 38, rowBottom: 89,
        anchorX: 100, wrapColumns: 80, firstRowStartColumn: 5,
        offsetStart: 165, distanceToBottomRight: 170
    )

    private func reason(
        _ event: ReplyInlineEvent,
        sidebarShowingReplyAtShow: Bool = false
    ) -> ReplyInlineDismissReason? {
        ReplyInlineDismissal.reason(
            for: event, passage: Self.passage, sidebarShowingReplyAtShow: sidebarShowingReplyAtShow
        )
    }

    private func current(
        text: String = "origin-checked open tab",
        baselineY: Double = 50.5,
        offsetStart: Int = 165,
        distanceToBottomRight: Int = 170
    ) -> ReplyInlineSelectionGeometry {
        ReplyInlineSelectionGeometry(
            text: text, topLeftX: 100, baselineY: baselineY,
            offsetStart: offsetStart, distanceToBottomRight: distanceToBottomRight
        )
    }

    @Test("A click anywhere but the toolbar takes it away")
    func clickElsewhereDismisses() {
        #expect(reason(.mouseDown(onToolbar: false)) == .click)
    }

    @Test("A click on the toolbar is Reply, not a dismissal")
    func clickOnTheToolbarDoesNot() {
        #expect(reason(.mouseDown(onToolbar: true)) == nil)
    }

    @Test("Any key takes it away")
    func keyDismisses() {
        #expect(reason(.keyDown) == .key)
    }

    @Test("The same selection leaves it")
    func sameSelectionStays() {
        #expect(reason(.selectionChecked(current())) == nil)
    }

    @Test("A selection that moved vertically with the same offsets still counts as the same")
    func baselineAloneDoesNotDismiss() {
        #expect(reason(.selectionChecked(current(baselineY: 120))) == nil)
    }

    @Test("A cleared selection dismisses")
    func clearedSelectionDismisses() {
        #expect(reason(.selectionChecked(nil)) == .selectionChanged)
    }

    @Test("A selection no longer in view dismisses")
    func offScreenSelectionDismisses() {
        #expect(reason(.selectionChecked(current(baselineY: -1))) == .selectionChanged)
    }

    @Test("Different text under the same cells dismisses")
    func changedTextDismisses() {
        #expect(reason(.selectionChecked(current(text: "something the agent just wrote"))) == .selectionChanged)
    }

    @Test("Moved cells dismiss, at either end")
    func movedOffsetsDismiss() {
        #expect(reason(.selectionChecked(current(offsetStart: 245))) == .selectionChanged)
        #expect(reason(.selectionChecked(current(distanceToBottomRight: 250))) == .selectionChanged)
    }

    @Test("A sidebar change that flips what the label named dismisses, in either direction")
    func sidebarFlipDismisses() {
        #expect(reason(.sidebarChanged(showingReply: true), sidebarShowingReplyAtShow: false) == .sidebar)
        #expect(reason(.sidebarChanged(showingReply: false), sidebarShowingReplyAtShow: true) == .sidebar)
    }

    @Test("A sidebar change that leaves the label true does not (width, focus, Files to Notes)")
    func sidebarNoOpStays() {
        #expect(reason(.sidebarChanged(showingReply: false), sidebarShowingReplyAtShow: false) == nil)
        #expect(reason(.sidebarChanged(showingReply: true), sidebarShowingReplyAtShow: true) == nil)
    }

    @Test("The pane closing dismisses")
    func paneClosedDismisses() {
        #expect(reason(.paneClosed) == .pane)
    }
}
