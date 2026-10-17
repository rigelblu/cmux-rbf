import AppKit

extension SidebarGroupHeaderRowActions {
    /// Status headers use the same optional toggle for row click, chevron, and accessibility press.
    func settingStatusHeaderToggle(_ toggle: (@MainActor () -> Void)?) -> Self {
        Self(
            onToggleCollapsed: { toggle?() }, onFocusAnchor: onFocusAnchor, onTapPlus: onTapPlus,
            onRunResolvedItem: onRunResolvedItem, onRename: onRename, onSetColor: onSetColor,
            onPromptCustomColor: onPromptCustomColor, onTogglePinned: onTogglePinned,
            onMarkRead: onMarkRead, onMarkUnread: onMarkUnread, onClearLatestNotifications: onClearLatestNotifications,
            onMarkAllRead: onMarkAllRead, onMarkAllUnread: onMarkAllUnread, onUngroup: onUngroup, onDelete: onDelete,
            onEditConfig: onEditConfig, onOpenDocs: onOpenDocs,
            notificationState: notificationState, onMoveGroup: onMoveGroup, moveMenu: moveMenu
        )
    }
}
