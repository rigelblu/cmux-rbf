import CoreGraphics

/// Geometry for the pane header's empty chrome — the part of the header not
/// covered by a tab or caption, where a click focuses the pane and a drag moves
/// the window in minimal mode.
///
/// Extracted from `TabBarDragZoneView` so both the hit test and the window-drag
/// cursor rects derive from one definition. They must agree: a region that
/// captures clicks without a matching cursor rect focuses the pane while
/// showing no drag affordance, and the reverse shows a drag cursor over dead
/// pixels.
enum TabBarEmptyChromeHitRegion {
    /// Whether `point` lies in the header's empty chrome.
    ///
    /// `includesLeadingSpace` is the caption case. Tabs pack from the leading
    /// edge, so their empty chrome is entirely on the trailing side and the
    /// trailing-only test is exact. A centered caption leaves empty chrome on
    /// both sides, and the leading half is otherwise click-dead.
    static func captures(
        point: CGPoint,
        bounds: CGRect,
        itemFrames: [CGRect],
        reservedTrailingWidth: CGFloat,
        includesLeadingSpace: Bool,
        horizontalSlop: CGFloat
    ) -> Bool {
        let trailingLimit = bounds.maxX - max(0, reservedTrailingWidth)
        guard point.x < trailingLimit else { return false }

        let padded = paddedFrames(itemFrames, horizontalSlop: horizontalSlop)
        guard !padded.contains(where: { $0.contains(point) }) else { return false }
        guard !includesLeadingSpace else { return true }

        return point.x >= (padded.map(\.maxX).max() ?? bounds.minX)
    }

    /// The same region expressed as rects, for window-drag cursor tracking.
    static func cursorRects(
        bounds: CGRect,
        itemFrames: [CGRect],
        reservedTrailingWidth: CGFloat,
        includesLeadingSpace: Bool,
        horizontalSlop: CGFloat
    ) -> [CGRect] {
        let trailingLimit = bounds.maxX - max(0, reservedTrailingWidth)
        guard trailingLimit > bounds.minX else { return [] }

        let padded = paddedFrames(itemFrames, horizontalSlop: horizontalSlop)
        let trailingStart = max(bounds.minX, padded.map(\.maxX).max() ?? bounds.minX)

        var rects: [CGRect] = []
        if includesLeadingSpace {
            let leadingLimit = min(trailingLimit, padded.map(\.minX).min() ?? trailingLimit)
            if leadingLimit > bounds.minX {
                rects.append(CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: leadingLimit - bounds.minX,
                    height: bounds.height
                ))
            }
        }
        if trailingLimit > trailingStart {
            rects.append(CGRect(
                x: trailingStart,
                y: bounds.minY,
                width: trailingLimit - trailingStart,
                height: bounds.height
            ))
        }
        return rects
    }

    private static func paddedFrames(
        _ frames: [CGRect],
        horizontalSlop: CGFloat
    ) -> [CGRect] {
        frames.map { $0.insetBy(dx: -horizontalSlop, dy: -2) }
    }
}
