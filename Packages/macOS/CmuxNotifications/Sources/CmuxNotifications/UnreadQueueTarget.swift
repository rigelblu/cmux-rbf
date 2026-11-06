/// A pane in ⌘⇧U's unread queue: a workspace pane (or a workspace alone, for a workspace-level
/// notification) or a surface in a window Dock (`cm-128.11`).
///
/// It is ``FocusedNotificationTarget`` under the queue's name. The shape already existed, so the
/// alias gives the queue's callers their own word without a second enum or a rename of the focus type.
public typealias UnreadQueueTarget = FocusedNotificationTarget
