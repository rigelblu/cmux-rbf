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
    /// (cm-128.13) A notification he put back with Mark as Unread (`TerminalNotification.isPutBack`). Optional keeps
    /// snapshots written before it compatible: a file without it restores plain unread, and an older build ignores the key.
    var isPutBack: Bool?
    var paneFlash: Bool?
    /// Optional so snapshots written before the flag existed still decode.
    var isAgentEvent: Bool?
    var retargetsToLiveSurfaceOwner: Bool?
    var correlationKey: String?
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    /// Agent/alert identity used if a restored notification is redelivered.
    /// Optional keeps snapshots written before per-agent sounds compatible.
    var soundContext: NotificationSoundOverrideContext?
    var agentKind: String?
    var agentCategory: String?
    var agentSessionId: String?

    init(
        id: UUID,
        title: String,
        subtitle: String,
        body: String,
        createdAt: TimeInterval,
        queuedAt: TimeInterval? = nil, // (cm-128.11)
        isRead: Bool,
        isPutBack: Bool? = nil, // (cm-128.13)
        paneFlash: Bool? = nil,
        isAgentEvent: Bool? = nil,
        retargetsToLiveSurfaceOwner: Bool? = nil,
        correlationKey: String? = nil,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        soundContext: NotificationSoundOverrideContext? = nil,
        agentKind: String? = nil,
        agentCategory: String? = nil,
        agentSessionId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.queuedAt = queuedAt // (cm-128.11)
        self.isRead = isRead
        self.isPutBack = isPutBack // (cm-128.13)
        self.paneFlash = paneFlash
        self.isAgentEvent = isAgentEvent
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.correlationKey = correlationKey
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.soundContext = soundContext
        self.agentKind = agentKind
        self.agentCategory = agentCategory
        self.agentSessionId = agentSessionId
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
            isPutBack: notification.isPutBack ? true : nil, // (cm-128.13) no key for a plain notification
            paneFlash: notification.paneFlash,
            isAgentEvent: notification.isAgentEvent,
            retargetsToLiveSurfaceOwner: notification.retargetsToLiveSurfaceOwner,
            correlationKey: notification.correlationKey,
            scrollPosition: persistedScrollPosition,
            clickAction: notification.clickAction,
            soundContext: notification.soundContext,
            agentKind: notification.agentKind,
            agentCategory: notification.agentCategory,
            agentSessionId: notification.agentSessionId
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
            isPutBack: isPutBack ?? false, // (cm-128.13) a file saved without the key restores plain unread
            // Unknown provenance restores as agent-produced so a legacy
            // banner cannot re-enter the mobile Feed; it stays in the
            // Notifications screen either way.
            isAgentEvent: isAgentEvent ?? true,
            paneFlash: paneFlash ?? true,
            scrollPosition: restoredScrollPosition,
            clickAction: clickAction,
            soundContext: soundContext,
            agentKind: agentKind,
            agentCategory: agentCategory,
            agentSessionId: agentSessionId
        )
    }
}
