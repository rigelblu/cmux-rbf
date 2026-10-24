// cmux-rbf #cm-73.2a
import AppKit
import SwiftUI

/// cmux-rbf #cm-73.16: arrangement, equalize and exit controls on the hovered pair header.
enum PairHeaderControls {
    /// cmux-rbf #cm-73.16: the last glyph's center sits this far from the pane's right edge.
    static let glyphCenterFromTrailing: CGFloat = 17.5
    /// The segmented control's right edge sits this far left of the 50/50 glyph's center.
    static let segmentedTrailingGapFromGlyphCenter: CGFloat = 13.5
    /// The width of the 50/50 button's hit area (the same as a header glyph button's reserved width).
    static let glyphButtonWidth: CGFloat = TabBarStyling.splitActionButtonReservedWidth
    /// The AppKit small segmented control, two segments: 54 x 20 pt in Light.
    static let segmentedSize = CGSize(width: 54, height: 20)

    /// cmux-rbf #cm-73.16: space between the pane's right edge and the last button's hit area, centering it on
    /// `glyphCenterFromTrailing`.
    static var buttonTrailingPadding: CGFloat {
        glyphCenterFromTrailing - glyphButtonWidth / 2
    }

    /// Space between the segmented control and the 50/50 button's hit area.
    static var segmentedSpacing: CGFloat {
        segmentedTrailingGapFromGlyphCenter - glyphButtonWidth / 2
    }

    /// The header that carries the controls: the pair header the pointer is over, or `nil` when it is over neither.
    static func carrierPane(hovered: PaneID?, first: PaneID, second: PaneID) -> PaneID? { // cmux-rbf #cm-73.2a
        guard let hovered, hovered == first || hovered == second else { return nil }
        return hovered
    }

    /// The 50/50 glyph: side by side uses `distribute.vertical.center`, stacked uses `distribute.horizontal.center`.
    /// This is the reverse of the symbols' names, which is how Tom reads them.
    static func equalizeSymbolName(for orientation: SplitOrientation) -> String {
        switch orientation {
        case .horizontal:
            return "distribute.vertical.center" // cmux-rbf #cm-73.2a
        case .vertical:
            return "distribute.horizontal.center" // cmux-rbf #cm-73.2a
        }
    }

    static func segmentIndex(for orientation: SplitOrientation) -> Int {
        switch orientation {
        case .horizontal:
            return 0
        case .vertical:
            return 1
        }
    }

    static func orientation(forSegment index: Int) -> SplitOrientation {
        index == 0 ? .horizontal : .vertical
    }

    // cmux-rbf (#cm-73.32): hover row motion button presentation derived from state and tooltips.
    struct MotionButtonPresentation: Equatable {
        let isVisible: Bool
        let symbolName: String?
        let tooltip: String?
        let isSelected: Bool

        static func resolve(
            state: PairFigmaMotionState,
            tooltips: BonsplitConfiguration.SplitButtonTooltips
        ) -> MotionButtonPresentation {
            switch state {
            case .hidden:
                return MotionButtonPresentation(
                    isVisible: false,
                    symbolName: nil,
                    tooltip: nil,
                    isSelected: false
                )
            case .still:
                return MotionButtonPresentation(
                    isVisible: true,
                    symbolName: "play.fill",
                    tooltip: tooltips.figmaPlayMotion,
                    isSelected: false
                )
            case .playing:
                return MotionButtonPresentation(
                    isVisible: true,
                    symbolName: "stop.fill",
                    tooltip: tooltips.figmaShowStill,
                    isSelected: true
                )
            }
        }
    }
}

/// cmux-rbf #cm-73.16: arrangement, 50/50 and exit, drawn at the right of the hovered header.
struct PairHeaderControlsView: View {
    let orientation: SplitOrientation
    let appearance: BonsplitConfiguration.Appearance
    let tooltips: BonsplitConfiguration.SplitButtonTooltips
    let barHeight: CGFloat
    let iconScale: CGFloat
    let liveOrientation: () -> SplitOrientation?
    let boardState: PairBoardControlState
    let liveBoardState: () -> PairBoardControlState
    let onLayoutBoards: (BoardLayoutOrientation) -> Void
    let onTogglePin: () -> Void
    let onChoose: (SplitOrientation) -> Void
    let onEqualize: () -> Void
    let onExit: () -> Void // cmux-rbf #cm-73.16
    // cmux-rbf #cm-73.3
    let figmaPage: PairFigmaPage?
    let liveFigmaPage: () -> PairFigmaPage?
    let onChooseFigmaPage: (PairFigmaPage) -> Void
    // cmux-rbf (#cm-73.32)
    let figmaMotionState: PairFigmaMotionState
    let onToggleFigmaMotion: () -> Void

    init(orientation: SplitOrientation, appearance: BonsplitConfiguration.Appearance,
         tooltips: BonsplitConfiguration.SplitButtonTooltips, barHeight: CGFloat, iconScale: CGFloat,
         liveOrientation: @escaping () -> SplitOrientation?,
         boardState: PairBoardControlState = PairBoardControlState(),
         liveBoardState: @escaping () -> PairBoardControlState = { PairBoardControlState() },
         onLayoutBoards: @escaping (BoardLayoutOrientation) -> Void = { _ in },
         onTogglePin: @escaping () -> Void = {},
         onChoose: @escaping (SplitOrientation) -> Void,
         onEqualize: @escaping () -> Void, onExit: @escaping () -> Void,
         figmaPage: PairFigmaPage? = nil, // cmux-rbf #cm-73.3
         liveFigmaPage: @escaping () -> PairFigmaPage? = { nil },
         onChooseFigmaPage: @escaping (PairFigmaPage) -> Void = { _ in },
         figmaMotionState: PairFigmaMotionState = .hidden, // cmux-rbf (#cm-73.32)
         onToggleFigmaMotion: @escaping () -> Void = {}) {
        self.orientation = orientation
        self.appearance = appearance
        self.tooltips = tooltips
        self.barHeight = barHeight
        self.iconScale = iconScale
        self.liveOrientation = liveOrientation
        self.boardState = boardState
        self.liveBoardState = liveBoardState
        self.onLayoutBoards = onLayoutBoards
        self.onTogglePin = onTogglePin
        self.onChoose = onChoose
        self.onEqualize = onEqualize
        self.onExit = onExit
        self.figmaPage = figmaPage
        self.liveFigmaPage = liveFigmaPage
        self.onChooseFigmaPage = onChooseFigmaPage
        self.figmaMotionState = figmaMotionState
        self.onToggleFigmaMotion = onToggleFigmaMotion
    }

    var body: some View {
        HStack(spacing: PairHeaderControls.segmentedSpacing) {
            // cmux-rbf (#cm-73.32): motion toggle button sits at left end before switch, shown only for marked preview.
            let motion = PairHeaderControls.MotionButtonPresentation.resolve(state: figmaMotionState, tooltips: tooltips)
            if motion.isVisible, let symbolName = motion.symbolName, let tooltip = motion.tooltip {
                PairHeaderMotionButton(
                    symbolName: symbolName,
                    tooltip: tooltip,
                    isSelected: motion.isSelected,
                    appearance: appearance,
                    iconScale: iconScale,
                    onToggle: onToggleFigmaMotion
                )
                .frame(width: PairHeaderControls.glyphButtonWidth, height: barHeight)
            }

            // cmux-rbf #cm-73.3: only this Design Focus hover row gets the clickable switch.
            PairFigmaPageSegmentedControl(
                selected: figmaPage, tooltips: tooltips, symbolPointSize: 12 * iconScale,
                liveSelected: liveFigmaPage, onChoose: onChooseFigmaPage
            )
            .frame(width: PairHeaderControls.segmentedSize.width, height: PairHeaderControls.segmentedSize.height)

            PairArrangementSegmentedControl(
                selected: orientation,
                sideBySideTooltip: tooltips.pairSideBySide,
                stackedTooltip: tooltips.pairStacked,
                symbolPointSize: 12 * iconScale,
                liveSelected: liveOrientation,
                onChoose: onChoose
            )
            .frame(
                width: PairHeaderControls.segmentedSize.width,
                height: PairHeaderControls.segmentedSize.height
            )

            PairBoardSegmentedControl(
                state: boardState, tooltips: tooltips, symbolPointSize: 12 * iconScale,
                liveState: liveBoardState, onLayoutBoards: onLayoutBoards, onTogglePin: onTogglePin
            )
            .frame(width: 81, height: PairHeaderControls.segmentedSize.height)

            Button(action: onEqualize) {
                Image(systemName: PairHeaderControls.equalizeSymbolName(for: orientation))
                    .font(.system(size: 12 * iconScale))
                    .frame(width: PairHeaderControls.glyphButtonWidth, height: barHeight)
                    .contentShape(Rectangle())
                    .accessibilityLabel(tooltips.pairEqualize)
            }
            .buttonStyle(PairEqualizeButtonStyle(appearance: appearance))
            .safeHelp(tooltips.pairEqualize)
            .accessibilityIdentifier("paneTabBarControl.pairEqualize")

            // cmux-rbf #cm-73.16: native control permits the same runtime press test as the segmented control.
            PairHeaderExitButton(tooltip: tooltips.pairExit, appearance: appearance, iconScale: iconScale, onExit: onExit)
                .frame(width: PairHeaderControls.glyphButtonWidth, height: barHeight)
        }
        .padding(.trailing, PairHeaderControls.buttonTrailingPadding)
        .frame(height: barHeight)
        .tabBarButtonAnimationsDisabled()
    }
}

private struct PairEqualizeButtonStyle: ButtonStyle {
    let appearance: BonsplitConfiguration.Appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(TabBarColors.splitActionIcon(for: appearance, isPressed: configuration.isPressed))
            .opacity(configuration.isPressed ? 0.72 : 1.0)
    }
}

/// An AppKit small segmented control: side by side and stacked, the showing arrangement selected.
private struct PairArrangementSegmentedControl: NSViewRepresentable {
    let selected: SplitOrientation
    let sideBySideTooltip: String
    let stackedTooltip: String
    let symbolPointSize: CGFloat
    /// The arrangement the host shows right now, read after a click so a refused choice snaps back.
    let liveSelected: () -> SplitOrientation?
    let onChoose: (SplitOrientation) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = 2
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.segmentStyle = .automatic
        control.target = context.coordinator
        control.action = #selector(Coordinator.segmentChosen(_:))
        control.setWidth(PairHeaderControls.segmentedSize.width / 2, forSegment: 0)
        control.setWidth(PairHeaderControls.segmentedSize.width / 2, forSegment: 1)
        apply(to: control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        apply(to: control)
    }

    private func apply(to control: NSSegmentedControl) {
        let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
        let segments: [(symbol: String, tooltip: String)] = [
            ("rectangle.split.2x1", sideBySideTooltip),
            ("rectangle.split.1x2", stackedTooltip)
        ]
        for (index, segment) in segments.enumerated() {
            let image = NSImage(systemSymbolName: segment.symbol, accessibilityDescription: segment.tooltip)?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = true
            control.setImage(image, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
            control.setToolTip(segment.tooltip, forSegment: index)
        }
        control.selectedSegment = PairHeaderControls.segmentIndex(for: selected)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PairArrangementSegmentedControl

        init(parent: PairArrangementSegmentedControl) {
            self.parent = parent
        }

        @objc func segmentChosen(_ sender: NSSegmentedControl) {
            let chosen = PairHeaderControls.orientation(forSegment: sender.selectedSegment)
            parent.onChoose(chosen)
            // The host decides. If it kept the arrangement, put the selection back on what it shows.
            let showing = parent.liveSelected() ?? parent.selected
            sender.selectedSegment = PairHeaderControls.segmentIndex(for: showing)
        }
    }
}
