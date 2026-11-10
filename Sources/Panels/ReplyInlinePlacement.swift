import CoreGraphics
import Foundation

/// Where the Reply toolbar sits over a pane (`cm-136.1`, Q3 and R4).
///
/// Pure, in points, **top-left origin, measured from the pane's top**: the
/// same space `ReplyInlinePassage.rowTop` and `rowBottom` are in. The caller
/// converts to AppKit's flipped or unflipped space.
enum ReplyInlinePlacement {
    /// The toolbar's minimum size, 76 by 28 points. A longer label widens it;
    /// the pane's width does not (Q3).
    static let toolbarSize = CGSize(width: 76, height: 28)
    /// Space between the toolbar and the row it keeps clear of.
    static let gap: CGFloat = 3

    enum Edge: String, Equatable {
        case above
        case below
        /// No room above or below (the selection fills the pane): inside the
        /// pane at its top edge, over the selection's first rows (R4).
        case paneTop
    }

    struct Result: Equatable {
        let frame: CGRect
        let edge: Edge
    }

    /// - Returns: `nil` when the pane is narrower than the toolbar: no toolbar
    ///   shows, and the selection behaves as it does today (Q3).
    static func frame(
        toolbar: CGSize = toolbarSize,
        rowTop: Double,
        rowBottom: Double,
        anchorX: Double,
        bounds: CGSize
    ) -> Result? {
        guard bounds.width >= toolbar.width else { return nil }
        // Slide along the row to stay inside.
        let x = min(max(CGFloat(anchorX), 0), bounds.width - toolbar.width)

        // Above, unless the room above the first row is shorter than the
        // toolbar plus its gap (31 pt with the defaults).
        if CGFloat(rowTop) >= toolbar.height + gap {
            return Result(
                frame: CGRect(x: x, y: CGFloat(rowTop) - gap - toolbar.height, width: toolbar.width, height: toolbar.height),
                edge: .above
            )
        }
        let belowY = CGFloat(rowBottom) + gap
        if belowY + toolbar.height <= bounds.height {
            return Result(
                frame: CGRect(x: x, y: belowY, width: toolbar.width, height: toolbar.height),
                edge: .below
            )
        }
        return Result(
            frame: CGRect(x: x, y: 0, width: toolbar.width, height: toolbar.height),
            edge: .paneTop
        )
    }
}
