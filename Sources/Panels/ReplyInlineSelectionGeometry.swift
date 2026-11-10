import AppKit
import Foundation

/// Where a selection is, as Ghostty reports it (`ghostty_text_s`). Pixel
/// fields are `-1` when none of the selection is in view.
struct ReplyInlineSelectionGeometry: Equatable {
    /// The whole selection, visible or not.
    let text: String
    /// The first cell's left edge, in logical points.
    let topLeftX: Double
    /// The first row's text **baseline**, not its top. `-1` when no part of
    /// the selection is in view.
    let baselineY: Double
    /// Viewport cell offset (`row × columns + column`) of the top-left cell.
    /// Clamped to the viewport when part is off-screen.
    let offsetStart: Int
    /// Cells from the first selected cell to the bottom-right selected cell
    /// (Ghostty's `offset_len`, which is `end - start`).
    let distanceToBottomRight: Int
}
