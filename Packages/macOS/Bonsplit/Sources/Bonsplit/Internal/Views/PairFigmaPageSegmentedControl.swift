// cmux-rbf #cm-73.3
import AppKit
import SwiftUI

/// The native Preview / Editor choice; the host's live side remains authoritative.
struct PairFigmaPageSegmentedControl: NSViewRepresentable {
    let selected: PairFigmaPage?
    let tooltips: BonsplitConfiguration.SplitButtonTooltips
    let symbolPointSize: CGFloat
    let liveSelected: () -> PairFigmaPage?
    let onChoose: (PairFigmaPage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.segmentStyle = .automatic
        control.target = context.coordinator
        control.action = #selector(Coordinator.chosen(_:))
        control.setAccessibilityIdentifier("paneTabBarControl.figmaPage")
        for index in 0..<2 { control.setWidth(27, forSegment: index) }
        apply(selected, to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        apply(selected, to: control)
    }

    private func apply(_ page: PairFigmaPage?, to control: NSSegmentedControl) {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        let segments = [("dot.viewfinder", tooltips.figmaPreview), ("pencil", tooltips.figmaEditor)]
        for (index, segment) in segments.enumerated() {
            let image = NSImage(systemSymbolName: segment.0, accessibilityDescription: segment.1)?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
            control.setToolTip(segment.1, forSegment: index)
        }
        control.isEnabled = page != nil
        control.selectedSegment = page.map { $0 == .preview ? 0 : 1 } ?? -1
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PairFigmaPageSegmentedControl
        init(parent: PairFigmaPageSegmentedControl) { self.parent = parent }

        @objc func chosen(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            if (0..<2).contains(index), let showing = parent.liveSelected() {
                let chosen: PairFigmaPage = index == 0 ? .preview : .editor
                if chosen != showing { parent.onChoose(chosen) }
            }
            parent.apply(parent.liveSelected(), to: sender)
        }
    }
}
