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

    // cmux-rbf (#cm-73.32)
    @Test func motionButtonPresentationRule() {
        let tooltips = BonsplitConfiguration.SplitButtonTooltips(
            figmaPlayMotion: "Play motion",
            figmaShowStill: "Show still"
        )
        #expect(PairHeaderControls.MotionButtonPresentation.resolve(state: .still, tooltips: tooltips) == .init(
            isVisible: true, symbolName: "play.fill", tooltip: "Play motion", isSelected: false
        ))
        #expect(PairHeaderControls.MotionButtonPresentation.resolve(state: .playing, tooltips: tooltips) == .init(
            isVisible: true, symbolName: "stop.fill", tooltip: "Show still", isSelected: true
        ))
        #expect(PairHeaderControls.MotionButtonPresentation.resolve(state: .hidden, tooltips: tooltips) == .init(
            isVisible: false, symbolName: nil, tooltip: nil, isSelected: false
        ))
    }

    // cmux-rbf (#cm-73.32)
    @Test func hoverRowMotionButtonShowsStillAndPlayingAndHidesOnHidden() throws {
        var stillToggled = 0
        let stillView = PairHeaderControlsView(
            orientation: .horizontal, appearance: .init(), tooltips: .init(),
            barHeight: 28, iconScale: 1, liveOrientation: { .horizontal },
            onChoose: { _ in }, onEqualize: {}, onExit: {},
            figmaPage: .preview, figmaMotionState: .still,
            onToggleFigmaMotion: { stillToggled += 1 }
        )
        let stillHost = NSHostingView(rootView: stillView)
        stillHost.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        stillHost.layoutSubtreeIfNeeded()

        let playingView = PairHeaderControlsView(
            orientation: .horizontal, appearance: .init(), tooltips: .init(),
            barHeight: 28, iconScale: 1, liveOrientation: { .horizontal },
            onChoose: { _ in }, onEqualize: {}, onExit: {},
            figmaPage: .preview, figmaMotionState: .playing
        )
        let playingHost = NSHostingView(rootView: playingView)
        playingHost.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        playingHost.layoutSubtreeIfNeeded()

        let hiddenView = PairHeaderControlsView(
            orientation: .horizontal, appearance: .init(), tooltips: .init(),
            barHeight: 28, iconScale: 1, liveOrientation: { .horizontal },
            onChoose: { _ in }, onEqualize: {}, onExit: {},
            figmaPage: .preview, figmaMotionState: .hidden
        )
        let hiddenHost = NSHostingView(rootView: hiddenView)
        hiddenHost.frame = NSRect(x: 0, y: 0, width: 360, height: 28)
        hiddenHost.layoutSubtreeIfNeeded()

        let stillSegments = descendants(stillHost).compactMap { $0 as? NSSegmentedControl }
        let stillSwitch = try #require(stillSegments.first { $0.toolTip(forSegment: 0) == "Preview" })
        let playingSegments = descendants(playingHost).compactMap { $0 as? NSSegmentedControl }
        let playingSwitch = try #require(playingSegments.first { $0.toolTip(forSegment: 0) == "Preview" })
        let hiddenSegments = descendants(hiddenHost).compactMap { $0 as? NSSegmentedControl }
        let hiddenSwitch = try #require(hiddenSegments.first { $0.toolTip(forSegment: 0) == "Preview" })

        let stillMinX = stillSwitch.convert(stillSwitch.bounds, to: stillHost).minX
        let playingMinX = playingSwitch.convert(playingSwitch.bounds, to: playingHost).minX
        let hiddenMinX = hiddenSwitch.convert(hiddenSwitch.bounds, to: hiddenHost).minX

        // The motion button sits at the left end before the switch, offsetting the switch to the right.
        #expect(stillMinX > hiddenMinX)
        #expect(playingMinX > hiddenMinX)
        #expect(abs(stillMinX - playingMinX) < 0.5)

        let stillMotion = descendants(stillHost).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "paneTabBarControl.figmaMotion" }
        let stillMotionButton = try #require(stillMotion)
        #expect(stillMotionButton.toolTip == "Play motion")
        stillMotionButton.performClick(nil)
        #expect(stillToggled == 1)

        let playingMotion = descendants(playingHost).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "paneTabBarControl.figmaMotion" }
        let playingMotionButton = try #require(playingMotion)
        #expect(playingMotionButton.toolTip == "Show still")

        let hiddenMotion = descendants(hiddenHost).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "paneTabBarControl.figmaMotion" }
        #expect(hiddenMotion == nil)
    }

    // cmux-rbf (#cm-73.32)
    @Test func controllerRoutesToggleFigmaMotionInsidePair() throws {
        let controller = BonsplitController()
        let host = Host()
        controller.delegate = host
        controller.requestToggleFigmaMotion()
        #expect(host.motionToggles == 0)
        let first = try #require(controller.focusedPaneId)
        let second = try #require(controller.splitPane(first, orientation: .horizontal, withTab: .init(title: "Figma")))
        try #require(controller.setPairZoom(firstPane: first, secondPane: second, orientation: .horizontal))
        controller.requestToggleFigmaMotion()
        #expect(host.motionToggles == 1)
        #expect(controller.pairFigmaMotionState() == .still)
    }

    private final class Host: BonsplitDelegate {
        var page: PairFigmaPage? = .preview
        var choices: [PairFigmaPage] = []
        var motion: PairFigmaMotionState = .still
        var motionToggles: Int = 0
        func pairFigmaPage(for controller: BonsplitController) -> PairFigmaPage? { page }
        func splitTabBar(_ controller: BonsplitController, didChooseFigmaPage page: PairFigmaPage) {
            choices.append(page)
            self.page = page
        }
        func pairFigmaMotionState(for controller: BonsplitController) -> PairFigmaMotionState { motion }
        func splitTabBarDidToggleFigmaMotion(_ controller: BonsplitController) {
            motionToggles += 1
        }
    }
}
