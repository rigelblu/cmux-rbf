import AppKit
import SwiftUI
import Testing
@testable import Bonsplit

@MainActor
@Suite(.serialized)
struct PairFigmaPageControlTests {
    @Test func hoverRowStartsWithNativePreviewEditorSwitch() throws {
        let view = PairHeaderControlsView(
            orientation: .horizontal, appearance: .init(), tooltips: .init(),
            barHeight: 28, iconScale: 1, liveOrientation: { .horizontal },
            onChoose: { _ in }, onEqualize: {}, onExit: {}
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        host.layoutSubtreeIfNeeded()
        let segments = descendants(host).compactMap { $0 as? NSSegmentedControl }
        let arrangement = try #require(segments.first { $0.toolTip(forSegment: 0) == "Side by Side" })
        let page = try #require(segments.first { $0.toolTip(forSegment: 0) == "Preview" }, "hover row has no Preview / Editor switch")
        #expect(page.toolTip(forSegment: 1) == "Editor")
        #expect(page.segmentCount == 2)
        #expect(page.controlSize == arrangement.controlSize)
        #expect(page.bounds.height == arrangement.bounds.height)
        #expect(page.trackingMode == .selectOne)
        #expect(page.width(forSegment: 0) == 27)
        #expect(page.width(forSegment: 1) == 27)
        #expect(page.convert(page.bounds, to: host).width == 54)
        #expect(page.convert(page.bounds, to: host).maxX <= arrangement.convert(arrangement.bounds, to: host).minX)
        for index in 0..<2 { #expect(page.image(forSegment: index) != nil) }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants($0) }
    }

    @Test func clicksRecheckLiveSideAndSnapBackAfterRefusal() throws {
        var live: PairFigmaPage? = .preview
        var choices: [PairFigmaPage] = []
        var accept = true
        let view = PairHeaderControlsView(
            orientation: .horizontal, appearance: .init(), tooltips: .init(),
            barHeight: 28, iconScale: 1, liveOrientation: { .horizontal },
            onChoose: { _ in }, onEqualize: {}, onExit: {},
            figmaPage: .preview, liveFigmaPage: { live },
            onChooseFigmaPage: { page in
                choices.append(page)
                if accept { live = page }
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        host.layoutSubtreeIfNeeded()
        let control = try #require(descendants(host).compactMap { $0 as? NSSegmentedControl }
            .first { $0.toolTip(forSegment: 0) == "Preview" })
        #expect(control.selectedSegment == 0)
        try press(control, index: 0)
        #expect(choices.isEmpty)
        try press(control, index: 1)
        #expect(choices == [.editor])
        #expect(control.selectedSegment == 1)
        try press(control, index: 0)
        #expect(choices == [.editor, .preview])
        #expect(control.selectedSegment == 0)
        // A key switched the pane after this header's snapshot was taken.
        live = .editor
        try press(control, index: 1)
        #expect(choices == [.editor, .preview])
        #expect(control.selectedSegment == 1)
        accept = false
        try press(control, index: 0)
        #expect(choices == [.editor, .preview, .preview])
        #expect(control.selectedSegment == 1, "a refused choice must show the host's actual side")
        live = nil
        try press(control, index: 0)
        #expect(choices.count == 3)
        #expect(!control.isEnabled)
    }

    @Test func controllerRoutesOnlyChangedChoicesInsideThePair() throws {
        let controller = BonsplitController()
        let host = Host()
        controller.delegate = host
        controller.requestFigmaPage(.editor)
        #expect(host.choices.isEmpty)
        let first = try #require(controller.focusedPaneId)
        let second = try #require(controller.splitPane(first, orientation: .horizontal, withTab: .init(title: "Figma")))
        try #require(controller.setPairZoom(firstPane: first, secondPane: second, orientation: .horizontal))
        controller.requestFigmaPage(.preview)
        #expect(host.choices.isEmpty)
        controller.requestFigmaPage(.editor)
        #expect(host.choices == [.editor])
        #expect(controller.pairFigmaPage() == .editor)
        controller.requestFigmaPage(.editor)
        #expect(host.choices == [.editor])
        controller.requestFigmaPage(.preview)
        #expect(host.choices == [.editor, .preview])
        host.page = nil
        controller.requestFigmaPage(.editor)
        #expect(host.choices.count == 2)
    }

    private func press(_ control: NSSegmentedControl, index: Int) throws {
        control.selectedSegment = index
        let action = try #require(control.action)
        #expect(control.sendAction(action, to: control.target))
    }

    @Test func hostRefreshPublishesTheShowingSideWithoutAnotherHover() {
        let controller = BonsplitController()
        let host = Host()
        controller.delegate = host
        controller.refreshPairFigmaPage()
        #expect(controller.internalController.pairFigmaPage == .preview)
        host.page = .editor
        controller.refreshPairFigmaPage()
        #expect(controller.internalController.pairFigmaPage == .editor)
        host.page = nil
        controller.refreshPairFigmaPage()
        #expect(controller.internalController.pairFigmaPage == nil)
    }

    @Test func realPairHeadersForwardTheNativeChoice() throws {
        let controller = BonsplitController()
        controller.tabShortcutHintsEnabled = false
        let delegate = Host()
        controller.delegate = delegate
        let first = try #require(controller.focusedPaneId)
        let second = try #require(controller.splitPane(first, orientation: .horizontal, withTab: .init(title: "Figma")))
        try #require(controller.setPairZoom(firstPane: first, secondPane: second, orientation: .horizontal))

        for paneID in [first, second] {
            delegate.page = .preview
            let pane = try #require(controller.internalController.paneState(for: paneID))
            let host = NSHostingView(rootView: TabBarView(
                pane: pane, isFocused: paneID == first, showSplitButtons: false, presentation: .caption
            ).environment(controller).environment(controller.internalController))
            host.frame = NSRect(x: 0, y: 0, width: 635, height: 28)
            host.layoutSubtreeIfNeeded()
            let background = try #require(descendants(host).compactMap {
                $0 as? TabBarDragAndHoverView.TabBarBackgroundNSView
            }.first)
            let event = try #require(NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil
            ))
            background.mouseEntered(with: event)
            host.layoutSubtreeIfNeeded()
            #expect(controller.internalController.showsPairHeaderControls(on: paneID))
            let control = try #require(descendants(host).compactMap { $0 as? NSSegmentedControl }
                .first { $0.accessibilityIdentifier() == "paneTabBarControl.figmaPage" })
            #expect(control.isEnabled)
            #expect(control.selectedSegment == 0)
            let before = delegate.choices.count
            try press(control, index: 1)
            #expect(delegate.choices.count == before + 1)
            #expect(delegate.choices.last == .editor)
            #expect(control.selectedSegment == 1)
            background.mouseExited(with: event)
        }
    }

    // cmux-rbf (#cm-73.37): inspect the rendered native row, not a presentation copy.
    @Test func hoverRowHasNoMotionButton() throws {
        let view = PairHeaderControlsView(
            orientation: .horizontal, appearance: .init(), tooltips: .init(),
            barHeight: 28, iconScale: 1, liveOrientation: { .horizontal },
            onChoose: { _ in }, onEqualize: {}, onExit: {}, figmaPage: .preview
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        host.layoutSubtreeIfNeeded()
        let controls = descendants(host)
        #expect(controls.compactMap { $0 as? NSSegmentedControl }.contains { $0.accessibilityIdentifier() == "paneTabBarControl.figmaPage" })
        #expect(!controls.compactMap { $0 as? NSButton }.contains { $0.identifier?.rawValue == "paneTabBarControl.figmaMotion" }, "hover row must have no motion button")
    }

    private final class Host: BonsplitDelegate {
        var page: PairFigmaPage? = .preview
        var choices: [PairFigmaPage] = []
        func pairFigmaPage(for controller: BonsplitController) -> PairFigmaPage? { page }
        func splitTabBar(_ controller: BonsplitController, didChooseFigmaPage page: PairFigmaPage) {
            choices.append(page)
            self.page = page
        }
    }
}
