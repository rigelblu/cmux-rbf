import CmuxAppKitSupportUI // (#cm-109.7)
import CmuxWorkspaces
import Foundation
import SwiftUI

// MARK: - Status display names

extension WorkspaceTaskStatus {
    /// The localized lane name shown in menus, palette entries, and tooltips.
    var displayName: String {
        switch self {
        case .todo:
            return String(localized: "sidebar.status.todo", defaultValue: "Todo")
        case .working:
            return String(localized: "sidebar.status.working", defaultValue: "Working")
        case .needsAttention:
            return String(localized: "sidebar.status.needsAttention", defaultValue: "Needs Attention")
        case .review:
            return String(localized: "sidebar.status.review", defaultValue: "In Review")
        case .done:
            return String(localized: "sidebar.status.done", defaultValue: "Done")
        }
    }
}

// MARK: - Glyph model

/// Pure mapping from a task status to the drawn glyph's shape: how much of
/// the circle is filled, which color role it takes, and whether the
/// checkmark renders. Kept free of SwiftUI so the mapping is unit-testable.
/// Manual-override state surfaces only in the tooltip and the status
/// popover, never as extra glyph decoration.
struct SidebarWorkspaceTaskStatusGlyphModel: Equatable {
    /// Semantic color the view resolves against the row's palette.
    enum ColorRole: Equatable {
        /// Todo: secondary gray outline only.
        case neutral
        /// Working: accent blue.
        case working
        /// Needs attention: the loudest role (orange/red attention accent).
        case attention
        /// In review: green.
        case review
        /// Done: muted gray-green.
        case done
    }

    /// Fraction of the progress pie that is filled, 0...1.
    let fillFraction: Double
    let colorRole: ColorRole
    /// Done renders a checkmark over the filled circle.
    let showsCheckmark: Bool
    let showsDot: Bool // (#cm-110.13)

    init(status: WorkspaceTaskStatus, isNone: Bool = false) { // (#cm-110.13)
        showsDot = isNone // (#cm-110.13)
        if isNone { // (#cm-110.13)
            fillFraction = 0 // (#cm-110.13)
            colorRole = .neutral // (#cm-110.13)
            showsCheckmark = false // (#cm-110.13)
            return // (#cm-110.13)
        } // (#cm-110.13)
        switch status {
        case .todo:
            fillFraction = 0
            colorRole = .neutral
            showsCheckmark = false
        case .working:
            fillFraction = 0.5
            colorRole = .working
            showsCheckmark = false
        case .needsAttention:
            fillFraction = 0.5
            colorRole = .attention
            showsCheckmark = false
        case .review:
            fillFraction = 0.75
            colorRole = .review
            showsCheckmark = false
        case .done:
            fillFraction = 1
            colorRole = .done
            showsCheckmark = true
        }
    }

    /// Localized format strings resolved once, not per render.
    private static let manualTooltipFormat = String(
        localized: "sidebar.status.tooltip.manual",
        defaultValue: "%@ — set manually"
    )
    private static let inferredTooltipFormat = String(
        localized: "sidebar.status.tooltip.inferred",
        defaultValue: "%@ — inferred"
    )

    /// None uses its plain localized name; other statuses include their origin. (#cm-110.13)
    static func tooltip(status: WorkspaceTaskStatus, hasOverride: Bool, name: String? = nil, isNone: Bool = false) -> String { // (#cm-110.13)
        if isNone { return WorkspaceStatusPresentation.noneTitle } // (#cm-110.13)
        return String( // (#cm-110.13)
            format: hasOverride ? manualTooltipFormat : inferredTooltipFormat,
            locale: .current,
            name ?? status.displayName // (#cm-109) his name for the status when the row has one
        )
    }
}

/// Shared row policy: None and a human-set status draw a glyph while controls (#cm-110.13)
/// are on; Auto keeps an empty slot. (#cm-110.13)
struct SidebarWorkspaceManualTaskStatusIndicatorModel: Equatable {
    let featureEnabled: Bool
    let taskStatus: WorkspaceTaskStatus?
    let hasManualOverride: Bool
    var isHidden: Bool = false // (#cm-110.13)

    var isNone: Bool { featureEnabled && isHidden } // (#cm-110.13)

    var showsIndicator: Bool {
        isNone || (featureEnabled && hasManualOverride && taskStatus != nil) // (#cm-110.13)
    }
}

// MARK: - Row status menu

/// The interactive wrapper for sidebar workspace rows on None or a manual (#cm-110.13)
/// status. It keeps the row glyph compact while (#cm-110.13)
/// sending every selection through the shared workspace todo action path.
struct SidebarWorkspaceManualStatusIndicatorMenu: View {
    let status: WorkspaceTaskStatus
    let model: SidebarWorkspaceCompactStatusMenuModel
    let workspaceId: UUID
    let applyTodoStatus: (WorkspaceStatusPickAction, [UUID]) -> Void // (#cm-109)
    let hideTodoStatus: ([UUID]) -> Void
    let usesMonochrome: Bool
    let monochromeColor: Color
    let neutralColor: Color
    let fontScale: CGFloat
    let contrastBackground: NSColor? // (#cm-109.7)
    var drawnAlpha: CGFloat = 1 // (#cm-109.7)

    @State private var isStatusPopoverPresented = false

    /// His name for the status shown, from the picker's checked row; cmux's own name when the picker has none. (#cm-109)
    private var statusName: String {
        if model.isNone { return WorkspaceStatusPresentation.noneTitle } // (#cm-110.13)
        return WorkspaceStatusPresentation.checkedName(in: model.picker) ?? status.displayName // (#cm-110.13)
    }

    /// His entry for the status shown: the picker's checked entry row. `nil` for a status the list leaves out, which
    /// draws today's glyph. (#cm-109.3)
    private var checkedEntry: WorkspaceStatusEntry? {
        WorkspaceStatusPresentation.checkedEntry(in: model.picker)
    }

    private var labelText: String {
        String(localized: "sidebar.status.compactLabel", defaultValue: "Status: \(statusName)")
    }

    var tooltip: String { // (#cm-110.13)
        if model.isNone { return WorkspaceStatusPresentation.noneTitle } // (#cm-110.13)
        return String(localized: "sidebar.status.compactTooltip", defaultValue: "Change workspace status") // (#cm-110.13)
    } // (#cm-110.13)

    var statusGlyph: SidebarWorkspaceTaskStatusGlyph { // (#cm-110.13)
        SidebarWorkspaceTaskStatusGlyph( // (#cm-110.13)
            status: status, // (#cm-110.13)
            hasOverride: !model.isNone, // (#cm-110.13)
            usesMonochrome: usesMonochrome, // (#cm-110.13)
            monochromeColor: monochromeColor, // (#cm-110.13)
            neutralColor: neutralColor, // (#cm-110.13)
            fontScale: fontScale, // (#cm-110.13)
            contrastBackground: contrastBackground, // (#cm-109.7) // (#cm-110.13)
            drawnAlpha: drawnAlpha, // (#cm-109.7) // (#cm-110.13)
            name: statusName, // (#cm-109) // (#cm-110.13)
            icon: checkedEntry?.icon, // (#cm-109.3) // (#cm-110.13)
            colorHex: checkedEntry.flatMap { model.colorHexes[$0.id] }, // (#cm-109.3) // (#cm-110.13)
            isNone: model.isNone // (#cm-110.13)
        ) // (#cm-110.13)
    } // (#cm-110.13)

    var body: some View {
        Button {
            isStatusPopoverPresented.toggle()
        } label: {
            statusGlyph // (#cm-110.13)
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(statusPopoverHost)
        .fixedSize(horizontal: true, vertical: true)
        .safeHelp(tooltip) // (#cm-110.13)
        .accessibilityLabel(labelText)
        .accessibilityIdentifier("SidebarWorkspaceManualStatusIndicatorMenu")
    }

    /// The popover's host; a snapshot with no picker has no popover. (#cm-109)
    @ViewBuilder
    private var statusPopoverHost: some View {
        if let picker = model.picker {
            SidebarWorkspaceTodoPopoverHost(
                isPresented: $isStatusPopoverPresented,
                model: SidebarWorkspaceStatusPopoverModel(
                    inferred: model.inferred,
                    activeOverride: model.activeOverride,
                    picker: picker,
                    colorHexes: model.colorHexes // (#cm-109.3)
                ),
                minWidth: 200,
                maxHeight: 400,
                preferredEdge: .maxY
            ) { model, close in
                SidebarWorkspaceStatusPopover(
                    model: model,
                    onSelectLane: { action in
                        applyTodoStatus(action, [workspaceId])
                    },
                    onSelectNone: {
                        hideTodoStatus([workspaceId])
                    },
                    onClose: close
                )
            }
        }
    }
}

// MARK: - Glyph view

/// The custom-drawn circular progress-pie status glyph shown in the todo
/// pane's header, the status popover's lane rows, and sidebar rows on None or (#cm-110.13)
/// a manual status. None draws a dot; Auto draws no row glyph. Drawn in a fixed-width slot (#cm-110.13)
/// (~9pt base, font-scaled). Modeled on `PullRequestOpenIcon`/
/// `PullRequestMergedIcon` (custom `Path` drawing, caller passes resolved
/// colors; no store access).
struct SidebarWorkspaceTaskStatusGlyph: View {
    let status: WorkspaceTaskStatus
    let hasOverride: Bool
    /// Active (inverted-foreground) rows render monochrome, matching how
    /// `logLevelColor` flattens semantic colors on the selected row.
    let usesMonochrome: Bool
    /// The color used for every part of the glyph in monochrome mode.
    let monochromeColor: Color
    /// The secondary color used for the todo outline.
    let neutralColor: Color
    let fontScale: CGFloat
    let contrastBackground: NSColor? // (#cm-109.7)
    var drawnAlpha: CGFloat = 1 // (#cm-109.7)
    /// His name for the status, for the tooltip; cmux's own name when `nil`. (#cm-109)
    var name: String? = nil
    /// The shape or symbol his entry names, or `nil` to draw the glyph of `status`. (#cm-109.3)
    var icon: WorkspaceStatusGlyph? = nil // (#cm-109.6)
    /// The color the app resolved for his entry, or `nil` to use `status`'s color role. (#cm-109.3)
    var colorHex: String? = nil

    /// None replaces the status, icon and color with the neutral dot. (#cm-110.13)
    var isNone: Bool = false // (#cm-110.13)

    @Environment(\.colorScheme) private var colorScheme

    private static let baseSize: CGFloat = 9
    static let slotWidth: CGFloat = 11 // (#cm-109.6)
    static func symbolCanvasBounds(fontScale: CGFloat) -> CGRect { // (#cm-109.6)
        let side = slotWidth * fontScale // (#cm-109.6)
        return CGRect(x: 0, y: 0, width: side, height: side) // (#cm-109.6)
    } // (#cm-109.6)
    private static let strokeWidth: CGFloat = 1
    private static let attentionStrokeWidth: CGFloat = 1.4

    var model: SidebarWorkspaceTaskStatusGlyphModel { // (#cm-110.13)
        SidebarWorkspaceTaskStatusGlyphModel(status: status, isNone: isNone) // (#cm-110.13)
    }

    /// The color the glyph starts from, before any contrast floor: the same one the AppKit glyph starts from. (#cm-109.7)
    private var baseNSColor: NSColor { // (#cm-109.7)
        var env = EnvironmentValues() // (#cm-109.7)
        env.colorScheme = colorScheme // (#cm-109.7)
        let glyphModel = SidebarRowTaskStatusGlyphButton.Model( // (#cm-109.7)
            status: status, hasOverride: hasOverride, usesMonochrome: usesMonochrome, fontScale: fontScale, // (#cm-109.7)
            colorScheme: colorScheme, colorHex: colorHex, isNone: isNone // (#cm-109.7) // (#cm-110.13)
        ) // (#cm-109.7)
        return SidebarRowTaskStatusGlyphButton.rawBaseColor( // (#cm-109.7)
            model: glyphModel, // (#cm-109.7)
            monochromeColor: NSColor(cgColor: monochromeColor.resolve(in: env).cgColor) ?? (colorScheme == .dark ? .white : .black), // (#cm-109.7)
            neutralColor: NSColor(cgColor: neutralColor.resolve(in: env).cgColor) ?? .secondaryLabelColor // (#cm-109.7)
        ) // (#cm-109.7)
    } // (#cm-109.7)

    /// The fill and tick colors with the contrast floor applied; `nil` where the row passed no background. (#cm-109.7)
    private var flooredColors: (fill: NSColor, tick: NSColor)? { // (#cm-109.7)
        guard let contrastBackground else { return nil } // (#cm-109.7)
        return cmuxFlooredGlyphColors( // (#cm-109.7)
            base: baseNSColor, colorScheme: colorScheme, background: contrastBackground, drawnAlpha: drawnAlpha // (#cm-109.7)
        ) // (#cm-109.7)
    } // (#cm-109.7)

    private var statusColor: Color {
        // (#cm-109.7) His color for the status first, else the status's own role: the color the AppKit glyph starts from,
        // (#cm-109.7) floored to 3:1 against the row where one was passed. Upstream's "Loudest lane" and "Muted gray-green"
        // (#cm-109.7) notes on the attention and done colors now sit on `SidebarRowTaskStatusGlyphButton.rawBaseColor`.
        Color(nsColor: flooredColors?.fill ?? baseNSColor) // (#cm-109.7)
    }

    private var strokeWidth: CGFloat {
        model.colorRole == .attention ? Self.attentionStrokeWidth : Self.strokeWidth
    }

    var body: some View {
        let size = Self.baseSize * fontScale
        glyphBody // (#cm-109.3)
        .frame(width: size, height: size)
        // Fixed-width slot so titles align whether or not the pie is drawn
        // wider by the attention stroke.
        .frame(width: Self.slotWidth * fontScale, alignment: .center)
        .safeHelp(tooltip)
        .accessibilityLabel(tooltip)
    }

    var tooltip: String { // (#cm-110.13)
        SidebarWorkspaceTaskStatusGlyphModel.tooltip(status: status, hasOverride: hasOverride, name: name, isNone: isNone) // (#cm-110.13)
    } // (#cm-110.13)

    /// The drawn shape: a named icon through the one drawing function, in a `Canvas`; otherwise upstream's circle,
    /// pie and checkmark. (#cm-109.3)
    @ViewBuilder
    private var glyphBody: some View {
        if model.showsDot { // (#cm-110.13)
            SidebarStatusNoneShape() // (#cm-110.13)
                .fill(statusColor) // (#cm-110.13)
        } else if let icon { // (#cm-110.13)
            let color = statusColor
            let tick = checkmarkColor
            let size = Self.baseSize * fontScale // (#cm-109.6)
            switch icon { // (#cm-109.6)
            case .shape(let shape): // (#cm-109.6)
                Canvas { context, canvasSize in
                    let environment = context.environment
                    let resolved = color.resolve(in: environment).cgColor
                    let tickResolved = tick.resolve(in: environment).cgColor
                    context.withCGContext { cgContext in
                        WorkspaceStatusIconDrawing.draw(
                            shape, // (#cm-109.6)
                            in: cgContext,
                            box: CGRect(origin: .zero, size: canvasSize),
                            color: resolved,
                            tickColor: tickResolved
                        )
                    }
                }
            case .symbol: // (#cm-109.6)
                if let symbolMask = WorkspaceStatusIconDrawing.symbolMask(for: icon, fontScale: fontScale) { // (#cm-109.6)
                    let slot = Self.slotWidth * fontScale // (#cm-109.6)
                    let canvasBounds = Self.symbolCanvasBounds(fontScale: fontScale) // (#cm-109.6)
                    Color.clear // (#cm-109.6)
                        .frame(width: size, height: size) // (#cm-109.6)
                        .overlay { // (#cm-109.6)
                            Canvas { context, canvasSize in // (#cm-109.6)
                                let resolved = color.resolve(in: context.environment).cgColor // (#cm-109.6)
                                context.withCGContext { cgContext in // (#cm-109.6)
                                    let box = CGRect( // (#cm-109.6)
                                        x: (canvasSize.width - size) / 2, // (#cm-109.6)
                                        y: (canvasSize.height - size) / 2, // (#cm-109.6)
                                        width: size, // (#cm-109.6)
                                        height: size // (#cm-109.6)
                                    ) // (#cm-109.6)
                                    WorkspaceStatusIconDrawing.drawSymbol( // (#cm-109.6)
                                        symbolMask, // (#cm-109.6)
                                        in: cgContext, // (#cm-109.6)
                                        box: box, // (#cm-109.6)
                                        slot: slot, // (#cm-109.6)
                                        color: resolved, // (#cm-109.6)
                                        bounds: CGRect(origin: .zero, size: canvasSize) // (#cm-109.6)
                                    ) // (#cm-109.6)
                                } // (#cm-109.6)
                            } // (#cm-109.6)
                            .frame(width: canvasBounds.width, height: canvasBounds.height) // (#cm-109.6)
                        } // (#cm-109.6)
                } else { // (#cm-109.6)
                    fallbackGlyph // (#cm-109.6)
                } // (#cm-109.6)
            } // (#cm-109.6)
        } else {
            fallbackGlyph // (#cm-109.6)
        }
    }

    @ViewBuilder // (#cm-109.6)
    private var fallbackGlyph: some View { // (#cm-109.6)
        ZStack { // (#cm-109.6)
            Circle() // (#cm-109.6)
                .stroke(statusColor, lineWidth: strokeWidth) // (#cm-109.6)
            if model.fillFraction >= 1 { // (#cm-109.6)
                Circle() // (#cm-109.6)
                    .fill(statusColor) // (#cm-109.6)
            } else if model.fillFraction > 0 { // (#cm-109.6)
                SidebarStatusPieShape(fraction: model.fillFraction) // (#cm-109.6)
                    .fill(statusColor) // (#cm-109.6)
            } // (#cm-109.6)
            if model.showsCheckmark { // (#cm-109.6)
                SidebarStatusCheckmarkShape() // (#cm-109.6)
                    .stroke( // (#cm-109.6)
                        checkmarkColor, // (#cm-109.6)
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round) // (#cm-109.6)
                    ) // (#cm-109.6)
            } // (#cm-109.6)
        } // (#cm-109.6)
    } // (#cm-109.6)

    private var checkmarkColor: Color {
        if usesMonochrome { return Color.black.opacity(0.7) } // (#cm-109.7)
        guard let tick = flooredColors?.tick else { return Color.white } // (#cm-109.7)
        return Color(nsColor: tick) // (#cm-109.7)
    }
}

/// The None dot shares its geometry between the AppKit and SwiftUI glyphs. (#cm-110.13)
struct SidebarStatusNoneShape: Shape { // (#cm-110.13)
    func path(in rect: CGRect) -> Path { // (#cm-110.13)
        var path = Path() // (#cm-110.13)
        let diameter = min(rect.width, rect.height) / 3 // (#cm-110.13)
        path.addEllipse(in: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, // (#cm-110.13)
                                   width: diameter, height: diameter)) // (#cm-110.13)
        return path // (#cm-110.13)
    } // (#cm-110.13)
} // (#cm-110.13)

/// A pie slice from 12 o'clock sweeping clockwise by `fraction` of the circle.
struct SidebarStatusPieShape: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * max(0, min(fraction, 1))),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// A small checkmark centered in the glyph's circle.
struct SidebarStatusCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        path.move(to: CGPoint(x: rect.minX + width * 0.28, y: rect.minY + height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.45, y: rect.minY + height * 0.68))
        path.addLine(to: CGPoint(x: rect.minX + width * 0.74, y: rect.minY + height * 0.34))
        return path
    }
}
