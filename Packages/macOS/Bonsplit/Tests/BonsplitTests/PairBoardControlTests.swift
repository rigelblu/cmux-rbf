import AppKit
import SwiftUI
import Testing
@testable import Bonsplit

@Suite(.serialized) @MainActor
struct PairBoardControlTests {
    private func ready(_ orientation: BoardLayoutOrientation = .vertical, pin: Bool = false) -> PairBoardControlState {
        .init(litOrientation: orientation, pin: pin, boardEnabled: true, pinEnabled: true, unavailableReason: nil)
    }

    @Test func nativeSegmentsRecheckAndSnapBack() {
        var state = ready()
        var jobs: [BoardLayoutOrientation] = []
        var pins = 0
        let parent = PairBoardSegmentedControl(state: state, tooltips: .init(), symbolPointSize: 12,
            liveState: { state }, onLayoutBoards: { orientation in
                jobs.append(orientation)
                state = self.ready(orientation, pin: state.pin)
            }, onTogglePin: { pins += 1; state = self.ready(state.litOrientation!, pin: !state.pin) })
        let coordinator = parent.makeCoordinator()
        let control = parent.makeControl(coordinator: coordinator)
        #expect(control.segmentCount == 3)
        for i in 0..<3 { #expect(control.width(forSegment: i) == 27) }
        #expect(control.isSelected(forSegment: 0))
        control.setSelected(true, forSegment: 1)
        coordinator.chosen(control)
        #expect(jobs == [.horizontal])
        #expect(!control.isSelected(forSegment: 0))
        #expect(control.isSelected(forSegment: 1))
        coordinator.chosen(control)
        #expect(jobs == [.horizontal])
        control.setSelected(true, forSegment: 2)
        coordinator.chosen(control)
        #expect(pins == 1)
        #expect(control.isSelected(forSegment: 2))
        control.setSelected(true, forSegment: 0)
        coordinator.chosen(control)
        #expect(jobs == [.horizontal, .vertical], "pin must not block an explicit board pick")

        state = .init(litOrientation: .vertical, pin: true, boardEnabled: false, pinEnabled: true, unavailableReason: .busyAgent)
        control.setSelected(true, forSegment: 1)
        coordinator.chosen(control)
        #expect(jobs == [.horizontal, .vertical])
        #expect(control.isSelected(forSegment: 0))
        #expect(!control.isSelected(forSegment: 1))
        #expect(!control.isEnabled(forSegment: 0))
        #expect(!control.isEnabled(forSegment: 1))
        #expect(control.isEnabled(forSegment: 2))
        #expect(control.toolTip(forSegment: 0) == BonsplitConfiguration.SplitButtonTooltips().boardBusy)

        state = PairBoardControlState()
        control.setSelected(true, forSegment: 2)
        coordinator.chosen(control)
        #expect(pins == 1)
        for i in 0..<3 {
            #expect(!control.isSelected(forSegment: i))
            #expect(!control.isEnabled(forSegment: i))
            #expect(control.width(forSegment: i) == 27)
            #expect(control.toolTip(forSegment: i) == BonsplitConfiguration.SplitButtonTooltips().boardUnmatched)
        }
    }

    @Test func headerKeepsBoardPositionAcrossStatesAndRoutesActions() throws {
        var frames: [NSRect] = []
        for state in [ready(), ready(.horizontal, pin: true), PairBoardControlState(),
                      .init(litOrientation: .vertical, boardEnabled: false, pinEnabled: true, unavailableReason: .busyAgent)] {
            var live = state
            var jobs: [BoardLayoutOrientation] = []
            var pins = 0
            let view = PairHeaderControlsView(orientation: .horizontal, appearance: .init(), tooltips: .init(),
                barHeight: 28, iconScale: 1, liveOrientation: { .horizontal }, boardState: state,
                liveBoardState: { live }, onLayoutBoards: { jobs.append($0) }, onTogglePin: { pins += 1 },
                onChoose: { _ in }, onEqualize: {}, onExit: {})
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 28)
            host.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }
            let all = descendants(host)
            let segments = all.compactMap { $0 as? NSSegmentedControl }
            let pane = try #require(segments.first { $0.segmentCount == 2 })
            let board = try #require(segments.first { $0.segmentCount == 3 })
            let exit = try #require(all.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "paneTabBarControl.pairExit" })
            let frame = board.convert(board.bounds, to: host)
            frames.append(frame)
            #expect(pane.convert(pane.bounds, to: host).maxX <= frame.minX)
            #expect(frame.maxX < exit.convert(exit.bounds, to: host).minX)
            #expect(frame.width == 81)
            if state.boardEnabled {
                live = ready(.vertical)
                board.setSelected(true, forSegment: 1)
                #expect(board.sendAction(board.action!, to: board.target))
                #expect(jobs == [.horizontal])
                board.setSelected(true, forSegment: 2)
                #expect(board.sendAction(board.action!, to: board.target))
                #expect(pins == 1)
            }
        }
        #expect(frames.allSatisfy { $0 == frames.first! })
    }
}
