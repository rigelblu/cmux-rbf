import Foundation

enum NotificationFeedHistoryMutation: Sendable {
    case record(NotificationFeedHistoryRecord, supersededIDs: Set<UUID>)
    case reconcileActive([NotificationFeedHistoryRecord])
    case markReadIDs(Set<UUID>)
    case markReadWorkspace(UUID, skipping: Set<UUID>) // (cm-128.13) a put-back notification's record stays unread
    case markReadSurface(tabId: UUID, surfaceId: UUID?, skipping: Set<UUID>)
    case markAllRead
    case markUnreadIDs(Set<UUID>)
    case rebindSurface(sourceTabId: UUID, destinationTabId: UUID, surfaceId: UUID)
}
