import CmuxNotifications
import CmuxSettings
import Foundation

/// Owns the ephemeral record-to-banner handoff for unread completion reminders.
@MainActor
final class AgentUnattendedNudgeDelivery {
    private weak var store: TerminalNotificationStore?
    private let isPresent: @MainActor () -> Bool
    private var scheduler: AgentUnattendedNudgeScheduler?
    private var contexts: [UUID: (title: String, effects: TerminalNotificationPolicyEffects)] = [:]

    init<C: Clock>(store: TerminalNotificationStore, clock: C,
                   isPresent: @escaping @MainActor () -> Bool = { MacPresenceMonitor.live().evaluate().isActive }) where C.Duration == Duration {
        self.store = store
        self.isPresent = isPresent
        self.scheduler = AgentUnattendedNudgeScheduler(clock: clock, state: { [weak self] id in
            guard let self, let store = self.store else {
                return .init(enabled: false, exists: false, unread: false, focusedInFrontmostApp: false, present: false)
            }
            return store.unattendedNudgeState(notificationID: id, present: self.isPresent())
        }, notify: { [weak self] id in self?.fire(notificationID: id) })
    }

    func record(_ notification: TerminalNotification, title: String?, effects: TerminalNotificationPolicyEffects) {
        guard let title, let scheduler,
              scheduler.arm(notificationID: notification.id, pendingWork: false, promptTurn: false) else { return }
        contexts[notification.id] = (title, effects)
    }

    func reconcile(notifications: [TerminalNotification]) {
        let unread = Set(notifications.lazy.filter { !$0.isRead }.map(\.id))
        for id in Array(contexts.keys) where !unread.contains(id) {
            contexts.removeValue(forKey: id)
            scheduler?.cancel(notificationID: id)
        }
    }

    func settingsDidChange() {
        guard !NotificationsCatalogSection().agentIdleReminder.value(in: .standard) else { return }
        contexts.removeAll()
        scheduler?.cancelAll()
    }

    private func fire(notificationID: UUID) {
        guard let context = contexts[notificationID], let store,
              let original = store.notifications.first(where: { $0.id == notificationID }),
              store.isUnreadNudgeAdmitted(notificationID: notificationID) else { return }
        var effects = TerminalNotificationPolicyEffects.allSuppressed
        effects.desktop = context.effects.desktop
        effects.sound = context.effects.sound
        let request = TerminalNotificationPolicyRequest(
            tabId: original.tabId, surfaceId: original.surfaceId, panelId: original.panelId,
            retargetsToLiveSurfaceOwner: original.retargetsToLiveSurfaceOwner,
            correlationKey: original.correlationKey, title: context.title, subtitle: original.subtitle,
            body: original.body, replyShape: original.replyShape, cwd: nil,
            isAppFocused: false, isFocusedPanel: false,
            soundContext: original.soundContext.flatMap { .init(agentID: $0.agentID, alertType: .turnDone) },
            origin: original.origin)
        _ = store.applyNotification(request: request, effects: effects, now: original.createdAt,
            cooldownReservation: nil, scrollPosition: original.scrollPosition, clickAction: original.clickAction,
            notificationID: original.id, isUnattendedNudge: true)
    }
}
