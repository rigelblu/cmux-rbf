import AppKit

/// Template versions of the auto-layout column and row glyphs used in the approved header design.
struct BoardLayoutGlyph {
    static func image(_ orientation: BoardLayoutOrientation, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let path = NSBezierPath()
            path.lineWidth = size / 12
            let scale = size / 12
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }
            if orientation == .vertical {
                for y: CGFloat in [1.5, 7.5] {
                    path.appendRect(NSRect(x: 1 * scale, y: y * scale, width: 3 * scale, height: 3 * scale))
                }
                path.move(to: point(8.5, 1)); path.line(to: point(8.5, 10.5))
                path.move(to: point(6.5, 8.5)); path.line(to: point(8.5, 10.5)); path.line(to: point(10.5, 8.5))
            } else {
                for x: CGFloat in [1.5, 7.5] {
                    path.appendRect(NSRect(x: x * scale, y: 1 * scale, width: 3 * scale, height: 3 * scale))
                }
                path.move(to: point(1, 8.5)); path.line(to: point(10.5, 8.5))
                path.move(to: point(8.5, 6.5)); path.line(to: point(10.5, 8.5)); path.line(to: point(8.5, 10.5))
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
