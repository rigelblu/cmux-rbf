public import Foundation

/// One pane in the unread queue: its place and the notification a ⌘⇧U press opens (cm-128.11, moved here by cm-128.13).
public struct UnreadQueueStop: Sendable, Equatable {
    /// The pane: its workspace and surface, or a workspace alone for a workspace-level notification.
    public let target: UnreadQueueTarget
    /// The pane's place: the earliest `queuedAt` among its unread, openable notifications.
    public let queuedAt: Date
    /// The id of that earliest notification, the tie-break between two panes queued at the same time.
    public let tieBreakId: UUID
    /// The pane's newest unread, openable notification: store order is newest first.
    public let newest: NotificationNavSnapshot
    /// Every unread, openable notification of the pane, in the order given.
    public let memberIds: [UUID]
}

/// The one copy of the unread queue's grouping and order (cm-128.13, F2). The walk
/// (``NotificationNavigationCoordinator``) and the store's Send to Back both call it, so the order a press
/// walks is the order a menu sends panes back in.
public enum UnreadQueue {
    /// The queue: unread, openable notifications grouped by pane, oldest `queuedAt` first, ties by
    /// notification id. The stop is the pane, not the workspace (Tom, grill Q92). A notification with no
    /// surface groups by its workspace.
    /// - Parameters:
    ///   - notifications: the notifications in display order (newest first).
    ///   - excludedPane: a pane whose notifications are left out (⌘⌃U's sent-back pane, or the pane he's on when it holds a
    ///     notification he put back), or `nil`.
    ///   - owningPanelId: maps a surface to the panel that owns it (a remote tmux pane's container), asked one side at a time
    ///     (cm-128.13, step 4b R1). The default, a surface owns itself, matches ids as they are.
    public static func stops(
        in notifications: [NotificationNavSnapshot],
        excludingPane excludedPane: UnreadQueueTarget? = nil,
        owningPanelId: (_ workspaceId: UUID, _ surfaceId: UUID) -> UUID = { _, surfaceId in surfaceId } // (cm-128.13)
    ) -> [UnreadQueueStop] {
        struct Key: Hashable { let tabId: UUID; let surfaceId: UUID? }
        var order: [Key] = []
        var members: [Key: [NotificationNavSnapshot]] = [:]
        for notification in notifications
        where notification.isOpenableForJump(excludingNotificationId: nil, excludingWorkspaceId: nil)
            && !notification.isOnPane(excludedPane, owningPanelId: owningPanelId) { // (cm-128.13)
            let key = Key(tabId: notification.tabId, surfaceId: notification.surfaceId)
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(notification)
        }
        return order.compactMap { key -> UnreadQueueStop? in
            guard let group = members[key],
                  let newest = group.first,
                  let earliest = group.min(by: { lhs, rhs in
                      lhs.queuedAt != rhs.queuedAt
                          ? lhs.queuedAt < rhs.queuedAt
                          : lhs.id.uuidString < rhs.id.uuidString
                  }) else { return nil }
            return UnreadQueueStop(
                target: .workspace(tabId: key.tabId, surfaceId: key.surfaceId),
                queuedAt: earliest.queuedAt,
                tieBreakId: earliest.id,
                newest: newest,
                memberIds: group.map(\.id)
            )
        }
        .sorted { lhs, rhs in
            lhs.queuedAt != rhs.queuedAt
                ? lhs.queuedAt < rhs.queuedAt
                : lhs.tieBreakId.uuidString < rhs.tieBreakId.uuidString
        }
    }
}
