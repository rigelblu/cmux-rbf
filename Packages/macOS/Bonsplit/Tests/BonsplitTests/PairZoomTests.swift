// cmux-rbf #cm-73.2a
import AppKit
import Testing
import SwiftUI // cmux-rbf #cm-73.16
@testable import Bonsplit

@Suite
struct PairZoomTests {
    // 1. TabBarVisibility.caption presentation
    @Test
    func captionVisibilityGivesCaptionForPositiveCountsAndEmptyForZero() {
        #expect(TabBarVisibility.caption.presentation(tabCount: 0) == .empty)
        #expect(TabBarVisibility.caption.presentation(tabCount: 1) == .caption)
        #expect(TabBarVisibility.caption.presentation(tabCount: 2) == .caption)
        #expect(TabBarVisibility.caption.presentation(tabCount: 3) == .caption)
        #expect(TabBarVisibility.caption.presentation(tabCount: -1) == .empty)
    }

    // 2. Pair zoom setup and zoomedNode
    @Test
    @MainActor
    func pairZoomProducesSplitNodeWithSpecifiedPanesAndOrientation() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        _ = controller.createTab(title: "T1", inPane: p1)!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        _ = controller.splitPane(p2, orientation: .vertical, withTab: Bonsplit.Tab(title: "T3"))!

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        #expect(controller.isPairZoomed)
        #expect(controller.pairZoomPanes?.first == p1)
        #expect(controller.pairZoomPanes?.second == p2)
        #expect(controller.pairZoomOrientation == .horizontal)

        guard case .split(let splitState) = controller.internalController.zoomedNode else {
            Issue.record("Expected zoomedNode to be .split")
            return
        }
        #expect(splitState.orientation == .horizontal)
        #expect(splitState.first.allPaneIds == [p1])
        #expect(splitState.second.allPaneIds == [p2])
    }

    // 3. Orientation change
    @Test
    @MainActor
    func setPairZoomOrientationUpdatesSplitOrientation() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        controller.setPairZoomOrientation(.vertical)
        #expect(controller.pairZoomOrientation == .vertical)

        guard case .split(let splitState) = controller.internalController.zoomedNode else {
            Issue.record("Expected zoomedNode to be .split")
            return
        }
        #expect(splitState.orientation == .vertical)
    }

    // 4. clearPaneZoom clears pair
    @Test
    @MainActor
    func clearPaneZoomClearsPairZoom() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        #expect(controller.isPairZoomed)
        #expect(controller.clearPaneZoom())
        #expect(!controller.isPairZoomed)
        #expect(controller.internalController.zoomedNode == nil)
    }

    // 5. clearPairZoom explicitly
    @Test
    @MainActor
    func clearPairZoomClearsStateAndFiresCallback() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        var callbackFired = false
        controller.onPairZoomChange = {
            callbackFired = true
        }

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        #expect(controller.clearPairZoom())
        #expect(!controller.isPairZoomed)
        #expect(callbackFired)
    }

    // 6. Tom split clears pair, socket split keeps pair
    @Test
    @MainActor
    func splitTomClearsPairWhileSocketSplitKeepsPair() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        #expect(controller.isPairZoomed)

        // Socket split keeps pair
        let pSocket = controller.splitPane(p2, orientation: .vertical, withTab: Bonsplit.Tab(title: "TSocket"), fromSocket: true)
        #expect(pSocket != nil)
        #expect(controller.isPairZoomed)
        #expect(controller.internalController.zoomedNode != nil)

        // Tom split (default fromSocket: false) clears pair
        let pTom = controller.splitPane(p1, orientation: .vertical, withTab: Bonsplit.Tab(title: "TTom"))
        #expect(pTom != nil)
        #expect(!controller.isPairZoomed)
        #expect(controller.internalController.zoomedNode == nil)
    }

    // 7. Single pane zoom over pair
    @Test
    @MainActor
    func singlePaneZoomOverPairAndReturnToPair() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))

        // Zoom p1 over pair
        #expect(controller.togglePaneZoom(inPane: p1))
        #expect(controller.zoomedPaneId == p1)
        guard case .pane(let zoomedPane) = controller.internalController.zoomedNode else {
            Issue.record("Expected zoomedNode to be .pane")
            return
        }
        #expect(zoomedPane.id == p1)

        // Toggle p1 zoom off -> returns to pair, not the full layout
        #expect(controller.togglePaneZoom(inPane: p1))
        #expect(controller.zoomedPaneId == nil)
        #expect(controller.isPairZoomed)
        guard case .split(let splitState) = controller.internalController.zoomedNode else {
            Issue.record("Expected zoomedNode to return to .split")
            return
        }
        #expect(splitState.first.allPaneIds == [p1])
        #expect(splitState.second.allPaneIds == [p2])
    }

    // 8. Tab added to pair pane through socket is not selected
    @Test
    @MainActor
    func tabAddedThroughSocketToPairPaneIsNotSelected() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let t1 = controller.createTab(title: "T1", inPane: p1)!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))

        let paneState1 = controller.internalController.paneState(for: p1)!
        #expect(paneState1.selectedTabId == t1.id)

        // Add tab via socket to p1
        let tSocket = controller.createTab(title: "TSocket", inPane: p1, fromSocket: true)
        #expect(tSocket != nil)
        // Should NOT have selected tSocket
        #expect(paneState1.selectedTabId == t1.id)

        // Add tab normally (not socket) to p1 -> should be selected
        let tUser = controller.createTab(title: "TUser", inPane: p1, fromSocket: false)
        #expect(tUser != nil)
        #expect(paneState1.selectedTabId == tUser?.id)
    }

    // 9. Spatial navigation moves only between pair panes
    @Test
    @MainActor
    func spatialNavigationConfinedToPairPanes() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let p3 = controller.splitPane(p2, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T3"))!

        // Root layout is 3 panes horizontally: p1, p2, p3.
        // In root layout, adjacent right of p2 is p3.
        #expect(controller.adjacentPane(to: p2, direction: .right) == p3)

        // Set pair zoom with p1 and p2 only
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))

        // In pair zoom, adjacent right of p1 is p2
        #expect(controller.adjacentPane(to: p1, direction: .right) == p2)
        // In pair zoom, adjacent right of p2 is nil (p3 is hidden)
        #expect(controller.adjacentPane(to: p2, direction: .right) == nil)
        // Adjacent left of p2 is p1
        #expect(controller.adjacentPane(to: p2, direction: .left) == p1)
    }

    // 10. Focus line shows on pair pane even with 3 tabs
    @Test
    func focusLineShowsOnPairPaneEvenWithThreeTabs() {
        let background = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let normalChrome = TabBarPaneFocusChrome(
            isEnabled: true,
            presentation: .caption,
            isFocused: true,
            paneCount: 2,
            surfaceCount: 3,
            isWindowKey: true,
            isAnyPaneZoomed: false,
            isPairZoomed: false,
            resolvedBackgroundColor: background
        )
        // In normal mode, surfaceCount: 3 suppresses caption focus line
        #expect(!normalChrome.isVisible)

        // With isPairZoomed: true, focus line IS visible even with surfaceCount: 3
        let pairChrome = TabBarPaneFocusChrome(
            isEnabled: true,
            presentation: .caption,
            isFocused: true,
            paneCount: 2,
            surfaceCount: 3,
            isWindowKey: true,
            isAnyPaneZoomed: false,
            isPairZoomed: true,
            resolvedBackgroundColor: background
        )
        #expect(pairChrome.isVisible)
    }

    // 11. Selected tab caption when multiple tabs present
    @Test
    func captionDrawsSelectedTabRatherThanFirstTab() {
        let t1 = TabItem(id: UUID(), title: "jjui")
        let t2 = TabItem(id: UUID(), title: "Figma")
        let pane = PaneState(tabs: [t1, t2])
        pane.selectTab(t2.id)

        let captionTab = TabBarView.captionTab(in: pane)
        #expect(captionTab?.title == "Figma")
    }

    // 12. Closing one of the pair panes clears pair and fires callback
    @Test
    @MainActor
    func closingPairPaneClearsPairZoom() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        _ = controller.createTab(title: "T1", inPane: p1)!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let t2 = controller.internalController.paneState(for: p2)!.tabs.first!

        var callbackFired = false
        controller.onPairZoomChange = {
            callbackFired = true
        }

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        #expect(controller.isPairZoomed)

        // Close t2 which closes p2
        #expect(controller.closeTab(TabID(id: t2.id)))
        #expect(!controller.isPairZoomed)
        #expect(callbackFired)
    }

    // 13. setPairZoomOrientation fires change callback
    @Test
    @MainActor
    func setPairZoomOrientationFiresChangeCallback() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))

        var callbackCount = 0
        controller.onPairZoomChange = {
            callbackCount += 1
        }

        controller.setPairZoomOrientation(.vertical)
        #expect(callbackCount == 1)
    }

    // 14. Single pane zoom alone preserves adjacentPane navigation across root tree
    @Test
    @MainActor
    func singlePaneZoomAlonePreservesRootSpatialNavigation() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let p3 = controller.splitPane(p2, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T3"))!

        // Zoom p2 alone (single-pane zoom, not pair zoom)
        #expect(controller.togglePaneZoom(inPane: p2))
        #expect(controller.zoomedPaneId == p2)
        #expect(!controller.isPairZoomed)

        // Under single pane zoom, upstream used the root tree for adjacentPane
        #expect(controller.adjacentPane(to: p2, direction: .right) == p3)
        #expect(controller.adjacentPane(to: p2, direction: .left) == p1)
    }

    // 15. Socket split clears single pane zoom when not pair zoomed
    @Test
    @MainActor
    func socketSplitClearsSinglePaneZoomWhenNotPairZoomed() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!

        #expect(controller.togglePaneZoom(inPane: p1))
        #expect(controller.zoomedPaneId == p1)

        // Socket split should clear single-pane zoom
        let p3 = controller.splitPane(p2, orientation: .vertical, withTab: Bonsplit.Tab(title: "T3"), fromSocket: true)
        #expect(p3 != nil)
        #expect(controller.zoomedPaneId == nil)
    }

    // 16. moveTab with select: false, focus: false does not select or focus target pane
    @Test
    @MainActor
    func moveTabWithoutSelectOrFocus() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        _ = controller.createTab(title: "T1", inPane: p1)!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let t2 = controller.tabs(inPane: p2).first!.id

        // Focus p1
        controller.focusPane(p1)
        #expect(controller.focusedPaneId == p1)

        // Create extra tab in p1
        let extra = controller.createTab(title: "Extra", inPane: p1)!

        // Move extra from p1 to p2 with select: false, focus: false
        let moved = controller.moveTab(extra, toPane: p2, select: false, focus: false)
        #expect(moved)

        // p1 should still be focused
        #expect(controller.focusedPaneId == p1)
        // p2 selected tab should still be t2, not extra
        let p2State = controller.internalController.paneState(for: p2)!
        #expect(p2State.selectedTabId == t2.id)
    }

    // 17. Which header carries the hover controls: the one the pointer is over
    // cmux-rbf #cm-73.2a
    @Test
    func carrierPaneIsTheHoveredPaneOfThePair() {
        let a = PaneID()
        let b = PaneID()
        let other = PaneID()
        #expect(PairHeaderControls.carrierPane(hovered: a, first: a, second: b) == a)
        #expect(PairHeaderControls.carrierPane(hovered: b, first: a, second: b) == b)
        #expect(PairHeaderControls.carrierPane(hovered: nil, first: a, second: b) == nil)
        #expect(PairHeaderControls.carrierPane(hovered: other, first: a, second: b) == nil)
    }

    // cmux-rbf #cm-73.2a
    @Test
    @MainActor
    func controllerCarrierIsTheHoveredHeaderInBothOrientations() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let internal_ = controller.internalController

        #expect(internal_.pairHeaderControlsCarrier == nil)

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        // Nothing hovered: no carrier.
        #expect(internal_.pairHeaderControlsCarrier == nil)

        for orientation in [SplitOrientation.horizontal, SplitOrientation.vertical] {
            controller.setPairZoomOrientation(orientation)

            internal_.setPairHeaderHover(true, pane: p1)
            #expect(internal_.pairHeaderControlsCarrier == p1)
            #expect(internal_.showsPairHeaderControls(on: p1))
            #expect(!internal_.showsPairHeaderControls(on: p2))
            internal_.setPairHeaderHover(false, pane: p1)
            #expect(internal_.pairHeaderControlsCarrier == nil)

            internal_.setPairHeaderHover(true, pane: p2)
            #expect(internal_.pairHeaderControlsCarrier == p2)
            #expect(internal_.showsPairHeaderControls(on: p2))
            #expect(!internal_.showsPairHeaderControls(on: p1))
            internal_.setPairHeaderHover(false, pane: p2)
            #expect(internal_.pairHeaderControlsCarrier == nil)
        }

        #expect(controller.clearPairZoom())
        #expect(internal_.pairHeaderControlsCarrier == nil)
    }

    // cmux-rbf #cm-73.2a
    // 17b. The 50/50 glyph: side by side uses distribute.vertical.center, stacked uses distribute.horizontal.center.
    @Test
    func equalizeSymbolIsSwappedFromTheSymbolNames() {
        #expect(PairHeaderControls.equalizeSymbolName(for: .horizontal) == "distribute.vertical.center")
        #expect(PairHeaderControls.equalizeSymbolName(for: .vertical) == "distribute.horizontal.center")
    }

    // 18. Visibility: hidden at rest, shown on the hovered header, cleared when the pair ends
    // cmux-rbf #cm-73.2a
    @Test
    @MainActor
    func controlsShowOnlyOnTheHoveredPairHeader() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let internal_ = controller.internalController

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        // At rest: bare.
        #expect(!internal_.showsPairHeaderControls(on: p2))
        #expect(!internal_.showsPairHeaderControls(on: p1))

        // Pointer over the first header: they show there, not on the second.
        internal_.setPairHeaderHover(true, pane: p1)
        #expect(internal_.showsPairHeaderControls(on: p1))
        #expect(!internal_.showsPairHeaderControls(on: p2))

        // Moving from one header to the other: the exit and the entry can arrive in either order.
        internal_.setPairHeaderHover(true, pane: p2)
        internal_.setPairHeaderHover(false, pane: p1)
        #expect(internal_.showsPairHeaderControls(on: p2))
        #expect(!internal_.showsPairHeaderControls(on: p1))
        internal_.setPairHeaderHover(false, pane: p2)
        #expect(!internal_.showsPairHeaderControls(on: p2))

        internal_.setPairHeaderHover(true, pane: p1)
        internal_.setPairHeaderHover(false, pane: p1)
        internal_.setPairHeaderHover(true, pane: p2)
        #expect(internal_.showsPairHeaderControls(on: p2))
        #expect(!internal_.showsPairHeaderControls(on: p1))
    }

    // cmux-rbf #cm-73.2a
    // O1: the newest hovered header wins while the older one's exit has not arrived yet.
    @Test
    @MainActor
    func newestHoveredPairHeaderWinsBeforeTheOlderExitArrives() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let internal_ = controller.internalController

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))

        // Hover p1, then p2 with no exit for p1 yet: both are in the set, the controls follow p2.
        internal_.setPairHeaderHover(true, pane: p1)
        internal_.setPairHeaderHover(true, pane: p2)
        #expect(internal_.hoveredPairHeaderPanes == [p1, p2])
        #expect(internal_.pairHeaderControlsCarrier == p2)
        #expect(internal_.showsPairHeaderControls(on: p2))
        #expect(!internal_.showsPairHeaderControls(on: p1))

        // p1's exit arrives late: still p2.
        internal_.setPairHeaderHover(false, pane: p1)
        #expect(internal_.pairHeaderControlsCarrier == p2)
        #expect(internal_.showsPairHeaderControls(on: p2))
        #expect(!internal_.showsPairHeaderControls(on: p1))
    }

    @Test
    @MainActor
    func hoverIsClearedWhenPairZoomEnds() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let internal_ = controller.internalController

        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        internal_.setPairHeaderHover(true, pane: p1)
        #expect(internal_.hoveredPairHeaderPanes == [p1])
        #expect(controller.clearPairZoom())
        #expect(internal_.hoveredPairHeaderPanes.isEmpty)
        #expect(!internal_.showsPairHeaderControls(on: p2))

        // Entering the mode again starts bare, and a hover report outside the mode is ignored.
        internal_.setPairHeaderHover(true, pane: p1)
        #expect(internal_.hoveredPairHeaderPanes.isEmpty)
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        #expect(!internal_.showsPairHeaderControls(on: p2))

        // clearPaneZoom ends the pair too.
        internal_.setPairHeaderHover(true, pane: p2)
        #expect(internal_.hoveredPairHeaderPanes == [p2])
        #expect(controller.clearPaneZoom())
        #expect(internal_.hoveredPairHeaderPanes.isEmpty)
    }

    // cmux-rbf #cm-73.2a
    // R1: a single pane zoomed on top of the pair hides the pair, so the pair controls have no carrier.
    @Test
    @MainActor
    func noCarrierWhileASinglePaneIsZoomedInsideThePair() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let internal_ = controller.internalController
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        internal_.setPairHeaderHover(true, pane: p2) // cmux-rbf #cm-73.2a
        #expect(internal_.pairHeaderControlsCarrier == p2)

        // Zoom the carrier itself: its header must not show the controls even while hovered.
        #expect(controller.togglePaneZoom(inPane: p2))
        #expect(controller.isPairZoomed)
        #expect(internal_.pairHeaderControlsCarrier == nil)
        internal_.setPairHeaderHover(true, pane: p2)
        #expect(!internal_.showsPairHeaderControls(on: p2))
        #expect(!internal_.showsPairHeaderControls(on: p1))

        // Same for the other pane.
        #expect(controller.togglePaneZoom(inPane: p2))
        #expect(controller.togglePaneZoom(inPane: p1))
        #expect(internal_.pairHeaderControlsCarrier == nil)

        // Ending the single-pane zoom brings the controls back; the pointer is still on a header.
        #expect(controller.togglePaneZoom(inPane: p1))
        #expect(controller.zoomedPaneId == nil)
        #expect(internal_.pairHeaderControlsCarrier == p2)
        #expect(internal_.showsPairHeaderControls(on: p2))
    }

    // cmux-rbf #cm-73.2a
    // O6: a pair pane leaving the tree clears the hover set (the pair ends through the tree normalization).
    @Test
    @MainActor
    func hoverIsClearedWhenAPairPaneLeavesTheTree() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let internal_ = controller.internalController
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        internal_.setPairHeaderHover(true, pane: p1)
        #expect(internal_.hoveredPairHeaderPanes == [p1])

        #expect(controller.closePane(p2))
        #expect(!controller.isPairZoomed)
        #expect(internal_.hoveredPairHeaderPanes.isEmpty)
    }

    // cmux-rbf #cm-73.2a
    // O6: setPairZoom with different panes starts a new pair, so a hover on the old pair does not carry over.
    @Test
    @MainActor
    func hoverIsClearedWhenTheNextPairHasDifferentPanes() {
        let controller = BonsplitController()
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        let p3 = controller.splitPane(p2, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T3"))!
        let internal_ = controller.internalController
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        internal_.setPairHeaderHover(true, pane: p1)
        #expect(internal_.hoveredPairHeaderPanes == [p1])

        // Re-pairing the same panes keeps the hover (the pointer has not moved).
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .vertical))
        #expect(internal_.hoveredPairHeaderPanes == [p1])

        // A different second pane: the old pair's hover is dropped.
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p3, orientation: .horizontal))
        #expect(controller.isPairZoomed)
        #expect(internal_.hoveredPairHeaderPanes.isEmpty)
    }

    // cmux-rbf #cm-73.16
    @Test @MainActor func exitRequestReachesHostOnlyInPairMode() {
        let controller = BonsplitController()
        let spy = PairArrangementDelegateSpy()
        controller.delegate = spy
        controller.requestPairExit()
        #expect(spy.exitCount == 0)
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        controller.requestPairExit()
        #expect(spy.exitCount == 1)
    }

    // cmux-rbf #cm-73.16: inspect native controls mounted by the mode header.
    @Test @MainActor func hoveredHeaderHasExitControl() throws {
        let controller = BonsplitController()
        let spy = PairArrangementDelegateSpy()
        controller.delegate = spy
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))
        let view = PairHeaderControlsView(
            orientation: .horizontal,
            appearance: BonsplitConfiguration.Appearance(),
            tooltips: BonsplitConfiguration.SplitButtonTooltips(),
            barHeight: 28, iconScale: 1,
            liveOrientation: { .horizontal }, onChoose: { _ in }, onEqualize: {},
            onExit: { controller.requestPairExit() }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 28)
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap { descendants($0) }
        }
        let controls = descendants(host)
        #expect(controls.contains { $0 is NSSegmentedControl }, "harness must find existing native arrangement control")
        let exit = try #require(controls.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "paneTabBarControl.pairExit" }, "hovered mode header has no exit control")
        #expect(exit.toolTip == "Exit Design Focus")
        #expect(exit.image != nil)
        exit.performClick(nil)
        #expect(spy.exitCount == 1)
    }

    // cmux-rbf #cm-73.16: configured dark chrome must override light system colours for every glyph.
    @Test @MainActor func exitTintMatchesEqualizeOnDarkChromeInLightAppearance() throws {
        let appearance = BonsplitConfiguration.Appearance(chromeColors: .init(backgroundHex: "#272822"))
        let light = try #require(NSAppearance(named: .aqua))
        var actual: NSColor?
        var expected: NSColor?
        light.performAsCurrentDrawingAppearance {
            let view = PairHeaderControlsView(
                orientation: .horizontal, appearance: appearance,
                tooltips: .init(), barHeight: 28, iconScale: 1,
                liveOrientation: { .horizontal }, onChoose: { _ in }, onEqualize: {}, onExit: {}
            )
            let host = NSHostingView(rootView: view)
            host.appearance = light
            host.frame = NSRect(x: 0, y: 0, width: 180, height: 28)
            host.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews + view.subviews.flatMap { descendants($0) }
            }
            let button = descendants(host).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "paneTabBarControl.pairExit" }
            actual = button?.contentTintColor?.usingColorSpace(.sRGB)
            expected = TabBarColors.nsColorSplitActionIcon(for: appearance, isPressed: false).usingColorSpace(.sRGB)
        }
        let tint = try #require(actual)
        let equalize = try #require(expected)
        let actualComponents = [tint.redComponent, tint.greenComponent, tint.blueComponent, tint.alphaComponent]
        let expectedComponents = [equalize.redComponent, equalize.greenComponent, equalize.blueComponent, equalize.alphaComponent]
        #expect(zip(actualComponents, expectedComponents).allSatisfy { abs($0 - $1) < 0.001 }, "exit \(actualComponents) differs from 50/50 \(expectedComponents)")
    }

    // 19. Choosing a segment
    @Test
    @MainActor
    func choosingTheOtherArrangementCallsTheHostOnceAndTheSelectedOneDoesNot() {
        let controller = BonsplitController()
        let spy = PairArrangementDelegateSpy()
        controller.delegate = spy
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))

        controller.requestPairArrangement(.horizontal)
        #expect(spy.chosenArrangements.isEmpty)

        controller.requestPairArrangement(.vertical)
        #expect(spy.chosenArrangements == [.vertical])
        // The host owns the change; Bonsplit itself did not flip the pair.
        #expect(controller.pairZoomOrientation == .horizontal)

        controller.setPairZoomOrientation(.vertical)
        controller.requestPairArrangement(.vertical)
        #expect(spy.chosenArrangements == [.vertical])
        controller.requestPairArrangement(.horizontal)
        #expect(spy.chosenArrangements == [.vertical, .horizontal])
    }

    @Test
    @MainActor
    func arrangementAndEqualizeRequestsDoNothingOutsidePairZoom() {
        let controller = BonsplitController()
        let spy = PairArrangementDelegateSpy()
        controller.delegate = spy
        let p1 = controller.focusedPaneId!
        _ = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))

        controller.requestPairArrangement(.vertical)
        controller.requestPairEqualize()
        #expect(spy.chosenArrangements.isEmpty)
        #expect(spy.equalizeCount == 0)
    }

    @Test
    @MainActor
    func equalizeButtonCallsTheHostOncePerPress() {
        let controller = BonsplitController()
        let spy = PairArrangementDelegateSpy()
        controller.delegate = spy
        let p1 = controller.focusedPaneId!
        let p2 = controller.splitPane(p1, orientation: .horizontal, withTab: Bonsplit.Tab(title: "T2"))!
        #expect(controller.setPairZoom(firstPane: p1, secondPane: p2, orientation: .horizontal))

        controller.requestPairEqualize()
        #expect(spy.equalizeCount == 1)
        controller.requestPairEqualize()
        #expect(spy.equalizeCount == 2)
    }
}

@MainActor
private final class PairArrangementDelegateSpy: BonsplitDelegate {
    var chosenArrangements: [SplitOrientation] = []
    var equalizeCount = 0
    var exitCount = 0
    func splitTabBarDidRequestExitPair(_ controller: BonsplitController) { exitCount += 1 } // cmux-rbf #cm-73.16

    func splitTabBar(_ controller: BonsplitController, didChoosePairArrangement orientation: SplitOrientation) {
        chosenArrangements.append(orientation)
    }

    func splitTabBarDidRequestEqualizePair(_ controller: BonsplitController) {
        equalizeCount += 1
    }
}
