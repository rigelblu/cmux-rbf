import AppKit
import Foundation

enum ReplyInlineDismissReason: String, Equatable {
    case reply
    case click
    case key
    case newSelection
    case selectionChanged
    case sidebar
    case pane
    /// The agent exited while the toolbar showed; Reply found no live session.
    case agentGone
    /// `reply.inline.enabled` was turned off while the toolbar showed.
    case setting
}
