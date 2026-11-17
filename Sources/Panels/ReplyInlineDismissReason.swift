import AppKit
import Foundation

enum ReplyInlineDismissReason: String, Equatable {
    case reply
    case click
    case key
    case newSelection
    case selectionChanged
    /// The destination the button names changed: the sidebar, the panel's
    /// binding, or the reply it follows (`Reply` ⇄ `Add to reply`).
    case destination
    /// The click that adds the passage to the reply in the panel.
    case add
    case pane
    /// The agent exited while the toolbar showed; Reply found no live session.
    case agentGone
    /// `reply.inline.enabled` was turned off while the toolbar showed.
    case setting
}
