import AppKit
import SwiftUI

/// Two exclusive board directions and an independent local pin, with stable geometry in every state.
struct PairBoardSegmentedControl: NSViewRepresentable {
    let state: PairBoardControlState
    let tooltips: BonsplitConfiguration.SplitButtonTooltips
    let symbolPointSize: CGFloat
    let liveState: () -> PairBoardControlState
    let onLayoutBoards: (BoardLayoutOrientation) -> Void
    let onTogglePin: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        makeControl(coordinator: context.coordinator)
    }

    func makeControl(coordinator: Coordinator) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 3
        control.trackingMode = .selectAny
        control.controlSize = .small
        control.segmentStyle = .automatic
        control.target = coordinator
        control.action = #selector(Coordinator.chosen(_:))
        control.setAccessibilityIdentifier("paneTabBarControl.boardLayout")
        for index in 0..<3 { control.setWidth(27, forSegment: index) }
        apply(state, to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        apply(state, to: control)
    }

    private func apply(_ state: PairBoardControlState, to control: NSSegmentedControl) {
        let names = [tooltips.boardColumn, tooltips.boardRow, tooltips.boardPin]
        let images = [BoardLayoutGlyph.image(.vertical, size: symbolPointSize),
                      BoardLayoutGlyph.image(.horizontal, size: symbolPointSize),
                      NSImage(systemSymbolName: state.pin ? "pin.fill" : "pin", accessibilityDescription: tooltips.boardPin)?
                        .withSymbolConfiguration(.init(pointSize: symbolPointSize * 0.85, weight: .regular))]
        for index in 0..<3 {
            let enabled = index == 2 ? state.pinEnabled : state.boardEnabled
            let reason: String
            switch state.unavailableReason {
            case .unmatchedTarget: reason = tooltips.boardUnmatched
            case .busyAgent: reason = tooltips.boardBusy
            case nil: reason = names[index]
            }
            let image = images[index]
            image?.isTemplate = true
            image?.accessibilityDescription = names[index]
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
            control.setEnabled(enabled, forSegment: index)
            control.setToolTip(enabled ? names[index] : reason, forSegment: index)
        }
        control.setSelected(state.litOrientation == .vertical, forSegment: 0)
        control.setSelected(state.litOrientation == .horizontal, forSegment: 1)
        control.setSelected(state.pin, forSegment: 2)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PairBoardSegmentedControl
        init(parent: PairBoardSegmentedControl) { self.parent = parent }

        @objc func chosen(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            // The hover snapshot is presentation only; every action queries the live target.
            let before = parent.liveState()
            if index == 2 {
                if before.pinEnabled { parent.onTogglePin() }
            } else if index == 0 || index == 1 {
                let orientation: BoardLayoutOrientation = index == 0 ? .vertical : .horizontal
                if before.boardEnabled && before.litOrientation != orientation { parent.onLayoutBoards(orientation) }
            }
            parent.apply(parent.liveState(), to: sender)
        }
    }
}
