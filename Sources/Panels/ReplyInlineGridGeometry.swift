import AppKit
import Foundation

/// The pane's grid, in logical points, top-left origin.
struct ReplyInlineGridGeometry: Equatable {
    let columns: Int
    let cellHeight: Double
    let paddingTop: Double
}
