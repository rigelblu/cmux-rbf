import CmuxSettings
import Foundation

struct SessionNotificationSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var body: String
    var createdAt: TimeInterval
    /// When the notification went unread, its place in ⌘⇧U's queue (cm-128.11, Tom V1). Optional keeps
    /// snapshots written before it compatible: a file without it restores at `createdAt`, and an older build
    /// ignores the key.
    var queuedAt: TimeInterval?
    var isRead: Bool
    var paneFlash: Bool?
    var retargetsToLiveSurfaceOwner: Bool?
    var correlationKey: String?
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    /// Agent/alert identity used if a restored notification is redelivered.
    /// Optional keeps snapshots written before per-agent sounds compatible.
    var soundContext: NotificationSoundOverrideContext?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        queuedAt: TimeInterval? = nil, // (cm-128.11)
        isRead: Bool,
        paneFlash: Bool? = nil,
        retargetsToLiveSurfaceOwner: Bool? = nil,
        correlationKey: String? = nil,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        soundContext: NotificationSoundOverrideContext? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.queuedAt = queuedAt // (cm-128.11)
        self.isRead = isRead
        self.paneFlash = paneFlash
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.correlationKey = correlationKey
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.soundContext = soundContext
    }

    init(notification: TerminalNotification) {
        let persistedScrollPosition = notification.scrollPosition.map {
            TerminalNotificationScrollPosition(row: $0.row, totalRows: $0.totalRows)
        }
        self.init(
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            createdAt: notification.createdAt.timeIntervalSince1970,
            queuedAt: notification.queuedAt.timeIntervalSince1970, // (cm-128.11)
            isRead: notification.isRead,
            paneFlash: notification.paneFlash,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            correlationKey: notification.correlationKey,
            scrollPosition: persistedScrollPosition,
            clickAction: notification.clickAction,
            soundContext: notification.soundContext
        )
    }

    func terminalNotification(tabId: UUID, surfaceId: UUID?, panelId: UUID?) -> TerminalNotification {
        let restoredScrollPosition = scrollPosition.map {
            TerminalNotificationScrollPosition(row: $0.row, totalRows: $0.totalRows)
        }
        return TerminalNotification(
            id: id,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            retargetsToLiveSurfaceOwner: retargetsToLiveSurfaceOwner ?? true,
            correlationKey: correlationKey,
            title: title,
            subtitle: subtitle,
            body: body,
            createdAt: Date(timeIntervalSince1970: createdAt),
            // (cm-128.11) A file saved before `queuedAt` restores at `createdAt`, the init's default for nil.
            queuedAt: queuedAt.map { Date(timeIntervalSince1970: $0) },
            isRead: isRead,
            paneFlash: paneFlash ?? true,
            scrollPosition: restoredScrollPosition,
            clickAction: clickAction,
            soundContext: soundContext
        )
    }
}
