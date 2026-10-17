import AppKit
import CmuxAppKitSupportUI
import CmuxWorkspaces
import SwiftUI

/// Where each part of a status icon goes in a box (#cm-109.3). Pure: an icon and a box go in, numbers come out, so a
/// test can read them without a bitmap. Positions and radii are in points for a 9 pt box, each times the box's scale
/// (its width over 9). The stroke widths and the dash's on length are the same at every scale.
struct WorkspaceStatusIconGeometry: Equatable {
    /// The box the icon sits in, a square whose width is 9 pt times the place's font scale.
    var box: CGRect
    /// The box's width over 9.
    var scale: CGFloat
    /// The ring's center.
    var center: CGPoint
    /// The ring's radius, to the middle of its stroke: 8 pt across at scale 1.
    var ringRadius: CGFloat
    /// The ring's stroke, 1 pt at every scale.
    var ringStroke: CGFloat
    /// For `dotted-ring`: how many dashes the ring is.
    var dashCount: Int?
    /// For `dotted-ring`: the length of a dash, which does not scale.
    var dashOn: CGFloat?
    /// For `dotted-ring`: the gap, the circumference over the count less the dash, so exactly the count fit.
    var dashOff: CGFloat?
    /// For `dotted-ring`: the offset that centers a dash on 12 o'clock when the ring starts there.
    var dashPhase: CGFloat?
    /// For `quarter`, `half`, `three-quarters` and `full`: the disc or wedge's radius.
    var pieRadius: CGFloat?
    /// For those four: the fraction of the circle filled from 12 o'clock, clockwise.
    var pieFraction: Double?
    /// For `check`: the disc that fills the box.
    var checkDisc: CGRect?
    /// For `check`: the tick's three points.
    var tick: [CGPoint]?
    /// For `check`: the tick's stroke, 1.2 pt at every scale.
    var tickStroke: CGFloat?
    /// For `pause`: the two vertical bars inside the ring.
    var pauseBars: [CGRect]? // (#cm-109.3)
}

/// Draws the eight icons and system symbols. One function for every place a status icon appears: the AppKit button, the SwiftUI glyph and
/// the Status menu's image all call it, so no second copy of the shapes exists.
enum WorkspaceStatusIconDrawing {
    /// Positions in points for a 9 pt box.
    static let baseSide: CGFloat = 9
    private static let ringDiameter: CGFloat = 8
    private static let ringStroke: CGFloat = 1
    private static let pieRadius: CGFloat = 2.5
    private static let dashCount = 12
    private static let dashOn: CGFloat = 0.42
    private static let tickStroke: CGFloat = 1.2
    /// Today's tick points from the top left of a 9 pt box (`SidebarStatusCheckmarkShape`'s fractions of 9).
    private static let tickPoints: [CGPoint] = [CGPoint(x: 2.52, y: 4.68), CGPoint(x: 4.05, y: 6.12), CGPoint(x: 6.66, y: 3.06)]

    static func geometry(for icon: WorkspaceStatusIcon, in box: CGRect) -> WorkspaceStatusIconGeometry {
        let scale = box.width / baseSide
        let ringRadius = ringDiameter / 2 * scale
        var geometry = WorkspaceStatusIconGeometry(
            box: box,
            scale: scale,
            center: CGPoint(x: box.midX, y: box.midY),
            ringRadius: ringRadius,
            ringStroke: ringStroke
        )
        switch icon {
        case .ring:
            break
        case .pause: // (#cm-109.3)
            let barWidth = box.width * 0.14 // (#cm-109.3)
            let barHeight = box.height * 0.42 // (#cm-109.3)
            let gap = box.width * 0.14 // (#cm-109.3)
            let top = box.midY - barHeight / 2 // (#cm-109.3)
            let leftX = box.midX - gap / 2 - barWidth // (#cm-109.3)
            let rightX = box.midX + gap / 2 // (#cm-109.3)
            geometry.pauseBars = [ // (#cm-109.3)
                CGRect(x: leftX, y: top, width: barWidth, height: barHeight), // (#cm-109.3)
                CGRect(x: rightX, y: top, width: barWidth, height: barHeight) // (#cm-109.3)
            ] // (#cm-109.3)
        case .dottedRing:
            let circumference = 2 * .pi * ringRadius
            geometry.dashCount = dashCount
            geometry.dashOn = dashOn
            geometry.dashOff = circumference / CGFloat(dashCount) - dashOn
            geometry.dashPhase = dashOn / 2
        case .quarter:
            geometry.pieRadius = pieRadius * scale
            geometry.pieFraction = 0.25
        case .half:
            geometry.pieRadius = pieRadius * scale
            geometry.pieFraction = 0.5
        case .threeQuarters:
            geometry.pieRadius = pieRadius * scale
            geometry.pieFraction = 0.75
        case .full:
            geometry.pieRadius = pieRadius * scale
            geometry.pieFraction = 1
        case .check:
            geometry.checkDisc = box
            geometry.tick = tickPoints.map { CGPoint(x: box.minX + $0.x * scale, y: box.minY + $0.y * scale) }
            geometry.tickStroke = tickStroke
        }
        return geometry
    }

    /// Draws `icon` into a context whose y runs down (a flipped view's, a flipped image's, or a SwiftUI `Canvas`'s).
    /// `color` draws the ring and the fills; `tickColor` draws the check's tick.
    static func draw(
        _ icon: WorkspaceStatusIcon,
        in context: CGContext,
        box: CGRect,
        color: CGColor,
        tickColor: CGColor
    ) {
        let geometry = geometry(for: icon, in: box)
        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(color)
        context.setLineWidth(geometry.ringStroke)
        if let on = geometry.dashOn, let off = geometry.dashOff, let phase = geometry.dashPhase {
            // From 12 o'clock, clockwise: the view runs y down, so `clockwise: false` is clockwise on screen, as in
            // `SidebarRowTaskStatusGlyphButton`'s pie.
            let ring = CGMutablePath()
            ring.addArc(
                center: geometry.center, radius: geometry.ringRadius,
                startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi, clockwise: false
            )
            context.addPath(ring)
            context.setLineCap(.round)
            context.setLineDash(phase: phase, lengths: [on, off])
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
        } else if geometry.checkDisc == nil {
            let side = geometry.ringRadius * 2
            context.strokeEllipse(in: CGRect(
                x: geometry.center.x - geometry.ringRadius, y: geometry.center.y - geometry.ringRadius,
                width: side, height: side
            ))
        }

        if let radius = geometry.pieRadius, let fraction = geometry.pieFraction {
            context.setFillColor(color)
            if fraction >= 1 {
                context.fillEllipse(in: CGRect(
                    x: geometry.center.x - radius, y: geometry.center.y - radius, width: radius * 2, height: radius * 2
                ))
            } else {
                let wedge = CGMutablePath()
                wedge.move(to: geometry.center)
                wedge.addArc(
                    center: geometry.center, radius: radius,
                    startAngle: -.pi / 2, endAngle: -.pi / 2 + 2 * .pi * CGFloat(fraction), clockwise: false
                )
                wedge.closeSubpath()
                context.addPath(wedge)
                context.fillPath()
            }
        }

        if let disc = geometry.checkDisc, let tick = geometry.tick, let tickStroke = geometry.tickStroke {
            context.setFillColor(color)
            context.fillEllipse(in: disc)
            let path = CGMutablePath()
            path.addLines(between: tick)
            context.addPath(path)
            context.setStrokeColor(tickColor)
            context.setLineWidth(tickStroke)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }

        if let bars = geometry.pauseBars { // (#cm-109.3)
            context.setFillColor(color) // (#cm-109.3)
            for bar in bars { // (#cm-109.3)
                context.fill(bar) // (#cm-109.3)
            } // (#cm-109.3)
        } // (#cm-109.3)
    }

    /// Arithmetic for positioning and scaling a symbol in a box (#cm-109.6).
    /// Pure: numbers go in, rect comes out, so a test can read it without a bitmap.
    static func symbolRect(
        inkRect: CGRect,
        imageSize: CGSize,
        box: CGRect,
        slot: CGFloat,
        bounds: CGRect
    ) -> CGRect {
        guard inkRect.width > 0, inkRect.height > 0 else {
            return CGRect(origin: box.origin, size: imageSize)
        }
        let maxInkWidth = min(slot, 2 * max(0, min(box.midX - bounds.minX, bounds.maxX - box.midX)))
        let maxInkHeight = min(slot, 2 * max(0, min(box.midY - bounds.minY, bounds.maxY - box.midY)))
        let scaleX = maxInkWidth / inkRect.width
        let scaleY = maxInkHeight / inkRect.height
        let k = min(1, scaleX, scaleY)
        let w = imageSize.width * k
        let h = imageSize.height * k
        let inkCenter = CGPoint(x: inkRect.midX * k, y: inkRect.midY * k)
        return CGRect(
            x: box.midX - inkCenter.x,
            y: box.midY - inkCenter.y,
            width: w,
            height: h
        )
    }

    private struct MaskCacheKey: Hashable {
        let name: String
        let pointSize: CGFloat
    }

    struct SymbolMask: Sendable {
        let mask: CGImage
        let inkRect: CGRect
        let imageSize: CGSize
    }

    @MainActor
    private static var maskCache: [MaskCacheKey: SymbolMask] = [:]

    static func bitmap2x(of image: NSImage) -> CGImage? {
        let rep2x = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide >= Int(ceil(image.size.width * 2))
        })
        return rep2x?.cgImage ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    @MainActor
    static func maskAndInk(name: String, pointSize: CGFloat) -> SymbolMask? {
        let key = MaskCacheKey(name: name, pointSize: pointSize)
        if let cached = maskCache[key] {
            return cached
        }
        guard let image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: name,
            pointSize: pointSize,
            weight: .regular
        ) else {
            return nil
        }
        guard let cgImage = bitmap2x(of: image) else {
            return nil
        }
        let ink = measureInkRect(cgImage, imageSize: image.size)
        let result = SymbolMask(mask: cgImage, inkRect: ink, imageSize: image.size)
        maskCache[key] = result
        return result
    }

    @MainActor
    static func symbolMask(for icon: WorkspaceStatusGlyph?, fontScale: CGFloat) -> SymbolMask? {
        guard case .symbol(let name) = icon else { return nil }
        return maskAndInk(name: name, pointSize: baseSide * fontScale)
    }

    static func measureInkRect(_ cgImage: CGImage, imageSize: CGSize) -> CGRect {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return .zero }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &data,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .zero }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w
        var minY = h
        var maxX = -1
        var maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        let scale = CGFloat(w) / imageSize.width
        return CGRect(
            x: CGFloat(minX) / scale,
            y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale,
            height: CGFloat(maxY - minY + 1) / scale
        )
    }

    static func drawSymbol(
        _ mask: SymbolMask,
        in context: CGContext,
        box: CGRect,
        slot: CGFloat,
        color: CGColor,
        bounds: CGRect
    ) {
        let r = symbolRect(
            inkRect: mask.inkRect,
            imageSize: mask.imageSize,
            box: box,
            slot: slot,
            bounds: bounds
        )
        context.saveGState()
        context.translateBy(x: 0, y: r.minY + r.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: r, mask: mask.mask)
        context.setFillColor(color)
        context.fill(r)
        context.restoreGState()
    }
}

/// The image the Status menu shows beside a row of his, in both sidebar renderers (#cm-109.3). It takes the dot's
/// place and draws what the AppKit row draws, through the same function.
enum WorkspaceStatusMenuImage {
    /// The glyph's scale in the menu: the popover's, 12 pt for a 9 pt box.
    static let glyphScale: CGFloat = 12.0 / 9.0
    /// The image is two points larger than the 12 pt box, so upstream's 1.4 pt attention stroke on the box's edge falls inside it.
    static let side: CGFloat = 14

    /// Whether a row gets an image: the dot's rule widened to an icon or symbol. A row with a color, or an entry that names an
    /// icon; a row with neither keeps today's look.
    static func shows(icon: WorkspaceStatusGlyph?, colorHex: String?) -> Bool {
        icon != nil || colorHex != nil
    }

    /// The image for a row, drawn under the menu's appearance. The neutral color is resolved here, once, under
    /// `isDark`; the handler resolves nothing.
    @MainActor
    static func make(
        status: WorkspaceTaskStatus,
        icon: WorkspaceStatusGlyph?,
        colorHex: String?,
        isDark: Bool
    ) -> NSImage {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        let menuBackground = WindowAppearanceSnapshot.resolvedColor(
            .windowBackgroundColor,
            for: isDark ? .dark : .light
        )
        let model = SidebarRowTaskStatusGlyphButton.Model(
            status: status,
            hasOverride: false,
            usesMonochrome: false,
            fontScale: glyphScale,
            colorScheme: isDark ? .dark : .light,
            icon: icon,
            colorHex: colorHex,
            contrastBackground: menuBackground
        )
        var neutral = NSColor.secondaryLabelColor
        var color = neutral.cgColor
        appearance?.performAsCurrentDrawingAppearance {
            neutral = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? NSColor.secondaryLabelColor
            color = SidebarRowTaskStatusGlyphButton.statusColor(
                model: model, monochromeColor: neutral, neutralColor: neutral
            ).cgColor
        }
        let tick = SidebarRowTaskStatusGlyphButton.tickColor(model: model, neutralColor: neutral).cgColor
        let symbolMask = WorkspaceStatusIconDrawing.symbolMask(for: icon, fontScale: glyphScale)
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            SidebarRowTaskStatusGlyphButton.drawGlyph(
                model: model,
                symbolMask: symbolMask,
                color: color,
                tickColor: tick,
                in: context,
                bounds: rect
            )
            return true
        }
    }
}
