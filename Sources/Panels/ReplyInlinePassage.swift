import AppKit
import Foundation

/// The passage the toolbar holds from the release on (Q1): the text as
/// Ghostty gave it, and where it sits.
struct ReplyInlinePassage: Equatable {
    /// The selection exactly as Ghostty gave it.
    let rawText: String
    let sourcePanelID: UUID
    /// Viewport rows the selection covers (clamped to the viewport).
    let topRow: Int
    let bottomRow: Int
    /// Top edge of the first row and bottom edge of the last row, in points
    /// from the pane's top: the edges the toolbar keeps clear of.
    let rowTop: Double
    let rowBottom: Double
    let anchorX: Double
    /// For the cleaner: the pane's columns minus the agent's right margin.
    let wrapColumns: Int
    /// For the cleaner: the column the selection's first cell sits in.
    let firstRowStartColumn: Int
    /// Kept for the dismissal compare (Q4): the selection is unchanged while
    /// these and the text still match what Ghostty reports.
    let offsetStart: Int
    let distanceToBottomRight: Int
}
