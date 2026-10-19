import CoreGraphics

/// The shape of a design pane and the direction of its top-level boards.
public enum BoardLayoutOrientation: String, CaseIterable, Sendable {
    /// One column, top to bottom.
    case vertical
    /// One row, left to right.
    case horizontal

    /// Chooses a row for a square or wide pane, otherwise a column.
    /// - Parameter size: The landed pane's size in points.
    public init(size: CGSize) {
        self = size.width >= size.height ? .horizontal : .vertical
    }
}
