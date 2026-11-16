import CmuxNotifications
import CmuxSettings
import Foundation

struct TerminalNotification: Identifiable, Hashable, Sendable {
    let id: UUID
    let tabId: UUID
    let surfaceId: UUID?
    let panelId: UUID?
    let retargetsToLiveSurfaceOwner: Bool
    let correlationKey: String?
    let title: String
    let subtitle: String
    let body: String
    let createdAt: Date
    /// When the notification went unread: its pane's place in ⌘⇧U's queue, oldest first (cm-128.11, Tom V1).
    /// Set to `createdAt` when recorded; a newer notification on the pane inherits the earliest of the
    /// unread ones it replaces. Reading and Mark as Unread leave it; only Send to Back sets it to now.
    var queuedAt: Date
    var isRead: Bool
    /// (cm-128.13) Set when Mark as Unread turned this notification unread: his own mark, with a place in the queue.
    /// It looks like his dot and no displayed number counts it, and it survives what his dot survives. Cleared by
    /// every read that does not keep it, and by Send to Back; a removal takes it with the notification.
    var isPutBack: Bool = false
    var paneFlash: Bool = true
    var scrollPosition: TerminalNotificationScrollPosition?
    var clickAction: TerminalNotificationClickAction?
    var replyShape: TerminalNotificationReplyShape = .none
    var soundContext: NotificationSoundOverrideContext?
    /// Who emitted the text. Remote origins are clamped to display-only side effects by
    /// the store and surface to hooks as `CMUX_NOTIFICATION_ORIGIN`.
    var origin: TerminalNotificationOrigin = .local

    init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        retargetsToLiveSurfaceOwner: Bool = true,
        correlationKey: String? = nil,
        title: String,
        subtitle: String,
        body: String,
        createdAt: Date,
        queuedAt: Date? = nil,
        isRead: Bool,
        isPutBack: Bool = false, // (cm-128.13)
        paneFlash: Bool = true,
        scrollPosition: TerminalNotificationScrollPosition? = nil,
        clickAction: TerminalNotificationClickAction? = nil,
        replyShape: TerminalNotificationReplyShape = .none,
        soundContext: NotificationSoundOverrideContext? = nil,
        origin: TerminalNotificationOrigin = .local
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.panelId = panelId
        self.retargetsToLiveSurfaceOwner = retargetsToLiveSurfaceOwner
        self.correlationKey = correlationKey
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.createdAt = createdAt
        self.queuedAt = queuedAt ?? createdAt
        self.isRead = isRead
        self.isPutBack = isPutBack // (cm-128.13)
        self.paneFlash = paneFlash
        self.scrollPosition = scrollPosition
        self.clickAction = clickAction
        self.replyShape = replyShape
        self.soundContext = soundContext
        self.origin = origin
    }

    func matches(tabId targetTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard tabId == targetTabId else { return false }
        guard let targetSurfaceId else {
            return surfaceId == nil && panelId == nil
        }
        return surfaceId == targetSurfaceId || panelId == targetSurfaceId
    }

    /// Matches a clear without letting live-owner expansion cross a confined notification's workspace boundary.
    func matchesClear(tabId targetTabId: UUID, liveTabId: UUID, surfaceId targetSurfaceId: UUID?) -> Bool {
        guard let targetSurfaceId else {
            let matchesWorkspace = tabId == targetTabId || (retargetsToLiveSurfaceOwner && tabId == liveTabId)
            return matchesWorkspace && surfaceId == nil && panelId == nil
        }
        guard surfaceId == targetSurfaceId || panelId == targetSurfaceId else {
            return false
        }
        // A retargetable notification is owned by the globally unique surface,
        // not by the workspace in which it happened to be stored when it was
        // delivered. This lets a completion clear a banner that was recorded
        // under the pane's previous workspace after a move.
        return retargetsToLiveSurfaceOwner || tabId == targetTabId
    }
}
