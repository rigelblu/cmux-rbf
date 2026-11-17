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
        destinationAtShow: ReplyInlineDestination = .prompt
    ) -> ReplyInlineDismissReason? {
        ReplyInlineDismissal.reason(
            for: event, passage: Self.passage, destinationAtShow: destinationAtShow
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

    /// `cm-136.7`: the button's destination is what the toolbar was read for,
    /// so a flip in either direction takes it away. Replaces the sidebar-only
    /// check, which had the same two directions.
    @Test("A destination change that flips what the label named dismisses, in either direction")
    func destinationChangeDismisses() {
        #expect(reason(.destinationChanged(.replyPanel), destinationAtShow: .prompt) == .destination)
        #expect(reason(.destinationChanged(.prompt), destinationAtShow: .replyPanel) == .destination)
    }

    @Test("A destination that is still what it was at show leaves it (width, focus, Files to Notes)")
    func sameDestinationKeepsToolbar() {
        #expect(reason(.destinationChanged(.prompt), destinationAtShow: .prompt) == nil)
        #expect(reason(.destinationChanged(.replyPanel), destinationAtShow: .replyPanel) == nil)
    }

    @Test("The pane closing dismisses")
    func paneClosedDismisses() {
        #expect(reason(.paneClosed) == .pane)
    }

    @Test("The setting turned off takes a showing toolbar away")
    func settingOffDismisses() {
        #expect(reason(.settingChanged(enabled: false)) == .setting)
    }

    @Test("The setting still on, or turned back on, leaves it")
    func settingOnStays() {
        #expect(reason(.settingChanged(enabled: true)) == nil)
    }
}
