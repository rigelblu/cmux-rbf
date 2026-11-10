import AppKit
import Foundation

/// Whether an event takes a showing toolbar away, and why.
///
/// The toolbar goes when its selection is cleared or changes, on any click or
/// key, and when the label it was read for stops being true (R2). Everything
/// else leaves it. A click on the toolbar is not a dismissal: it is Reply.
enum ReplyInlineDismissal {
    static func reason(
        for event: ReplyInlineEvent,
        passage: ReplyInlinePassage,
        sidebarShowingReplyAtShow: Bool
    ) -> ReplyInlineDismissReason? {
        switch event {
        case .mouseDown(let onToolbar):
            return onToolbar ? nil : .click
        case .keyDown:
            return .key
        case .selectionChecked(let current):
            guard let current,
                  current.baselineY >= 0,
                  current.offsetStart == passage.offsetStart,
                  current.distanceToBottomRight == passage.distanceToBottomRight,
                  current.text == passage.rawText
            else { return .selectionChanged }
            return nil
        case .sidebarChanged(let showingReply):
            return showingReply == sidebarShowingReplyAtShow ? nil : .sidebar
        case .paneClosed:
            return .pane
        }
    }
}
