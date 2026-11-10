import AppKit
import Foundation

/// What happened to a showing toolbar.
enum ReplyInlineEvent: Equatable {
    /// A mouse-down in the toolbar's window; `onToolbar` when it landed on the
    /// toolbar itself.
    case mouseDown(onToolbar: Bool)
    /// Any key-down in the toolbar's window.
    case keyDown
    /// The selection compare while shown: what Ghostty reports now (`nil`: none).
    case selectionChecked(ReplyInlineSelectionGeometry?)
    /// The window's sidebar changed; whether it now shows Reply.
    case sidebarChanged(showingReply: Bool)
    case paneClosed
}
