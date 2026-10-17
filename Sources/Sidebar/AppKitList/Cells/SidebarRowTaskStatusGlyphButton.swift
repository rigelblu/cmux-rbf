import AppKit
import CmuxAppKitSupportUI // (#cm-109.7)
import CmuxWorkspaces
import SwiftUI

// MARK: - Manual status glyph

/// Pure-AppKit port of `SidebarWorkspaceTaskStatusGlyph` for the row's title
/// line: circle outline + progress pie + Done checkmark, drawn with the exact
/// SwiftUI geometry (9pt base circle in an 11pt slot, both font-scaled,
/// 1pt stroke / 1.4pt for attention, checkmark stroke 1.2 round). The control
/// frame adds the legacy button's 2pt padding on every edge.
@MainActor
final class SidebarRowTaskStatusGlyphButton: NSControl {
    struct Model: Equatable {
        let status: WorkspaceTaskStatus
        let hasOverride: Bool
        let usesMonochrome: Bool
        let fontScale: CGFloat
        let colorScheme: ColorScheme
        /// His name for the status, for the label and tooltip; cmux's own name when `nil`. (#cm-109)
        var name: String? = nil
        /// The shape or symbol his entry names, or `nil` to draw the glyph of `status`. (#cm-109.3)
        var icon: WorkspaceStatusGlyph? = nil // (#cm-109.6)
        /// The color the app resolved for his entry, or `nil` to use `status`'s color role. (#cm-109.3)
        var colorHex: String? = nil
        /// What the glyph sits on, opaque, so the color can be floored to 3:1 against it; `nil` leaves the color as it was. (#cm-109.7)
        var contrastBackground: NSColor? = nil // (#cm-109.7)
        /// The alpha the row draws its content at (Done dims it), which the floor measures at. (#cm-109.7)
        var drawnAlpha: CGFloat = 1 // (#cm-109.7)
    }

    private nonisolated static let baseSize: CGFloat = 9 // (#cm-109.3)
    private nonisolated static let slotWidth: CGFloat = 11 // (#cm-109.6)
    private nonisolated static let strokeWidth: CGFloat = 1 // (#cm-109.3)
    private nonisolated static let attentionStrokeWidth: CGFloat = 1.4 // (#cm-109.3)
    private static let padding: CGFloat = 2

    var onClick: (() -> Void)?
    private var model: Model?
    var currentModelForTesting: Model? { model } // (#cm-109.7)
    private var monochromeColor: NSColor = .secondaryLabelColor
    private var neutralColor: NSColor = .secondaryLabelColor

    override var isFlipped: Bool { true }

    func configure(model: Model, monochromeColor: NSColor, neutralColor: NSColor) {
        let changed = self.model != model
            || self.monochromeColor != monochromeColor
            || self.neutralColor != neutralColor
        self.model = model
        self.monochromeColor = monochromeColor
        self.neutralColor = neutralColor
        toolTip = SidebarWorkspaceTaskStatusGlyphModel.tooltip(
            status: model.status,
            hasOverride: model.hasOverride,
            name: model.name
        )
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            localized: "sidebar.status.compactLabel",
            defaultValue: "Status: \(model.name ?? model.status.displayName)"
        ))
        setAccessibilityIdentifier("SidebarWorkspaceManualStatusIndicatorMenu")
        if changed {
            needsDisplay = true
        }
    }

    /// The control's occupied size: the fixed-width slot plus 2pt padding
    /// (legacy: `.frame(width: slotWidth * fontScale)` + `.padding(2)`).
    static func occupiedSize(fontScale: CGFloat) -> NSSize {
        NSSize(
            width: slotWidth * fontScale + padding * 2,
            height: baseSize * fontScale + padding * 2
        )
    }

    /// (#cm-109.7) The color the glyph starts from, before any contrast floor: the one color in one-color mode, else his
    /// color for the status, else `status`'s own role. The SwiftUI glyph reads this too, so the two draw the same color. (#cm-109.7)
    static func rawBaseColor(model: Model, monochromeColor: NSColor, neutralColor: NSColor) -> NSColor { // (#cm-109.7)
        if model.usesMonochrome { return monochromeColor } // (#cm-109.7)
        if let hex = model.colorHex, // (#cm-109.7)
           let color = WorkspaceTabColorSettings.displayNSColor(hex: hex, colorScheme: model.colorScheme, forceBright: false) { // (#cm-109.7)
            return color // (#cm-109.7)
        } // (#cm-109.7)
        switch SidebarWorkspaceTaskStatusGlyphModel(status: model.status).colorRole { // (#cm-109.7)
        case .neutral: // (#cm-109.7)
            return neutralColor // (#cm-109.7)
        case .working: // (#cm-109.7)
            return cmuxAccentNSColor(for: model.colorScheme) // (#cm-109.7)
        case .attention: // (#cm-109.7)
            // (#cm-109.7) Loudest lane: full-strength attention accent between orange and red.
            return NSColor(srgbRed: 1.0, green: 0.42, blue: 0.2, alpha: 1) // (#cm-109.7)
        case .review: // (#cm-109.7)
            return .systemGreen // (#cm-109.7)
        case .done: // (#cm-109.7)
            // (#cm-109.7) Muted gray-green so finished rows read as settled, not celebratory.
            return NSColor(srgbRed: 0.45, green: 0.62, blue: 0.5, alpha: 1) // (#cm-109.7)
        } // (#cm-109.7)
    } // (#cm-109.7)

    /// The color a glyph draws in: the one color while `usesMonochrome` is on, else his color for the status, as the
    /// Status menu's dot has it worked out (as stored in Light, brightened in Dark), else `status`'s own role. (#cm-109.3)
    /// (#cm-109.7) With a `contrastBackground` the result is an opaque color that reaches 3:1 against it as drawn at
    /// `drawnAlpha`; without one it is the color as it was. (#cm-109.7)
    static func statusColor(model: Model, monochromeColor: NSColor, neutralColor: NSColor) -> NSColor {
        let baseColor = rawBaseColor(model: model, monochromeColor: monochromeColor, neutralColor: neutralColor) // (#cm-109.7)
        guard let contrastBackground = model.contrastBackground else { return baseColor } // (#cm-109.7)
        return cmuxFlooredGlyphColors( // (#cm-109.7)
            base: baseColor, colorScheme: model.colorScheme, background: contrastBackground, drawnAlpha: model.drawnAlpha // (#cm-109.7)
        ).fill // (#cm-109.7)
    }

    /// (#cm-109.3) The check's tick: black at 0.7 in the one-color mode; else white.
    /// (#cm-109.7) Where the contrast floor brightened the fill it is the row's own color, so the tick stays readable on
    /// it. `neutralColor` is the button's own, as for the fill. (#cm-109.7)
    static func tickColor(model: Model, neutralColor: NSColor = .secondaryLabelColor) -> NSColor { // (#cm-109.3)
        if model.usesMonochrome { return NSColor.black.withAlphaComponent(0.7) } // (#cm-109.3)
        guard let contrastBackground = model.contrastBackground else { return .white } // (#cm-109.7)
        return cmuxFlooredGlyphColors( // (#cm-109.7)
            base: rawBaseColor(model: model, monochromeColor: .white, neutralColor: neutralColor), // (#cm-109.7)
            colorScheme: model.colorScheme, background: contrastBackground, drawnAlpha: model.drawnAlpha // (#cm-109.7)
        ).tick // (#cm-109.7)
    } // (#cm-109.3)

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let symbolMask = WorkspaceStatusIconDrawing.symbolMask(for: model.icon, fontScale: model.fontScale) // (#cm-109.6)
        Self.drawGlyph(
            model: model,
            symbolMask: symbolMask, // (#cm-109.6)
            color: Self.statusColor(model: model, monochromeColor: monochromeColor, neutralColor: neutralColor).cgColor,
            tickColor: Self.tickColor(model: model, neutralColor: neutralColor).cgColor, // (#cm-109.7)
            in: context,
            bounds: bounds
        )
    }

    /// Draws the glyph centered in `bounds`, into a context whose y runs down. The body of `draw`, as a function of a
    /// context, a rect and the model, so the Status menu's image draws what the row draws. (#cm-109.3)
    nonisolated static func drawGlyph( // (#cm-109.3)
        model: Model,
        symbolMask: WorkspaceStatusIconDrawing.SymbolMask? = nil, // (#cm-109.6)
        color: CGColor,
        tickColor: CGColor,
        in context: CGContext,
        bounds: CGRect
    ) {
        let size = baseSize * model.fontScale
        let circleRect = CGRect(
            x: (bounds.width - size) / 2,
            y: (bounds.height - size) / 2,
            width: size,
            height: size
        )
        // (#cm-109.3) A named icon draws its own shape; a symbol draws its mask; anything else draws upstream's, below. (#cm-109.6)
        if let icon = model.icon { // (#cm-109.3)
            switch icon { // (#cm-109.6)
            case .shape(let shape): // (#cm-109.6)
                WorkspaceStatusIconDrawing.draw(shape, in: context, box: circleRect, color: color, tickColor: tickColor) // (#cm-109.6)
                return // (#cm-109.6)
            case .symbol: // (#cm-109.6)
                if let symbolMask { // (#cm-109.6)
                    let slot = slotWidth * model.fontScale // (#cm-109.6)
                    WorkspaceStatusIconDrawing.drawSymbol( // (#cm-109.6)
                        symbolMask, // (#cm-109.6)
                        in: context, // (#cm-109.6)
                        box: circleRect, // (#cm-109.6)
                        slot: slot, // (#cm-109.6)
                        color: color, // (#cm-109.6)
                        bounds: bounds // (#cm-109.6)
                    ) // (#cm-109.6)
                    return // (#cm-109.6)
                } // (#cm-109.6)
            } // (#cm-109.6)
        } // (#cm-109.3)
        let glyph = SidebarWorkspaceTaskStatusGlyphModel(status: model.status)
        let strokeWidth = glyph.colorRole == .attention ? attentionStrokeWidth : Self.strokeWidth

        context.setStrokeColor(color)
        context.setLineWidth(strokeWidth)
        context.strokeEllipse(in: circleRect)

        if glyph.fillFraction >= 1 {
            context.setFillColor(color)
            context.fillEllipse(in: circleRect)
        } else if glyph.fillFraction > 0 {
            // Same math as `SidebarStatusPieShape` (the view is flipped, so
            // SwiftUI's y-down arc renders identically): 12 o'clock sweeping
            // clockwise by `fillFraction` of the circle.
            let center = CGPoint(x: circleRect.midX, y: circleRect.midY)
            let radius = min(circleRect.width, circleRect.height) / 2
            let path = CGMutablePath()
            path.move(to: center)
            path.addArc(
                center: center,
                radius: radius,
                startAngle: -.pi / 2,
                endAngle: -.pi / 2 + 2 * .pi * max(0, min(glyph.fillFraction, 1)),
                clockwise: false
            )
            path.closeSubpath()
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        }

        if glyph.showsCheckmark {
            // `SidebarStatusCheckmarkShape` point fractions in the circle rect.
            let checkmark = CGMutablePath()
            checkmark.move(to: CGPoint(
                x: circleRect.minX + circleRect.width * 0.28,
                y: circleRect.minY + circleRect.height * 0.52
            ))
            checkmark.addLine(to: CGPoint(
                x: circleRect.minX + circleRect.width * 0.45,
                y: circleRect.minY + circleRect.height * 0.68
            ))
            checkmark.addLine(to: CGPoint(
                x: circleRect.minX + circleRect.width * 0.74,
                y: circleRect.minY + circleRect.height * 0.34
            ))
            context.addPath(checkmark)
            context.setStrokeColor(tickColor) // (#cm-109.3)
            context.setLineWidth(1.2)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow so the table row action does not also fire (legacy: the
        // glyph Button consumes the click without selecting the row), and
        // dim while pressed like a SwiftUI plain Button.
        alphaValue = SidebarRowPressedDim.pressedAlpha
    }

    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onClick?()
    }

    /// VoiceOver/keyboard activation parity with the legacy SwiftUI Button.
    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }
}
