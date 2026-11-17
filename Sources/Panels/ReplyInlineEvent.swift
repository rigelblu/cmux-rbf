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
    /// The destination the toolbar's button names changed; `destination` is
    /// its value now.
    case destinationChanged(ReplyInlineDestination)
    case paneClosed
    /// `reply.inline.enabled` changed; `enabled` is its value now.
    case settingChanged(enabled: Bool)
}
