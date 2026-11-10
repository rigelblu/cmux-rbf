import Foundation

/// Something that can send paste events to a terminal pane by its panel id.
/// Production resolves the pane and ends in `TextBoxSubmit.sendEvents`; a test
/// passes a fake that records each `(events, panelID)`.
protocol ReplyInlinePasteTarget {
    /// - Returns: `false`, having sent nothing, when the pane can't be resolved.
    func send(_ events: [TextBoxSubmit.DispatchEvent], toPanel id: UUID) -> Bool
}
