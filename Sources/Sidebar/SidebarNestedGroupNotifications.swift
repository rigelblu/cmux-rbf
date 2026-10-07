import CmuxWorkspaces
import Foundation

/// What a group header's notification commands read and mark in a window that holds a nested group (#cm-106):
/// every workspace inside the group at every level, except the one behind its name, and the commands on a header
/// with no workspace of its own (all but the three single-workspace ones stay available). Each answer is nil, or
/// false for "not handled", in a window with no nested group, so upstream's closures run unchanged there.
@MainActor
struct SidebarNestedGroupNotifications {
    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    let groupId: UUID

    /// The five availability answers; nil in a window with no nested group.
    func state() -> SidebarGroupHeaderRowActions.NotificationState? {
        guard let tabManager, tabManager.workspaces.hasNestedWorkspaceGroup, let notificationStore else { return nil }
        let anchorId = tabManager.workspaceGroupAnchor(for: groupId)?.id
        let memberIds = tabManager.workspaces.workspaceIdsInside(groupId).filter { $0 != anchorId }
        return .init(
            canMarkRead: anchorId.map { notificationStore.canMarkWorkspaceRead(forTabIds: [$0]) } ?? false,
            canMarkUnread: anchorId.map { notificationStore.canMarkWorkspaceUnread(forTabIds: [$0]) } ?? false,
            hasLatestNotifications: anchorId.map { notificationStore.latestNotification(forTabId: $0) != nil } ?? false,
            canMarkAllRead: memberIds.contains { notificationStore.canMarkWorkspaceRead(forTabIds: [$0]) },
            canMarkAllUnread: memberIds.contains { notificationStore.canMarkWorkspaceUnread(forTabIds: [$0]) }
        )
    }

    /// Marks every workspace inside read or unread. Returns whether it handled the command, which it does in a
    /// window with a nested group only.
    func markAll(read: Bool) -> Bool {
        guard let tabManager, tabManager.workspaces.hasNestedWorkspaceGroup, let notificationStore else { return false }
        let anchorId = tabManager.workspaceGroupAnchor(for: groupId)?.id
        for id in tabManager.workspaces.workspaceIdsInside(groupId) where id != anchorId {
            if read {
                if notificationStore.canMarkWorkspaceRead(forTabIds: [id]) { notificationStore.markRead(forTabId: id) }
            } else {
                if notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) { notificationStore.markUnread(forTabId: id) }
            }
        }
        return true
    }
}
