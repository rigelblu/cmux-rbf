import CoreGraphics

/// Computes pair geometry from the displayed pair model, without reading the hidden split tree.
public struct PairPaneGeometry {
    /// Size of the second pane in points.
    public let secondSize: CGSize

    /// Resolves the divider using the same minimums and fraction bounds as the native split.
    /// - Parameters:
    ///   - container: The pair's available rectangle size.
    ///   - orientation: The pair's pane arrangement.
    ///   - dividerPosition: The first pane's fraction of the available axis.
    ///   - imposedFirstExtent: An authoritative first-pane extent, if set.
    ///   - dividerThickness: The visible divider thickness.
    ///   - minimumExtent: The configured minimum size along the split axis.
    ///   - dividerRange: The configured allowed fraction range.
    public init(container: CGSize, orientation: SplitOrientation, dividerPosition: CGFloat,
                imposedFirstExtent: CGFloat?, dividerThickness: CGFloat,
                minimumExtent: CGFloat, dividerRange: ClosedRange<CGFloat>) {
        let axis = orientation == .horizontal ? container.width : container.height
        let available = max(0, axis - dividerThickness)
        let minimum = min(max(1, minimumExtent), available / 2)
        let fraction = available > 0 ? min(0.5, minimum / available) : 0
        let lower = max(fraction, dividerRange.lowerBound)
        let upper = min(1 - fraction, dividerRange.upperBound)
        let middle = min(max(0.5, dividerRange.lowerBound), dividerRange.upperBound)
        let bounds = lower <= upper ? lower...upper : middle...middle
        let proposed = imposedFirstExtent ?? available * dividerPosition
        let first = min(max(proposed, available * bounds.lowerBound), available * bounds.upperBound)
        let second = max(0, available - first)
        secondSize = orientation == .horizontal
            ? CGSize(width: second, height: container.height)
            : CGSize(width: container.width, height: second)
    }
}
